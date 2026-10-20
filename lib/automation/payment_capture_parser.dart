import '../core/security/source_privacy.dart';
import '../domain/models.dart';
import '../domain/family_payment.dart';
import '../domain/money.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/parser/ocr_receipt_parser.dart';
import '../transaction/parser/chinese_number_parser.dart';
import '../transaction/auto_correction.dart';
import '../transaction/confidence/confidence_engine.dart';
import '../transaction/confidence/confidence_calibration.dart';
import '../transaction/confidence/confidence_models.dart';
import 'payment_apps.dart';
import 'payment_source_profiles.dart';
import 'family_payment_detector.dart';

class PaymentCapture {
  const PaymentCapture({
    required this.id,
    required this.packageName,
    required this.kind,
    required this.text,
    required this.capturedAt,
    required this.ledgerId,
    this.accountId,
    this.categoryId,
    this.autoSave = true,
  });
  final String id, packageName, kind, text, ledgerId;
  final String? accountId, categoryId;
  final DateTime capturedAt;
  final bool autoSave;
  factory PaymentCapture.fromJson(Map data) {
    final id = data['id'],
        app = data['packageName'],
        kind = data['kind'],
        text = data['text'],
        time = data['capturedAt'],
        ledger = data['ledgerId'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        app is! String ||
        !isPaymentCapturePackage(app) ||
        ![
          'notification',
          'accessibility',
          'screenshot',
          'bankNotice',
        ].contains(kind) ||
        (kind == 'screenshot' && app != manualOcrPackage) ||
        text is! String ||
        text.isEmpty ||
        text.length > 4000 ||
        time is! int ||
        time <= 0 ||
        ledger is! String ||
        ledger.isEmpty) {
      throw const FormatException('Invalid payment capture');
    }
    return PaymentCapture(
      id: id,
      packageName: app,
      kind: kind as String,
      text: text,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(time),
      ledgerId: ledger,
      accountId: data['accountId'] is String ? data['accountId'] : null,
      categoryId: data['categoryId'] is String ? data['categoryId'] : null,
      autoSave: data['autoSave'] == true,
    );
  }
}

class ParsedPaymentCapture {
  const ParsedPaymentCapture(
    this.draft,
    this.canAutoSave, {
    required this.confidence,
    this.familyPayment,
  });
  final TransactionDraft draft;
  final bool canAutoSave;
  final TransactionConfidence confidence;
  final FamilyPaymentDetection? familyPayment;
}

class PaymentCaptureParser {
  static final success = RegExp(
    r'支付成功|付款成功|交易成功|消费成功|扣款成功|收款成功|到账成功|转账成功|充值成功|提现成功|自动扣款成功|退款成功|已退款|已全额退款|退款处理完成|已(?:成功)?(?:支付|付款|扣款|收款)',
  );
  static final completedProse = RegExp(
    r'(?:你|您)(?:已|已经)?(?:向|在).{1,80}?(?:支付|付款|消费)(?:了|成功|完成)?\s*[¥￥]?\s*\d+(?:\.\d{1,2})?\s*元|(?:成功|已)(?:支付|付款|消费|扣款).{0,20}?\d+(?:\.\d{1,2})?\s*元',
  );
  static bool _isTransfer(String text) => RegExp(
    r'你发起了一笔转账|对方已收款|转账成功|已转账|转账金额|转账时间|转账单号|资金待入账|转入成功|转出成功|成功转入|成功转出',
  ).hasMatch(text);

  static bool _isRedPacket(String packageName, String text) {
    if (packageName == 'com.tencent.mm') {
      return RegExp(r'红包已发出|红包发送成功|已存入零钱').hasMatch(text) ||
          (RegExp(
                r'^(?:红包详情|微信红包|.{1,40}的红包)$',
                multiLine: true,
              ).hasMatch(text) &&
              RegExp(r'红包金额|领取时间|发出时间|领取成功|已领取').hasMatch(text));
    }
    if (packageName == 'com.eg.android.AlipayGphone') {
      final structure = RegExp(
        r'^(?:红包详情|支付宝红包|送你的红包|.{1,40}发的红包)$',
        multiLine: true,
      ).hasMatch(text);
      return structure &&
          RegExp(r'红包金额|查看红包|领取成功(?:，已存入余额)?|已领取|领取中').hasMatch(text);
    }
    return false;
  }

