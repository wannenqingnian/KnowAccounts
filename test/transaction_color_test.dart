import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/widgets.dart';
import 'package:smart_ledger/theme/transaction_colors.dart';

LedgerEntry entry(TransactionType type) => LedgerEntry(
  id: type.name,
  type: type,
  amountMinor: 1000,
  accountId: 'cash',
  accountName: '现金',
  categoryName: '餐饮',
  occurredDate: DateTime(2026, 10, 19),
  createdAt: DateTime(2026, 10, 19),
  version: 1,
);

void main() {
  testWidgets('transaction palette changes amount text only', (tester) async {
    const expense = Color(0xFFAA0000);
    const income = Color(0xFF00AA00);
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: scheme,
          extensions: const [
            TransactionColors(expense: expense, income: income),
          ],
        ),
        home: Scaffold(
          body: Column(
            children: [
              EntryTile(entry: entry(TransactionType.expense), onTap: () {}),
              EntryTile(entry: entry(TransactionType.income), onTap: () {}),
            ],
          ),
        ),
      ),
    );

    final expenseText = tester.widget<Text>(find.textContaining('-¥'));
    final incomeText = tester.widget<Text>(find.textContaining('+¥'));
    expect(expenseText.style?.color, expense);
    expect(incomeText.style?.color, income);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.restaurant_outlined)).color,
      scheme.onTertiaryContainer,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.south_west)).color,
      scheme.primary,
    );
  });
}
