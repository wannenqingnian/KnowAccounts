import 'chinese_number_parser.dart';
import '../../domain/models.dart';

class OcrReceipt {
  const OcrReceipt({
    required this.amountMinor,
    required this.date,
    required this.type,
    required this.merchant,
    required this.accountText,
    required this.categoryText,
    required this.evidence,
    required this.warnings,
    required this.blocked,
    required this.fieldCount,
  });
  final int? amountMinor;
  final String? date;
  final TransactionType type;
  final String merchant, accountText, categoryText;
  final Map<String, String> evidence;
  final List<String> warnings;
  final bool blocked;
  final int fieldCount;
  int get quality =>
      (amountMinor == null ? 0 : 5) +
      (date == null ? 0 : 3) +
      (merchant.isEmpty ? 0 : 2) +
      (accountText.isEmpty ? 0 : 2) +
      fieldCount.clamp(0, 4);
  String get text =>
      '${switch (type) {
        TransactionType.income => '收入',
        TransactionType.refund => '退款',
        _ => '支出',
      }}\n'
      '${date ?? ''}\n$merchant\n$accountText\n$categoryText';
}

class _Field {
  const _Field(this.key, this.value, this.line);
  final String key, value;
  final int line;
}

class _Money {
  const _Money(this.minor, this.rank, this.reason, {this.headline = false});
  final int minor, rank;
  final String reason;
  final bool headline;
}

/// Field roles, not app or merchant templates. UI actions, item prices,
/// discounts, balances and identifiers never compete with actual payment.
class OcrReceiptParser {
  static const amountRanks = {
    '退款到账金额': 125,
    '已退款金额': 125,
    '退款金额': 125,
    // Informational gross amount on a partially refunded order. It must never
    // outrank the actual refund, but is retained to calculate net spending.
    '原支付金额': 80,
    '订单原金额': 80,
    '实付金额': 110,
    '实际支付': 110,
    '实际付款': 110,
    '实付款': 110,
    '实付': 110,
    '付款金额': 105,
    '支付金额': 105,
    '扣款金额': 105,
    '到账金额': 105,
    '转账金额': 105,
    '提现金额': 105,
    '充值金额': 105,
    '红包金额': 105,
    '实收金额': 105,
    '应付金额': 100,
    '应收金额': 100,
    '应付': 100,
    '应收': 100,
    '交易金额': 90,
    '消费金额': 90,
    '交易总额': 90,
    '合计': 85,
    '总计': 85,
    '金额': 70,
  };
  static const timeRanks = {
    '退款到账时间': 115,
    '退款时间': 115,
    '支付时间': 100,
    '付款时间': 100,
    '扣款时间': 100,
    '到账时间': 100,
    '转账时间': 100,
    '收款时间': 100,
    '提现时间': 100,
    '充值时间': 100,
    '交易时间': 90,
    '交易日期': 90,
    '消费时间': 90,
    '日期': 50,
    '创建时间': 10,
    '下单时间': 10,
    '订单时间': 10,
  };
  static const merchantKeys = [
    '商户全称',
    '商户名称',
    '收款商户',
    '商家名称',
    '商户',
    '商家',
    '收款方',
    '收款单位',
    '收款人',
    '对方账户',
  ];
  static const accountKeys = [
    '支付方式',
    '付款方式',
    '付款账户',
    '扣款账户',
    '支付账户',
    '支付渠道',
    '转入方式',
    '充值方式',
    '到账银行卡',
  ];
  static const _extras = [
    '订单金额',
    '商品金额',
    '原价',
    '优惠金额',
    '优惠',
    '折扣',
    '账户余额',
    '余额',
    '手续费',
    '服务费',
    '找零',
    '现金',
    '交易单号',
    '交易号',
    '订单号',
    '流水号',
    '商户单号',
    '经营单号',
    '收单机构',
    '当前状态',
    '退款记录',
    '交易状态',
    '交易类型',
    '收支类型',
    '账单分类',
    '商品',
    '商品说明',
    '金额校验',
    '日期校验',
    '账户校验',
    '商户校验',
    '交易校验',
  ];
  static final _keys = <String>{
    ...amountRanks.keys,
    ...timeRanks.keys,
    ...merchantKeys,
    ...accountKeys,
    ..._extras,
  }.toList()..sort((a, b) => b.length.compareTo(a.length));
  static final _label = RegExp(_keys.map(RegExp.escape).join('|'));
  static final _date = RegExp(
    r'(?<!\d)(20\d{2}|19\d{2}|2100)[年./-](\d{1,2})[月./-](\d{1,2})日?(?!\d)',
  );
  static final _money = RegExp(
    r'(?<![\dA-Za-z.,])([+\-−－–—]?)\s*[¥￥]?\s*(\d{1,3}(?:,\d{3})+|\d{1,10})(?:\.(\d{1,2}))?(?![\d.,])(?:\s*元)?',
  );
  static final _headline = RegExp(
    r'^[+\-−－–—]?\s*(?:[¥￥]\s*\d[\d,]*(?:\.\d{1,2})?|\d[\d,]*\.\d{1,2})\s*(?:元)?$',
  );
  static final _success = RegExp(
    r'支付成功|付款成功|交易成功|消费成功|扣款成功|收款成功|到账成功|转账成功|充值成功|提现成功|自动扣款成功|资金待入账|转入成功|转出成功|成功转入|成功转出',
  );
  static final _failed = RegExp(
    r'支付失败|付款失败|交易失败|待支付|待付款|未支付|交易关闭|已取消|支付处理中|付款中',
  );
  static final _footer = RegExp(
    r'^(?:账单服务|交易服务|商家小程序|对订单有疑惑|发起群收款|联系商家|申请电子凭证|查看往来记录)',
  );
  static final _navigation = RegExp(
    r'^(?:主页|首页|交易详情|账单详情|付款详情|订单详情|详情|账单|返回|关闭|支付成功|付款成功|微信|微信支付|支付宝|查看共享链接内容|在.*上工作)$',
  );

