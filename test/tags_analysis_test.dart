import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/tags.dart';
import 'package:smart_ledger/finance/advanced_analysis.dart';

void main() {
  test('tag normalization validates count and length', () {
    expect(parseTagInput('#通勤，旅行 通勤'), ['通勤', '旅行']);
    expect(
      () => parseTagInput(List.generate(11, (i) => '标签$i').join('，')),
      throwsA(isA<LedgerException>()),
    );
    expect(() => parseTagInput('一' * 21), throwsA(isA<LedgerException>()));
  });
  test(
    'tags survive edit and encrypted backup; fractional allocation stays exact',
    () async {
      final db = AppDatabase.memory();
      try {
        final repo = LedgerRepository(db);
        await repo.initialize();
        final accounts = await repo.accounts('personal');
        final cats = await repo.categories('personal');
        final day = DateTime(2026, 10, 4);
        final id = await repo.save(
          'personal',
          TransactionInput(
            type: TransactionType.expense,
            amountMinor: 351,
            accountId: accounts.first.id,
            categoryId: cats.first.id,
            occurredDate: day,
            tags: const ['通勤', '旅行', '通勤'],
          ),
        );
        var entries = await repo.entries('personal');
        expect(entries.single.tags, ['通勤', '旅行']);
        expect(tagTotals(entries, DateTime(2026, 10), DateTime(2026, 11)), {
          '通勤': 176,
          '旅行': 175,
        });
        final backup = await BackupService(db).export('test-password');
        await repo.save(
          'personal',
          TransactionInput(
            type: TransactionType.expense,
            amountMinor: 351,
            accountId: accounts.first.id,
            categoryId: cats.first.id,
            occurredDate: day,
            tags: const ['新标签'],
          ),
          id: id,
        );
        expect((await repo.entries('personal')).single.tags, ['新标签']);
        await BackupService(db).restore(backup, 'test-password');
        entries = await repo.entries('personal');
        expect(entries.single.tags, ['通勤', '旅行']);
        final flows = dailyFlows(
          entries,
          DateTime(2026, 10),
          DateTime(2026, 11),
        );
        expect(flows['2026-10-04']!.value(2), -351);
      } finally {
        await db.close();
      }
    },
  );
  test(
    'parent category rollup, asset transfers and report exclusions use correct scopes',
    () {
      final date = DateTime(2026, 10, 4);
      LedgerEntry e(
        String id,
        TransactionType type,
        int amount,
        String account, {
        String? target,
        bool excluded = false,
      }) => LedgerEntry(
        id: id,
        type: type,
        amountMinor: amount,
        accountId: account,
        accountName: account,
        targetAccountId: target,
        categoryId: 'child',
        occurredDate: date,
        createdAt: date,
        version: 1,
        excludeFromReports: excluded,
      );
      const accounts = [
        Account(
          id: 'a',
          name: 'a',
          kind: AccountKind.bank,
          openingMinor: 10000,
          balanceMinor: 10000,
        ),
        Account(
          id: 'b',
          name: 'b',
          kind: AccountKind.credit,
          openingMinor: -3000,
          balanceMinor: -3000,
        ),
      ];
      const cats = [
        Category(id: 'root', name: '交通', type: TransactionType.expense),
        Category(
          id: 'child',
          name: '公交',
          type: TransactionType.expense,
          parentId: 'root',
        ),
      ];
      final rows = [
        e('1', TransactionType.expense, 300, 'a'),
        e('2', TransactionType.transfer, 2000, 'a', target: 'b'),
        e('3', TransactionType.income, 1000, 'a', excluded: true),
      ];
      expect(
        categoryTotals(
          rows,
          cats,
          DateTime(2026, 10),
          DateTime(2026, 11),
          roots: true,
        ),
        {'交通': 300},
      );
      expect(balanceAt(rows, accounts, DateTime(2026, 11)), 7700);
      expect(
        balanceAt(rows, accounts, DateTime(2026, 11), accountId: 'a'),
        8700,
      );
      expect(balanceAt(rows, accounts, DateTime(2026, 10)), 7000);
    },
  );
}
