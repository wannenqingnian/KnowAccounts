import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/family_payment.dart';
import 'package:smart_ledger/automation/payment_apps.dart';
import 'package:smart_ledger/automation/payment_capture_parser.dart';
import 'package:smart_ledger/automation/payment_capture_processor.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  late List<Account> accounts;
  late List<Category> categories;
  final time = DateTime(2026, 10, 5, 12, 5);
  PaymentCapture event(
    String text, {
    String kind = 'notification',
    String packageName = 'com.eg.android.AlipayGphone',
    String? accountId,
    String? categoryId,
    bool autoSave = true,
    String digit = 'a',
    String ledger = 'personal',
  }) => PaymentCapture(
    id: digit * 64,
    packageName: packageName,
    kind: kind,
    text: text,
    capturedAt: time,
    ledgerId: ledger,
    accountId: accountId,
    categoryId: categoryId,
    autoSave: autoSave,
  );
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    accounts = await repo.accounts('personal');
    categories = await repo.categories('personal');
  });
  tearDown(() => db.close());
  const complete =
      '支付成功\n商户名称 瑞幸咖啡\n交易金额 38.50元\n支付方式 微信零钱\n支付时间 2026-10-05 12:05';
  test(
    'reimbursement receipt never auto posts as ordinary income and text source directs linking',
    () async {
      final text =
          '到账成功\n商户名称 公司财务\n交易金额 100.00元\n支付方式 微信零钱\n支付时间 2026-10-05\n分类 工资\n备注 报销到账';
      final capture = event(text);
      final parsed = PaymentCaptureParser().parse(
        capture,
        accounts,
        categories,
        now: time,
      );
      expect(parsed.canAutoSave, false);
      expect(parsed.draft.warnings.any((w) => w.contains('报销')), true);
      await PaymentCaptureProcessor(repo).process(capture, now: time);
      expect(await repo.entries('personal'), isEmpty);
      expect(await repo.pendingDrafts('personal'), hasLength(1));
      final draft = TransactionParser().parse(
        RawTransaction(
          text: '收到公司报销款到账100元微信',
          source: TransactionSource.text,
          capturedAt: time,
        ),
        ledgerId: 'personal',
        accounts: accounts,
        categories: categories,
      );
      expect(draft.blocked, true);
      expect(draft.warnings.any((w) => w.contains('报销管理')), true);
    },
  );
  test(
    'all twelve allowlisted app envelopes use shared clear receipt fields, not invented app merchants',
    () {
      for (final app in paymentApps) {
        final result = PaymentCaptureParser().parse(
          event(complete, packageName: app.packageName),
          accounts,
          categories,
          now: time,
        );
        expect(result.draft.amountMinor, 3850, reason: app.name);
        expect(result.draft.merchant, '瑞幸咖啡');
        expect(
          result.draft.accountId,
          accounts.firstWhere((a) => a.kind == AccountKind.wechat).id,
        );
        expect(result.draft.warnings, isEmpty, reason: app.name);
        expect(result.canAutoSave, true, reason: app.name);
      }
    },
  );
  test('wechat combined merchant and expense text keeps only merchant', () {
    final parsed = PaymentCaptureParser().parse(
      event(
        '支付成功\n商户名称 精品沙县小吃,支出16.00元\n支付方式 微信零钱\n支付时间 2026-10-05 12:05',
        kind: 'accessibility',
        packageName: 'com.tencent.mm',
      ),
      accounts,
      categories,
      now: time,
    );
    expect(parsed.draft.amountMinor, 1600);
    expect(parsed.draft.merchant, '精品沙县小吃');
  });
  test(
    'background screenshot capture is accepted and produces a reviewable OCR draft',
    () {
      final capture = PaymentCapture.fromJson({
        'id': 'f' * 64,
        'packageName': manualOcrPackage,
        'kind': 'screenshot',
        'text': complete,
        'capturedAt': time.millisecondsSinceEpoch,
        'ledgerId': 'personal',
        'autoSave': false,
      });
      final parsed = PaymentCaptureParser().parse(
        capture,
        accounts,
        categories,
        now: time,
      );
      expect(parsed.draft.amountMinor, 3850);
      expect(parsed.draft.merchant, '瑞幸咖啡');
      expect(parsed.canAutoSave, false);
      expect(parsed.draft.raw.text, contains('本地截图OCR'));
    },
  );
  test(
    'payment capture turns an unmatched partial refund order into net expense',
    () {
      const refund = '''金冠智充
-20.00
退款记录
已退款¥12.93
2026年10月05日 12:54:05
当前状态 已退款(¥12.93)
支付时间 2026年10月05日 12:07:39
商品 用户充值
商户全称 南阳金冠智能开关有限公司
支付方式 零钱
交易单号 4500000483202610119870382192
账单服务''';
      final result = PaymentCaptureParser().parse(
        event(
          refund,
          kind: 'screenshot',
          packageName: manualOcrPackage,
          autoSave: false,
        ),
        accounts,
        categories,
        now: time,
      );
      expect(PaymentCaptureParser.isLikelyBillScreenshot(refund), isTrue);
      expect(result.draft.type, TransactionType.expense);
      expect(result.draft.amountMinor, 707);
      expect(result.draft.evidence['original_amount_minor'], '2000');
      expect(result.draft.evidence['refund_amount_minor'], '1293');
      expect(result.draft.warnings.join(), contains('净消费7.07元'));
      expect(
        result.draft.warnings.any((item) => item.contains('未确认交易成功')),
        isFalse,
      );
      expect(result.canAutoSave, isFalse);
    },
  );
  test('manual OCR recognizes family-card transaction from page title', () {
    const familyCard = '''亲属卡交易-龇牙咧嘴
-8.50
当前状态 支付成功
支付场景 蜜雪冰城
商户简称 蜜雪冰城
交易用户 龇牙咧嘴
支付时间 2026年10月04日 21:56:12
支付方式 零钱
交易单号 4500000472202610049430755405
商户单号 179911967021626100421560331032
账单服务
亲属卡管理''';
    final result = PaymentCaptureParser().parse(
      event(
        familyCard,
        kind: 'screenshot',
        packageName: manualOcrPackage,
        autoSave: false,
      ),
      accounts,
      categories,
      now: time,
    );

    expect(result.draft.amountMinor, 850);
    expect(result.familyPayment?.platform, FamilyCardPlatform.wechat);
    expect(result.familyPayment?.roleHint, isNull);
    expect(result.canAutoSave, isFalse);
    expect(result.draft.warnings.join(), contains('发送方还是使用方'));
  });
  test(
    'quick OCR rejects ordinary app screens instead of opening an empty form',
    () async {
      const ordinaryScreen =
          '账本管理\n金额隐私模式\n自动记账\nOCR模型与图片导入\n'
          '语音模型\n日志记录\n待确认账单 0\n新建账本\n金额，例如16.00\n保存记账';
      expect(
        PaymentCaptureParser.isLikelyBillScreenshot(ordinaryScreen),
        false,
      );
      expect(PaymentCaptureParser.isLikelyBillScreenshot(complete), true);
      final capture = event(
        ordinaryScreen,
        packageName: manualOcrPackage,
        kind: 'screenshot',
        autoSave: false,
        digit: 'e',
      );
      expect(
        await PaymentCaptureProcessor(repo).process(capture, now: time),
        'discarded',
      );
      expect(await repo.pendingDrafts('personal'), isEmpty);
    },
  );
  test(
    'natural payment message uses explicit merchant and configured fixed funding account; unbound waits',
    () {
      final a = accounts.firstWhere((a) => a.kind == AccountKind.alipay);
      const text = '你已向精品沙县小吃付款16.00元，支付成功';
      final parsed = PaymentCaptureParser().parse(
        event(text, accountId: a.id),
        accounts,
        categories,
        now: time,
      );
      expect(parsed.draft.merchant, '精品沙县小吃');
      expect(parsed.draft.amountMinor, 1600);
      expect(parsed.draft.accountId, a.id);
      expect(parsed.canAutoSave, true, reason: parsed.draft.warnings.join(';'));
      expect(
        PaymentCaptureParser()
            .parse(event(text), accounts, categories, now: time)
            .canAutoSave,
        false,
      );
      final unspecified = PaymentCaptureParser().parse(
        event('支付成功，支付了16.00元', accountId: a.id),
        accounts,
        categories,
        now: time,
      );
      expect(unspecified.canAutoSave, false);
      expect(unspecified.draft.merchant, isEmpty);
    },
  );
  test(
    'unknown merchant uses explicit configured category, explicit account overrides default, income is not expense',
    () {
      final a = accounts.firstWhere((a) => a.kind == AccountKind.alipay);
      final category = categories.firstWhere((c) => c.name == '购物');
      final parsed = PaymentCaptureParser().parse(
        event(
          '支付成功\n商户名称 小林手作店\n交易金额 85元\n支付方式 微信零钱\n支付时间 2026-10-05',
          accountId: a.id,
          categoryId: category.id,
        ),
        accounts,
        categories,
        now: time,
      );
      expect(parsed.canAutoSave, true, reason: parsed.draft.warnings.join(';'));
      expect(parsed.draft.accountId, isNot(a.id));
      expect(parsed.draft.categoryId, category.id);
      final explicit = PaymentCaptureParser().parse(
        event(
          '支付成功\n商户名称 小林手作店\n交易金额 85元\n支付方式 微信零钱\n支付时间 2026-10-05\n账单分类 餐饮',
          categoryId: category.id,
        ),
        accounts,
        categories,
        now: time,
      );
      expect(
        explicit.draft.categoryId,
        categories.firstWhere((c) => c.name == '餐饮').id,
      );
      expect(
        explicit.canAutoSave,
        true,
        reason: explicit.draft.warnings.join(';'),
      );
      final income = PaymentCaptureParser().parse(
        event('收款成功\n商户名称 张三\n到账金额 100元\n支付方式 微信零钱\n支付时间 2026-10-05\n账单分类 工资'),
        accounts,
        categories,
        now: time,
      );
      expect(income.draft.type, TransactionType.income);
      expect(income.draft.amountMinor, 10000);
      expect(income.canAutoSave, true, reason: income.draft.warnings.join(';'));
    },
  );
  test(
    'page time cannot be guessed; low information, future dates, failed and promotional/conflicting messages never auto save',
    () {
      for (final text in [
        complete.replaceAll('2026-10-05', '2026-10-06'),
        complete.replaceAll('支付成功', '支付失败'),
        '$complete\n优惠券100元',
        '$complete\n交易金额 78元',
        complete.replaceAll('微信零钱', '银行卡'),
        '支付成功\n金额38.50元',
      ]) {
        expect(
          PaymentCaptureParser()
              .parse(event(text), accounts, categories, now: time)
              .canAutoSave,
          false,
          reason: text,
        );
      }
      expect(
        PaymentCaptureParser()
            .parse(
              event(
                complete.replaceAll('支付时间 2026-10-05 12:05', ''),
                kind: 'accessibility',
              ),
              accounts,
              categories,
              now: time,
            )
            .canAutoSave,
        false,
      );
      final page = PaymentCaptureParser().parse(
        event(complete, kind: 'accessibility'),
        accounts,
        categories,
        now: time,
      );
      expect(page.canAutoSave, true, reason: page.draft.warnings.join(';'));
      expect(
        PaymentCaptureParser()
            .parse(
              event('支付成功\n商户名称 瑞幸咖啡\n交易金额 38.50元\n支付方式 微信零钱'),
              accounts,
              categories,
              now: time.add(const Duration(hours: 2)),
            )
            .canAutoSave,
        false,
      );
    },
  );
  test(
    'alipay transfer and asset labels preserve the primary amount and date',
    () {
      for (final sample in <(String, int)>[
        ('支付宝转账\n转账成功\n转账金额 16.00元\n转账时间 2026年10月05日 12:05:15\n收款方 张三', 1600),
        (
          '结果详情\n提现成功\n提现金额 88.00元\n到账银行卡 招商银行尾号1234\n提现时间 2026年10月05日 12:05:15',
          8800,
        ),
        ('充值成功\n充值金额 20.00元\n充值方式 支付宝余额\n充值时间 2026年10月05日 12:05:15', 2000),
      ]) {
        final parsed = PaymentCaptureParser().parse(
          event(sample.$1, kind: 'accessibility'),
          accounts,
          categories,
          now: time,
        );
        expect(parsed.draft.amountMinor, sample.$2, reason: sample.$1);
        expect(
          parsed.draft.occurredDate,
          DateTime(2026, 10, 5, 12, 5, 15),
          reason: sample.$1,
        );
      }
    },
  );
  test(
    'masked bank tail selects the correct same-bank card; unknown tail never auto saves',
    () {
      const cards = [
        Account(
          id: 'bank1',
          name: '招商卡一',
          kind: AccountKind.bank,
          openingMinor: 0,
          balanceMinor: 0,
          bankId: 'cmb',
          cardLast4: '1111',
        ),
        Account(
          id: 'bank2',
          name: '招商卡二',
          kind: AccountKind.bank,
          openingMinor: 0,
          balanceMinor: 0,
          bankId: 'cmb',
          cardLast4: '2222',
        ),
      ];
      final result = PaymentCaptureParser().parse(
        event(complete.replaceAll('微信零钱', '招商银行储蓄卡****2222')),
        cards,
        categories,
        now: time,
      );
      expect(result.draft.accountId, 'bank2');
      expect(result.canAutoSave, true, reason: result.draft.warnings.join(';'));
      final missing = PaymentCaptureParser().parse(
        event(complete.replaceAll('微信零钱', '招商银行储蓄卡****3333')),
        cards,
        categories,
        now: time,
      );
      expect(missing.draft.accountId, isNull);
      expect(missing.canAutoSave, false);
    },
  );
  test(
    'capture replay after acknowledgement/crash cannot repost even after deleting posted transaction',
    () async {
      final processor = PaymentCaptureProcessor(repo);
      final capture = event(complete);
      expect(await processor.process(capture, now: time), 'posted');
      expect(await processor.process(capture, now: time), 'repeated');
      expect((await repo.entries('personal')).length, 1);
      await repo.delete('personal', (await repo.entries('personal')).single.id);
      expect(await processor.process(capture, now: time), 'repeated');
      expect(await repo.entries('personal'), isEmpty);
    },
  );
  test('historical accessibility refund page is discarded', () async {
    final staleRefund = event(
      '微信支付\n退款成功\n退款金额 12.93元\n退款时间 2026年10月11日 12:54:05\n商户名称 南阳金冠智能开关有限公司',
      kind: 'accessibility',
      packageName: 'com.tencent.mm',
      autoSave: false,
      digit: '9',
    );
    expect(
      await PaymentCaptureProcessor(
        repo,
      ).process(staleRefund, now: DateTime(2026, 10, 16, 20, 17)),
      'discarded',
    );
    expect(await repo.pendingDrafts('personal'), isEmpty);

    final currentRefund = event(
      '微信支付\n退款成功\n退款金额 12.93元\n退款时间 2026年10月16日 20:10:00\n商户名称 南阳金冠智能开关有限公司',
      kind: 'accessibility',
      packageName: 'com.tencent.mm',
      autoSave: false,
      digit: '8',
    );
    expect(
      await PaymentCaptureProcessor(
        repo,
      ).process(currentRefund, now: DateTime(2026, 10, 16, 20, 17)),
      'pending',
    );
  });
  test(
    'notification and accessibility plus OCR cannot auto post two copies; pending duplicate warning survives reload',
    () async {
      final processor = PaymentCaptureProcessor(repo);
      expect(await processor.process(event(complete), now: time), 'posted');
      expect(
        await processor.process(
          event(complete, kind: 'accessibility', digit: 'b'),
          now: time,
        ),
        'pending',
      );
      expect((await repo.entries('personal')).length, 1);
      final pending = (await repo.pendingDrafts('personal')).single;
      expect(pending.storedWarnings.join(';'), contains('疑似重复'));
      expect(
        await processor.process(
          event(complete, kind: 'accessibility', digit: 'b'),
          now: time,
        ),
        'repeated',
      );
      final draft = TransactionParser().parse(
        RawTransaction(
          text: complete,
          capturedAt: time,
          source: TransactionSource.ocr,
        ),
        ledgerId: 'personal',
        accounts: accounts,
        categories: categories,
      );
      final id = await repo.storeDraft(draft);
      final result = await repo.autoConfirmDraft(
        'personal',
        id,
        TransactionInput(
          type: draft.type,
          amountMinor: draft.amountMinor!,
          accountId: draft.accountId!,
          categoryId: draft.categoryId,
          occurredDate: draft.occurredDate,
          merchant: draft.merchant,
        ),
      );
      expect(result, isNull);
      expect((await repo.entries('personal')).length, 1);
    },
  );
  test(
    'manual mode, archived bindings, absent ledgers and malformed envelopes fail closed without losing existing data',
    () async {
      final processor = PaymentCaptureProcessor(repo);
      expect(
        await processor.process(event(complete, autoSave: false), now: time),
        'pending',
      );
      expect(await repo.entries('personal'), isEmpty);
      final a = accounts.firstWhere((a) => a.kind == AccountKind.alipay);
      await repo.setAccountArchived('personal', a.id, true);
      final parsed = PaymentCaptureParser().parse(
        event('支付成功，向瑞幸咖啡付款38.50元', accountId: a.id),
        await repo.accounts('personal'),
        categories,
        now: time,
      );
      expect(parsed.canAutoSave, false);
      expect(
        await processor.process(
          event(complete, ledger: 'absent', digit: 'c'),
          now: time,
        ),
        'discarded',
      );
      for (final bad in [
        <String, dynamic>{},
        {
          'id': 'a' * 64,
          'packageName': 'com.evil.fake',
          'kind': 'notification',
          'text': complete,
          'capturedAt': time.millisecondsSinceEpoch,
          'ledgerId': 'personal',
        },
      ]) {
        expect(() => PaymentCapture.fromJson(bad), throwsFormatException);
      }
      final roundtrip = AutomationConfig.fromJson(
        AutomationConfig(
          enabled: true,
          enhanced: true,
          rules: {'com.tencent.mm': PaymentRule(accountId: a.id)},
        ).toJson(),
      );
      expect(roundtrip.enabled && roundtrip.enhanced, true);
      expect(roundtrip.rule('com.tencent.mm').accountId, a.id);
    },
  );
}
