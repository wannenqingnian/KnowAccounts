import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/analysis_page.dart';
import 'package:smart_ledger/features/manage_page.dart';
import 'package:smart_ledger/features/money_privacy.dart';
import 'package:smart_ledger/features/reimbursement_page.dart';
import 'package:smart_ledger/features/attachment_panel.dart';
import 'package:smart_ledger/features/attachments_page.dart';
import 'package:smart_ledger/features/widgets.dart';
import 'mvp_completion_test.dart' show image;

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  late LedgerController state;
  late String id;
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    state = LedgerController(repo);
    await state.load();
    id = await repo.save(
      'personal',
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: 12345,
        accountId: state.accounts.first.id,
        categoryId: state.categories
            .firstWhere((c) => c.type == TransactionType.expense)
            .id,
        occurredDate: DateTime(2026, 10, 5),
        merchant: '测试报销',
        reimbursable: true,
      ),
      attachments: [image()],
    );
    await state.load();
  });
  tearDown(() async {
    await db.close();
  });
  Widget app(Widget child, {bool hidden = false}) => ProviderScope(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      ledgerProvider.overrideWith((ref) => state),
    ],
    child: MaterialApp(
      builder: (context, child) => MoneyPrivacy(hidden: hidden, child: child!),
      home: child,
    ),
  );
  testWidgets(
    'reimbursement page launches a linked editable receipt with remaining amount, saves and updates status',
    (tester) async {
      await tester.pumpWidget(app(const ReimbursementPage()));
      await settle(tester);
      expect(find.textContaining('待报销'), findsWidgets);
      expect(find.text('记录报销到账'), findsOneWidget);
      await tester.tap(find.text('记录报销到账'));
      await tester.pumpAndSettle();
      expect(find.text('记录报销到账'), findsWidgets);
      final amount = find.widgetWithText(TextFormField, '金额');
      await tester.enterText(amount, '23.45');
      await tester.ensureVisible(find.text('保存账目'));
      await tester.tap(find.text('保存账目'));
      await settle(tester);
      expect(
        (await repo.entries(
          'personal',
        )).where((e) => e.isReimbursement).single.amountMinor,
        2345,
      );
      expect(find.textContaining('部分报销'), findsWidgets);
      expect(
        (await repo.summary('personal', DateTime(2026, 10))).incomeMinor,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'attachment manager removes an existing image only on save and preserves transaction postings',
    (tester) async {
      await tester.pumpWidget(
        app(AttachmentsPage(ledger: 'personal', transactionId: id)),
      );
      await settle(tester);
      expect(find.byType(AttachmentPanel), findsOneWidget);
      expect(find.text('移除'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect((await repo.attachments('personal', id)).length, 1);
      await tester.tap(find.text('保存附件'));
      await settle(tester);
      expect(await repo.attachments('personal', id), isEmpty);
      expect((await repo.accounts('personal')).first.balanceMinor, -12345);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'privacy masks entry amounts and omits chart painters without changing underlying data',
    (tester) async {
      final entry = state.entries.first;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Column(
              children: [
                EntryTile(entry: entry, onTap: () {}),
                Expanded(child: AnalysisPage(state: state)),
              ],
            ),
          ),
          hidden: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('123.45'), findsNothing);
      expect(find.textContaining('••••'), findsWidgets);
      expect(find.textContaining('分析金额和图表已隐藏'), findsOneWidget);
      expect(
        tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .where(
              (w) => [
                '_Bars',
                '_Ring',
                '_AssetLine',
              ].contains(w.painter.runtimeType.toString()),
            ),
        isEmpty,
      );
      expect(entry.amountMinor, 12345);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: EntryTile(entry: entry, onTap: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('123.45'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'management privacy switch persists across controller reload and reimbursement entry is available',
    (tester) async {
      await tester.pumpWidget(
        app(const Scaffold(body: SingleChildScrollView(child: ManagePage()))),
      );
      await settle(tester);
      expect(find.text('报销管理'), findsOneWidget);
      expect(find.text('日志记录'), findsOneWidget);
      expect(find.text('智能记账'), findsOneWidget);
      expect(find.text('数据与隐私'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('金额隐私模式'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.ancestor(
          of: find.text('金额隐私模式'),
          matching: find.byType(SwitchListTile),
        ),
      );
      await settle(tester);
      expect(await repo.amountPrivacy(), true);
      await state.load();
      expect(state.amountPrivacy, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
