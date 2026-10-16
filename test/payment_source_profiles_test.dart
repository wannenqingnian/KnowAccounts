import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/payment_apps.dart';
import 'package:smart_ledger/automation/payment_capture_parser.dart';
import 'package:smart_ledger/automation/payment_source_profiles.dart';
import 'package:smart_ledger/transaction/parser/ocr_receipt_parser.dart';

class _Case {
  const _Case(this.text);

  final String text;
  int get amount => 1600;
  String get merchant => '瑞幸咖啡';
}

void main() {
  const date = '交易时间 2026年10月12日 10:30:00';
  final cases = <String, _Case>{
    'com.tencent.mm': const _Case('支付成功\n支出¥16.00\n收款方 示例商户\n付款方式 零钱\n$date'),
    'com.eg.android.AlipayGphone': const _Case(
      '代付成功\n订单金额 16.00元\n收款方 示例商户\n交易方式 余额宝\n$date',
    ),
    'com.jingdong.app.mall': const _Case(
      '付款成功\n实付 16.00元\n商品名称 示例商户\n支付方式 京东白条\n$date',
    ),
    'com.jd.jrapp': const _Case('交易成功\n实付 16.00元\n交易说明 示例商户\n支付方式 京东支付\n$date'),
    'com.sankuai.meituan': const _Case(
      '支付成功 ¥16.00\n商户名称 示例商户\n支付方式 美团月付\n$date',
    ),
    'com.sankuai.meituan.takeoutnew': const _Case(
      '交易成功 ¥16.00\n商户名称 示例商户\n支付方式 微信支付\n$date',
    ),
    'com.unionpay': const _Case(
      '支付成功\n实付金额（元） 16.00\n商户名称 示例商户\n付款卡 招商银行尾号1234\n订单时间 2026年10月12日 10:30:00',
    ),
    'com.taobao.taobao': const _Case(
      '免密支付成功\n实付价 16.00元\n商户名称 示例商户\n付款方式 支付宝余额\n$date',
    ),
    'com.xunmeng.pinduoduo': const _Case(
      '拼单成功\n交易金额 16.00元\n已选择：示例商户\n支付方式 多多支付\n$date',
    ),
    'com.ss.android.ugc.aweme': const _Case(
      '购买成功\n实付16.00元\n团购头图\n示例商户\n支付方式 抖音支付\n$date',
    ),
    'me.ele': const _Case(
      '下单成功，商家已接单\n16.00元\n提交订单\n商户名称 示例商户\n付款方式 支付宝\n$date',
    ),
    'com.sdu.didi.psnger': const _Case(
      '支付成功\n实付车费 16.00元\n服务商 示例商户\n支付渠道 微信支付\n完成时间 2026年10月12日 10:30:00',
    ),
    'com.huawei.wallet': const _Case(
      '交易成功\n交易金额 16.00元\n商家 示例商户\n付款银行 招商银行尾号1234\n$date',
    ),
    'com.dianping.v1': const _Case('支付成功 ¥16.00\n商户名称 示例商户\n支付方式 微信支付\n$date'),
    'com.ss.android.ugc.aweme.lite': const _Case(
      '自动付款成功\n实付 16.00元\n已选择 示例商户\n付款方式 抖音月付\n$date',
    ),
    'com.ss.android.ugc.livelite': const _Case(
      '入账成功\n实付价 16.00元\n商户名称 示例商户\n交易方式 抖音支付\n$date',
    ),
    'com.ss.android.yumme.video': const _Case(
      '支付成功16.00\n商户名称 示例商户\n付款方式 抖音支付\n$date',
    ),
    'com.wudaokou.hippo': const _Case(
      '支付成功：¥16.00\n商户名称 示例商户\n优先使用此付款方式 盒马礼品卡\n$date',
    ),
    'com.kuaishou.nebula': const _Case(
      '购买成功\n立即支付16.00元\n关注\n示例商户\n付款方式 微信支付\n$date',
    ),
    'com.smile.gifmaker': const _Case(
      '支付成功\n实付16.00元\n进店\n示例商户\n付款方式 支付宝\n$date',
    ),
    'com.alibaba.wireless': const _Case(
      '付款成功\n立即支付16.00元\n某某有限公司\n示例商户\n付款方式 支付宝\n$date',
    ),
    'com.taobao.idlefish': const _Case('支付成功\n现价16.00元\n示例商户\n付款方式 支付宝\n$date'),
    'com.ccb.longjiLife': const _Case(
      '支付成功\n交易金额 16.00元\n商户名 示例商户\n优先选择此方式支付 建设银行尾号1234\n$date',
    ),
  };

  test('every enabled source owns a deep field profile', () {
    expect(
      cases.keys.toSet(),
      paymentApps.map((app) => app.packageName).toSet(),
    );
    expect(paymentSourceProfiles.keys.toSet(), cases.keys.toSet());
  });

  test('all 23 source vocabularies normalize amount merchant and date', () {
    for (final app in paymentApps) {
      final sample = cases[app.packageName]!;
      final normalized = paymentSourceProfile(
        app.packageName,
      ).normalize(sample.text.replaceAll('示例商户', '瑞幸咖啡'));
      final receipt = OcrReceiptParser().parse(normalized);
      expect(receipt, isNotNull, reason: '${app.name}\n$normalized');
      expect(
        receipt!.amountMinor,
        sample.amount,
        reason: '${app.name}\n$normalized',
      );
      expect(
        receipt.merchant,
        sample.merchant,
        reason: '${app.name}\n$normalized',
      );
      expect(
        receipt.date,
        '2026-10-12T10:30:00',
        reason: '${app.name}\n$normalized',
      );
      expect(
        PaymentCaptureParser.successful(app.packageName, sample.text),
        true,
        reason: app.name,
      );
    }
  });

  test('application-only completion words never leak to another source', () {
    expect(PaymentCaptureParser.successful('com.smile.gifmaker', '购买成功'), true);
    expect(
      PaymentCaptureParser.successful('com.eg.android.AlipayGphone', '购买成功'),
      false,
    );
    expect(
      PaymentCaptureParser.successful('com.xunmeng.pinduoduo', '拼单成功'),
      true,
    );
    expect(PaymentCaptureParser.successful('com.taobao.taobao', '拼单成功'), false);
  });
}
