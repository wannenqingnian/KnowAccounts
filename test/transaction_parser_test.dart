import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/chinese_number_parser.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  final numbers = ChineseNumberParser();
  final examples = {
    '三十八块五': 3850,
    '两百八': 28000,
    '一千二': 120000,
    '三千零八': 300800,
    '一万零二': 1000200,
    '一万二': 1200000,
    '十二元': 1200,
    '零点五': 50,
    '三十八点五元': 3850,
    '38.50元': 3850,
    '42块5': 4250,
    '42块50': 4250,
    '七毛': 70,
    '一分': 1,
    '三十八元五角二分': 3852,
    '壹佰贰拾叁圆肆角伍分': 12345,
    '9999999999.99': 999999999999,
  };
  for (final e in examples.entries) {
    test(
      'exact money: ${e.key}',
      () => expect(numbers.parseMinor(e.key), e.value),
    );
  }
  test('invalid amounts cannot become money', () {
    for (final text in [
      '0',
      '-38',
      '十百',
      '三十八元五十角',
      '1.234',
      '一百百',
      '一二十',
      '99999999999',
      '38元100',
      '1e3',
      '半百',
      '38..5',
    ]) {
      expect(numbers.parseMinor(text), isNull, reason: text);
    }
  });
  const accounts = [
    Account(
      id: 'wechat',
      name: '微信',
      kind: AccountKind.wechat,
      openingMinor: 0,
      balanceMinor: 0,
    ),
    Account(
      id: 'alipay',
      name: '支付宝',
      kind: AccountKind.alipay,
      openingMinor: 0,
      balanceMinor: 0,
    ),
  ];
  const categories = [
    Category(id: 'food', name: '餐饮', type: TransactionType.expense),
    Category(
      id: 'coffee',
      name: '咖啡',
      type: TransactionType.expense,
      parentId: 'food',
    ),
    Category(id: 'transport', name: '交通', type: TransactionType.expense),
    Category(
      id: 'taxi',
      name: '打车',
      type: TransactionType.expense,
      parentId: 'transport',
    ),
    Category(id: 'shopping', name: '购物', type: TransactionType.expense),
    Category(
      id: 'household',
      name: '日用品',
      type: TransactionType.expense,
      parentId: 'shopping',
    ),
    Category(id: 'salary', name: '工资', type: TransactionType.income),
  ];
  TransactionDraft parse(
    String text, {
    DateTime? now,
    List<Account>? customAccounts,
  }) => TransactionParser().parse(
    RawTransaction(text: text, capturedAt: now ?? DateTime(2026, 10, 5, 10)),
    ledgerId: 'personal',
    accounts: customAccounts ?? accounts,
    categories: categories,
  );

  test('Chinese example resolves five fields and stays a draft', () {
    final d = parse('昨天晚上滴滴四十二块五，支付宝付的');
    expect(d.amountMinor, 4250);
    expect(d.merchant, '滴滴');
    expect(d.categoryId, 'taxi');
    expect(d.accountId, 'alipay');
    expect(d.occurredDate, DateTime(2026, 10, 4, 10));
    expect(d.blocked, isFalse);
    expect(d.warnings, isEmpty);
    expect(d.raw.text, '昨天晚上滴滴四十二块五，支付宝付的');
  });
  test('bare amount is a suggestion and relative date crosses month', () {
    final d = parse('昨天滴滴42支付宝', now: DateTime(2026, 3, 1));
    expect(d.occurredDate, DateTime(2026, 2, 28));
    expect(d.amountMinor, 4200);
    expect(d.warnings, contains('金额未注明元，按人民币理解，请核对'));
  });
  test('salary in Alipay is income, not contradictory payment', () {
    final d = parse('今天工资到账五千元，支付宝');
    expect(d.type, TransactionType.income);
    expect(d.amountMinor, 500000);
    expect(d.categoryId, 'salary');
    expect(d.blocked, isFalse);
  });
  test('OCR-style text excludes date, clock and order number', () {
    final d = parse(
      '2026-10-04 19:42\n订单号：202610048888\n微信支付 ￥38.50\nSTARBUCKS 0234',
    );
    expect(d.amountMinor, 3850);
    expect(d.merchant, '星巴克');
    expect(d.categoryId, 'coffee');
    expect(d.occurredDate, DateTime(2026, 10, 4, 19, 42));
  });
  test('multiple prices/accounts are unresolved, even with equal amounts', () {
    final d = parse('瑞幸38元，优惠5元，微信或支付宝');
    expect(d.amountMinor, isNull);
    expect(d.accountId, isNull);
    expect(d.warnings, contains('识别到多个金额，请手动选择本笔交易金额'));
    expect(parse('早餐20元，晚餐20元').amountMinor, isNull);
  });
  test('duplicate account kinds do not silently pick an account', () {
    const extra = Account(
      id: 'other',
      name: '工作微信',
      kind: AccountKind.wechat,
      openingMinor: 0,
      balanceMinor: 0,
    );
    expect(
      parse('微信消费38元', customAccounts: [...accounts, extra]).accountId,
      isNull,
    );
  });
  test('explicit category beats merchant suggestion', () {
    expect(parse('今天Costco日用品两百八元支付宝').categoryId, 'household');
  });
  test(
    'unknown merchant is not invented and explicit parent/child use child',
    () {
      final d = parse('今天餐饮咖啡38元微信未知小店');
      expect(d.merchant, isEmpty);
      expect(d.categoryId, 'coffee');
    },
  );
  test(
    'foreign currencies, transfers, refunds and mixed directions are blocked',
    () {
      for (final text in [
        '微信退款38元',
        '支付宝转账38元',
        '咖啡USD38',
        '收到工资1000元又消费20元',
      ]) {
        expect(parse(text).blocked, isTrue, reason: text);
      }
    },
  );
  test('invalid calendar date does not normalize into another month', () {
    final d = parse('2026-02-30 微信消费38元');
    expect(d.occurredDate, DateTime(2026, 10, 5, 10));
    expect(d.warnings, contains('日期无效，暂用今天，请核对'));
  });
  test('IDs, negative amounts, oversized input cannot silently post', () {
    expect(parse('订单号202600048').amountMinor, isNull);
    expect(parse('价格-38元').amountMinor, isNull);
    expect(parse('价格38.123元').amountMinor, isNull);
    expect(parse('').blocked, isTrue);
    expect(parse('元' * 4001).blocked, isTrue);
    expect(parse('一起吃饭').amountMinor, isNull);
    expect(parse('咖啡12,34元微信').amountMinor, isNull);
  });
  test('quantity after price is not a fractional amount', () {
    expect(parse('今天咖啡38元一杯微信').amountMinor, 3800);
    expect(parse('今天午餐38元三个人微信').amountMinor, 3800);
    expect(parse('今天咖啡38元五角一杯微信').amountMinor, 3850);
  });
  test('fullwidth OCR digits and grouped thousands are supported', () {
    expect(parse('今天工资１，２００．５０元支付宝').amountMinor, 120050);
    expect(parse('今天工资壹佰贰拾叁圆支付宝').amountMinor, 12300);
    expect(parse('今天咖啡￥三十八块五微信').amountMinor, 3850);
  });
  test(
    'payment screenshot payee field is not income; actual mixed receipt remains blocked',
    () {
      final draft = parse('支付宝\n付款成功\n¥38.50\n收款商户 瑞幸咖啡\n付款方式 支付宝\n账单分类 咖啡');
      expect(draft.type, TransactionType.expense);
      expect(draft.blocked, isFalse);
      expect(draft.amountMinor, 3850);
      expect(parse('收款38元，支出20元').blocked, isTrue);
      expect(parse('收款38元微信').type, TransactionType.income);
    },
  );
}
