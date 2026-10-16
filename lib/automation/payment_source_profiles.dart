/// Per-application payment receipt vocabulary.
///
/// Accessibility trees from payment apps do not expose one common schema. This
/// layer converts only labels observed for the selected source into the small
/// canonical field vocabulary understood by [OcrReceiptParser]. It deliberately
/// does not infer a completed transaction: completion is still checked against
/// the source profile and the native page guard.
class PaymentInlineAmount {
  const PaymentInlineAmount(this.prefix, {this.status});

  final String prefix;
  final String? status;
}

class PaymentNeighborField {
  const PaymentNeighborField(
    this.anchor,
    this.canonical, {
    this.offset = 1,
    this.anchorContains = false,
  });

  final String anchor, canonical;
  final int offset;
  final bool anchorContains;
}

class PaymentSourceProfile {
  const PaymentSourceProfile({
    required this.completed,
    this.aliases = const {},
    this.inlineAmounts = const [],
    this.neighbors = const [],
  });

  final List<String> completed;
  final Map<String, List<String>> aliases;
  final List<PaymentInlineAmount> inlineAmounts;
  final List<PaymentNeighborField> neighbors;

  bool hasCompletedStatus(String text) => completed.any(text.contains);

  String normalize(String source) {
    final labelAliases = [
      for (final entry in aliases.entries)
        for (final alias in entry.value) (canonical: entry.key, alias: alias),
    ]..sort((left, right) => right.alias.length.compareTo(left.alias.length));
    final input = source
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final output = <String>[];
    for (final line in input) {
      var handled = false;
      for (final rule in inlineAmounts) {
        if (!line.startsWith(rule.prefix)) continue;
        final tail = line.substring(rule.prefix.length).trim();
        if (!_singleMoney.hasMatch(tail)) continue;
        if (rule.status != null) output.add(rule.status!);
        output.add('实付金额 $tail');
        handled = true;
        break;
      }
      if (handled) continue;
      var normalized = line;
      for (final rule in labelAliases) {
        if (!_isLabelPrefix(line, rule.alias, rule.canonical)) continue;
        final value = line
            .substring(rule.alias.length)
            .replaceFirst(RegExp(r'^[\s:：,，()（）]+'), '');
        normalized = value.isEmpty
            ? rule.canonical
            : '${rule.canonical} $value';
        break;
      }
      output.add(normalized);
    }
    for (var i = 0; i < input.length; i++) {
      for (final rule in neighbors) {
        final matches = rule.anchorContains
            ? input[i].contains(rule.anchor)
            : input[i] == rule.anchor;
        final target = i + rule.offset;
        if (!matches || target < 0 || target >= input.length) continue;
        final value = input[target].trim();
        if (!_validNeighbor(rule.canonical, value)) continue;
        output.add('${rule.canonical} $value');
      }
    }
    return output.toSet().join('\n');
  }

  static final _singleMoney = RegExp(
    r'^[\s:：]*[¥￥]?\s*[+-]?\d[\d,]*(?:\.\d{1,2})?\s*(?:元)?$',
  );

  static bool _isLabelPrefix(String line, String alias, String canonical) {
    if (line == alias) return true;
    if (!line.startsWith(alias) || line.length == alias.length) return false;
    if (!canonical.contains('金额')) return true;
    return RegExp(r'[\s:：,，()（）¥￥+\-\d]').hasMatch(line[alias.length]);
  }

  static bool _validNeighbor(String canonical, String value) {
    if (value.isEmpty || value.length > 100) return false;
    if (canonical.contains('金额')) return _singleMoney.hasMatch(value);
    if (RegExp(r'成功|完成|返回|关闭|首页|查看订单').hasMatch(value)) {
      return false;
    }
    return true;
  }
}

const _commonCompleted = [
  '支付成功',
  '付款成功',
  '交易成功',
  '消费成功',
  '扣款成功',
  '收款成功',
  '到账成功',
  '转账成功',
];

const _assetCompleted = [
  '充值成功',
  '提现成功',
  '资金待入账',
  '转入成功',
  '转出成功',
  '成功转入',
  '成功转出',
];

const _orderCompleted = [
  '下单成功，等待商家接单',
  '下单成功，商家已接单',
  '下单成功，商家正在备餐',
  '下单成功，商家备餐中',
  '下单成功，商家备货完成',
];

const _amount = <String, List<String>>{
  '实付金额': ['实付价', '实际付款'],
};

const _paymentAccount = <String, List<String>>{
  '付款方式': ['交易方式', '付款银行', '付款卡', '优先使用此付款方式', '优先选择此方式支付'],
};

