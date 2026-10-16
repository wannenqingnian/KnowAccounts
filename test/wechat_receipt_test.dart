import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/core/security/source_privacy.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

const receipt = '''先骑后付
-3.50
当前状态 支付成功
支付时间 2026年10月4日 15:05:04
商品 先骑后付
商户全称 北京快松果科技有限公司
收单机构 财付通支付科技有限公司
支付方式 零钱
交易单号 420000000000000000000001
商家小程序 松果出行
账单服务
发起群收款
管理扣费服务''';
void main() {
  const accounts = [
    Account(
      id: 'wx',
      name: '微信',
      kind: AccountKind.wechat,
      openingMinor: 0,
      balanceMinor: 0,
    ),
    Account(
      id: 'bank',
      name: '银行卡',
      kind: AccountKind.bank,
      openingMinor: 0,
      balanceMinor: 0,
    ),
  ];
  const categories = [
    Category(id: 'traffic', name: '交通', type: TransactionType.expense),
  ];
  TransactionDraft parse(
    String text, {
    TransactionSource source = TransactionSource.ocr,
  }) => TransactionParser().parse(
    RawTransaction(
      text: sanitizeSourceText(text),
      capturedAt: DateTime(2026, 10, 5),
      source: source,
    ),
    ledgerId: 'personal',
    accounts: accounts,
    categories: categories,
  );
  test(
    'WeChat negative display amount, wallet, merchant and date ignore footer actions and order number',
    () {
      final d = parse(receipt);
      expect(d.amountMinor, 350);
      expect(d.accountId, 'wx');
      expect(d.merchant, '松果出行');
      expect(d.categoryId, 'traffic');
      expect(d.occurredDate, DateTime(2026, 10, 4, 15, 5, 4));
      expect(d.type, TransactionType.expense);
      expect(d.blocked, isFalse);
    },
  );
  test(
    'phone OCR chatter and confused date do not block receipt confirmation',
    () {
      final d = parse('''查看共享链接内容
(arm = fs)
截图记账点击后会自动截图然后自动截图、识别并生成账单草稿
包含收入和支出说明
先骑后付
在 Cloud 上工作
*O
-3.50
支付成功
sett AIA
20264710 4H 15:05:04
商品
先骑后付
商户全称
北京快松果科技有限公司
收单机构
财付通支付科技有限公司
支付方式
交易单号
420000000000000000000001
商家小程序
SP 松果出行
账单服务
图 发起群收款''');
      expect(d.amountMinor, 350);
      expect(d.type, TransactionType.expense);
      expect(d.blocked, isFalse);
      expect(d.merchant, '松果出行');
      expect(d.categoryId, 'traffic');
      expect(d.occurredDate, DateTime(2026, 10, 4, 15, 5, 4));
      // 财付通 is a payment processor, not evidence of wallet funding.
      expect(d.accountId, isNull);
      expect(d.warnings, contains('OCR支付日期易混字符已修正，请核对'));
    },
  );
  test('ordinary valid date does not receive OCR repair warning', () {
    expect(parse(receipt).warnings, isNot(contains('OCR支付日期易混字符已修正，请核对')));
  });
  test(
    'OCR interword spaces, multiline fields and Unicode minus are supported',
    () {
      final d = parse(
        receipt
            .replaceAll('-3.50', '−3.50')
            .replaceAll('支付时间 ', '支付 时 间\n')
            .replaceAll('2026年10月4日', '2026 年 10 月 4 日')
            .replaceAll('商户全称 ', '商户 全 称\n')
            .replaceAll('支付方式 ', '支付 方式\n')
            .replaceAll('支付成功', '支付 成 功'),
      );
      expect(d.amountMinor, 350);
      expect(d.accountId, 'wx');
      expect(d.blocked, isFalse);
      expect(d.occurredDate, DateTime(2026, 10, 4, 15, 5, 4));
    },
  );
  test(
    'other negative text, real refund and multiple monetary lines are not silently accepted',
    () {
      expect(
        parse('微信付款-3.50元', source: TransactionSource.text).amountMinor,
        isNull,
      );
      expect(parse(receipt.replaceAll('支付成功', '退款成功')).blocked, isTrue);
      expect(
        parse(receipt.replaceAll('-3.50', '-3.50\n-5.00')).amountMinor,
        isNull,
      );
    },
  );
}
