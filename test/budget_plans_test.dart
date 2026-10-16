import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/budget_repository.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository ledger;
  late BudgetRepository budgets;
  late Account account;
  late Category coffee;
  late Category other;

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerRepository(db);
    budgets = BudgetRepository(db);
    await ledger.initialize();
    account = (await ledger.accounts('personal')).first;
    final categories = (await ledger.categories(
      'personal',
    )).where((value) => value.type == TransactionType.expense).toList();
    coffee = categories.firstWhere((value) => value.name == '咖啡');
    other = categories.firstWhere((value) => value.id != coffee.id);
  });

  tearDown(() => db.close());

  Future<String> expense(
    int amount,
    DateTime date, {
    Category? category,
    String merchant = '商户',
  }) => ledger.save(
    'personal',
    TransactionInput(
      type: TransactionType.expense,
      amountMinor: amount,
      accountId: account.id,
      categoryId: (category ?? coffee).id,
      merchant: merchant,
      occurredDate: date,
    ),
  );

  BudgetPlan plan({
    String id = '',
    String name = '咖啡预算',
    String? categoryId,
    int amount = 10000,
    BudgetPeriodKind period = BudgetPeriodKind.monthly,
    DateTime? starts,
    DateTime? end,
    BudgetRolloverMode rollover = BudgetRolloverMode.none,
  }) => BudgetPlan(
    id: id,
    name: name,
    categoryId: categoryId,
    amountMinor: amount,
    periodKind: period,
    startsOn: starts ?? DateTime(2026, 1, 1),
    customEndOn: end,
    rolloverMode: rollover,
    alertBps: 8000,
  );

  test('category budget includes its transactions and refunds only', () async {
    final id = await budgets.savePlan('personal', plan(categoryId: coffee.id));
    final original = await expense(4000, DateTime(2026, 1, 1), merchant: '咖啡店');
    await expense(5000, DateTime(2026, 1, 2), category: other);
    await ledger.save(
      'personal',
      TransactionInput(
        type: TransactionType.refund,
        amountMinor: 1000,
        accountId: account.id,
        categoryId: coffee.id,
        relatedTransactionId: original,
        occurredDate: DateTime(2026, 1, 3),
        merchant: '咖啡店退款',
      ),
    );

    final loaded = (await budgets.plans('personal')).single;
    expect(loaded.id, id);
    final summary = await budgets.periodSummary(
      'personal',
      loaded,
      DateTime(2026, 1, 31),
    );
    expect(summary!.spentMinor, 3000);
    expect(summary.remainingMinor, 7000);
    final details = await budgets.details('personal', summary);
    expect(details.length, 2);
    expect(
      details.map((value) => value.budgetDeltaMinor),
      containsAll([4000, -1000]),
    );
  });

  test('monthly remaining and overspend can roll into next period', () async {
    await budgets.savePlan(
      'personal',
      plan(name: '余额结转', rollover: BudgetRolloverMode.positive),
    );
    await expense(4000, DateTime(2026, 1, 10));
    final loaded = (await budgets.plans('personal')).single;
    final february = await budgets.periodSummary(
      'personal',
      loaded,
      DateTime(2026, 2, 15),
    );
    expect(february!.carriedMinor, 6000);
    expect(february.availableMinor, 16000);

    await budgets.savePlan(
      'personal',
      plan(id: loaded.id, name: loaded.name, rollover: BudgetRolloverMode.all),
    );
    await expense(13000, DateTime(2026, 2, 20));
    final march = await budgets.periodSummary(
      'personal',
      (await budgets.plans('personal')).single,
      DateTime(2026, 3, 5),
    );
    expect(march!.carriedMinor, 3000);
    expect(march.availableMinor, 13000);
  });

  test('quarter, year and custom periods use correct boundaries', () async {
    for (final value in [
      plan(name: '季度', period: BudgetPeriodKind.quarterly),
      plan(name: '年度', period: BudgetPeriodKind.yearly),
      plan(
        name: '旅行',
        period: BudgetPeriodKind.custom,
        starts: DateTime(2026, 2, 2),
        end: DateTime(2026, 2, 8),
      ),
    ]) {
      await budgets.savePlan('personal', value);
    }
    final values = await budgets.plans('personal');
    final quarter = await budgets.periodSummary(
      'personal',
      values.firstWhere((value) => value.name == '季度'),
      DateTime(2026, 2, 5),
    );
    expect(quarter!.periodStart, DateTime(2026, 1, 1));
    expect(quarter.periodEnd, DateTime(2026, 3, 31));
    final year = await budgets.periodSummary(
      'personal',
      values.firstWhere((value) => value.name == '年度'),
      DateTime(2026, 8, 1),
    );
    expect(year!.periodEnd, DateTime(2026, 12, 31));
    final custom = values.firstWhere((value) => value.name == '旅行');
    expect(
      await budgets.periodSummary('personal', custom, DateTime(2026, 2, 1)),
      isNull,
    );
    expect(
      (await budgets.periodSummary(
        'personal',
        custom,
        DateTime(2026, 2, 8),
      ))!.periodEnd,
      DateTime(2026, 2, 8),
    );
  });

  test('hidden and archived plans remain recoverable', () async {
    final id = await budgets.savePlan('personal', plan());
    await budgets.setHidden('personal', id, true);
    expect(await budgets.plans('personal'), isEmpty);
    expect(
      (await budgets.plans('personal', includeHidden: true)).single.hidden,
      true,
    );
    await budgets.setArchived('personal', id, true);
    expect(await budgets.plans('personal', includeHidden: true), isEmpty);
    final archived = await budgets.plans(
      'personal',
      includeHidden: true,
      includeArchived: true,
    );
    expect(archived.single.archived, true);
    await budgets.setArchived('personal', id, false);
    await budgets.setHidden('personal', id, false);
    expect((await budgets.plans('personal')).single.id, id);
  });

  test('schema 10 monthly budget migrates into a detailed plan', () async {
    final directory = await Directory.systemTemp.createTemp('budget-v10-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/old.sqlite');
    final legacy = sql.sqlite3.open(file.path);
    for (final statement in schemaStatements.where(
      (value) => !budgetSchemaStatements.contains(value),
    )) {
      legacy.execute(statement);
    }
    legacy.execute(
      "INSERT INTO ledgers VALUES ('personal','个人账本','CNY','2026-01-01')",
    );
    legacy.execute("INSERT INTO budgets VALUES ('personal','2026-04',50000)");
    legacy.execute('PRAGMA user_version=10');
    legacy.dispose();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final values = await BudgetRepository(upgraded).plans('personal');
    expect(values.single.amountMinor, 50000);
    expect(values.single.periodKind, BudgetPeriodKind.custom);
    expect(values.single.startsOn, DateTime(2026, 4, 1));
    expect(values.single.customEndOn, DateTime(2026, 4, 30));
  });
}
