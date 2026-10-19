import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/main.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/money.dart';
import 'helpers/memory_card_vault.dart';
import 'package:smart_ledger/features/account_editor.dart';

void main() {
  // Tests use independent executors, never two connections to one database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testWidgets(
    'small loan dialog keeps labels visible with large text and keyboard',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final state = LedgerController(repo);
      await state.load();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAccountEditor(context, state),
                child: const Text('新增'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('新增'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<AccountKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('贷款 / 现金借款').last);
      await tester.pumpAndSettle();
      final scroll = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      final label = find.text('账户类型');
      expect(
        tester.getRect(label).top,
        greaterThanOrEqualTo(tester.getRect(scroll).top),
      );
      final day = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '每月还款日',
      );
      await tester.ensureVisible(day);
      await tester.pumpAndSettle();
      expect(find.text('填写 1～31，可留空'), findsOneWidget);
      final helper = tester.widget<Text>(find.text('填写 1～31，可留空'));
      expect(helper.maxLines, 3);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.ensureVisible(day);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('保存账户').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      await db.close();
    },
  );

  testWidgets(
    'cancelled smart editor stays in inbox and reopening posts once',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一句话记账'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('smart_input_text')),
        '滴滴42元支付宝',
      );
      await tester.tap(find.text('识别账单'));
      await tester.pumpAndSettle();
      expect((await repo.pendingDrafts('personal')).length, 1);
      await tester.ensureVisible(find.text('核对并记账'));
      await tester.tap(find.text('核对并记账'));
      await tester.pumpAndSettle();
      // Dismiss without saving, then continue through the persisted inbox.
      await tester.tapAt(const Offset(10, 30));
      await tester.pumpAndSettle();
      expect(await repo.entries('personal'), isEmpty);
      await tester.tap(find.text('待确认账单 · 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并记账'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存账目'));
      await tester.tap(find.text('保存账目'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.text('没有待确认账单'), findsOneWidget);
      expect((await repo.entries('personal')).length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'mobile manual transaction reaches persistence, summary and list',
    (tester) async {
      final db = AppDatabase.memory();
      final repository = LedgerRepository(db);
      await repository.initialize();
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.text('财务总览'), findsOneWidget);
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动记账'));
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsNothing);
      expect(find.byKey(const ValueKey('transaction_amount')), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '38.50');
      await tester.enterText(find.byType(TextFormField).at(1), '瑞幸咖啡');
      final save = find.text('保存账目');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect((await repository.entries('personal')).single.amountMinor, 3850);
      expect(find.text('¥38.50'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('流水').last);
      await tester.pumpAndSettle();
      expect(find.text('瑞幸咖啡'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'manual transaction edits account and category from the summary',
    (tester) async {
      final db = AppDatabase.memory();
      final repository = LedgerRepository(db);
      await repository.initialize();
      final accounts = await repository.accounts('personal');
      final categories = await repository.categories('personal');
      final replacementAccount = accounts[1];
      final replacementCategory = categories.firstWhere(
        (category) =>
            category.type == TransactionType.expense &&
            category.parentId != null,
      );
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动记账'));
      await tester.pumpAndSettle();

      expect(find.text('全部分类'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transaction_account_chip')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(replacementAccount.displayName).last);
      await tester.pumpAndSettle();
      expect(find.text(replacementAccount.displayName), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('transaction_all_categories')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(replacementCategory.name).last);
      await tester.pumpAndSettle();
      expect(find.text(replacementCategory.name), findsOneWidget);
      expect(find.text('账户、分类、时间、标签、备注与附件'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets('manual transaction can switch ledger before saving', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    final repository = LedgerRepository(db);
    await repository.initialize();
    await repository.createLedger('旅行账本');
    final ledgers = await repository.ledgers();
    final target = ledgers.entries
        .firstWhere((entry) => entry.value == '旅行账本')
        .key;
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动记账'));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is DropdownButton<String> && widget.value == 'personal',
          )
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('旅行账本').last);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '88.00');
    await tester.enterText(find.byType(TextFormField).at(1), '旅行午餐');
    await tester.ensureVisible(find.text('保存账目'));
    await tester.tap(find.text('保存账目'));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();

    expect(await repository.entries('personal'), isEmpty);
    expect((await repository.entries(target)).single.merchant, '旅行午餐');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets(
    'transaction swipes edit and delete; undo closes after five seconds',
    (tester) async {
      final db = AppDatabase.memory();
      final repository = LedgerRepository(db);
      await repository.initialize();
      final account = (await repository.accounts('personal')).first;
      final category = (await repository.categories(
        'personal',
      )).firstWhere((item) => item.type == TransactionType.expense);
      final entryId = await repository.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1200,
          accountId: account.id,
          categoryId: category.id,
          merchant: '删除计时测试',
          occurredDate: DateTime.now(),
        ),
      );
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('流水').last);
      await tester.pumpAndSettle();
      expect(find.text('左滑显示编辑与删除'), findsOneWidget);
      await tester.drag(find.text('删除计时测试'), const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('entry-edit-$entryId')), findsOneWidget);
      expect(find.byKey(ValueKey('entry-delete-$entryId')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('entry-edit-$entryId')));
      await tester.pumpAndSettle();
      expect(find.text('保存账目'), findsOneWidget);
      await tester.tapAt(const Offset(8, 24));
      await tester.pumpAndSettle();
      await tester.drag(find.text('删除计时测试'), const Offset(-180, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('entry-delete-$entryId')));
      await tester.pumpAndSettle();
      expect(find.text('账目已移入回收站'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('账目已移入回收站'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('账目已移入回收站'), findsNothing);
      expect(find.text('撤销'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets('smart draft is editable and only posts after explicit save', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    final repository = LedgerRepository(db);
    await repository.initialize();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一句话记账'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('smart_input_text')),
      '昨天晚上滴滴四十二块五，支付宝付的',
    );
    await tester.tap(find.text('识别账单'));
    await tester.pumpAndSettle();
    expect(find.text('¥42.50'), findsOneWidget);
    expect(await repository.entries('personal'), isEmpty);
    await tester.ensureVisible(find.text('核对并记账'));
    await tester.tap(find.text('核对并记账'));
    await tester.pumpAndSettle();
    expect(find.text('42.50'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '43.25');
    await tester.ensureVisible(find.text('保存账目'));
    await tester.tap(find.text('保存账目'));
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    final e = (await repository.entries('personal')).single;
    expect(e.amountMinor, 4325);
    expect(e.merchant, '滴滴');
    expect(e.categoryName, '打车');
    expect(e.accountName, '支付宝');
    final now = DateTime.now();
    final expected = now.subtract(const Duration(days: 1));
    expect(dateKey(e.occurredDate), dateKey(expected));
    expect(
      e.occurredDate.difference(expected).abs(),
      lessThan(const Duration(seconds: 10)),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets(
    'ambiguous smart draft has no default amount, account or category',
    (tester) async {
      final db = AppDatabase.memory();
      final repository = LedgerRepository(db);
      await repository.initialize();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一句话记账'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('smart_input_text')),
        '今天小店20元，另一家30元',
      );
      await tester.tap(find.text('识别账单'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('核对并记账'));
      await tester.tap(find.text('核对并记账'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存账目'));
      await tester.tap(find.text('保存账目'));
      await tester.pumpAndSettle();
      expect(await repository.entries('personal'), isEmpty);
      expect(find.text('请选择账户'), findsOneWidget);
      expect(find.text('请选择分类'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'bank template accepts a full number but only shows the tail by default',
    (tester) async {
      final db = AppDatabase.memory();
      final vault = MemoryCardVault();
      final repository = LedgerRepository(db, cardVault: vault);
      await repository.initialize();
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('账户').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新增账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资金与负债账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<AccountKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('银行卡').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('招商银行').last);
      await tester.tap(find.text('招商银行').last);
      await tester.pumpAndSettle();
      final cardInput = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '卡号或尾号（选填）',
      );
      await tester.enterText(cardInput, '4111111111111111');
      await tester.tap(find.text('保存账户'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      final a = (await repository.accounts('personal')).last;
      expect(a.bankId, 'cmb');
      expect(a.cardLast4, '1111');
      expect(a.name, '招商银行 1111');
      expect(find.text('4111111111111111'), findsNothing);
      final bankRow = find.byKey(ValueKey('account_row_${a.id}'));
      await tester.ensureVisible(bankRow);
      await tester.pumpAndSettle();
      await tester.tap(bankRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看卡号'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('4111111111111111'), findsNothing);
      await tester.tap(find.text('显示完整卡号'));
      await tester.pump();
      expect(find.text('4111111111111111'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(find.text('4111111111111111'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'credit platform creation saves due day and repayment opens a transfer',
    (tester) async {
      final db = AppDatabase.memory();
      final repository = LedgerRepository(db);
      await repository.initialize();
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('账户').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新增账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资金与负债账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<AccountKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('信用支付').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('花呗').last);
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.enterText(field('当前欠款（填正数）'), '1000');
      await tester.enterText(field('每月还款日'), '9');
      await tester.tap(find.text('保存账户'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      final a = (await repository.accounts('personal')).last;
      expect(a.providerId, 'huabei');
      expect(a.balanceMinor, -100000);
      expect(a.repaymentDay, 9);
      final creditRow = find.byKey(ValueKey('account_row_${a.id}'));
      await tester.ensureVisible(creditRow);
      await tester.pumpAndSettle();
      await tester.tap(creditRow);
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录还款'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '100');
      await tester.ensureVisible(find.text('保存账目'));
      await tester.tap(find.text('保存账目'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(
        (await repository.entries('personal')).single.type,
        TransactionType.transfer,
      );
      expect((await repository.accounts('personal')).last.balanceMinor, -90000);
      expect(
        (await repository.summary('personal', DateTime.now())).expenseMinor,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'desktop overview and account navigation render without overflow',
    (tester) async {
      final db = AppDatabase.memory();
      final repository = LedgerRepository(db);
      await repository.initialize();
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repository)],
          child: const SmartLedgerApp(),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(find.text('知账'), findsOneWidget);
      await tester.tap(find.text('账户'));
      await tester.pumpAndSettle();
      expect(find.text('账户净余额'), findsOneWidget);
      expect(find.text('微信'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );
}