  OcrReceipt? parse(String input) {
    var normalized = input
        .replaceAll('文付成功', '支付成功')
        .replaceAll('文付方式', '支付方式');
    var lines = normalized
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final footer = lines.indexWhere((s) => _footer.hasMatch(s));
    if (footer >= 0) lines = lines.sublist(0, footer);
    var fields = _fields(lines);
    final hasStatus = lines.any(
      (s) =>
          _success.hasMatch(s) ||
          _failed.hasMatch(s) ||
          RegExp(r'退款成功|已退款|已全额退款|退款处理完成').hasMatch(s),
    );
    final useful = fields.where((f) => !f.key.endsWith('校验')).length;
    final hasMoney = lines.any(_headline.hasMatch) ||
        lines.any((s) => _money.hasMatch(s));
    // Recognize receipt structure, but leave ordinary prose to the text parser.
    if (useful < 1 && !(hasStatus && hasMoney)) {
      return null;
    }
    final warnings = <String>[];
    final evidence = <String, String>{};
    if (input.contains('文付成功')) warnings.add('支付状态字符疑似误识别，请核对');
    // Focus on the receipt after floating prose when a signed price precedes
    // its first status. Keep preceding short titles for merchant extraction.
    final statusIndex = lines.indexWhere(_success.hasMatch);
    final headlines = <int>[
      for (var i = 0; i < lines.length; i++)
        if (_headline.hasMatch(lines[i])) i,
    ];
    if (statusIndex >= 0) {
      final before = headlines.where((i) => i < statusIndex).toList();
      if (before.length == 1 &&
          !fields.any(
            (f) => merchantKeys.contains(f.key) && f.line < before.single,
          )) {
        final boundary = before.single;
        final title = _title(lines.take(boundary).toList());
        lines = [if (title.isNotEmpty) title, ...lines.skip(boundary)];
        fields = _fields(lines);
      }
    }
    final body = lines.join('\n');
    final refund = RegExp(
      r'退款成功|已退款|已全额退款|退款处理完成|退款到账|退款记录|退回成功|已退回|已退还',
    ).hasMatch(body);
    final statuses = _success.allMatches(body).length;
    var blocked = statuses > 1 || _failed.hasMatch(body);
    if (statuses > 1) warnings.add('图片包含多笔成功交易，请裁剪到单笔账单');
    if (_failed.hasMatch(body)) warnings.add('账单未完成付款，请核对交易状态后手动处理');
    final kind = fields
        .where(
          (f) =>
              f.key == '交易类型' ||
              f.key == '收支类型' ||
              f.key == '当前状态' ||
              f.key == '交易状态',
        )
        .map((f) => f.value)
        .join(' ');
    final complex = RegExp(r'转账|转入|转出|还款|借款|放款|贷款');
    if (complex.hasMatch(kind) ||
        lines.any(
          (s) => RegExp(r'^(?:退款|转账|还款|借款|放款|贷款)(?:成功|详情|中)').hasMatch(s),
        )) {
      blocked = true;
      warnings.add('转账和借贷请使用对应手动入口');
    }
    if (refund) {
      blocked = true;
      warnings.add('已识别退款；需关联原消费后入账，不会按普通收入或新支出保存');
    }
    if (RegExp(
      r'USD|JPY|EUR|HKD|美元|美金|日元|欧元|港币|\$|€',
      caseSensitive: false,
    ).hasMatch(body)) {
      blocked = true;
      warnings.add('当前仅支持人民币，请手动核对币种');
    }
    if (fields.any((f) => f.key == '交易校验' && f.value.contains('不一致'))) {
      blocked = true;
      warnings.add('多次识别的交易状态或币种不一致，请手动核对');
    }
    final income =
        RegExp(r'收入|收款|到账').hasMatch(kind) ||
        lines.any((s) => RegExp(r'收款成功|到账成功|^收入$').hasMatch(s));
    final expense =
        RegExp(r'支出|消费|支付|付款').hasMatch(kind) ||
        lines.any((s) => RegExp(r'支付成功|付款成功|消费成功|扣款成功|^支出$').hasMatch(s));
    if (income && expense) {
      blocked = true;
      warnings.add('收支方向不一致，请手动核对');
    }
    final type = refund
        ? TransactionType.refund
        : income && !expense
        ? TransactionType.income
        : TransactionType.expense;
    if (!income && !expense) warnings.add('未明确识别收支方向，暂按支出供核对');
    final prices = <_Money>[];
    if (refund) {
      final refundPattern = RegExp(
        r'(?:退款到账金额|已退款金额|退款金额|已退款|退款成功|退款记录)\s*[:：()（）]?\s*[¥￥]?\s*(\d[\d,]*(?:\.\d{1,2})?)\s*元?',
      );
      for (final match in refundPattern.allMatches(body)) {
        final minor = ChineseNumberParser().parseMinor(match[1]!);
        if (minor != null && minor > 0) {
          prices.add(_Money(minor, 130, '退款金额：${match[0]!.trim()}'));
        }
      }
    }
    for (final f in fields) {
      final rank = amountRanks[f.key];
      if (rank == null) continue;
      for (final n in _money.allMatches(f.value)) {
        final minor = _minor(n);
        if (minor != null) {
          prices.add(_Money(minor, rank, '${f.key}：${n[0]!.trim()}'));
        }
      }
    }
    // Only a standalone headline, not arbitrary numbers in order IDs/items.
    final boundaryFields = fields
        .where(
          (f) =>
              !merchantKeys.contains(f.key) &&
              f.key != '商品' &&
              f.key != '商品说明' &&
              !f.key.endsWith('校验'),
        )
        .toList();
    final firstField = boundaryFields.isEmpty
        ? lines.length
        : boundaryFields.first.line;
    for (var i = 0; i < lines.length && i <= firstField; i++) {
      if (!_headline.hasMatch(lines[i])) continue;
      final matches = _money.allMatches(lines[i]).toList();
      if (matches.length != 1) continue;
      final minor = _minor(matches.single);
      if (minor != null) {
        prices.add(_Money(minor, 95, '账单主金额：${lines[i]}', headline: true));
      }
    }
    int? amount;
    if (prices.isNotEmpty) {
      final rank = prices.map((p) => p.rank).reduce((a, b) => a > b ? a : b);
      final top = prices.where((p) => p.rank == rank).toList();
      final values = top.map((p) => p.minor).toSet();
      if (values.length == 1) {
        amount = values.single;
        if (!refund && prices.any((p) => p.headline && p.minor != amount)) {
          amount = null;
        }
        if (amount != null) evidence['amount'] = top.first.reason;
      }
      if (amount == null) warnings.add('交易金额候选不一致，请手动选择');
    }
    if (refund && amount != null) {
      final grossValues = <int>{
        ...prices
            .where((price) => price.headline && price.minor >= amount!)
            .map((price) => price.minor),
        ...fields
            .where((field) => field.key == '原支付金额' || field.key == '订单原金额')
            .expand((field) => _money.allMatches(field.value))
            .map(_minor)
            .whereType<int>()
            .where((value) => value >= amount!),
      };
      if (grossValues.length == 1) {
        final gross = grossValues.single;
        evidence['original_amount_minor'] = '$gross';
        evidence['refund_amount_minor'] = '$amount';
        if (gross > amount) {
          evidence['net_amount_minor'] = '${gross - amount}';
          evidence['amount_breakdown'] =
              '原支付${_moneyText(gross)}，已退款${_moneyText(amount)}，净消费${_moneyText(gross - amount)}';
        }
      }
    }
    if (statuses > 1 ||
        fields.any((f) => f.key == '金额校验' && f.value.contains('不一致'))) {
      amount = null;
      warnings.add('多次识别或多笔账单的金额不一致，请手动填写');
    }
    String? date;
    final candidates = <String>[];
    if (refund) {
      for (var i = 0; i < lines.length; i++) {
        final refundRecord = RegExp(r'^退款记录').hasMatch(lines[i]);
        final refundTime = RegExp(r'退款到账时间|退款时间').hasMatch(lines[i]);
        if (!refundRecord && !refundTime) {
          continue;
        }
        for (final candidate in [
          lines[i],
          if (i + 1 < lines.length) lines[i + 1],
          if (refundRecord && i + 2 < lines.length) lines[i + 2],
        ]) {
          candidates.addAll(_dates(candidate, warnings));
        }
        if (candidates.isNotEmpty) break;
      }
    }
    final dated = fields.where((f) => (timeRanks[f.key] ?? 0) >= 50).toList();
    final usableDated = refund
        ? dated.where((f) => (timeRanks[f.key] ?? 0) >= 110).toList()
        : dated;
    if (candidates.isEmpty && usableDated.isNotEmpty) {
      final rank = usableDated
          .map((f) => timeRanks[f.key]!)
          .reduce((a, b) => a > b ? a : b);
      for (final f in usableDated.where((f) => timeRanks[f.key] == rank)) {
        candidates.addAll(_dates(f.value, warnings));
      }
    } else if (candidates.isEmpty && !refund) {
      // Creation time is not payment time. Only use truly unlabelled dates.
      final ignored = fields
          .where((f) => (timeRanks[f.key] ?? 100) < 50)
          .map((f) => f.line)
          .toSet();
      for (var i = 0; i < lines.length; i++) {
        if (!ignored.contains(i) && !ignored.contains(i - 1)) {
          candidates.addAll(_dates(lines[i], warnings));
        }
      }
    }
    final dates = candidates.toSet();
    if (dates.length == 1) {
      date = dates.single;
      evidence['date'] = '交易日期：$date';
      if (refund) evidence['refund_date'] = date;
    }
    if (dates.length > 1) warnings.add('出现多个交易日期，暂用今天，请核对');
    if (refund && date == null) warnings.add('退款页面未提供退款时间，暂按识别日期，请核对');
    if (refund) {
      final paymentDates = fields
          .where(
            (field) => const {
              '支付时间',
              '付款时间',
              '扣款时间',
              '交易时间',
              '消费时间',
            }.contains(field.key),
          )
          .expand((field) => _dates(field.value, warnings))
          .toSet();
      if (paymentDates.length == 1) {
        evidence['payment_date'] = paymentDates.single;
      }
    }
    if (fields.any((f) => f.key == '日期校验' && f.value.contains('不一致'))) {
      date = null;
      warnings.add('多次识别日期不一致，请核对');
    }
    var merchant = '';
    for (final key in merchantKeys) {
      final values = fields
          .where((f) => f.key == key && _merchantValue(f.value))
          .map((f) => f.value)
          .toSet();
      if (values.length == 1) {
        merchant = values.single;
        evidence['merchant'] = '$key：$merchant';
        break;
      }
      if (values.length > 1) {
        warnings.add('商户候选不一致，请核对');
        break;
      }
    }
    if (merchant.isEmpty) {
      final moneyIndex = lines.indexWhere(_headline.hasMatch);
      if (moneyIndex >= 0) {
        final following = lines
            .skip(moneyIndex + 1)
            .take(3)
            .takeWhile(
              (s) =>
                  !_label.hasMatch(s) &&
                  !_success.hasMatch(s) &&
                  !_failed.hasMatch(s),
            );
        merchant = _title([...lines.take(moneyIndex), ...following]);
      }
      if (merchant.isNotEmpty) {
        evidence['merchant'] = '账单标题：$merchant';
        warnings.add('商户取自账单标题，请核对');
      }
    }
    var account = '';
    final accounts = fields
        .where((f) => accountKeys.contains(f.key))
        .map((f) => _account(f.value))
        .where((s) => s.isNotEmpty)
        .toSet();
    if (accounts.length == 1) account = accounts.single;
    if (accounts.length > 1) warnings.add('付款账户候选不一致，请手动选择');
    if (fields.any((f) => f.key == '账户校验' && f.value.contains('不一致'))) {
      account = '';
      warnings.add('多次识别账户不一致，请手动选择');
    }
    if (fields.any((f) => f.key == '商户校验' && f.value.contains('不一致'))) {
      merchant = '';
      warnings.add('多次识别商户不一致，请手动填写');
    }
    final category = fields
        .where((f) => f.key == '账单分类')
        .map((f) => f.value)
        .join(' ');
    final goods = fields
        .where((f) => f.key == '商品' || f.key == '商品说明')
        .map((f) => f.value)
        .join(' ');
    return OcrReceipt(
      amountMinor: amount,
      date: date,
      type: type,
      merchant: merchant,
      accountText: account,
      categoryText: category.isNotEmpty ? category : '$merchant $goods',
      evidence: evidence,
      warnings: warnings.toSet().toList(),
      blocked: blocked,
      fieldCount: useful,
    );
  }