  static bool successful(String packageName, String text) =>
      success.hasMatch(text) ||
      completedProse.hasMatch(text) ||
      _isTransfer(text) ||
      (_isRedPacket(packageName, text) &&
          RegExp(r'红包已发出|红包发送成功|已存入零钱|领取成功|已领取').hasMatch(text)) ||
      _appSpecificSuccess(packageName, text);

  /// A user-requested screenshot must contain both a monetary value and clear
  /// transaction structure. OCR text alone is not enough: otherwise any app
  /// screen (including Smart Ledger itself) would create an empty draft.
  static bool isLikelyBillScreenshot(String source) {
    final text = sanitizeSourceText(source);
    final hasMoney = RegExp(
      r'[¥￥]\s*[+-]?\d+(?:\.\d{1,2})?|^(?:\s*[+-]?\d+\.\d{2}\s*)$|(?:交易金额|支付金额|付款金额|收款金额|转账金额|实付金额|实付款|合计)\s*[:：]?\s*[¥￥]?\s*\d+(?:\.\d{1,2})?',
      multiLine: true,
    ).hasMatch(text);
    if (!hasMoney) return false;
    if (successful(manualOcrPackage, text)) return true;
    final hasDetailTitle = RegExp(
      r'账单详情|交易详情|支付详情|付款详情|收款详情|转账详情|消费详情',
    ).hasMatch(text);
    final structuredFields = <RegExp>[
      RegExp(r'交易时间|支付时间|付款时间|收款时间|转账时间|创建时间'),
      RegExp(r'交易单号|支付单号|商户单号|转账单号'),
      RegExp(r'支付方式|付款方式|收款方式|扣款方式'),
      RegExp(r'商户名称|商家名称|收款方|付款方|对方账户'),
      RegExp(r'交易金额|支付金额|付款金额|收款金额|转账金额|实付金额|实付款'),
    ].where((pattern) => pattern.hasMatch(text)).length;
    return (hasDetailTitle && structuredFields >= 1) || structuredFields >= 2;
  }

  static bool _appSpecificSuccess(String packageName, String text) {
    return paymentSourceProfile(packageName).hasCompletedStatus(text);
  }

