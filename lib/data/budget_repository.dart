import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/database/app_database.dart';
import '../domain/models.dart';
import '../domain/money.dart';

class BudgetRepository {
  BudgetRepository(this.db);

  final AppDatabase db;
  static const _uuid = Uuid();

  Future<List<QueryRow>> _query(String sql, [List<Object> args = const []]) =>
      db
          .customSelect(
            sql,
            variables: args
                .map<Variable>(
                  (value) => value is int
                      ? Variable<int>(value)
                      : Variable<String>(value as String),
                )
                .toList(),
          )
          .get();

  Future<List<BudgetPlan>> plans(
    String ledger, {
    bool includeHidden = false,
    bool includeArchived = false,
  }) async => (await _query(
    '''SELECT b.*,c.name AS category_name,p.name AS parent_name
    FROM budget_plans b LEFT JOIN categories c ON c.id=b.category_id
    LEFT JOIN categories p ON p.id=c.parent_id WHERE b.ledger_id=?
    ${includeHidden ? '' : 'AND b.hidden_at IS NULL'}
    ${includeArchived ? '' : 'AND b.archived_at IS NULL'}
    ORDER BY b.archived_at IS NOT NULL,b.hidden_at IS NOT NULL,b.created_at,b.name''',
    [ledger],
  )).map(_plan).toList();

  BudgetPlan _plan(QueryRow row) {
    final category = row.readNullable<String>('category_name');
    final parent = row.readNullable<String>('parent_name');
    return BudgetPlan(
      id: row.read('id'),
      name: row.read('name'),
      categoryId: row.readNullable('category_id'),
      categoryName: category == null
          ? null
          : parent == null
          ? category
          : '$parent / $category',
      amountMinor: row.read('amount_minor'),
      periodKind: BudgetPeriodKind.values.byName(row.read('period_kind')),
      startsOn: DateTime.parse(row.read('starts_on')),
      customEndOn: _date(row.readNullable('custom_end_on')),
      rolloverMode: BudgetRolloverMode.values.byName(row.read('rollover_mode')),
      alertEnabled: row.read<int>('alert_enabled') == 1,
      alertBps: row.read('alert_bps'),
      hidden: row.readNullable<String>('hidden_at') != null,
      archived: row.readNullable<String>('archived_at') != null,
    );
  }

  DateTime? _date(String? value) =>
      value == null ? null : DateTime.parse(value);

