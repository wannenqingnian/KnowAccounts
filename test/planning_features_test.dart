import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/data/tag_repository.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('templates persist optional fields and tags', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = LedgerRepository(db);
    await repo.initialize();
    final account = (await repo.accounts('personal')).first;
    final category = (await repo.categories(
      'personal',
    )).firstWhere((item) => item.type == TransactionType.expense);

    await repo.saveTransactionTemplate(
      'personal',
      TransactionTemplate(
        id: '',
        name: '工作午餐',
        type: TransactionType.expense,
        amountMinor: 0,
        accountId: account.id,
        categoryId: category.id,
        merchant: '食堂',
        tags: const ['工作', '午餐'],
      ),
    );

    final saved = (await repo.transactionTemplates('personal')).single;
    expect(saved.name, '工作午餐');
    expect(saved.amountMinor, 0);
    expect(saved.categoryId, category.id);
    expect(saved.tags, ['工作', '午餐']);
  });

  test(
    'running a recurring rule posts once and advances its schedule',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = LedgerRepository(db);
      await repo.initialize();
      final account = (await repo.accounts('personal')).first;
      final category = (await repo.categories(
        'personal',
      )).firstWhere((item) => item.type == TransactionType.expense);
      final next = DateTime(2026, 10, 31, 8, 30, 5);

      final id = await repo.saveRecurringRule(
        'personal',
        RecurringRule(
          id: '',
          name: '月度订阅',
          kind: RecurringKind.incomeExpense,
          type: TransactionType.expense,
          amountMinor: 1990,
          accountId: account.id,
          categoryId: category.id,
          frequency: RecurrenceFrequency.monthly,
          interval: 1,
          nextAt: next,
          tags: const ['订阅'],
        ),
      );
      await repo.runRecurringRule('personal', id);

      final entries = await repo.entries('personal');
      expect(entries.single.amountMinor, 1990);
      expect(entries.single.occurredDate, next);
      expect(entries.single.tags, ['订阅']);
      final rule = (await repo.recurringRules('personal')).single;
      expect(rule.nextAt, DateTime(2026, 11, 30, 8, 30, 5));
      expect(rule.lastRunAt, isNotNull);
    },
  );

  test(
    'an enabled due rule is generated once when plans are processed',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = LedgerRepository(db);
      await repo.initialize();
      final account = (await repo.accounts('personal')).first;
      final category = (await repo.categories(
        'personal',
      )).firstWhere((item) => item.type == TransactionType.income);
      final due = DateTime(2026, 1, 1, 9, 0, 1);
      await repo.saveRecurringRule(
        'personal',
        RecurringRule(
          id: '',
          name: '固定收入',
          kind: RecurringKind.incomeExpense,
          type: TransactionType.income,
          amountMinor: 50000,
          accountId: account.id,
          categoryId: category.id,
          frequency: RecurrenceFrequency.monthly,
          interval: 1,
          nextAt: due,
        ),
      );

      final at = DateTime(2026, 3, 2);
      await repo.processDueRecurringRules(at: at);
      await repo.processDueRecurringRules(at: at);

      final entries = await repo.entries('personal');
      expect(entries, hasLength(1));
      expect(entries.single.occurredDate, due);
      expect(
        (await repo.recurringRules('personal')).single.nextAt.isAfter(at),
        isTrue,
      );
    },
  );

  test(
    'recurring end conditions, skip and execution history are persisted',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = LedgerRepository(db);
      await repo.initialize();
      final account = (await repo.accounts('personal')).first;
      final category = (await repo.categories(
        'personal',
      )).firstWhere((item) => item.type == TransactionType.expense);
      final due = DateTime(2026, 12, 1, 8, 0, 5);
      final id = await repo.saveRecurringRule(
        'personal',
        RecurringRule(
          id: '',
          name: '限次订阅',
          kind: RecurringKind.incomeExpense,
          type: TransactionType.expense,
          amountMinor: 900,
          accountId: account.id,
          categoryId: category.id,
          frequency: RecurrenceFrequency.monthly,
          interval: 1,
          nextAt: due,
          maxRuns: 2,
        ),
      );

      await repo.skipRecurringRule('personal', id);
      await repo.runRecurringRule('personal', id);
      await repo.runRecurringRule('personal', id);

      final rule = (await repo.recurringRules('personal')).single;
      expect(rule.enabled, isFalse);
      expect(rule.runCount, 2);
      final history = await repo.recurringExecutions('personal', id);
      expect(
        history.map((item) => item.status),
        containsAll(['skipped', 'success']),
      );
      expect(history.where((item) => item.status == 'success'), hasLength(2));
    },
  );

  test(
    'tag manager merges old records and smart tags apply to new bills',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = LedgerRepository(db);
      final tags = TagRepository(db);
      await repo.initialize();
      final account = (await repo.accounts('personal')).first;
      final category = (await repo.categories(
        'personal',
      )).firstWhere((item) => item.type == TransactionType.expense);
      final smart = await tags.save(
        'personal',
        name: '咖啡',
        smartPattern: '星巴克，瑞幸',
      );
      final old = await tags.save('personal', name: '饮品');
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 3200,
          accountId: account.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 14, 9, 30, 6),
          merchant: '星巴克臻选',
          tags: const ['饮品'],
        ),
      );

      await tags.merge('personal', old, smart);
      final entry = (await repo.entries('personal')).single;
      expect(entry.tags, ['咖啡']);
      final definitions = await tags.definitions('personal');
      expect(definitions.single.name, '咖啡');
      expect(definitions.single.usageCount, 1);
    },
  );

  test(
    'category icon library choice is stored independently from its name',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = LedgerRepository(db);
      await repo.initialize();
      final id = await repo.addCategory(
        'personal',
        '周末计划',
        TransactionType.expense,
        iconKey: 'travel',
      );
      expect(
        (await repo.categories(
          'personal',
        )).firstWhere((item) => item.id == id).iconKey,
        'travel',
      );
      await repo.setCategoryIcon('personal', id, 'entertainment');
      expect(
        (await repo.categories(
          'personal',
        )).firstWhere((item) => item.id == id).iconKey,
        'entertainment',
      );
    },
  );
}
