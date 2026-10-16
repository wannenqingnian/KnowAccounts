import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/data/budget_repository.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  // Each database owns a separate executor, including the restore staging database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase source;
  late AppDatabase target;
  late LedgerRepository sourceRepo;
  late LedgerRepository targetRepo;
  const password = 'test-password-2026';
  setUp(() async {
    source = AppDatabase.memory();
    target = AppDatabase.memory();
    sourceRepo = LedgerRepository(source);
    targetRepo = LedgerRepository(target);
    await sourceRepo.initialize();
    await targetRepo.initialize();
    final account = (await sourceRepo.accounts('personal')).first;
    final category = (await sourceRepo.categories('personal')).first;
    await sourceRepo.save(
      'personal',
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: 3850,
        accountId: account.id,
        categoryId: category.id,
        merchant: '瑞幸',
        occurredDate: DateTime(2026, 10, 5),
      ),
    );
  });
  tearDown(() async {
    await source.close();
    await target.close();
  });

  test(
    'encrypted round-trip restores all ledgers and preserves local device identity',
    () async {
      await sourceRepo.createLedger('旅行');
      await sourceRepo.setBudget('personal', DateTime(2026, 10), 800000);
      final originalDevice =
          (await target
                  .customSelect(
                    "SELECT value FROM settings WHERE key = 'device_id'",
                  )
                  .get())
              .single
              .read<String>('value');
      final bytes = await BackupService(source).export(password);
      expect(utf8.decode(bytes).contains('瑞幸'), isFalse);
      await BackupService(target).restore(bytes, password);
      expect((await targetRepo.entries('personal')).single.amountMinor, 3850);
      expect((await targetRepo.accounts('personal')).first.balanceMinor, -3850);
      expect((await targetRepo.ledgers()).values, contains('旅行'));
      expect(
        (await targetRepo.summary('personal', DateTime(2026, 10))).budgetMinor,
        800000,
      );
      expect(
        (await BudgetRepository(target).plans('personal')).single.amountMinor,
        800000,
      );
      expect(
        (await target
                .customSelect(
                  "SELECT value FROM settings WHERE key = 'device_id'",
                )
                .get())
            .single
            .read<String>('value'),
        originalDevice,
      );
    },
  );

  test(
    'wrong password and tampered ciphertext leave current data unchanged',
    () async {
      final bytes = await BackupService(source).export(password);
      await expectLater(
        BackupService(target).restore(bytes, 'wrong-password'),
        throwsA(isA<LedgerException>()),
      );
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final cipher = base64Decode(envelope['ciphertext'] as String);
      cipher[0] ^= 1;
      envelope['ciphertext'] = base64Encode(cipher);
      await expectLater(
        BackupService(target).restore(
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
          password,
        ),
        throwsA(isA<LedgerException>()),
      );
      expect(await targetRepo.entries('personal'), isEmpty);
      expect((await targetRepo.accounts('personal')).first.balanceMinor, 0);
    },
  );

  test(
    'structurally inconsistent backup is rejected before replacement',
    () async {
      await source.customStatement(
        'UPDATE transaction_postings SET delta_minor = 999',
      );
      final bytes = await BackupService(source).export(password);
      await expectLater(
        BackupService(target).restore(bytes, password),
        throwsA(isA<LedgerException>()),
      );
      expect(await targetRepo.entries('personal'), isEmpty);
      expect((await targetRepo.accounts('personal')).first.balanceMinor, 0);
    },
  );
}