  static String _moneyText(int minor) =>
      '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')}元';

  List<_Field> _fields(List<String> lines) {
    final result = <_Field>[];
    for (var i = 0; i < lines.length; i++) {
      final matches = _label
          .allMatches(lines[i])
          .where(
            (m) =>
                !((amountRanks.containsKey(m[0]) ||
                        const ['余额', '现金', '优惠', '折扣', '找零'].contains(m[0])) &&
                    RegExp(
                      r'^[\u3400-\u9fff]',
                    ).hasMatch(lines[i].substring(m.end))),
          )
          .where(
            (m) =>
                m.start == 0 ||
                !RegExp(r'[\u3400-\u9fff]').hasMatch(lines[i][m.start - 1]) ||
                RegExp(r'^[:：]').hasMatch(lines[i].substring(m.end)),
          )
          .toList();
      for (var j = 0; j < matches.length; j++) {
        final m = matches[j];
        // Avoid matching 金额 inside an unknown longer field like 商品总金额.
        if (m.start > 0 &&
            RegExp(r'[\u3400-\u9fff]').hasMatch(lines[i][m.start - 1])) {
          continue;
        }
        var value = lines[i]
            .substring(
              m.end,
              j + 1 < matches.length ? matches[j + 1].start : lines[i].length,
            )
            .replaceFirst(RegExp(r'^[\s:：]+'), '')
            .trim();
        if (value.isEmpty &&
            i + 1 < lines.length &&
            !_label.hasMatch(lines[i + 1]) &&
            !_success.hasMatch(lines[i + 1]) &&
            !_failed.hasMatch(lines[i + 1])) {
          value = lines[i + 1];
        }
        if (accountKeys.contains(m[0]) &&
            i + 2 < lines.length &&
            value == lines[i + 1] &&
            RegExp(r'^尾号\s*\d{4}$').hasMatch(value) &&
            RegExp(r'^(?:交易单号|交易号|订单号|流水号|商户单号|经营单号)').hasMatch(lines[i + 2])) {
          value = '';
        }
        result.add(_Field(m[0]!, value, i));
      }
    }
    return result;
  }

  int? _minor(RegExpMatch m) => ChineseNumberParser().parseMinor(
    '${m[2]!.replaceAll(',', '')}${m[3] == null ? '' : '.${m[3]}'}',
  );
  List<String> _dates(String text, List<String> warnings) {
    // Normalization may remove the space between `日` and the clock. Restore
    // it for ordinary one- or two-digit month/day values before matching the
    // calendar date itself.
    text = text.replaceAllMapped(
      RegExp(
        r'(?<!\d)(20\d{2})年(\d{1,2})月(\d{1,2})日[ \t]*([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?!\d)',
      ),
      (m) =>
          '${m[1]}年${m[2]}月${m[3]}日 ${m[4]!.padLeft(2, '0')}:${m[5]}${m[6] == null ? '' : ':${m[6]}'}',
    );
    // OCR can omit 月/日 while keeping a fixed-width date and the clock.
    // Accept only MMDDHH followed by a valid clock, never an arbitrary number.
    text = text.replaceAllMapped(
      RegExp(
        r'(?<!\d)(20\d{2})年(\d{2})月?(\d{2})日?[ \t]*([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?!\d)',
      ),
      (m) {
        if (!m[0]!.contains('月') || !m[0]!.contains('日')) {
          warnings.add('OCR日期分隔符缺失，已按固定格式恢复，请核对');
        }
        // Always restore the separator before the clock. Earlier text
        // normalization deliberately removes spaces around date separators,
        // so a valid `...日 12:05:15` may arrive here as `...日12:05:15`.
        return '${m[1]}年${m[2]}月${m[3]}日 ${m[4]}:${m[5]}${m[6] == null ? '' : ':${m[6]}'}';
      },
    );
    text = text.replaceAllMapped(
      RegExp(r'(20\d{2}[-/.]\d{1,2}[-/.]\d{2})(?=\d{2}:\d{2})'),
      (m) => '${m[1]} ',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'(?<!\d)(20\d{2})(47|年)(\d{1,2})([ \t]+|月)(\d{1,2})(H|日)(?=[ \t]+\d{1,2}:\d{2})',
      ),
      (m) {
        if (m[2] != '47' && m[6] != 'H') return m[0]!;
        warnings.add('OCR支付日期易混字符已修正，请核对');
        return '${m[1]}年${m[3]}月${m[5]}日';
      },
    );
    final values = <String>[];
    for (final match in _date.allMatches(text)) {
      if (!_validDate(match, warnings)) continue;
      final day =
          '${match[1]}-${match[2]!.padLeft(2, '0')}-${match[3]!.padLeft(2, '0')}';
      final tail = text.substring(match.end);
      final clock = RegExp(
        r'^[T\s]*([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?',
      ).firstMatch(tail);
      values.add(
        clock == null
            ? day
            : '${day}T${clock[1]!.padLeft(2, '0')}:${clock[2]}:${clock[3] ?? '00'}',
      );
    }
    return values;
  }

  bool _validDate(RegExpMatch m, List<String> warnings) {
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    final date = DateTime(y, mo, d);
    if (date.year == y && date.month == mo && date.day == d) return true;
    warnings.add('日期无效，暂用今天，请核对');
    return false;
  }

  bool _merchantValue(String s) =>
      s.length >= 2 &&
      s.length <= 60 &&
      RegExp(r'[\u3400-\u9fffA-Za-z]').hasMatch(s) &&
      !_label.hasMatch(s) &&
      !_navigation.hasMatch(
        s.replaceAll(RegExp(r'^[^\u3400-\u9fffA-Za-z]+'), ''),
      );
  String _title(List<String> lines) {
    final candidates = lines
        .where(
          (s) =>
              _merchantValue(s) &&
              (RegExp(r'[\u3400-\u9fff]').allMatches(s).length >= 2 ||
                  RegExp(
                    r'^[A-Z]{3,}$|^[A-Za-z][A-Za-z .&0-9-]{3,}$',
                  ).hasMatch(s)) &&
              !RegExp(
                r'截图|识别|记账|授权|共享链接|Cloud|ChatGPT|交易详情|账单详情|^.{0,3}留言$',
              ).hasMatch(s) &&
              !RegExp(r'成功|时间|\d{4}[-/年.]|^.*银行$').hasMatch(s),
        )
        .toList();
    int score(String s) =>
        RegExp(r'[\u3400-\u9fff]').allMatches(s).length -
        RegExp(r'[A-Za-z]').allMatches(s).length * 2;
    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.isEmpty ? '' : candidates.first;
  }

  String _account(String s) {
    s = s.trim().replaceFirst(RegExp(r'^[^0-9\u3400-\u9fffA-Za-z*]+'), '');
    if (s.isEmpty || RegExp(r'^[0-9\s-]+$').hasMatch(s)) return '';
    if (RegExp(r'[\u3400-\u9fff]').allMatches(s).length < 2 &&
        RegExp(r'[A-Za-z]').allMatches(s).length < 4) {
      return '';
    }
    if (s == '零钱' || s == '零钱通') return '微信零钱';
    if (s == '余额' || s == '余额宝') return '支付宝$s';
    if (_keys.contains(s) || RegExp('(?:${_label.pattern})[:：]').hasMatch(s)) {
      return '';
    }
    if (s.contains('财付通') && !s.contains('银行')) return '';
    return s.replaceAllMapped(
      RegExp(r'[(（][ \t]*(\d{4})[ \t]*[)）]'),
      (m) => ' 尾号${m[1]}',
    );
  }
}
