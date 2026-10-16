import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/money.dart';
import 'package:smart_ledger/features/date_time_picker.dart';
import 'package:smart_ledger/features/year_month_picker.dart';

void main() {
  test('transaction storage preserves local time to the second', () async {
    final db = AppDatabase.memory();
    final repository = LedgerRepository(db);
    await repository.initialize();
    final account = (await repository.accounts('personal')).first;
    final category = (await repository.categories(
      'personal',
    )).firstWhere((item) => item.type == TransactionType.expense);
    final occurred = DateTime(2026, 10, 12, 13, 14, 37, 912, 500);

    await repository.save(
      'personal',
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: account.id,
        categoryId: category.id,
        occurredDate: occurred,
      ),
    );

    final saved = (await repository.entries('personal')).single;
    expect(saved.occurredDate, DateTime(2026, 10, 12, 13, 14, 37));
    expect(dateTimeKey(saved.occurredDate), '2026-10-12T13:14:37');
    await db.close();
  });

  testWidgets('second picker exposes hour, minute and second controls', (
    tester,
  ) async {
    DateTime? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showSecondDateTimePicker(
                context,
                initial: DateTime(2026, 10, 12, 9, 8, 7),
              );
            },
            child: const Text('选择'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transaction_hour')), findsOneWidget);
    expect(find.byKey(const ValueKey('transaction_minute')), findsOneWidget);
    expect(find.byKey(const ValueKey('transaction_second')), findsOneWidget);
    expect(find.text('2026-10-12 09:08:07'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected, DateTime(2026, 10, 12, 9, 8, 7));
  });

  testWidgets('year-month dialog provides a month grid', (tester) async {
    DateTime? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showYearMonthPicker(
                context,
                initial: DateTime(2026, 3),
              );
            },
            child: const Text('年月'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('年月'));
    await tester.pumpAndSettle();
    expect(find.text('选择年月'), findsOneWidget);
    expect(find.text('3 月'), findsOneWidget);
    expect(find.text('12 月'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('year_manual_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('year_manual_input')),
      '2034',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8 月'));
    await tester.pumpAndSettle();
    expect(selected, DateTime(2034, 8));
  });

  testWidgets('year-only dialog accepts a manually entered year', (
    tester,
  ) async {
    DateTime? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showYearMonthPicker(
                context,
                initial: DateTime(2026, 3),
                yearOnly: true,
              );
            },
            child: const Text('年份'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('年份'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('year_manual_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('year_manual_input')),
      '1998',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected, DateTime(1998, 3));
  });
}
