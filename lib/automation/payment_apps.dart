class PaymentApp {
  const PaymentApp(this.packageName, this.name);
  final String packageName, name;
}

const manualOcrPackage = 'com.smartledger.capture.ocr';

bool isPaymentCapturePackage(String packageName) =>
    packageName == manualOcrPackage ||
    paymentApps.any((app) => app.packageName == packageName);

String paymentCaptureSourceName(String packageName) =>
    packageName == manualOcrPackage
    ? 'OCR截图'
    : paymentApps.firstWhere((app) => app.packageName == packageName).name;

const paymentApps = [
  PaymentApp('com.tencent.mm', '微信'),
  PaymentApp('com.eg.android.AlipayGphone', '支付宝'),
  PaymentApp('com.jingdong.app.mall', '京东'),
  PaymentApp('com.jd.jrapp', '京东金融'),
  PaymentApp('com.sankuai.meituan', '美团'),
  PaymentApp('com.sankuai.meituan.takeoutnew', '美团外卖'),
  PaymentApp('com.unionpay', '云闪付'),
  PaymentApp('com.taobao.taobao', '淘宝'),
  PaymentApp('com.xunmeng.pinduoduo', '拼多多'),
  PaymentApp('com.ss.android.ugc.aweme', '抖音'),
  PaymentApp('me.ele', '淘宝闪购 / 饿了么'),
  PaymentApp('com.sdu.didi.psnger', '滴滴'),
  PaymentApp('com.huawei.wallet', '华为钱包'),
  PaymentApp('com.dianping.v1', '大众点评'),
  PaymentApp('com.ss.android.ugc.aweme.lite', '抖音极速版'),
  PaymentApp('com.ss.android.ugc.livelite', '抖音火山版'),
  PaymentApp('com.ss.android.yumme.video', '红果短剧'),
  PaymentApp('com.wudaokou.hippo', '盒马'),
  PaymentApp('com.kuaishou.nebula', '快手极速版'),
  PaymentApp('com.smile.gifmaker', '快手'),
  PaymentApp('com.alibaba.wireless', '1688'),
  PaymentApp('com.taobao.idlefish', '闲鱼'),
  PaymentApp('com.ccb.longjiLife', '建行生活'),
];

class PaymentRule {
  const PaymentRule({this.enabled = true, this.accountId, this.categoryId});
  final bool enabled;
  final String? accountId, categoryId;
  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'accountId': accountId,
    'categoryId': categoryId,
  };
  factory PaymentRule.fromJson(Map data) => PaymentRule(
    enabled: data['enabled'] == true,
    accountId: data['accountId'] is String ? data['accountId'] : null,
    categoryId: data['categoryId'] is String ? data['categoryId'] : null,
  );
}

class AutomationConfig {
  const AutomationConfig({
    this.enabled = false,
    this.enhanced = false,
    this.autoSave = true,
    this.reviewPopup = true,
    this.screenshotFallback = false,
    this.ledgerId = 'personal',
    this.rules = const {},
  });
  final bool enabled, enhanced, autoSave, reviewPopup, screenshotFallback;
  final String ledgerId;
  final Map<String, PaymentRule> rules;
  PaymentRule rule(String packageName) =>
      rules[packageName] ?? const PaymentRule();
  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'enhanced': enhanced,
    'autoSave': autoSave,
    'reviewPopup': reviewPopup,
    'screenshotFallback': screenshotFallback,
    'ledgerId': ledgerId,
    'apps': {
      for (final app in paymentApps)
        app.packageName: rule(app.packageName).toJson(),
    },
  };
  factory AutomationConfig.fromJson(Map data) => AutomationConfig(
    enabled: data['enabled'] == true,
    enhanced: data['enhanced'] == true,
    autoSave: data['autoSave'] != false,
    reviewPopup: data['reviewPopup'] != false,
    screenshotFallback: data['screenshotFallback'] == true,
    ledgerId: data['ledgerId'] is String ? data['ledgerId'] : 'personal',
    rules: {
      if (data['apps'] is Map)
        for (final app in paymentApps)
          if (data['apps'][app.packageName] is Map)
            app.packageName: PaymentRule.fromJson(
              data['apps'][app.packageName],
            ),
    },
  );
}
