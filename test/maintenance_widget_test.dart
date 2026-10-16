import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/category_manager.dart';
import 'package:smart_ledger/features/archived_accounts.dart';
import 'package:smart_ledger/features/transaction_editor.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testWidgets(
    'category menu renames a default, archives its descendants, and restores parent',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final state = LedgerController(repo);
      await state.load();
      final root = state.categories.firstWhere((c) => c.name == '餐饮');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ledgerProvider.overrideWith((ref) => state),
          ],
          child: const MaterialApp(home: CategoryManager()),
        ),
      );
      final row = find.byKey(ValueKey('category_row_${root.id}'));
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改名称'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '吃饭');
      await tester.tap(find.text('确认'));
      await settle(tester);
      expect(find.text('吃饭'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('归档分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('归档'));
      await settle(tester);
      expect(find.text('吃饭'), findsNothing);
      expect(state.categories.any((c) => c.parentId == root.id), false);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('吃饭'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复分类'));
      await settle(tester);
      expect(find.text('吃饭'), findsNothing);
      expect(state.categories.any((c) => c.id == root.id), true);
      expect(state.categories.any((c) => c.parentId == root.id), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'archived account can restore and editing archived historical fields opens without dropdown assertion',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final account = (await repo.accounts('personal')).first;
      final category = (await repo.categories(
        'personal',
      )).firstWhere((c) => c.name == '早餐');
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1600,
          accountId: account.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 3),
        ),
      );
      await repo.setAccountArchived('personal', account.id, true);
      await repo.setCategoryArchived('personal', category.id, true);
      final state = LedgerController(repo);
      await state.load();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ledgerProvider.overrideWith((ref) => state),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TransactionEditor(entry: state.entries.single),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('关联账户或分类已归档，请选择可用项或先在管理中恢复。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ledgerProvider.overrideWith((ref) => state),
          ],
          child: const MaterialApp(home: ArchivedAccounts()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('余额 -¥16.00'), findsOneWidget);
      await tester.tap(find.text('恢复账户'));
      await settle(tester);
      expect(find.text('暂无已归档账户'), findsOneWidget);
      expect(state.accounts.any((a) => a.id == account.id), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );
}
