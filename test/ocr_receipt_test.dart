import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/security/source_privacy.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/ocr/ocr_text_selector.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/transaction/parser/ocr_receipt_parser.dart';

const shaxianPhoneText = '''精品沙县小吃
ED 一
ao
& 交易详情
主页
——_
-16.00
Em 信人小
县小吃
k
月DOD /-
文付成功
收单机构
财付通文付科技有限公司
支付时间
2026年10月05日 12:05:15
支付方式
交易单号
450000000000000000000001
114
经营单号
101000000000000000000001
05200
交易服务
@) 对订单有疑惑
EX 发起群收款''';
const shaxianClean = '''精品沙县小吃
交易详情
-16.00
精品沙县小吃
当前状态 支付成功
收单机构 财付通支付科技有限公司
支付时间 2026年10月03日 12:05:15
支付方式 零钱
交易单号 450000000000000000000001
交易服务
发起群收款''';
const testAccounts = [
  Account(
    id: 'wx',
    name: '微信',
    kind: AccountKind.wechat,
    openingMinor: 0,
    balanceMinor: 0,
  ),
  Account(
    id: 'ali',
    name: '支付宝',
    kind: AccountKind.alipay,
    openingMinor: 0,
    balanceMinor: 0,
  ),
  Account(
    id: 'cmb1',
    name: '招行工资卡',
    kind: AccountKind.bank,
    bankId: 'cmb',
    cardLast4: '1234',
    openingMinor: 0,
    balanceMinor: 0,
  ),
  Account(
    id: 'cmb2',
    name: '招行备用卡',
    kind: AccountKind.bank,
    bankId: 'cmb',
    cardLast4: '5678',
    openingMinor: 0,
    balanceMinor: 0,
  ),
];
const testCategories = [
  Category(id: 'food', name: '餐饮', type: TransactionType.expense),
  Category(id: 'coffee', name: '咖啡', type: TransactionType.expense),
  Category(id: 'salary', name: '工资', type: TransactionType.income),
];
TransactionDraft receiptDraft(String text) => TransactionParser().parse(
  RawTransaction(
    text: sanitizeSourceText(text),
    capturedAt: DateTime(2026, 10, 5),
    source: TransactionSource.ocr,
  ),
  ledgerId: 'personal',
  accounts: testAccounts,
  categories: testCategories,
);