const _douyinProfiles = PaymentSourceProfile(
  completed: [
    ..._commonCompleted,
    '购买成功',
    '自动付款成功',
    '入账成功',
    ..._assetCompleted,
  ],
  aliases: {
    ..._amount,
    ..._paymentAccount,
    '商户名称': ['团购头图', '已选择'],
    '交易时间': ['入账时间', '充值时间', '到账时间', '还款时间'],
  },
  inlineAmounts: [
    PaymentInlineAmount('实付'),
    PaymentInlineAmount('实付价'),
    PaymentInlineAmount('支付成功', status: '支付成功'),
    PaymentInlineAmount('付款成功', status: '付款成功'),
  ],
  neighbors: [
    PaymentNeighborField('团购头图', '商户名称'),
    PaymentNeighborField('支付成功', '实付金额'),
  ],
);

const _kuaishouProfile = PaymentSourceProfile(
  completed: [..._commonCompleted, '购买成功'],
  aliases: {
    ..._amount,
    '商户名称': ['门店通用'],
  },
  inlineAmounts: [
    PaymentInlineAmount('立即支付'),
    PaymentInlineAmount('免密支付'),
    PaymentInlineAmount('实付'),
  ],
  neighbors: [
    PaymentNeighborField('关注', '商户名称'),
    PaymentNeighborField('进店', '商户名称'),
  ],
);

