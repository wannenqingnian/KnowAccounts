import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/payment_discount_parser.dart';

class LegacyBackupDatabase extends AppDatabase {
  LegacyBackupDatabase() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 16;
}

Future<void> saveDiscountedExpense(LedgerRepository repository) async {
  await repository.initialize();
  final account = (await repository.accounts('personal')).first;
  final category = (await repository.categories(
    'personal',
  )).firstWhere((value) => value.type == TransactionType.expense);
  await repository.save(
    'personal',
    TransactionInput(
      type: TransactionType.expense,
      amountMinor: 3850,
      discountMinor: 350,
      accountId: account.id,
      categoryId: category.id,
      merchant: '测试商户',
      occurredDate: DateTime(2026, 10, 21, 12),
    ),
  );
}

Future<void> expectPaidAmountOnly(
  LedgerRepository repository,
  int? discount,
) async {
  final entry = (await repository.entries('personal')).single;
  expect(entry.amountMinor, 3850);
  expect(entry.discountMinor, discount);
  final account = (await repository.accounts(
    'personal',
  )).singleWhere((value) => value.id == entry.accountId);
  expect(account.balanceMinor, -3850);
  final summary = await repository.summary('personal', DateTime(2026, 10));
  expect(summary.expenseMinor, 3850);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  test('all requested discount labels remain separate from payment', () {
    for (final label in [
      '已优惠',
      '共优惠',
      '优惠金额',
      '优惠',
      '立减',
      '随机立减',
      '碰一下支付立减',
      '支付立减',
    ]) {
      expect(
        PaymentDiscountParser.parse('$label ¥3.50', paidMinor: 3850)?.minor,
        350,
        reason: label,
      );
    }
    expect(PaymentDiscountParser.parse('优惠 8.5折\n优惠券'), isNull);
    expect(
      PaymentDiscountParser.parse('满100减20', paidMinor: 8000)?.minor,
      2000,
    );
  });

  test(
    'v16 migration keeps transactions, balances and statistics unchanged',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ledger-discount-v17-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/ledger.sqlite');
      final legacy = AppDatabase(NativeDatabase(file));
      try {
        await saveDiscountedExpense(LedgerRepository(legacy));
        await legacy.customStatement(
          'ALTER TABLE transactions DROP COLUMN discount_minor',
        );
        await legacy.customStatement('PRAGMA user_version=16');
      } finally {
        await legacy.close();
      }
      final upgraded = AppDatabase(NativeDatabase(file));
      try {
        await expectPaidAmountOnly(LedgerRepository(upgraded), null);
        final version = await upgraded
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.read<int>('user_version'), 17);
      } finally {
        await upgraded.close();
      }
    },
  );

  test('v16 encrypted backup fills missing discount with null', () async {
    final legacy = LegacyBackupDatabase();
    final target = AppDatabase.memory();
    try {
      await saveDiscountedExpense(LedgerRepository(legacy));
      await legacy.customStatement(
        'ALTER TABLE transactions DROP COLUMN discount_minor',
      );
      final backup = await BackupService(
        legacy,
      ).export('discount-test-password');
      await LedgerRepository(target).initialize();
      await BackupService(target).restore(backup, 'discount-test-password');
      await expectPaidAmountOnly(LedgerRepository(target), null);
    } finally {
      await legacy.close();
      await target.close();
    }
  });

  test(
    'v17 encrypted backup preserves discount without subtracting it again',
    () async {
      final source = AppDatabase.memory();
      final target = AppDatabase.memory();
      try {
        await saveDiscountedExpense(LedgerRepository(source));
        await expectPaidAmountOnly(LedgerRepository(source), 350);
        final backup = await BackupService(
          source,
        ).export('discount-test-password');
        await LedgerRepository(target).initialize();
        await BackupService(target).restore(backup, 'discount-test-password');
        await expectPaidAmountOnly(LedgerRepository(target), 350);
      } finally {
        await source.close();
        await target.close();
      }
    },
  );
}
