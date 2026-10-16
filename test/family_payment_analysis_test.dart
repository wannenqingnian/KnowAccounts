import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/family_payment_repository.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/family_payment.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/analysis_page.dart';
import 'package:smart_ledger/finance/family_payment_analysis.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository ledger;
  late FamilyPaymentRepository family;
  late DateTime now;

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerRepository(db);
    await ledger.initialize();
    family = FamilyPaymentRepository(db);
    now = DateTime.now();
  });

  tearDown(() => db.close());

  Future<void> seedReports() async {
    final accounts = await ledger.accounts('personal');
    final category = (await ledger.categories(
      'personal',
    )).firstWhere((item) => item.type == TransactionType.expense);
    await family.saveCard(
      ledgerId: 'personal',
      platform: FamilyCardPlatform.alipay,
      displayName: '孩子的支付宝亲情卡',
      localRole: FamilyLocalRole.payer,
      senderLimitMinor: 100000,
      defaultFundingAccountId: accounts.first.id,
      defaultCategoryId: category.id,
    );
    await family.saveCard(
      ledgerId: 'personal',
      platform: FamilyCardPlatform.wechat,
      displayName: '妈妈的微信亲属卡',
      localRole: FamilyLocalRole.beneficiary,
      userLimitMinor: 80000,
    );

    final payer = await family.observeCapture(
      captureId: 'a' * 64,
      ledgerId: 'personal',
      platform: FamilyCardPlatform.alipay,
      sourceKind: 'notification',
      sourcePackage: FamilyCardPlatform.alipay.packageName,
      amountMinor: 10000,
      merchant: '生鲜超市',
      occurredAt: now,
      rawText: '孩子的支付宝亲情卡 亲情卡付款成功 100.00 订单号 202610140001',
    );
    await family.confirmFamilyEvent(
      ledgerId: 'personal',
      eventId: payer!,
      localRole: FamilyLocalRole.payer,
    );
    await family.applyRefund(
      ledgerId: 'personal',
      eventId: payer,
      refundMinor: 3000,
      occurredAt: now,
    );

    final beneficiary = await family.observeCapture(
      captureId: 'b' * 64,
      ledgerId: 'personal',
      platform: FamilyCardPlatform.wechat,
      sourceKind: 'accessibility',
      sourcePackage: FamilyCardPlatform.wechat.packageName,
      amountMinor: 5000,
      merchant: '图书店',
      occurredAt: now,
      rawText: '妈妈的微信亲属卡 亲属卡支付 50.00 交易单号 202610140002',
    );
    await family.confirmFamilyEvent(
      ledgerId: 'personal',
      eventId: beneficiary!,
      localRole: FamilyLocalRole.beneficiary,
    );
    await family.applyRefund(
      ledgerId: 'personal',
      eventId: beneficiary,
      refundMinor: 1000,
      occurredAt: now,
    );

    await family.observeCapture(
      captureId: 'c' * 64,
      ledgerId: 'personal',
      platform: FamilyCardPlatform.wechat,
      sourceKind: 'ocr',
      sourcePackage: 'com.smartledger.capture.ocr',
      amountMinor: 2000,
      merchant: '早餐铺',
      occurredAt: now,
      rawText: '妈妈的微信亲属卡 亲属卡支付 20.00 交易单号 202610140003',
    );
  }

  test(
    'payer and beneficiary reports use separate net-consumption scopes',
    () async {
      await seedReports();
      final report = FamilyPaymentAnalysis(
        await family.events('personal'),
        await family.cards('personal', includeArchived: true),
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1),
      );
      expect(report.payerGrossMinor, 10000);
      expect(report.payerRefundMinor, 3000);
      expect(report.payerNetMinor, 7000);
      expect(report.payerCount, 1);
      expect(report.beneficiaryGrossMinor, 5000);
      expect(report.beneficiaryRefundMinor, 1000);
      expect(report.beneficiaryNetMinor, 4000);
      expect(report.beneficiaryCount, 1);
      expect(report.pendingMinor, 2000);
      expect(report.pendingCount, 1);
      expect(report.payerByPlatform['支付宝亲情卡'], 7000);
      expect(report.beneficiaryByPlatform['微信亲属卡'], 4000);
      expect((await ledger.summary('personal', now)).expenseMinor, 7000);
    },
  );

  testWidgets('analysis page shows independent family-card reports', (
    tester,
  ) async {
    await seedReports();
    final state = LedgerController(ledger);
    await state.load();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(ledger),
          ledgerProvider.overrideWith((ref) => state),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AnalysisPage(state: state)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('亲情卡分析'));
    await tester.pumpAndSettle();
    expect(find.text('资金方实际代付'), findsOneWidget);
    expect(find.text('消费方受资助消费'), findsOneWidget);
    expect(find.text('¥70.00'), findsWidgets);
    expect(find.text('¥40.00'), findsWidgets);
    expect(find.textContaining('另有 1 笔待审核'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
