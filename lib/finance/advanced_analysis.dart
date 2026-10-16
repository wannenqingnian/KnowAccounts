import '../domain/models.dart';
import '../domain/money.dart';

bool inReport(LedgerEntry e, DateTime start, DateTime end) =>
    !e.deleted &&
    !e.excludeFromReports &&
    !e.occurredDate.isBefore(start) &&
    e.occurredDate.isBefore(end);

Map<String, int> categoryTotals(
  Iterable<LedgerEntry> entries,
  List<Category> categories,
  DateTime start,
  DateTime end, {
  bool income = false,
  bool roots = false,
}) {
  final byId = {for (final c in categories) c.id: c};
  final result = <String, int>{};
  for (final e in entries) {
    if (!inReport(e, start, end) ||
        e.type != (income ? TransactionType.income : TransactionType.expense)) {
      continue;
    }
    final c = byId[e.categoryId];
    final name = roots && c?.parentId != null
        ? byId[c!.parentId]?.name ?? c.name
        : c?.name ?? e.categoryName ?? '未分类';
    result[name] = (result[name] ?? 0) + e.amountMinor;
  }
  return result;
}

/// A multi-tag amount is split into exact integer shares so the chart cannot
/// count the same expense twice. First tags receive any remaining cents.
Map<String, int> tagTotals(
  Iterable<LedgerEntry> entries,
  DateTime start,
  DateTime end, {
  bool income = false,
}) {
  final result = <String, int>{};
  for (final e in entries) {
    if (!inReport(e, start, end) ||
        e.type != (income ? TransactionType.income : TransactionType.expense)) {
      continue;
    }
    final tags = e.tags.isEmpty ? ['未标记'] : e.tags;
    for (var i = 0; i < tags.length; i++) {
      final share =
          e.amountMinor ~/ tags.length +
          (i < e.amountMinor % tags.length ? 1 : 0);
      result[tags[i]] = (result[tags[i]] ?? 0) + share;
    }
  }
  return result;
}

class DailyFlow {
  int income = 0, expense = 0, refund = 0;
  int value(int metric) => metric == 0
      ? expense
      : metric == 1
      ? income
      : income - expense + refund;
}

Map<String, DailyFlow> dailyFlows(
  Iterable<LedgerEntry> entries,
  DateTime start,
  DateTime end,
) {
  final result = <String, DailyFlow>{};
  for (final e in entries) {
    if (!inReport(e, start, end) ||
        ![
          TransactionType.income,
          TransactionType.expense,
          TransactionType.refund,
        ].contains(e.type)) {
      continue;
    }
    final flow = result.putIfAbsent(dateKey(e.occurredDate), DailyFlow.new);
    if (e.type == TransactionType.income) flow.income += e.amountMinor;
    if (e.type == TransactionType.expense) flow.expense += e.amountMinor;
    if (e.type == TransactionType.refund) flow.refund += e.amountMinor;
  }
  return result;
}

/// Balance history reconstructed from current opening balances and actual
/// postings, including transactions excluded from spending reports.
int balanceAt(
  Iterable<LedgerEntry> entries,
  List<Account> accounts,
  DateTime end, {
  String? accountId,
}) {
  var value = accounts
      .where((a) => accountId == null || a.id == accountId)
      .fold<int>(0, (sum, a) => sum + a.openingMinor);
  for (final e in entries) {
    if (e.deleted || !e.occurredDate.isBefore(end)) continue;
    if (accountId == null || e.accountId == accountId) {
      value +=
          (e.type == TransactionType.expense ||
              e.type == TransactionType.transfer)
          ? -e.amountMinor
          : e.amountMinor;
    }
    if (e.type == TransactionType.transfer &&
        (accountId == null || e.targetAccountId == accountId)) {
      value += e.amountMinor;
    }
  }
  return value;
}
