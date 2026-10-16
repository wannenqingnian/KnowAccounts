import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/automation/family_payment_detector.dart';
import 'package:smart_ledger/automation/payment_capture_parser.dart';
import 'package:smart_ledger/automation/payment_capture_processor.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/family_payment_repository.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/family_payment.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/family_cards_page.dart';
import 'package:smart_ledger/features/manage_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repository;
  late FamilyPaymentRepository family;

  setUp(() async {
    db = AppDatabase.memory();
    repository = LedgerRepository(db);
    await repository.initialize();
    family = FamilyPaymentRepository(db);
  });

  tearDown(() => db.close());

  test(
    'detector distinguishes strong family-card markers from unsafe text',
    () {
      const detector = FamilyPaymentDetector();
      expect(
        detector
            .detect(
              packageName: 'com.tencent.mm',
              text: '亲属卡扣款 支付成功',
              completed: true,
            )
            ?.platform,
        FamilyCardPlatform.wechat,
      );
      expect(
        detector
            .detect(
              packageName: 'smartledger.manual.ocr',
              text: '亲属卡交易-龇牙咧嘴\n支付成功\n支付方式 零钱',
              completed: true,
            )
            ?.platform,
        FamilyCardPlatform.wechat,
      );
      expect(
        detector
            .detect(
              packageName: 'com.tencent.mm',
              text: '付款方式：亲属卡（妈妈） 支付成功',
              completed: true,
            )
            ?.cardHint,
        '妈妈',
      );
      expect(
        detector
            .detect(
              packageName: 'com.eg.android.AlipayGphone',
              text: '亲情号支付 付款成功',
              completed: true,
            )
            ?.platform,
        FamilyCardPlatform.alipay,
      );
      expect(
        detector
            .detect(
              packageName: 'com.ccb.longjiLife',
              text: '微信亲属卡扣款成功 25.00元',
              completed: true,
            )
            ?.platform,
        FamilyCardPlatform.wechat,
      );
      expect(
        detector.detect(
          packageName: 'com.eg.android.AlipayGphone',
          text: '支付宝小荷包付款成功',
          completed: true,
        ),
        isNull,
      );
      expect(
        detector.detect(
          packageName: 'com.eg.android.AlipayGphone',
          text: '代付成功',
          completed: true,
        ),
        isNull,
      );
      expect(
        detector.detect(
          packageName: 'com.tencent.mm',
          text: '亲属卡支付',
          completed: false,
        ),
        isNull,
      );
    },
  );

  test(
    'Acceptance #1 & #2: beneficiary limits tracked with 0 account postings; payer confirmation posts single 25 yuan expense; multi-source idempotent',
    () async {
      final cardId = await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        displayName: '妈妈的微信亲属卡',
        localRole: FamilyLocalRole.beneficiary,
        payerLabel: '妈妈',
        beneficiaryLabel: '我',
        senderLimitMinor: 100000,
        userLimitMinor: 80000,
      );
      final accounts = await repository.accounts('personal');
      final categories = await repository.categories('personal');
      final expense = categories.firstWhere(
        (value) => value.type == TransactionType.expense,
      );
      const order = '4200001234567890';
      final text =
          '''支付成功
亲属卡支付
商户名称 测试便利店
交易金额 25.00元
支付方式 亲属卡
交易单号 $order
支付时间 2026-10-14 12:05''';
      PaymentCapture capture(String digit, String kind) => PaymentCapture(
        id: digit * 64,
        packageName: 'com.tencent.mm',
        kind: kind,
        text: text,
        capturedAt: DateTime(2026, 10, 14, 12, 5),
        ledgerId: 'personal',
        accountId: accounts.first.id,
        categoryId: expense.id,
      );
      final parsed = PaymentCaptureParser().parse(
        capture('a', 'notification'),
        accounts,
        categories,
        now: DateTime(2026, 10, 14, 12, 5),
      );
      expect(parsed.familyPayment?.platform, FamilyCardPlatform.wechat);
      expect(parsed.canAutoSave, isFalse);
      expect(parsed.draft.warnings.join(), contains('使用方不会扣减'));

      expect(
        await PaymentCaptureProcessor(
          repository,
        ).process(capture('a', 'notification')),
        'pending',
      );
      expect(
        await PaymentCaptureProcessor(
          repository,
        ).process(capture('b', 'accessibility')),
        'pending',
      );
      // Orderless bank notice for the same purchase within 5 minutes merges into same event
      await family.observeCapture(
        captureId: 'c' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'bankNotice',
        sourcePackage: 'com.ccb.longjiLife',
        amountMinor: 2500,
        merchant: '财付通-测试便利店',
        occurredAt: DateTime(2026, 10, 14, 12, 6),
        rawText: '微信亲属卡消费 ¥25.00 商户：财付通-测试便利店',
      );
      // Duplicate captureId is idempotent
      await family.observeCapture(
        captureId: 'c' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'bankNotice',
        sourcePackage: 'com.ccb.longjiLife',
        amountMinor: 2500,
        merchant: '财付通-测试便利店',
        occurredAt: DateTime(2026, 10, 14, 12, 6),
        rawText: '微信亲属卡消费 ¥25.00 商户：财付通-测试便利店',
      );

      // Ordinary confirmDraft is blocked from deducting beneficiary's asset account
      await expectLater(
        repository.confirmDraft(
          'personal',
          'auto-${'a' * 64}',
          TransactionInput(
            type: TransactionType.expense,
            amountMinor: 2500,
            accountId: accounts.first.id,
            categoryId: expense.id,
            occurredDate: DateTime(2026, 10, 14, 12, 5),
            merchant: '测试便利店',
          ),
        ),
        throwsA(isA<LedgerException>()),
      );

      final events = await family.events('personal');
      expect(events, hasLength(1));
      expect(events.single.cardId, cardId);
      expect(events.single.localRole, FamilyLocalRole.beneficiary);
      expect(events.single.amountMinor, 2500);
      expect(events.single.evidence, hasLength(3));
      expect(events.single.confidence, greaterThanOrEqualTo(80));

      // Confirm as beneficiary -> 0 postings, 0 entries, pendingCount becomes 0
      final beneficiaryTx = await family.confirmFamilyEvent(
        ledgerId: 'personal',
        eventId: events.single.id,
        localRole: FamilyLocalRole.beneficiary,
      );
      expect(beneficiaryTx, isNull);
      expect(await repository.entries('personal'), isEmpty);
      expect(
        await db.customSelect('SELECT * FROM transaction_postings').get(),
        isEmpty,
      );
      expect(await repository.pendingDrafts('personal'), isEmpty);

      final summary = (await family.cards(
        'personal',
        month: DateTime(2026, 10),
      )).single;
      expect(summary.card.senderLimitMinor, 0);
      expect(summary.card.userLimitMinor, 80000);
      expect(summary.usedMinor, 2500);
      expect(summary.availableMinor, 77500);
      expect(summary.pendingCount, 0);

      // Now test Payer side on a second ledger: confirming posts exactly one 25.00 expense
      await repository.createLedger('妈妈账本');
      final payerLedgers = await repository.ledgers();
      final payerLedgerId = payerLedgers.entries
          .firstWhere((e) => e.value == '妈妈账本')
          .key;
      final payerAccounts = await repository.accounts(payerLedgerId);
      final payerCategories = await repository.categories(payerLedgerId);
      final payerExpense = payerCategories.firstWhere(
        (c) => c.type == TransactionType.expense,
      );
      final payerCardId = await family.saveCard(
        ledgerId: payerLedgerId,
        platform: FamilyCardPlatform.wechat,
        displayName: '给孩子的亲属卡',
        localRole: FamilyLocalRole.payer,
        payerLabel: '我',
        beneficiaryLabel: '孩子',
        senderLimitMinor: 100000,
        userLimitMinor: 80000,
        defaultFundingAccountId: payerAccounts.first.id,
        defaultCategoryId: payerExpense.id,
      );
      final payerEventId = await family.observeCapture(
        captureId: 'd' * 64,
        ledgerId: payerLedgerId,
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 2500,
        merchant: '测试便利店',
        occurredAt: DateTime(2026, 10, 14, 12, 5),
        rawText: text,
      );
      final txId = await family.confirmFamilyEvent(
        ledgerId: payerLedgerId,
        eventId: payerEventId!,
        localRole: FamilyLocalRole.payer,
      );
      expect(txId, isNotNull);
      final payerEntries = await repository.entries(payerLedgerId);
      expect(payerEntries, hasLength(1));
      expect(payerEntries.single.amountMinor, 2500);
      expect(
        (await repository.accounts(payerLedgerId)).first.balanceMinor,
        -2500,
      );
      final payerSummary = (await family.cards(
        payerLedgerId,
        month: DateTime(2026, 10),
      )).single;
      expect(payerSummary.card.id, payerCardId);
      expect(payerSummary.usedMinor, 2500);
      expect(payerSummary.pendingCount, 0);
    },
  );

  test(
    'Acceptance #3: two independent orderless transactions of the same amount are never auto-merged',
    () async {
      await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        displayName: '日常亲属卡',
        localRole: FamilyLocalRole.beneficiary,
        senderLimitMinor: 50000,
        userLimitMinor: 50000,
      );
      final e1 = await family.observeCapture(
        captureId: '1' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 2500,
        merchant: '瑞幸咖啡',
        occurredAt: DateTime(2026, 10, 14, 9, 0),
        rawText: '亲属卡支付成功 ¥25.00 瑞幸咖啡',
      );
      final e2 = await family.observeCapture(
        captureId: '2' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 2500,
        merchant: '瑞幸咖啡',
        occurredAt: DateTime(2026, 10, 14, 9, 2),
        rawText: '亲属卡支付成功 ¥25.00 瑞幸咖啡',
      );
      expect(e1, isNotNull);
      expect(e2, isNotNull);
      expect(e1, isNot(equals(e2)));
      final allEvents = await family.events('personal');
      expect(allEvents, hasLength(2));
      expect(allEvents.first.candidateMergeEventId, e1);
    },
  );

  test(
    'Acceptance #4: same order number with different amounts flags conflict and requires manual review',
    () async {
      await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.alipay,
        displayName: '支付宝亲情卡',
        localRole: FamilyLocalRole.beneficiary,
        senderLimitMinor: 50000,
        userLimitMinor: 50000,
      );
      final e1 = await family.observeCapture(
        captureId: '3' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.alipay,
        sourceKind: 'notification',
        sourcePackage: 'com.eg.android.AlipayGphone',
        amountMinor: 2500,
        merchant: '全家便利店',
        occurredAt: DateTime(2026, 10, 14, 10, 0),
        rawText: '亲情卡付款成功 25.00元 订单号 2026101400009999',
      );
      final e2 = await family.observeCapture(
        captureId: '4' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.alipay,
        sourceKind: 'accessibility',
        sourcePackage: 'com.eg.android.AlipayGphone',
        amountMinor: 3000,
        merchant: '全家便利店',
        occurredAt: DateTime(2026, 10, 14, 10, 0),
        rawText: '亲情卡付款成功 30.00元 订单号 2026101400009999',
      );
      expect(e1, equals(e2));
      final ev = (await family.event('personal', e1!))!;
      expect(ev.status, FamilyPaymentStatus.needsReview);
      expect(ev.hasConflict, isTrue);
      expect(ev.conflictMessages.join(), contains('金额不一致'));

      // Confirming without resolving the conflict amount is rejected
      await expectLater(
        family.confirmFamilyEvent(
          ledgerId: 'personal',
          eventId: e1,
          localRole: FamilyLocalRole.beneficiary,
        ),
        throwsA(isA<LedgerException>()),
      );

      // Explicitly specifying the verified amount resolves the conflict
      await family.confirmFamilyEvent(
        ledgerId: 'personal',
        eventId: e1,
        localRole: FamilyLocalRole.beneficiary,
        amountMinor: 2500,
      );
      final resolved = (await family.event('personal', e1))!;
      expect(resolved.status, FamilyPaymentStatus.confirmed);
      expect(resolved.hasConflict, isFalse);
      expect(resolved.amountMinor, 2500);
    },
  );

  test(
    'Acceptance #5: two WeChat family cards never misassociate; unassigned events stay visible and recalculate after manual assignment',
    () async {
      final card1 = await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        displayName: '爸爸的微信亲属卡',
        localRole: FamilyLocalRole.beneficiary,
        payerLabel: '爸爸',
        beneficiaryLabel: '我',
        senderLimitMinor: 100000,
        userLimitMinor: 60000,
      );
      final card2 = await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        displayName: '妈妈的微信亲属卡',
        localRole: FamilyLocalRole.beneficiary,
        payerLabel: '妈妈',
        beneficiaryLabel: '我',
        senderLimitMinor: 100000,
        userLimitMinor: 80000,
      );
      // Ambiguous capture without payer clue stays unassigned (card_id == null)
      final unassignedId = await family.observeCapture(
        captureId: '5' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 4000,
        merchant: '社区超市',
        occurredAt: DateTime(2026, 10, 14, 15, 0),
        rawText: '支付成功 亲属卡支付 40.00元 社区超市',
      );
      final unassignedList = await family.unassignedEvents(
        'personal',
        month: DateTime(2026, 10),
      );
      expect(unassignedList, hasLength(1));
      expect(unassignedList.single.id, unassignedId);

      var summaries = await family.cards('personal', month: DateTime(2026, 10));
      expect(summaries[0].usedMinor, 0);
      expect(summaries[1].usedMinor, 0);
      expect(summaries[0].unassignedUsedMinor, 4000);
      expect(summaries[0].unassignedPendingCount, 1);

      // Manually bind to card2 -> card2 stats immediately include the 40.00 yuan event
      await family.assignCard(
        ledgerId: 'personal',
        eventId: unassignedId!,
        cardId: card2,
      );
      summaries = await family.cards('personal', month: DateTime(2026, 10));
      final s1 = summaries.firstWhere((s) => s.card.id == card1);
      final s2 = summaries.firstWhere((s) => s.card.id == card2);
      expect(s1.usedMinor, 0);
      expect(s2.usedMinor, 4000);
      expect(s2.pendingCount, 1);
      expect(s2.unassignedPendingCount, 0);
    },
  );

  test(
    'Acceptance #6: October records and September pending events are counted separately by month',
    () async {
      await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        displayName: '月度隔离测试卡',
        localRole: FamilyLocalRole.beneficiary,
        senderLimitMinor: 50000,
        userLimitMinor: 50000,
      );
      await family.observeCapture(
        captureId: '6' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 1500,
        merchant: '九月早餐店',
        occurredAt: DateTime(2026, 9, 30, 23, 30),
        rawText: '亲属卡支付 15.00元 九月早餐店',
      );
      final octEventId = await family.observeCapture(
        captureId: '7' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 2800,
        merchant: '十月书店',
        occurredAt: DateTime(2026, 10, 2, 10, 0),
        rawText: '亲属卡支付 28.00元 十月书店',
      );
      await family.confirmFamilyEvent(
        ledgerId: 'personal',
        eventId: octEventId!,
        localRole: FamilyLocalRole.beneficiary,
      );

      final septSummary = (await family.cards(
        'personal',
        month: DateTime(2026, 9),
      )).single;
      final octSummary = (await family.cards(
        'personal',
        month: DateTime(2026, 10),
      )).single;
      expect(septSummary.usedMinor, 1500);
      expect(septSummary.pendingCount, 1);
      expect(octSummary.usedMinor, 2800);
      expect(octSummary.pendingCount, 0);
    },
  );

  test(
    'Acceptance #7: v12 populated database upgrades preserving all transactions, postings and balances; cross-ledger FK rejected',
    () async {
      final directory = await Directory.systemTemp.createTemp('ledger-v12-');
      final file = File('${directory.path}/data.sqlite');
      final legacy = sql.sqlite3.open(file.path);
      try {
        for (final statement in schemaStatements.where(
          (statement) => !familyPaymentSchemaStatements.contains(statement),
        )) {
          legacy.execute(statement);
        }
        legacy.execute(
          "INSERT INTO ledgers VALUES ('personal','个人账本','CNY','2026-09-01T00:00:00.000Z')",
        );
        legacy.execute(
          "INSERT INTO currencies VALUES ('personal','CNY','人民币','¥',1000000,2,'2026-09-01T00:00:00.000Z')",
        );
        legacy.execute(
          "INSERT INTO accounts (id,ledger_id,name,kind,currency,opening_minor,created_at) VALUES ('acc-1','personal','储蓄卡','bank','CNY',100000,'2026-09-01T00:00:00.000Z')",
        );
        legacy.execute(
          "INSERT INTO categories (id,ledger_id,name,type,sort_order,icon_key) VALUES ('cat-1','personal','餐饮','expense',0,'')",
        );
        legacy.execute("INSERT INTO settings VALUES ('device_id','dev-v12')");
        legacy.execute(
          "INSERT INTO transactions (id,ledger_id,type,amount_minor,currency,account_id,category_id,merchant,note,tags_json,occurred_date,device_id,created_at,updated_at) VALUES ('tx-1','personal','expense',3500,'CNY','acc-1','cat-1','老面馆','','[]','2026-09-15T12:00:00','dev-v12','2026-09-15T12:00:00.000Z','2026-09-15T12:00:00.000Z')",
        );
        legacy.execute(
          "INSERT INTO transaction_postings (id,transaction_id,account_id,delta_minor,currency) VALUES ('post-1','tx-1','acc-1',-3500,'CNY')",
        );
        legacy.execute('PRAGMA user_version=12');
      } finally {
        legacy.dispose();
      }

      final upgraded = AppDatabase(NativeDatabase(file));
      try {
        final repo = LedgerRepository(upgraded);
        await repo.initialize();
        expect(
          (await upgraded.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          16,
        );
        final accounts = await repo.accounts('personal');
        expect(accounts.single.balanceMinor, 96500);
        final entries = await repo.entries('personal');
        expect(entries, hasLength(1));
        expect(entries.single.amountMinor, 3500);

        // Cross-ledger foreign key validation (#11)
        await repo.createLedger('家庭账本');
        final otherLedgerId = (await repo.ledgers()).entries
            .firstWhere((e) => e.value == '家庭账本')
            .key;
        final otherAccount = (await repo.accounts(otherLedgerId)).first;
        await expectLater(
          FamilyPaymentRepository(upgraded).saveCard(
            ledgerId: 'personal',
            platform: FamilyCardPlatform.wechat,
            displayName: '跨账本错误卡',
            localRole: FamilyLocalRole.payer,
            defaultFundingAccountId: otherAccount.id,
          ),
          throwsA(isA<LedgerException>()),
        );

        // Export & restore after upgrade preserves everything
        final backupBytes = await BackupService(
          upgraded,
        ).export('upgrade-pass');
        final restoredDb = AppDatabase.memory();
        try {
          await LedgerRepository(restoredDb).initialize();
          await BackupService(restoredDb).restore(backupBytes, 'upgrade-pass');
          expect(
            (await LedgerRepository(
              restoredDb,
            ).accounts('personal')).single.balanceMinor,
            96500,
          );
        } finally {
          await restoredDb.close();
        }
      } finally {
        await upgraded.close();
      }

      // Reopening the already-upgraded database is idempotent
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        expect(
          (await LedgerRepository(
            reopened,
          ).accounts('personal')).single.balanceMinor,
          96500,
        );
      } finally {
        await reopened.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Acceptance #8: refund and void keep family-card quota, bill summary and account postings consistent',
    () async {
      final accounts = await repository.accounts('personal');
      final categories = await repository.categories('personal');
      final expense = categories.firstWhere(
        (c) => c.type == TransactionType.expense,
      );
      await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.alipay,
        displayName: '父母亲情卡',
        localRole: FamilyLocalRole.payer,
        senderLimitMinor: 100000,
        userLimitMinor: 80000,
        defaultFundingAccountId: accounts.first.id,
        defaultCategoryId: expense.id,
      );
      final eventId = await family.observeCapture(
        captureId: '8' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.alipay,
        sourceKind: 'notification',
        sourcePackage: 'com.eg.android.AlipayGphone',
        amountMinor: 10000,
        merchant: '生鲜超市',
        occurredAt: DateTime(2026, 10, 14, 11, 0),
        rawText: '亲情卡付款成功 100.00元 生鲜超市 订单号 2026101488887777',
      );
      await family.confirmFamilyEvent(
        ledgerId: 'personal',
        eventId: eventId!,
        localRole: FamilyLocalRole.payer,
      );
      expect(
        (await family.cards(
          'personal',
          month: DateTime(2026, 10),
        )).single.usedMinor,
        10000,
      );
      expect(
        (await repository.accounts('personal')).first.balanceMinor,
        -10000,
      );
      expect(
        (await repository.summary('personal', DateTime(2026, 10))).expenseMinor,
        10000,
      );

      // Partial refund of 30.00 yuan (3000 minor)
      await family.applyRefund(
        ledgerId: 'personal',
        eventId: eventId,
        refundMinor: 3000,
        occurredAt: DateTime(2026, 10, 14, 12, 0),
      );
      expect(
        (await family.cards(
          'personal',
          month: DateTime(2026, 10),
        )).single.usedMinor,
        7000,
      );
      expect((await repository.accounts('personal')).first.balanceMinor, -7000);
      expect(
        (await repository.summary('personal', DateTime(2026, 10))).expenseMinor,
        7000,
      );

      // Void event -> quota used, bill summary, and account balance all return to 0
      await family.voidEvent(ledgerId: 'personal', eventId: eventId);
      expect(
        (await family.cards(
          'personal',
          month: DateTime(2026, 10),
        )).single.usedMinor,
        0,
      );
      expect((await repository.accounts('personal')).first.balanceMinor, 0);
      expect(
        (await repository.summary('personal', DateTime(2026, 10))).expenseMinor,
        0,
      );
      expect(
        (await family.event('personal', eventId))!.status,
        FamilyPaymentStatus.voided,
      );
    },
  );

  test('family-card accounts and events survive encrypted backup', () async {
    await family.saveCard(
      ledgerId: 'personal',
      platform: FamilyCardPlatform.alipay,
      displayName: '孩子的支付宝亲情卡',
      localRole: FamilyLocalRole.payer,
      payerLabel: '我',
      beneficiaryLabel: '孩子',
      senderLimitMinor: 50000,
      userLimitMinor: 30000,
      defaultFundingAccountId: (await repository.accounts('personal')).first.id,
    );
    final bytes = await BackupService(db).export('family-card-password');
    final restored = AppDatabase.memory();
    try {
      await LedgerRepository(restored).initialize();
      await BackupService(restored).restore(bytes, 'family-card-password');
      final cards = await FamilyPaymentRepository(restored).cards('personal');
      expect(cards, hasLength(1));
      expect(cards.single.card.platform, FamilyCardPlatform.alipay);
      expect(cards.single.card.localRole, FamilyLocalRole.payer);
      expect(cards.single.card.senderLimitMinor, 50000);
      expect(cards.single.card.userLimitMinor, 0);
    } finally {
      await restored.close();
    }
  });

  testWidgets(
    'family-card editor exposes one role limit and retains pending review flow',
    (tester) async {
      await family.saveCard(
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        displayName: '妈妈的微信亲属卡',
        localRole: FamilyLocalRole.beneficiary,
        senderLimitMinor: 100000,
        userLimitMinor: 80000,
      );
      await family.observeCapture(
        captureId: '9' * 64,
        ledgerId: 'personal',
        platform: FamilyCardPlatform.wechat,
        sourceKind: 'notification',
        sourcePackage: 'com.tencent.mm',
        amountMinor: 1800,
        merchant: '早餐铺',
        occurredAt: DateTime.now(),
        rawText: '亲属卡支付 18.00元 早餐铺',
      );
      final state = LedgerController(repository);
      await state.load();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repository),
            ledgerProvider.overrideWith((ref) => state),
          ],
          child: const MaterialApp(home: FamilyCardsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('亲情卡账户'), findsOneWidget);
      expect(find.textContaining('不是真实资产余额'), findsOneWidget);
      expect(find.textContaining('待审核交易'), findsOneWidget);
      expect(find.text('审核并确认'), findsOneWidget);

      await tester.tap(find.text('新增亲情卡'));
      await tester.pumpAndSettle();
      expect(find.text('使用方月度额度'), findsOneWidget);
      expect(find.text('发送方月度额度'), findsNothing);
      expect(find.text('真实扣款账户（选填）'), findsNothing);

      await tester.tap(find.text('使用方 / 用款方'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送方 / 代付方').last);
      await tester.pumpAndSettle();
      expect(find.text('发送方月度额度'), findsOneWidget);
      expect(find.text('使用方月度额度'), findsNothing);
      expect(find.text('真实扣款账户（选填）'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('审核并确认'));
      await tester.pumpAndSettle();
      expect(find.text('审核亲情卡交易'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('审核亲情卡交易'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('family cards remain integrated into the account page', (
    tester,
  ) async {
    await family.saveCard(
      ledgerId: 'personal',
      platform: FamilyCardPlatform.wechat,
      displayName: '妈妈的亲属卡',
      localRole: FamilyLocalRole.beneficiary,
      userLimitMinor: 80000,
    );
    final state = LedgerController(repository);
    await state.load();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AccountsPage(state: state)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('妈妈的亲属卡'), findsOneWidget);
    expect(find.textContaining('微信亲属卡 · 使用方'), findsOneWidget);
    expect(find.text('全部账户 · 5'), findsOneWidget);

    await tester.tap(find.byTooltip('新增账户'));
    await tester.pumpAndSettle();
    expect(find.text('资金与负债账户'), findsOneWidget);
    expect(find.text('亲情卡账户'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
