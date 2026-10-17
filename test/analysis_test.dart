import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/finance/analysis.dart';

LedgerEntry entry(
  TransactionType type,
  int amount,
  DateTime date, {
  String? category,
  bool deleted = false,
  bool excluded = false,
  bool reimbursement = false,
  int reimbursed = 0,
}) => LedgerEntry(
  id: '$type-$amount-$date',
  type: type,
  amountMinor: amount,
  accountId: 'a',
  accountName: '账户',
  occurredDate: date,
  createdAt: date,
  version: 1,
  categoryName: category,
  deleted: deleted,
  excludeFromReports: excluded,
  isReimbursement: reimbursement,
  reimbursedMinor: reimbursed,
);
void main() {
  test(
    'month boundaries, exclusions, refunds and principal transfers remain distinct',
    () {
      final report = PeriodAnalysis(
        [
          entry(TransactionType.expense, 10000, DateTime(2026, 9, 30)),
          entry(
            TransactionType.expense,
            3000,
            DateTime(2026, 10, 1),
            category: '餐饮',
          ),
          entry(
            TransactionType.expense,
            2000,
            DateTime(2026, 10, 31),
            category: '交通',
          ),
          entry(
            TransactionType.income,
            100000,
            DateTime(2026, 10, 3),
            category: '工资',
          ),
          entry(TransactionType.refund, 7000, DateTime(2026, 10, 4)),
          entry(TransactionType.transfer, 800000, DateTime(2026, 10, 4)),
          entry(TransactionType.adjustment, 900000, DateTime(2026, 10, 4)),
          entry(
            TransactionType.expense,
            12345,
            DateTime(2026, 10, 4),
            deleted: true,
          ),
          entry(
            TransactionType.income,
            12345,
            DateTime(2026, 10, 4),
            excluded: true,
          ),
          entry(TransactionType.expense, 10000, DateTime(2026, 11, 1)),
        ],
        DateTime(2026, 10),
        DateTime(2026, 11),
      );
      expect(report.expense, 5000);
      expect(report.income, 100000);
      expect(report.refund, 7000);
      expect(report.netExpense, -2000);
      expect(report.surplus, 102000);
      expect(report.count, 4);
      expect(report.expenses, {'餐饮': 3000, '交通': 2000});
      expect(report.incomes, {'工资': 100000});
    },
  );
  test(
    'annual aggregation includes leap day, uncategorized income and refunds arriving in next year',
    () {
      final rows = [
        entry(TransactionType.expense, 1234, DateTime(2024, 2, 29)),
        entry(TransactionType.income, 12345, DateTime(2024, 12, 31)),
        entry(TransactionType.refund, 1234, DateTime(2025, 1, 1)),
      ];
      final year = PeriodAnalysis(rows, DateTime(2024), DateTime(2025));
      expect(year.netExpense, 1234);
      expect(year.incomes, {'未分类': 12345});
      expect(
        PeriodAnalysis(rows, DateTime(2025), DateTime(2026)).netExpense,
        -1234,
      );
    },
  );
  test(
    'comparison handles zero and negative baselines without NaN or division by zero',
    () {
      expect(PeriodAnalysis.comparison(0, 0), '与上期持平');
      expect(PeriodAnalysis.comparison(100, 0), '上期为零');
      expect(PeriodAnalysis.comparison(120, 100), '较上期增加 20.0%');
      expect(PeriodAnalysis.comparison(-100, -200), '较上期增加 50.0%');
    },
  );
  test(
    'today consumption excludes reimbursed expense and reimbursement arrival',
    () {
      final day = DateTime(2026, 10, 17);
      expect(
        todayExpenseTotal([
          entry(TransactionType.expense, 10000, day, reimbursed: 10000),
          entry(TransactionType.refund, 10000, day, reimbursement: true),
          entry(TransactionType.expense, 2500, day),
        ], day),
        2500,
      );
    },
  );
}
