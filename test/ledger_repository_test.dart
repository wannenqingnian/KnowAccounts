import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/money.dart';

void main() {
  // Tests use independent executors, never two connections to one database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  late List<Account> accounts;
  late Category expense;
  late Category income;
  final date = DateTime(2026, 10, 5);

  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    accounts = await repo.accounts('personal');
    final categories = await repo.categories('personal');
    expense = categories.firstWhere((c) => c.name == '咖啡');
    income = categories.firstWhere((c) => c.name == '工资');
  });
  tearDown(() async => db.close());

  TransactionInput input(
    TransactionType type,
    int amount, {
    String? target,
    String? related,
    DateTime? on,
  }) => TransactionInput(
    type: type,
    amountMinor: amount,
    accountId: accounts.first.id,
    targetAccountId: target,
    categoryId: type == TransactionType.income ? income.id : expense.id,
    relatedTransactionId: related,
    occurredDate: on ?? date,
    merchant: '瑞幸',
  );

  test('exact decimal parsing and formatting', () {
    expect(parseMoney('38.50'), 3850);
    expect(parseMoney('0.01'), 1);
    expect(parseMoney('10000000.09'), 1000000009);
    expect(money(-123456), '-¥1,234.56');
    for (final invalid in ['0', '-1', '1.234', 'NaN', '1e2', '1..2', '']) {
      expect(() => parseMoney(invalid), throwsA(isA<LedgerException>()));
    }
  });

  test('income, expense and transfer preserve balance and reporting', () async {
    await repo.save('personal', input(TransactionType.income, 100000));
    await repo.save('personal', input(TransactionType.expense, 3850));
    await repo.save(
      'personal',
      input(TransactionType.transfer, 50000, target: accounts[1].id),
    );
    final balances = await repo.accounts('personal');
    expect(balances[0].balanceMinor, 46150);
    expect(balances[1].balanceMinor, 50000);
    expect(balances.fold<int>(0, (s, a) => s + a.balanceMinor), 96150);
    final summary = await repo.summary('personal', date);
    expect(summary.expenseMinor, 3850);
    expect(summary.incomeMinor, 100000);
  });

  test('invalid transfer rolls back without creating a transaction', () async {
    await expectLater(
      repo.save(
        'personal',
        input(TransactionType.transfer, 100, target: accounts[0].id),
      ),
      throwsA(isA<LedgerException>()),
    );
    expect(await repo.entries('personal'), isEmpty);
    expect((await repo.accounts('personal')).first.balanceMinor, 0);
  });

  test(
    'refund reduces expense, blocks over-refund and protects original',
    () async {
      final original = await repo.save(
        'personal',
        input(TransactionType.expense, 3850),
      );
      final refund = await repo.save(
        'personal',
        input(TransactionType.refund, 3850, related: original),
      );
      expect((await repo.summary('personal', date)).expenseMinor, 0);
      expect((await repo.summary('personal', date)).incomeMinor, 0);
      expect((await repo.accounts('personal')).first.balanceMinor, 0);
      await expectLater(
        repo.save(
          'personal',
          input(TransactionType.refund, 1, related: original),
        ),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.delete('personal', original),
        throwsA(isA<LedgerException>()),
      );
      await repo.delete('personal', refund);
      await repo.delete('personal', original);
      await expectLater(
        repo.restore('personal', refund),
        throwsA(isA<LedgerException>()),
      );
      await repo.restore('personal', original);
      await repo.restore('personal', refund);
      expect((await repo.summary('personal', date)).expenseMinor, 0);
    },
  );

  test('cross-month refund belongs to refund month', () async {
    final original = await repo.save(
      'personal',
      input(TransactionType.expense, 1000),
    );
    await repo.save(
      'personal',
      input(
        TransactionType.refund,
        1000,
        related: original,
        on: DateTime(2026, 11, 1),
      ),
    );
    expect((await repo.summary('personal', date)).expenseMinor, 1000);
    final november = await repo.summary('personal', DateTime(2026, 11));
    expect(november.expenseMinor, -1000);
    expect(november.categoryExpenses['咖啡'], -1000);
  });

  test(
    'edit rebuilds postings, deletion and restore keep one transaction',
    () async {
      final id = await repo.save(
        'personal',
        input(TransactionType.expense, 1000),
      );
      await repo.save('personal', input(TransactionType.expense, 2000), id: id);
      expect((await repo.accounts('personal')).first.balanceMinor, -2000);
      expect((await repo.entries('personal')).single.version, 2);
      await repo.delete('personal', id);
      expect(await repo.entries('personal'), isEmpty);
      expect((await repo.accounts('personal')).first.balanceMinor, 0);
      expect((await repo.entries('personal', deleted: true)).length, 1);
      await repo.restore('personal', id);
      expect((await repo.accounts('personal')).first.balanceMinor, -2000);
      expect((await repo.entries('personal')).single.version, 4);
    },
  );

  test(
    'trash retention defaults to never and purges expired data safely',
    () async {
      expect(await repo.trashRetentionDays(), 0);
      final id = await repo.save(
        'personal',
        input(TransactionType.expense, 1200),
      );
      await repo.delete('personal', id);
      expect(
        (await repo.entries('personal', deleted: true)).single.deletedAt,
        isNotNull,
      );
      await db
          .customStatement('UPDATE transactions SET deleted_at=? WHERE id=?', [
            DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 8))
                .toIso8601String(),
            id,
          ]);
      await repo.setTrashRetentionDays(7);
      expect(await repo.trashRetentionDays(), 7);
      expect(await repo.entries('personal', deleted: true), isEmpty);
      expect(
        await db
            .customSelect(
              'SELECT id FROM transaction_postings WHERE transaction_id=?',
              variables: [Variable<String>(id)],
            )
            .get(),
        isEmpty,
      );
      await expectLater(
        repo.setTrashRetentionDays(2),
        throwsA(isA<LedgerException>()),
      );
    },
  );

  test(
    'trash supports manual permanent deletion and protects relations',
    () async {
      final original = await repo.save(
        'personal',
        input(TransactionType.expense, 1000),
      );
      final refund = await repo.save(
        'personal',
        input(TransactionType.refund, 400, related: original),
      );
      await repo.delete('personal', refund);
      await repo.delete('personal', original);
      await expectLater(
        repo.permanentlyDelete('personal', original),
        throwsA(isA<LedgerException>()),
      );
      expect(
        await repo.permanentlyDeleteMany('personal', [original, refund]),
        2,
      );
      expect(await repo.entries('personal', deleted: true), isEmpty);

      final first = await repo.save(
        'personal',
        input(TransactionType.expense, 200),
      );
      final second = await repo.save(
        'personal',
        input(TransactionType.expense, 300),
      );
      await repo.delete('personal', first);
      await repo.delete('personal', second);
      expect(await repo.emptyTrash('personal'), 2);
      expect(await repo.entries('personal', deleted: true), isEmpty);
    },
  );

  test('ledger isolation, category depth and income category checks', () async {
    await repo.createLedger('旅行');
    final other = (await repo.ledgers()).keys.firstWhere(
      (id) => id != 'personal',
    );
    await expectLater(
      repo.save(other, input(TransactionType.expense, 100)),
      throwsA(isA<LedgerException>()),
    );
    await expectLater(
      repo.addCategory(
        'personal',
        '第三级',
        TransactionType.expense,
        parentId: expense.id,
      ),
      throwsA(isA<LedgerException>()),
    );
    await expectLater(
      repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.income,
          amountMinor: 100,
          accountId: accounts[0].id,
          occurredDate: date,
          categoryId: expense.id,
        ),
      ),
      throwsA(isA<LedgerException>()),
    );
    expect(await repo.entries(other), isEmpty);
  });

  test('credit account repayment is a transfer, not an expense', () async {
    await repo.addAccount('personal', '信用卡', AccountKind.credit, -100000);
    final credit = (await repo.accounts(
      'personal',
    )).firstWhere((a) => a.kind == AccountKind.credit);
    await repo.save(
      'personal',
      input(TransactionType.transfer, 100000, target: credit.id),
    );
    expect(
      (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.id == credit.id).balanceMinor,
      0,
    );
    expect((await repo.summary('personal', date)).expenseMinor, 0);
  });

  test('budget and literal substring search', () async {
    await repo.setBudget('personal', date, 800000);
    await repo.save('personal', input(TransactionType.expense, 3850));
    expect((await repo.summary('personal', date)).remainingMinor, 796150);
    expect((await repo.entries('personal', search: '瑞幸')).length, 1);
    expect(await repo.entries('personal', search: '%'), isEmpty);
  });

  test(
    'database reopen retains transactions and initialization is idempotent',
    () async {
      final directory = await Directory.systemTemp.createTemp('ledger-test-');
      final file = File('${directory.path}/ledger.sqlite');
      final first = AppDatabase(NativeDatabase(file));
      final firstRepo = LedgerRepository(first);
      await firstRepo.initialize();
      final a = (await firstRepo.accounts('personal')).first;
      final c = (await firstRepo.categories('personal')).first;
      await firstRepo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 123,
          accountId: a.id,
          categoryId: c.id,
          occurredDate: date,
        ),
      );
      await first.close();
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        final reopenedRepo = LedgerRepository(reopened);
        await reopenedRepo.initialize();
        expect(
          (await reopenedRepo.entries('personal')).single.amountMinor,
          123,
        );
        expect((await reopenedRepo.accounts('personal')).length, 4);
        expect(
          (await reopenedRepo.accounts('personal')).first.balanceMinor,
          -123,
        );
        expect(
          (await reopened.customSelect('PRAGMA foreign_keys').get())
              .single
              .data
              .values
              .first,
          1,
        );
      } finally {
        await reopened.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
