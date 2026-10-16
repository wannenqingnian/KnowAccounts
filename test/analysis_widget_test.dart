import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/main.dart';

void main() {
  testWidgets(
    'analysis handles refunds, annual view, trend details and selected-ledger isolation',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final accounts = await repo.accounts('personal');
      final categories = await repo.categories('personal');
      final date = DateTime.now();
      final original = await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 3850,
          accountId: accounts[3].id,
          categoryId: categories.firstWhere((c) => c.name == '咖啡').id,
          tags: const ['通勤'],
          occurredDate: date,
        ),
      );
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.refund,
          amountMinor: 1000,
          accountId: accounts[3].id,
          relatedTransactionId: original,
          occurredDate: date,
        ),
      );
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.income,
          amountMinor: 100000,
          accountId: accounts[1].id,
          categoryId: categories.firstWhere((c) => c.name == '工资').id,
          occurredDate: date,
        ),
      );
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.transfer,
          amountMinor: 50000,
          accountId: accounts[1].id,
          targetAccountId: accounts[3].id,
          occurredDate: date,
        ),
      );
      // Hidden transactions are preserved in流水, but must not pollute reports.
      final hidden = await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.income,
          amountMinor: 990000,
          accountId: accounts[1].id,
          categoryId: categories.firstWhere((c) => c.name == '工资').id,
          occurredDate: date,
        ),
      );
      await db.customStatement(
        'UPDATE transactions SET exclude_from_reports=1 WHERE id=?',
        [hidden],
      );
      final entries = await repo.entries('personal');
      expect(
        entries.firstWhere((e) => e.id == hidden).excludeFromReports,
        isTrue,
      );
      expect(
        entries
            .firstWhere((e) => e.type == TransactionType.refund)
            .categoryName,
        '咖啡',
      );
      await repo.createLedger('空账本');
      final other = (await repo.ledgers()).entries
          .firstWhere((e) => e.value == '空账本')
          .key;
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('分析').last);
      await tester.pumpAndSettle();
      expect(find.text('¥1,000.00'), findsWidgets);
      expect(find.text('¥28.50'), findsOneWidget);
      expect(find.text('¥971.50'), findsOneWidget);
      final summary = find.byKey(const ValueKey('analysis_summary'));
      expect(tester.getSize(summary).height, lessThan(140));
      expect(
        tester.getTopLeft(find.text('¥28.50')).dy,
        tester.getTopLeft(find.text('¥971.50')).dy,
      );
      expect(tester.getTopLeft(find.text('月度收支趋势')).dy, lessThan(550));

      await tester.tap(find.text('按年'));
      await tester.pumpAndSettle();
      expect(find.text('¥28.50'), findsOneWidget);
      await tester.ensureVisible(find.text('月度收支趋势'));
      await tester.pumpAndSettle();
      // Annual chart is horizontally scrollable; use an already-visible month.
      await tester.ensureVisible(find.text('1月').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1月').first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      // Calendar days, category rollups and tag ranks drill into real entries.
      final heatDay = find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            (w.message?.startsWith(
                  '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ',
                ) ??
                false),
      );
      await tester.ensureVisible(heatDay);
      await tester.pumpAndSettle();
      await tester.tap(heatDay);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('一级分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一级分类'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('支出排行'));
      await tester.pumpAndSettle();
      expect(find.text('餐饮'), findsOneWidget);
      await tester.ensureVisible(find.text('标签排行'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通勤'));
      await tester.pumpAndSettle();
      expect(find.text('#通勤'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      final context = tester.element(find.text('收支分析'));
      await ProviderScope.containerOf(
        context,
      ).read(ledgerProvider).selectLedger(other);
      await tester.pumpAndSettle();
      expect(find.text('¥1,000.00'), findsNothing);
      await tester.ensureVisible(find.text('按年'));
      await tester.pumpAndSettle();
      expect(find.text('¥0.00'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );
  testWidgets('compact summary remains readable with large system text', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    final repo = LedgerRepository(db);
    await repo.initialize();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析').last);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('analysis_summary'))).height,
      lessThan(260),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