final paymentSourceProfiles = <String, PaymentSourceProfile>{
  'com.tencent.mm': const PaymentSourceProfile(
    completed: [
      ..._commonCompleted,
      ..._assetCompleted,
      '红包已发出',
      '红包发送成功',
      '已存入零钱',
      '领取成功',
      '已领取',
      '已转入',
      '已转出',
    ],
    aliases: {
      '实付金额': ['支出'],
      '实收金额': ['收到', '收入'],
      '付款方式': ['充值方式', '转入方式'],
      '交易时间': ['转账时间', '收款时间', '充值时间', '到账时间', '申请时间'],
      '商户名称': ['收款方', '收款账号'],
      '交易单号': ['付款单号', '收款单号', '转账单号'],
    },
    inlineAmounts: [
      PaymentInlineAmount('支出¥', status: '支付成功'),
      PaymentInlineAmount('支出￥', status: '支付成功'),
      PaymentInlineAmount('收入¥', status: '收款成功'),
      PaymentInlineAmount('收入￥', status: '收款成功'),
      PaymentInlineAmount('已支付¥', status: '支付成功'),
      PaymentInlineAmount('已收到¥', status: '收款成功'),
    ],
  ),
  'com.eg.android.AlipayGphone': const PaymentSourceProfile(
    completed: [
      ..._commonCompleted,
      ..._assetCompleted,
      '代付成功',
      '亲情卡付款成功',
      '免密支付成功',
      '自动续费成功',
      '自动扣款成功',
      '支付宝小荷包付款成功',
      '领取成功',
      '已领取',
    ],
    aliases: {
      '实付金额': ['订单金额'],
      '付款方式': ['交易方式', '退款方式'],
      '商户名称': ['收款方', '对方账户', '商品说明'],
      '交易时间': ['收款时间', '创建时间'],
    },
    inlineAmounts: [PaymentInlineAmount('提现金额¥')],
  ),
  'com.jingdong.app.mall': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      ..._amount,
      '商户名称': ['商品名称', '收款方', '交易说明'],
      '付款方式': ['支付方式'],
      '交易时间': ['创建时间'],
    },
    inlineAmounts: [PaymentInlineAmount('实付')],
    neighbors: [PaymentNeighborField('商品名称', '商户名称')],
  ),
  'com.jd.jrapp': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      ..._amount,
      '商户名称': ['收款方', '交易说明'],
      '付款方式': ['支付方式'],
      '交易时间': ['创建时间'],
    },
    inlineAmounts: [PaymentInlineAmount('实付')],
  ),
  'com.sankuai.meituan': const PaymentSourceProfile(
    completed: [..._commonCompleted, '先用后付自动扣款成功'],
    aliases: {
      ..._amount,
      '交易时间': ['创建时间', '下单时间'],
    },
    inlineAmounts: [
      PaymentInlineAmount('支付成功 ¥', status: '支付成功'),
      PaymentInlineAmount('交易成功 ¥', status: '交易成功'),
    ],
  ),
  'com.sankuai.meituan.takeoutnew': const PaymentSourceProfile(
    completed: [..._commonCompleted, '先用后付自动扣款成功'],
    aliases: {
      ..._amount,
      '交易时间': ['创建时间', '下单时间'],
    },
    inlineAmounts: [
      PaymentInlineAmount('支付成功 ¥', status: '支付成功'),
      PaymentInlineAmount('交易成功 ¥', status: '交易成功'),
    ],
  ),
  'com.dianping.v1': const PaymentSourceProfile(
    completed: [..._commonCompleted, '先用后付自动扣款成功'],
    aliases: {
      ..._amount,
      '交易时间': ['创建时间', '下单时间'],
    },
    inlineAmounts: [
      PaymentInlineAmount('支付成功 ¥', status: '支付成功'),
      PaymentInlineAmount('交易成功 ¥', status: '交易成功'),
    ],
  ),
  'com.unionpay': const PaymentSourceProfile(
    completed: [..._commonCompleted, '转出成功'],
    aliases: {
      '实付金额': ['实付金额（元）', '支出金额', '订单金额'],
      '实收金额': ['实收金额（元）', '收入金额'],
      '付款方式': ['付款卡', '付款卡号', '付款银行', '收款卡', '收款卡号', '收款银行'],
      '交易时间': ['扣款时间', '订单时间', '创建时间', '时间'],
    },
  ),
  'com.taobao.taobao': const PaymentSourceProfile(
    completed: [..._commonCompleted, '免密支付成功', ..._orderCompleted],
    aliases: {..._amount},
    inlineAmounts: [
      PaymentInlineAmount('实付价'),
      PaymentInlineAmount('合计¥'),
      PaymentInlineAmount('合计￥'),
      PaymentInlineAmount('免密支付'),
    ],
    neighbors: [
      PaymentNeighborField('实付价', '实付金额', offset: 2),
      PaymentNeighborField('合计:', '实付金额'),
    ],
  ),
  'com.xunmeng.pinduoduo': const PaymentSourceProfile(
    completed: [..._commonCompleted, '拼单成功', '已支付', '免拼成功'],
    aliases: {
      '付款方式': ['使用#', '优先使用#'],
      '商户名称': ['已选择', '已选'],
      '交易时间': ['支付时间', '到账时间'],
    },
  ),
  'com.ss.android.ugc.aweme': _douyinProfiles,
  'com.ss.android.ugc.aweme.lite': _douyinProfiles,
  'com.ss.android.ugc.livelite': _douyinProfiles,
  'com.ss.android.yumme.video': _douyinProfiles,
  'me.ele': const PaymentSourceProfile(
    completed: [..._commonCompleted, ..._orderCompleted],
    aliases: {
      '付款方式': ['已选'],
    },
    neighbors: [
      PaymentNeighborField('提交订单', '实付金额', offset: -1),
      PaymentNeighborField('已选', '付款方式'),
    ],
  ),
  // Didi is a Smart Ledger compatibility profile. It is not claimed as an
  // adapter observed in the analysed YiMu 6.1.6 package.
  'com.sdu.didi.psnger': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      '实付金额': ['行程费用', '实付车费'],
      '商户名称': ['行程', '服务商'],
      '付款方式': ['支付渠道'],
      '交易时间': ['完成时间'],
    },
  ),
  'com.huawei.wallet': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      '商户名称': ['商家', '商品名称'],
      ..._paymentAccount,
      '交易时间': ['日期'],
    },
    neighbors: [PaymentNeighborField('二维码付款码', '付款方式')],
  ),
  'com.wudaokou.hippo': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      '付款方式': ['优先使用此付款方式'],
    },
    inlineAmounts: [PaymentInlineAmount('支付成功：¥', status: '支付成功')],
  ),
  'com.kuaishou.nebula': _kuaishouProfile,
  'com.smile.gifmaker': _kuaishouProfile,
  'com.alibaba.wireless': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    inlineAmounts: [
      PaymentInlineAmount('立即支付'),
      PaymentInlineAmount('0元下单，收货后付款'),
    ],
    neighbors: [PaymentNeighborField('有限公司', '商户名称', anchorContains: true)],
  ),
  'com.taobao.idlefish': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      '实付金额': ['现价'],
    },
    inlineAmounts: [PaymentInlineAmount('现价')],
    neighbors: [PaymentNeighborField('现价', '商户名称', anchorContains: true)],
  ),
  'com.ccb.longjiLife': const PaymentSourceProfile(
    completed: [..._commonCompleted],
    aliases: {
      '商户名称': ['商户名', '商品名称'],
      '付款方式': ['支付方式', '优先选择此方式支付'],
      '交易时间': ['交易时间'],
    },
  ),
};

const fallbackPaymentSourceProfile = PaymentSourceProfile(
  completed: _commonCompleted,
);

PaymentSourceProfile paymentSourceProfile(String packageName) =>
    paymentSourceProfiles[packageName] ?? fallbackPaymentSourceProfile;