  static final _blockedState = RegExp(
    r'^(?:支付失败|付款失败|交易失败|消费失败|扣款失败|待支付|待付款|未支付|未付款|等待支付|等待付款|支付中|付款中|交易处理中|银行处理中|已取消|交易关闭|订单关闭|还款成功|借款成功|放款成功)(?:\s*[¥￥]?\s*\d+(?:\.\d{1,2})?\s*元?)?(?:[，,。；;：:].{0,100})?$',
  );
  static final _statusLabel = RegExp(
    r'^(?:当前状态|交易状态|订单状态|支付状态|付款状态|转账状态)\s*[:：]?\s*(.+)$',
  );
  static final _unsupportedCurrency = RegExp(
    r'USD|美元|港币|港元|欧元|日元|JPY|HKD|EUR|GBP|英镑|韩元|加元|AUD|CAD|KRW|澳元|比特币|USDT|BTC',
    caseSensitive: false,
  );
  static bool _unsupported(String text) {
    if (_unsupportedCurrency.hasMatch(text)) return true;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final labeled = _statusLabel.firstMatch(line)?[1]?.trim();
      if (_blockedState.hasMatch(labeled ?? line)) return true;
    }
    return false;
  }

  ParsedPaymentCapture parse(
    PaymentCapture capture,
    List<Account> accounts,
    List<Category> categories, {
    DateTime? now,
    List<AutoCorrectionRule> autoCorrections = const [],
    ConfidenceCalibrationProfile? calibrationProfile,
  }) {
    final original = sanitizeSourceText(capture.text);
    final normalized = paymentSourceProfile(
      capture.packageName,
    ).normalize(original);
    final receipt = OcrReceiptParser().parse(normalized);
    final warnings = <String>[];
    final name = paymentCaptureSourceName(capture.packageName);
    if (RegExp(r'报销').hasMatch(original)) {
      warnings.add('报销相关交易请核对；报销到账须到管理→报销管理关联原支出，不计普通收入');
    }
    final transfer = _isTransfer(original);
    final redPacket = _isRedPacket(capture.packageName, original);
    final refund =
        receipt?.type == TransactionType.refund ||
        RegExp(
          r'退款成功|已退款|已全额退款|退款到账|退款记录|退款(?:金额\s*[:：]?)?\s*[¥￥]?\s*\d+(?:\.\d{1,2})?\s*元?',
        ).hasMatch(original);
    final peer = transfer || redPacket;
    if (peer) {
      warnings.add(
        '$name${redPacket ? '红包' : '转账'}请核对收支方向；转给他人按收支，自己的账户间移动按转账，不重复计支出',
      );
    }
    if (refund) {
      warnings.add('$name退款已识别，将按退款金额关联原消费，不会记为普通收入或新支出');
    }
    var amount = receipt?.amountMinor;
    if (amount == null) {
      final values = <int>{};
      for (final m in RegExp(
        r'[¥￥]\s*\d+(?:\.\d{1,2})?(?!\d)|\d+(?:\.\d{1,2})?\s*元(?![\d.])',
      ).allMatches(normalized)) {
        final n = ChineseNumberParser().parseMinor(m[0]!);
        if (n != null && n > 0) values.add(n);
      }
      if (capture.kind == 'accessibility' || capture.kind == 'screenshot') {
        for (final m in RegExp(
          r'^\s*[+-]?(\d+\.\d{2})\s*$',
          multiLine: true,
        ).allMatches(normalized)) {
          final n = ChineseNumberParser().parseMinor(m[1]!);
          if (n != null && n > 0) values.add(n);
        }
      }
      if (values.length == 1) amount = values.single;
      if (values.length > 1) warnings.add('通知存在多个金额，请核对');
    }
    var merchant = _cleanCapturedMerchant(receipt?.merchant ?? '');
    // A notification's title is an app/channel name, never a merchant.
    if (capture.kind == 'notification' || capture.kind == 'bankNotice') {
      merchant = '';
      final field = RegExp(
        r'(?:商户全称|商户名称|商家名称|商户|商家|付款人)\s*[:：]?\s*([^\n，,；;]+)',
      ).firstMatch(normalized);
      final sentence = RegExp(
        r'(?:向|在)\s*([^\n，,；;]{2,50}?)\s*(?:成功)?(?:付款|支付|消费)',
      ).firstMatch(normalized);
      merchant = (field?[1] ?? sentence?[1] ?? '').trim();
      merchant = merchant
          .replaceFirst(RegExp(r'\s*(?:金额|支付方式|付款方式|交易金额|消费金额).*$'), '')
          .trim();
      merchant = _cleanCapturedMerchant(merchant);
    }
    final income =
        !refund &&
        (RegExp(r'收款成功|到账成功|(?<!对方)已收款|已(?:成功)?收款').hasMatch(normalized) ||
            (redPacket && RegExp(r'已存入零钱|领取成功|已领取').hasMatch(original)));
    var accountText = receipt?.accountText ?? '';
    accountText = accountText.replaceAllMapped(
      RegExp(r'(?:\*{2,}|[xX]{2,})\s*(\d{4})(?!\d)'),
      (m) => ' 尾号${m[1]}',
    );
    if (RegExp(
      r'^(微信|支付宝|云闪付|京东|美团|银联)(?:支付|付款)?$',
    ).hasMatch(accountText.replaceAll(RegExp(r'[\s\[\]【】()（）]'), ''))) {
      accountText = '';
      warnings.add('只识别支付渠道，未确定实际扣款账户，请核对');
    }
    final requiresDefaultAccount = accountText.isEmpty;
    if (RegExp(r'^(银行卡|信用卡|储蓄卡|借记卡)$').hasMatch(accountText.trim())) {
      warnings.add('仅识别卡片类型，未确定具体付款卡，请核对');
    }
    final bound = accounts
        .where((a) => a.id == capture.accountId && !a.archived)
        .firstOrNull;
    if (accountText.isEmpty &&
        bound != null &&
        !RegExp(r'银行卡|信用卡|花呗|白条|尾号|余额|零钱').hasMatch(normalized)) {
      accountText = bound.name;
    }
    final category = categories
        .where(
          (c) =>
              c.id == capture.categoryId &&
              !c.archived &&
              c.type ==
                  (income ? TransactionType.income : TransactionType.expense),
        )
        .firstOrNull;
    final explicitCategory =
        RegExp(
          r'^(?:账单分类|分类)\s*[:：]?\s*([^\n，,；;]+)',
          multiLine: true,
        ).firstMatch(normalized)?[1]?.trim() ??
        '';
    final categoryName = explicitCategory.isNotEmpty
        ? explicitCategory
        : category?.name;
    var date = receipt?.date;
    final detected = RegExp(
      r'(20\d{2})[-/年](\d{1,2})[-/月](\d{1,2})日?',
    ).firstMatch(normalized);
    date ??= detected?[0];
    if (date == null) {
      date = dateTimeKey(capture.capturedAt);
      if (capture.kind == 'accessibility' || capture.kind == 'screenshot') {
        warnings.add('页面未提供支付日期，请核对');
      } else if ((now ?? DateTime.now()).difference(capture.capturedAt).abs() >
          const Duration(minutes: 2)) {
        warnings.add('通知处理延迟，日期按通知时间推测，请核对');
      }
    }
    final completed = refund || successful(capture.packageName, original);
    final familyPayment = const FamilyPaymentDetector().detect(
      packageName: capture.packageName,
      text: original,
      completed: completed && !refund,
    );
    if (!completed) {
      warnings.add('未确认交易成功，不自动保存');
    }
    if (familyPayment != null) {
      warnings.add(
        '${familyPayment.platform.label}交易需确认本机是发送方还是使用方；额度不是余额，使用方不会扣减本人账户',
      );
    }
    if (_unsupported(original) ||
        success.allMatches(original).map((m) => m[0]).toSet().length > 1) {
      warnings.add('交易状态或内容不适合自动保存，请核对');
    }
    // Promotional/security copy does not invalidate a completed receipt, but it
    // makes unattended posting unsafe because its amount may be mistaken for
    // the transaction amount. Keep the draft and require a quick review.
    if (RegExp(r'优惠券|验证码|账单汇总|催付').hasMatch(original)) {
      warnings.add('页面含优惠或验证信息，请核对交易金额');
    }
    if (peer && merchant.isEmpty) {
      merchant = redPacket ? '$name红包' : '$name转账';
    }
    final canonical =
        '${refund
            ? '退款成功'
            : income
            ? '收款成功'
            : '支付成功'}\n'
        '${merchant.isEmpty ? '' : '商户名称 $merchant\n'}'
        '${amount == null ? '' : '交易金额 ${amount ~/ 100}.${(amount % 100).toString().padLeft(2, '0')}元\n'}'
        '${receipt?.evidence['original_amount_minor'] == null ? '' : '原支付金额 ${_minorText(receipt!.evidence['original_amount_minor']!)}\n'}'
        '${receipt?.evidence['refund_amount_minor'] == null ? '' : '已退款金额 ${_minorText(receipt!.evidence['refund_amount_minor']!)}\n'}'
        '${accountText.isEmpty ? '' : '支付方式 $accountText\n'}'
        '支付时间 $date\n'
        '${refund || categoryName == null ? '' : '账单分类 $categoryName\n'}'
        '交易服务\n采集来源 ${capture.kind == 'accessibility'
            ? '无障碍页面'
            : capture.kind == 'screenshot'
            ? '本地截图OCR'
            : '支付通知'} · $name\n原始内容\n$original';
    final raw = RawTransaction(
      text: canonical.length <= 4000 ? canonical : canonical.substring(0, 4000),
      source: capture.kind == 'screenshot'
          ? TransactionSource.ocr
          : TransactionSource.notification,
      capturedAt: capture.capturedAt,
      sourceApp: capture.packageName,
      paymentMethod: accountText,
    );
    final parsed = TransactionParser().parse(
      raw,
      ledgerId: capture.ledgerId,
      accounts: accounts,
      categories: categories,
    );
    // Preserve original ambiguities; normalization must not hide receipt conflicts.
    warnings.addAll(receipt?.warnings.where((w) => w != '商户取自账单标题，请核对') ?? []);
    warnings.addAll(parsed.warnings);
    if (receipt?.evidence['net_amount_minor'] != null) {
      warnings.removeWhere(
        (warning) =>
            warning.contains('退款已识别，将按退款金额关联') ||
            warning.contains('已识别退款；需关联原消费'),
      );
    }
    if (requiresDefaultAccount && capture.accountId != null && bound == null) {
      warnings.add('设定的付款账户已归档或不存在');
    }
    if (!income &&
        explicitCategory.isEmpty &&
        capture.categoryId != null &&
        category == null) {
      warnings.add('设定的分类不适用于本笔收支');
    }
    if (merchant.isEmpty) warnings.add('商户未确定，请核对');
    if (merchant.length > 100) warnings.add('商户信息异常，请核对');
    var draft = TransactionDraft(
      raw: raw,
      ledgerId: capture.ledgerId,
      type: parsed.type,
      amountMinor: parsed.amountMinor,
      occurredDate: parsed.occurredDate,
      accountId: parsed.accountId,
      categoryId: parsed.categoryId,
      relatedTransactionId: parsed.relatedTransactionId,
      merchant: parsed.merchant,
      note: parsed.note,
      tags: parsed.tags,
      blocked: parsed.blocked,
      warnings: warnings.toSet().toList(),
      evidence: {
        ...parsed.evidence,
        if (receipt != null) ...receipt.evidence,
        'source': '$name / ${capture.kind}',
        if (receipt?.date == null && detected == null)
          'date': '通知或页面采集时间：$date',
        if (accountText == bound?.name)
          'account': '使用你设定的付款账户：${bound!.displayName}',
        if (familyPayment != null)
          'family_platform': familyPayment.platform.name,
        if (familyPayment?.roleHint != null)
          'family_role': familyPayment!.roleHint!.name,
      },
      familyRole: familyPayment?.roleHint,
    );
    draft = applyAutoCorrection(draft, autoCorrections);
    final confidence = const ConfidenceEngine().evaluate(
      draft,
      context: ConfidenceContext(
        sourceKind: capture.kind,
        modelVersion: capture.kind == 'screenshot'
            ? 'PP-OCRv6/unknown-tier'
            : 'source-profile-v1',
        completed: completed,
        calibrationProfile: calibrationProfile,
      ),
    );
    draft = draft.withConfidence(confidence);
    final eligible =
        capture.autoSave &&
        familyPayment == null &&
        confidence.allowsAutoPost &&
        !_unsupported(original) &&
        !draft.occurredDate.isAfter(
          DateTime(
            capture.capturedAt.year,
            capture.capturedAt.month,
            capture.capturedAt.day,
            capture.capturedAt.hour,
            capture.capturedAt.minute,
            capture.capturedAt.second,
          ),
        );
    return ParsedPaymentCapture(
      draft,
      eligible,
      confidence: confidence,
      familyPayment: familyPayment,
    );
  }

  static String _cleanCapturedMerchant(String value) {
    var clean = value.trim();
    // WeChat can expose one accessibility sentence such as
    // `精品沙县小吃,支出16.00元`. The amount is transaction evidence, not part
    // of the merchant name. Require a direction/amount label so legitimate
    // merchant names containing digits are left untouched.
    clean = clean.replaceFirst(
      RegExp(
        r'\s*[,，;；|]\s*(?:支出|收入|支付|付款|实付|实收|交易金额|消费金额|金额)\s*[:：]?\s*[¥￥]?\s*[+\-]?\d+(?:\.\d{1,2})?\s*元?.*$',
      ),
      '',
    );
    return clean.trim();
  }

  static String _minorText(String value) {
    final minor = int.tryParse(value);
    if (minor == null || minor < 0) return '';
    return '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')}元';
  }
}