  Future<String> savePlan(String ledger, BudgetPlan plan) async {
    final name = plan.name.trim();
    if (name.isEmpty || name.length > 60) {
      throw const LedgerException('预算名称需为1～60字');
    }
    if (plan.amountMinor <= 0 || plan.amountMinor > 999999999999999) {
      throw const LedgerException('预算金额必须大于零');
    }
    if (plan.alertBps < 1 || plan.alertBps > 10000) {
      throw const LedgerException('提醒比例需为0.01%～100%');
    }
    if (plan.periodKind == BudgetPeriodKind.custom) {
      if (plan.customEndOn == null ||
          plan.customEndOn!.isBefore(plan.startsOn)) {
        throw const LedgerException('自定义预算需设置有效结束日期');
      }
    } else if (plan.customEndOn != null) {
      throw const LedgerException('周期预算不能设置自定义结束日期');
    }
    if (plan.categoryId != null) {
      final category = await _query(
        '''SELECT id FROM categories WHERE id=? AND ledger_id=?
        AND type='expense' AND archived_at IS NULL''',
        [plan.categoryId!, ledger],
      );
      if (category.isEmpty) throw const LedgerException('请选择当前账本的支出分类');
    }
    final id = plan.id.isEmpty ? _uuid.v4() : plan.id;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await db.customStatement(
        '''INSERT INTO budget_plans
        (id,ledger_id,name,category_id,amount_minor,period_kind,starts_on,
         custom_end_on,rollover_mode,alert_enabled,alert_bps,hidden_at,
         archived_at,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name,
        category_id=excluded.category_id,amount_minor=excluded.amount_minor,
        period_kind=excluded.period_kind,starts_on=excluded.starts_on,
        custom_end_on=excluded.custom_end_on,rollover_mode=excluded.rollover_mode,
        alert_enabled=excluded.alert_enabled,alert_bps=excluded.alert_bps,
        hidden_at=excluded.hidden_at,archived_at=excluded.archived_at,
        updated_at=excluded.updated_at
        WHERE budget_plans.ledger_id=excluded.ledger_id''',
        [
          id,
          ledger,
          name,
          plan.categoryId,
          plan.amountMinor,
          plan.periodKind.name,
          dateKey(plan.startsOn),
          plan.customEndOn == null ? null : dateKey(plan.customEndOn!),
          plan.rolloverMode.name,
          plan.alertEnabled ? 1 : 0,
          plan.alertBps,
          plan.hidden ? now : null,
          plan.archived ? now : null,
          now,
          now,
        ],
      );
    } catch (error) {
      if (error.toString().contains('UNIQUE')) {
        throw const LedgerException('预算名称已存在');
      }
      rethrow;
    }
    return id;
  }

  Future<void> setHidden(String ledger, String id, bool hidden) =>
      _setState(ledger, id, 'hidden_at', hidden);

  Future<void> setArchived(String ledger, String id, bool archived) =>
      _setState(ledger, id, 'archived_at', archived);

  Future<void> _setState(
    String ledger,
    String id,
    String column,
    bool enabled,
  ) async {
    if (column != 'hidden_at' && column != 'archived_at') {
      throw ArgumentError.value(column);
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final changed = await db.customUpdate(
      enabled
          ? 'UPDATE budget_plans SET $column=?,updated_at=? WHERE id=? AND ledger_id=?'
          : 'UPDATE budget_plans SET $column=NULL,updated_at=? WHERE id=? AND ledger_id=?',
      variables: enabled
          ? [
              Variable<String>(now),
              Variable<String>(now),
              Variable<String>(id),
              Variable<String>(ledger),
            ]
          : [
              Variable<String>(now),
              Variable<String>(id),
              Variable<String>(ledger),
            ],
    );
    if (changed != 1) throw const LedgerException('预算不存在');
  }

  Future<List<BudgetPeriodSummary>> periodsForDate(
    String ledger,
    DateTime date, {
    bool includeHidden = false,
    bool includeArchived = false,
  }) async {
    final values = await plans(
      ledger,
      includeHidden: includeHidden,
      includeArchived: includeArchived,
    );
    final result = <BudgetPeriodSummary>[];
    for (final plan in values) {
      final summary = await periodSummary(ledger, plan, date);
      if (summary != null) result.add(summary);
    }
    result.sort((a, b) {
      if (a.exceeded != b.exceeded) return a.exceeded ? -1 : 1;
      if (a.warning != b.warning) return a.warning ? -1 : 1;
      return a.remainingMinor.compareTo(b.remainingMinor);
    });
    return result;
  }

  Future<BudgetPeriodSummary?> periodSummary(
    String ledger,
    BudgetPlan plan,
    DateTime date,
  ) async {
    final day = DateTime(date.year, date.month, date.day);
    if (day.isBefore(plan.startsOn)) return null;
    final target = _bounds(plan, day);
    if (target == null) return null;
    var carried = 0;
    if (plan.rolloverMode != BudgetRolloverMode.none &&
        plan.periodKind != BudgetPeriodKind.custom) {
      var cursor = _bounds(plan, plan.startsOn)!;
      var guard = 0;
      while (cursor.$1.isBefore(target.$1) && guard++ < 1200) {
        final start = cursor.$1.isBefore(plan.startsOn)
            ? plan.startsOn
            : cursor.$1;
        final spent = await _spent(ledger, plan, start, cursor.$2);
        final remaining = plan.amountMinor + carried - spent;
        carried = switch (plan.rolloverMode) {
          BudgetRolloverMode.none => 0,
          BudgetRolloverMode.positive => math.max(0, remaining),
          BudgetRolloverMode.all => remaining,
        };
        cursor = _nextBounds(plan, cursor.$1);
      }
    }
    final start = target.$1.isBefore(plan.startsOn) ? plan.startsOn : target.$1;
    final spent = await _spent(ledger, plan, start, target.$2);
    return BudgetPeriodSummary(
      plan: plan,
      periodStart: start,
      periodEnd: target.$2.subtract(const Duration(days: 1)),
      carriedMinor: carried,
      spentMinor: spent,
    );
  }

  (DateTime, DateTime)? _bounds(BudgetPlan plan, DateTime date) {
    switch (plan.periodKind) {
      case BudgetPeriodKind.monthly:
        return (
          DateTime(date.year, date.month),
          DateTime(date.year, date.month + 1),
        );
      case BudgetPeriodKind.quarterly:
        final month = ((date.month - 1) ~/ 3) * 3 + 1;
        return (DateTime(date.year, month), DateTime(date.year, month + 3));
      case BudgetPeriodKind.yearly:
        return (DateTime(date.year), DateTime(date.year + 1));
      case BudgetPeriodKind.custom:
        final end = plan.customEndOn!;
        if (date.isBefore(plan.startsOn) || date.isAfter(end)) return null;
        return (plan.startsOn, end.add(const Duration(days: 1)));
    }
  }

  (DateTime, DateTime) _nextBounds(BudgetPlan plan, DateTime start) =>
      switch (plan.periodKind) {
        BudgetPeriodKind.monthly => (
          DateTime(start.year, start.month + 1),
          DateTime(start.year, start.month + 2),
        ),
        BudgetPeriodKind.quarterly => (
          DateTime(start.year, start.month + 3),
          DateTime(start.year, start.month + 6),
        ),
        BudgetPeriodKind.yearly => (
          DateTime(start.year + 1),
          DateTime(start.year + 2),
        ),
        BudgetPeriodKind.custom => (plan.startsOn, plan.customEndOn!),
      };

  Future<int> _spent(
    String ledger,
    BudgetPlan plan,
    DateTime start,
    DateTime end,
  ) async {
    final rows = await _query(
      '''SELECT COALESCE(SUM(CASE WHEN t.type='refund'
        THEN -t.amount_minor ELSE t.amount_minor END),0) AS spent
      FROM transactions t
      LEFT JOIN transactions original ON original.id=t.related_transaction_id
      WHERE t.ledger_id=? AND t.deleted_at IS NULL
      AND t.exclude_from_reports=0 AND t.exclude_from_budget=0
      AND t.type IN ('expense','refund')
      AND date(t.occurred_date)>=date(?) AND date(t.occurred_date)<date(?)
      ${plan.categoryId == null ? '' : '''AND (COALESCE(t.category_id,original.category_id)=?
        OR EXISTS (SELECT 1 FROM categories child
          WHERE child.id=COALESCE(t.category_id,original.category_id)
          AND child.parent_id=?))'''}''',
      [
        ledger,
        start.toIso8601String(),
        end.toIso8601String(),
        if (plan.categoryId != null) plan.categoryId!,
        if (plan.categoryId != null) plan.categoryId!,
      ],
    );
    return math.max(0, rows.single.read<int>('spent'));
  }

  Future<List<BudgetDetailEntry>> details(
    String ledger,
    BudgetPeriodSummary period,
  ) async =>
      (await _query(
            '''SELECT t.id,t.type,t.amount_minor,t.occurred_date,t.merchant,
    COALESCE(c.name,oc.name,'未分类') AS category_name
    FROM transactions t
    LEFT JOIN categories c ON c.id=t.category_id
    LEFT JOIN transactions original ON original.id=t.related_transaction_id
    LEFT JOIN categories oc ON oc.id=original.category_id
    WHERE t.ledger_id=? AND t.deleted_at IS NULL
    AND t.exclude_from_reports=0 AND t.exclude_from_budget=0
    AND t.type IN ('expense','refund')
    AND date(t.occurred_date)>=date(?) AND date(t.occurred_date)<date(?)
    ${period.plan.categoryId == null ? '' : '''AND (COALESCE(t.category_id,original.category_id)=?
      OR EXISTS (SELECT 1 FROM categories child
        WHERE child.id=COALESCE(t.category_id,original.category_id)
        AND child.parent_id=?))'''}
    ORDER BY t.occurred_date DESC,t.created_at DESC''',
            [
              ledger,
              period.periodStart.toIso8601String(),
              period.periodEnd.add(const Duration(days: 1)).toIso8601String(),
              if (period.plan.categoryId != null) period.plan.categoryId!,
              if (period.plan.categoryId != null) period.plan.categoryId!,
            ],
          ))
          .map(
            (row) => BudgetDetailEntry(
              transactionId: row.read('id'),
              occurredAt: DateTime.parse(row.read('occurred_date')),
              amountMinor: row.read('amount_minor'),
              type: TransactionType.values.byName(row.read('type')),
              merchant: row.read('merchant'),
              categoryName: row.read('category_name'),
            ),
          )
          .toList();
}
