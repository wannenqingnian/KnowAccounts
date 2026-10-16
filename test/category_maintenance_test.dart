import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/finance/advanced_analysis.dart';
import 'helpers/memory_card_vault.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db, cardVault: MemoryCardVault());
    await repo.initialize();
  });
  tearDown(() => db.close());

  test(
    'category rename preserves ID, transaction postings and history grouping',
    () async {
      final categories = await repo.categories('personal');
      final child = categories.firstWhere((c) => c.name == '早餐');
      final account = (await repo.accounts('personal')).first;
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1600,
          accountId: account.id,
          categoryId: child.id,
          occurredDate: DateTime(2026, 10, 3),
        ),
      );
      await repo.renameCategory('personal', child.id, '早点');
      final entry = (await repo.entries('personal')).single;
      expect(entry.categoryId, child.id);
      expect(entry.categoryName, '早点');
      expect((await repo.accounts('personal')).first.balanceMinor, -1600);
      expect(
        (await repo.summary('personal', DateTime(2026, 10))).categoryExpenses,
        {'早点': 1600},
      );
      await expectLater(
        repo.renameCategory('personal', child.id, '午餐'),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.renameCategory('personal', child.id, ' '),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.renameCategory('personal', child.id, '字' * 41),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.renameCategory('foreign', child.id, '新名'),
        throwsA(isA<LedgerException>()),
      );
    },
  );

  test(
    'parent archive is atomic; restore parent and children separately; history remains counted',
    () async {
      final child = (await repo.categories(
        'personal',
      )).firstWhere((c) => c.name == '早餐');
      final account = (await repo.accounts('personal')).first;
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 350,
          accountId: account.id,
          categoryId: child.id,
          occurredDate: DateTime(2026, 10, 3),
        ),
      );
      await repo.setCategoryArchived('personal', child.parentId!, true);
      expect(
        (await repo.categories(
          'personal',
        )).any((c) => c.id == child.id || c.id == child.parentId),
        false,
      );
      final all = await repo.categories('personal', includeArchived: true);
      expect(all.firstWhere((c) => c.id == child.id).archived, true);
      final state = LedgerController(repo);
      addTearDown(state.dispose);
      await state.load();
      expect(
        categoryTotals(
          state.entries,
          state.allCategories,
          DateTime(2026, 10),
          DateTime(2026, 11),
          roots: true,
        ),
        {'餐饮': 350},
      );
      await expectLater(
        repo.setCategoryArchived('personal', child.id, false),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.addCategory(
          'personal',
          '新菜',
          TransactionType.expense,
          parentId: child.parentId,
        ),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.save(
          'personal',
          TransactionInput(
            type: TransactionType.expense,
            amountMinor: 1,
            accountId: account.id,
            categoryId: child.id,
            occurredDate: DateTime(2026, 10, 3),
          ),
        ),
        throwsA(isA<LedgerException>()),
      );
      await repo.setCategoryArchived('personal', child.parentId!, false);
      expect(
        (await repo.categories('personal')).any((c) => c.id == child.id),
        false,
      );
      await repo.setCategoryArchived('personal', child.id, false);
      expect(
        (await repo.categories('personal')).any((c) => c.id == child.id),
        true,
      );
    },
  );

  test(
    'complete sibling ordering persists; stale, duplicate and foreign lists roll back',
    () async {
      final roots = (await repo.categories('personal'))
          .where((c) => c.type == TransactionType.expense && c.parentId == null)
          .toList();
      final ids = roots.map((c) => c.id).toList().reversed.toList();
      await repo.reorderCategories(
        'personal',
        TransactionType.expense,
        null,
        ids,
      );
      Future<List<String>> rootIds() async =>
          (await repo.categories('personal'))
              .where(
                (c) => c.type == TransactionType.expense && c.parentId == null,
              )
              .map((c) => c.id)
              .toList();
      expect(await rootIds(), ids);
      for (final bad in [
        ids.take(ids.length - 1).toList(),
        [...ids, ids.first],
        ['foreign', ...ids.skip(1)],
      ]) {
        await expectLater(
          repo.reorderCategories(
            'personal',
            TransactionType.expense,
            null,
            bad,
          ),
          throwsA(isA<LedgerException>()),
        );
        expect(await rootIds(), ids);
      }
      await expectLater(
        repo.reorderCategories('other', TransactionType.expense, null, ids),
        throwsA(isA<LedgerException>()),
      );
      final added = await repo.addCategory(
        'personal',
        '宠物',
        TransactionType.expense,
      );
      expect((await rootIds()).last, added);
      final children = (await repo.categories('personal'))
          .where((c) => c.parentId == roots.first.id)
          .map((c) => c.id)
          .toList()
          .reversed
          .toList();
      await repo.reorderCategories(
        'personal',
        TransactionType.expense,
        roots.first.id,
        children,
      );
      expect(
        (await repo.categories(
          'personal',
        )).where((c) => c.parentId == roots.first.id).map((c) => c.id),
        children,
      );
    },
  );

  test(
    'account archive preserves balance, card vault and asset history, but prevents new postings',
    () async {
      final account = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.bank);
      await repo.updateAccount(
        'personal',
        account.id,
        account.name,
        account.kind,
        10000,
        bankId: 'cmb',
        cardLast4: '1111',
        fullCardNumber: '4111111111111111',
        replaceCard: true,
      );
      final child = (await repo.categories(
        'personal',
      )).firstWhere((c) => c.name == '早餐');
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1600,
          accountId: account.id,
          categoryId: child.id,
          occurredDate: DateTime(2026, 10, 3),
        ),
      );
      await repo.setAccountArchived('personal', account.id, true);
      expect(
        (await repo.accounts('personal')).any((a) => a.id == account.id),
        false,
      );
      final all = await repo.accounts('personal', includeArchived: true);
      expect(all.firstWhere((a) => a.id == account.id).balanceMinor, 8400);
      expect(
        balanceAt(await repo.entries('personal'), all, DateTime(2026, 11)),
        8400,
      );
      await expectLater(
        repo.save(
          'personal',
          TransactionInput(
            type: TransactionType.income,
            amountMinor: 100,
            accountId: account.id,
            categoryId: (await repo.categories(
              'personal',
            )).firstWhere((c) => c.type == TransactionType.income).id,
            occurredDate: DateTime(2026, 10, 4),
          ),
        ),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.setAccountArchived('other', account.id, false),
        throwsA(isA<LedgerException>()),
      );
      await repo.setAccountArchived('personal', account.id, false);
      expect(
        await repo.fullCardNumber('personal', account.id),
        '4111111111111111',
      );
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((a) => a.id == account.id).balanceMinor,
        8400,
      );
    },
  );

  test(
    'last available account and last category of a type cannot be archived',
    () async {
      final accounts = await repo.accounts('personal');
      for (final account in accounts.skip(1)) {
        await repo.setAccountArchived('personal', account.id, true);
      }
      await expectLater(
        repo.setAccountArchived('personal', accounts.first.id, true),
        throwsA(isA<LedgerException>()),
      );
      final roots = (await repo.categories('personal'))
          .where((c) => c.type == TransactionType.income && c.parentId == null)
          .toList();
      for (final c in roots.skip(1)) {
        await repo.setCategoryArchived('personal', c.id, true);
      }
      await expectLater(
        repo.setCategoryArchived('personal', roots.first.id, true),
        throwsA(isA<LedgerException>()),
      );
      expect(
        (await repo.categories(
          'personal',
        )).where((c) => c.type == TransactionType.income).length,
        1,
      );
    },
  );

  test(
    'encrypted backup restores archive flags, stable order, full card and history',
    () async {
      final bank = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.bank);
      await repo.updateAccount(
        'personal',
        bank.id,
        bank.name,
        bank.kind,
        12345,
        bankId: 'cmb',
        cardLast4: '1111',
        fullCardNumber: '4111111111111111',
        replaceCard: true,
      );
      await repo.setAccountArchived('personal', bank.id, true);
      final roots = (await repo.categories('personal'))
          .where((c) => c.type == TransactionType.expense && c.parentId == null)
          .map((c) => c.id)
          .toList()
          .reversed
          .toList();
      await repo.reorderCategories(
        'personal',
        TransactionType.expense,
        null,
        roots,
      );
      await repo.setCategoryArchived('personal', roots.first, true);
      final bytes = await BackupService(
        db,
        cardVault: repo.cardVault,
      ).export('test-password-2026');
      final target = AppDatabase.memory();
      addTearDown(target.close);
      final vault = MemoryCardVault();
      final restored = LedgerRepository(target, cardVault: vault);
      await restored.initialize();
      await BackupService(
        target,
        cardVault: vault,
      ).restore(bytes, 'test-password-2026');
      expect(
        (await restored.accounts(
          'personal',
          includeArchived: true,
        )).firstWhere((a) => a.id == bank.id).archived,
        true,
      );
      expect(
        (await restored.categories('personal', includeArchived: true))
            .where(
              (c) => c.type == TransactionType.expense && c.parentId == null,
            )
            .map((c) => c.id),
        roots,
      );
      expect(
        (await restored.categories(
          'personal',
          includeArchived: true,
        )).firstWhere((c) => c.id == roots.first).archived,
        true,
      );
      await restored.setAccountArchived('personal', bank.id, false);
      expect(
        await restored.fullCardNumber('personal', bank.id),
        '4111111111111111',
      );
      expect(
        (await restored.accounts(
          'personal',
        )).firstWhere((a) => a.id == bank.id).balanceMinor,
        12345,
      );
    },
  );
}
