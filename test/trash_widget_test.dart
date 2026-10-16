import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/trash_page.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'trash page restores and permanently deletes individual entries',
    (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = LedgerRepository(db);
      await repo.initialize();
      final state = LedgerController(repo);
      await state.load();
      final account = state.accounts.first;
      final category = state.categories.firstWhere(
        (item) => item.type == TransactionType.expense,
      );
      Future<String> add(String merchant) => repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1200,
          accountId: account.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 12),
          merchant: merchant,
        ),
      );
      final restoreId = await add('恢复测试');
      final deleteId = await add('删除测试');
      await repo.delete('personal', restoreId);
      await repo.delete('personal', deleteId);
      await state.load();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ledgerProvider.overrideWith((ref) => state),
          ],
          child: const MaterialApp(home: TrashPage()),
        ),
      );
      await settle(tester);
      expect(find.text('自动彻底删除'), findsOneWidget);
      expect(find.text('永不自动删除'), findsOneWidget);
      expect(find.text('恢复测试'), findsOneWidget);
      expect(find.text('删除测试'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('trash-restore-$restoreId')));
      await settle(tester);
      expect(find.text('恢复测试'), findsNothing);
      expect((await repo.entries('personal')).single.id, restoreId);

      await tester.tap(find.byKey(ValueKey('trash-delete-$deleteId')));
      await tester.pumpAndSettle();
      expect(find.text('彻底删除这笔账目？'), findsOneWidget);
      await tester.tap(find.text('彻底删除').last);
      await settle(tester);
      expect(find.text('删除测试'), findsNothing);
      expect(await repo.entries('personal', deleted: true), isEmpty);
      expect(find.text('回收站为空'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('trash_retention')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留 1 天').last);
      await tester.pumpAndSettle();
      expect(find.text('修改自动清理期限'), findsOneWidget);
      await tester.tap(find.text('保存设置'));
      await settle(tester);
      expect(await repo.trashRetentionDays(), 1);
    },
  );

  testWidgets('long press selects multiple trash entries for one deletion', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = LedgerRepository(db);
    await repo.initialize();
    final state = LedgerController(repo);
    await state.load();
    final account = state.accounts.first;
    final category = state.categories.firstWhere(
      (item) => item.type == TransactionType.expense,
    );
    Future<String> add(String merchant) => repo.save(
      'personal',
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: account.id,
        categoryId: category.id,
        occurredDate: DateTime(2026, 10, 12),
        merchant: merchant,
      ),
    );
    final first = await add('批量一');
    final second = await add('批量二');
    final remaining = await add('保留项');
    await repo.delete('personal', first);
    await repo.delete('personal', second);
    await repo.delete('personal', remaining);
    await state.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          ledgerProvider.overrideWith((ref) => state),
        ],
        child: const MaterialApp(home: TrashPage()),
      ),
    );
    await settle(tester);

    await tester.longPress(find.byKey(ValueKey('trash-entry-$first')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(find.byKey(const ValueKey('trash-delete-selected')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('trash-entry-$second')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trash-delete-selected')));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除选中的 2 笔账目？'), findsOneWidget);
    await tester.tap(find.text('删除所选'));
    await settle(tester);

    final deleted = await repo.entries('personal', deleted: true);
    expect(deleted.map((entry) => entry.id), [remaining]);
    expect(find.text('保留项'), findsOneWidget);
    expect(find.text('批量一'), findsNothing);
    expect(find.text('批量二'), findsNothing);
  });
}
