import '../domain/models.dart';

/// Amounts stay in integer minor units. Refunds belong to their arrival period.
class PeriodAnalysis {
  PeriodAnalysis(Iterable<LedgerEntry> entries, this.start, this.end) {
    for (final e in entries) {
      if (e.deleted ||
          e.excludeFromReports ||
          e.occurredDate.isBefore(start) ||
          !e.occurredDate.isBefore(end)) {
        continue;
      }
      final category = e.categoryName ?? '未分类';
      switch (e.type) {
        case TransactionType.expense:
          expense += e.amountMinor;
          expenses[category] = (expenses[category] ?? 0) + e.amountMinor;
          count++;
        case TransactionType.income:
          income += e.amountMinor;
          incomes[category] = (incomes[category] ?? 0) + e.amountMinor;
          count++;
        case TransactionType.refund:
          if (e.isReimbursement) {
            reimbursement += e.amountMinor;
          } else {
            refund += e.amountMinor;
          }
          count++;
        case TransactionType.transfer:
        case TransactionType.adjustment:
          break;
      }
    }
  }
  final DateTime start, end;
  int expense = 0, income = 0, refund = 0, reimbursement = 0, count = 0;
  final expenses = <String, int>{}, incomes = <String, int>{};
  int get netExpense => expense - refund - reimbursement;
  int get surplus => income - netExpense;

  static String comparison(int current, int previous) {
    if (previous == 0) return current == 0 ? '与上期持平' : '上期为零';
    final change = (current - previous) / previous.abs() * 100;
    if (change == 0) return '与上期持平';
    return '较上期${change > 0 ? "增加" : "减少"} ${change.abs().toStringAsFixed(1)}%';
  }
}