void main() {
  test('labelled payment time preserves seconds', () {
    final receipt = OcrReceiptParser().parse(
      '支付宝转账\n转账成功\n转账金额 16.00元\n转账时间 2026年10月05日 12:05:15\n收款方 张三',
    );
    expect(receipt?.date, '2026-10-05T12:05:15');
  });
  test(
    'PP-OCR missing date separators are fixed only in a complete fixed-width clock format',
    () {
      final draft = receiptDraft(
        shaxianClean.replaceAll('2026年10月03日 12:05:15', '2026年100312:05:15'),
      );
      expect(draft.occurredDate, DateTime(2026, 10, 3, 12, 5, 15));
      expect(draft.warnings.any((s) => s.contains('分隔符缺失')), isTrue);
      final oneMissing = receiptDraft(
        shaxianClean.replaceAll('2026年10月03日 12:05:15', '2026年1003日12:05:15'),
      );
      expect(oneMissing.occurredDate, DateTime(2026, 10, 3, 12, 5, 15));
      final invalid = receiptDraft(
        shaxianClean.replaceAll('2026年10月03日 12:05:15', '2026年130312:05:15'),
      );
      expect(invalid.occurredDate, DateTime(2026, 10, 5));
      final incomplete = receiptDraft(
        shaxianClean.replaceAll('2026年10月03日 12:05:15', '2026年1003'),
      );
      expect(incomplete.occurredDate, DateTime(2026, 10, 5));
    },
  );
  test('a funding account value is not split by a numeric balance label', () {
    final draft = receiptDraft(
      '付款成功\n商户名称：未知书店\n实付金额：31.20元\n付款方式：余额宝\n支付时间：2026-10-03',
    );
    expect(draft.accountId, 'ali');
    expect(draft.amountMinor, 3120);
  });

  test(
    'new phone output uses unknown title without learning one merchant name',
    () {
      final d = receiptDraft(shaxianPhoneText);
      expect(d.amountMinor, 1600);
      expect(d.merchant, '精品沙县小吃');
      expect(d.categoryId, 'food');
      expect(d.accountId, isNull);
      expect(d.blocked, isFalse);
      expect(d.occurredDate, DateTime(2026, 10, 5, 12, 5, 15));
      final changed = receiptDraft(
        shaxianPhoneText.replaceAll('精品沙县小吃', '巷口面馆'),
      );
      expect(changed.merchant, '巷口面馆');
      expect(changed.amountMinor, 1600);
    },
  );
  test(
    'different WeChat layout: clean image text has wallet and October 3 date',
    () {
      expect(
        OcrReceiptParser().parse(sanitizeSourceText(shaxianClean))?.date,
        '2026-10-03T12:05:15',
      );
      final d = receiptDraft(shaxianClean);
      expect(d.amountMinor, 1600);
      expect(d.accountId, 'wx');
      expect(d.merchant, '精品沙县小吃');
      expect(d.occurredDate, DateTime(2026, 10, 3, 12, 5, 15));
    },
  );
  test(
    'Alipay order: actual payment beats order price, discount and balance',
    () {
      final d = receiptDraft('''付款成功
商家名称 远方咖啡店
订单金额 ¥36.00
优惠 ¥5.00
实付金额 ¥31.00
账户余额 ¥900.00
付款方式 余额宝
创建时间 2026-10-02 09:00
支付时间 2026-10-03 10:00''');
      expect(d.amountMinor, 3100);
      expect(d.merchant, '远方咖啡店');
      expect(d.categoryId, 'coffee');
      expect(d.accountId, 'ali');
      expect(d.occurredDate, DateTime(2026, 10, 3, 10));
      expect(d.blocked, isFalse);
    },
  );
  test(
    'partially refunded order uses original minus refund as net expense',
    () {
      final d = receiptDraft('''金冠智充
-20.00
退款记录
已退款¥12.93
2026年10月11日 12:54:05
当前状态 已退款(¥12.93)
支付时间 2026年10月11日 12:07:39
商品 用户充值
商户全称 南阳金冠智能开关有限公司
收单机构 上海汇付支付有限公司
支付方式 零钱
交易单号 4500000483202610119870382192
商户单号 02212610114365344719916
账单服务''');

      expect(d.type, TransactionType.expense);
      expect(d.amountMinor, 707);
      expect(d.occurredDate, DateTime(2026, 10, 11, 12, 7, 39));
      expect(d.merchant, '南阳金冠智能开关有限公司');
      expect(d.accountId, 'wx');
      expect(d.blocked, isFalse);
      expect(d.evidence['original_amount_minor'], '2000');
      expect(d.evidence['refund_amount_minor'], '1293');
      expect(d.evidence['net_amount_minor'], '707');
      expect(d.warnings.join(), contains('净消费7.07元'));

      final withoutRefundTime = receiptDraft('''金冠智充
-20.00
当前状态 已退款(¥12.93)
支付时间 2026年10月03日 12:07:39
商户全称 南阳金冠智能开关有限公司
支付方式 零钱''');
      expect(withoutRefundTime.amountMinor, 707);
      expect(withoutRefundTime.occurredDate, DateTime(2026, 10, 3, 12, 7, 39));
      expect(withoutRefundTime.warnings, contains('退款页面未提供退款时间，暂按识别日期，请核对'));
    },
  );
  test('bank payment account is scoped to funding field, not payee bank', () {
    final d = receiptDraft('''消费成功
交易金额 1,234.56元
商户名称 未知直营店
付款账户 招商银行(1234)
收款单位 中国工商银行服务中心
交易时间 2026.10.03 15:04''');
    expect(d.amountMinor, 123456);
    expect(d.accountId, 'cmb1');
    expect(d.merchant, '未知直营店');
    expect(d.occurredDate, DateTime(2026, 10, 3, 15, 4));
    expect(d.blocked, isFalse);
  });
  test('receipt total excludes item prices, cash tender and change', () {
    final d = receiptDraft('''邻里超市
牛奶 ¥12.50
水果 ¥20.00
合计 32.50
现金 50.00
找零 17.50
付款方式 微信
交易时间 2026/10/03 19:00''');
    expect(d.amountMinor, 3250);
    expect(d.accountId, 'wx');
    expect(d.blocked, isFalse);
  });
  test(
    'receipt income direction uses type/status rather than payment-method label',
    () {
      final d = receiptDraft('''当前状态 收款成功
收支类型 收入
到账金额 +5000.00
账单分类 工资
支付方式 支付宝
交易时间 2026-10-03''');
      expect(d.type, TransactionType.income);
      expect(d.amountMinor, 500000);
      expect(d.categoryId, 'salary');
      expect(d.blocked, isFalse);
    },
  );
  test(
    'conflicting strong amounts, pending payments and multiple bills do not silently post',
    () {
      expect(
        receiptDraft(
          shaxianClean
              .replaceAll('-16.00', '-18.00')
              .replaceAll('交易服务', '实付金额 16.00\n交易服务'),
        ).amountMinor,
        isNull,
      );
      expect(
        receiptDraft(shaxianClean.replaceAll('支付成功', '待支付')).blocked,
        isTrue,
      );
      expect(
        receiptDraft(
          '支付成功\n金额 ¥16.00\n支付成功\n金额 ¥28.00\n支付时间 2026-10-03',
        ).blocked,
        isTrue,
      );
      expect(
        receiptDraft(shaxianClean.replaceAll('支付成功', '退款成功')).blocked,
        isTrue,
      );
      expect(
        receiptDraft(shaxianClean.replaceAll('-16.00', r'USD $16.00')).blocked,
        isTrue,
      );
    },
  );
  test('layout passes fill missing fields and retain guards before footer', () {
    final better = shaxianClean.replaceAll('2026年10月03日', '2026年10月05日');
    final d = receiptDraft(selectOcrText([shaxianPhoneText, better]));
    expect(d.amountMinor, 1600);
    expect(d.accountId, 'wx');
    expect(d.merchant, '精品沙县小吃');
    final dateConflict = receiptDraft(
      selectOcrText([shaxianPhoneText, shaxianClean]),
    );
    expect(dateConflict.occurredDate, DateTime(2026, 10, 5));
    expect(dateConflict.warnings, contains('多次识别日期不一致，请核对'));
    final moneyConflict = receiptDraft(
      selectOcrText([
        shaxianClean,
        shaxianClean.replaceAll('-16.00', '-18.00'),
      ]),
    );
    expect(moneyConflict.amountMinor, isNull);
    final accountConflict = receiptDraft(
      selectOcrText([
        shaxianClean,
        shaxianClean.replaceAll('零钱', '招商银行(1234)'),
      ]),
    );
    expect(accountConflict.accountId, isNull);
  });
  test('same price repeated in labelled payment fields is one transaction', () {
    final d = receiptDraft(
      '付款成功\n支付金额 ￥１６．００\n实付金额 16.00元\n商户名称 新邻居小吃\n支付方式 零钱\n支付时间 2026-10-03',
    );
    expect(d.amountMinor, 1600);
    expect(d.merchant, '新邻居小吃');
    expect(d.blocked, isFalse);
  });
  test(
    'merchant before headline amount and provider-only header do not infer funding',
    () {
      final d = receiptDraft(
        '支付宝\n商户名称 另一家面馆\n-25.00\n当前状态 支付成功\n支付时间 2026-10-03',
      );
      expect(d.amountMinor, 2500);
      expect(d.merchant, '另一家面馆');
      expect(d.accountId, isNull);
    },
  );
  test('adjacent OCR clock and leading field separators are normalized', () {
    final d = receiptDraft(
      '消费成功\n交易金额 16.00元\n付款账户 >招商银行( 1234 )\n交易时间 |2026-10-0315:04',
    );
    expect(d.accountId, 'cmb1');
    expect(d.occurredDate, DateTime(2026, 10, 3, 15, 4));
  });
  test(
    'redacted order identifier above its label is not a funding card tail',
    () {
      final d = receiptDraft(
        '支付成功\n金额 16.00元\n支付方式\n450000000000000000001234\n交易单号\n114\n支付时间 2026-10-03',
      );
      expect(d.amountMinor, 1600);
      expect(d.accountId, isNull);
    },
  );
}
