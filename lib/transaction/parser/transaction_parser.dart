import '../../domain/models.dart';
import '../../domain/credit_platforms.dart';
import '../../domain/family_payment.dart';
import '../../merchant/merchant_normalizer.dart';
import '../../automation/payment_apps.dart';
import 'chinese_number_parser.dart';
import 'ocr_receipt_parser.dart';
import 'payment_account_resolver.dart';
import '../confidence/confidence_models.dart';

enum TransactionSource { text, ocr, speech, notification, import }

class RawTransaction {
  const RawTransaction({
    required this.text,
    required this.capturedAt,
    this.source = TransactionSource.text,
    this.sourceApp = '',
    this.paymentMethod = '',
  });
  final String text;
  final DateTime capturedAt;
  final TransactionSource source;
  final String sourceApp;
  final String paymentMethod;
}

/// A proposal posted after user confirmation or the authorized screenshot policy.
/// Evidence and warnings explain parsing. [confidence] is a versioned policy
/// snapshot and remains explicitly uncalibrated until labelled samples exist.
class TransactionDraft {
  const TransactionDraft({
    required this.raw,
    required this.ledgerId,
    required this.type,
    required this.occurredDate,
    required this.warnings,
    required this.evidence,
    this.amountMinor,
    this.accountId,
    this.categoryId,
    this.relatedTransactionId,
    this.merchant = '',
    this.note = '',
    this.tags = const [],
    this.blocked = false,
    this.familyEventId,
    this.familyRole,
    this.confidence,
  });
  final RawTransaction raw;
  final String ledgerId;
  final TransactionType type;
  final int? amountMinor;
  final DateTime occurredDate;
  final String? accountId;
  final String? categoryId;
  final String? relatedTransactionId;
  final String merchant;
  final String note;
  final List<String> tags;
  final List<String> warnings;
  final Map<String, String> evidence;
  final bool blocked;
  final String? familyEventId;
  final FamilyLocalRole? familyRole;
  final TransactionConfidence? confidence;

  TransactionDraft withWarnings(List<String> values) => TransactionDraft(
    raw: raw,
    ledgerId: ledgerId,
    type: type,
    amountMinor: amountMinor,
    occurredDate: occurredDate,
    accountId: accountId,
    categoryId: categoryId,
    relatedTransactionId: relatedTransactionId,
    merchant: merchant,
    note: note,
    tags: tags,
    blocked: blocked,
    evidence: evidence,
    warnings: values,
    familyEventId: familyEventId,
    familyRole: familyRole,
    confidence: confidence,
  );

  TransactionDraft withConfidence(TransactionConfidence value) =>
      TransactionDraft(
        raw: raw,
        ledgerId: ledgerId,
        type: type,
        amountMinor: amountMinor,
        occurredDate: occurredDate,
        accountId: accountId,
        categoryId: categoryId,
        relatedTransactionId: relatedTransactionId,
        merchant: merchant,
        note: note,
        tags: tags,
        blocked: blocked,
        evidence: evidence,
        warnings: warnings,
        familyEventId: familyEventId,
        familyRole: familyRole,
        confidence: value,
      );

  TransactionDraft withFamilyBinding({
    required String? eventId,
    FamilyLocalRole? role,
    String? resolvedAccountId,
    bool clearAccountForBeneficiary = false,
  }) => TransactionDraft(
    raw: raw,
    ledgerId: ledgerId,
    type: type,
    amountMinor: amountMinor,
    occurredDate: occurredDate,
    accountId: clearAccountForBeneficiary
        ? null
        : (resolvedAccountId ?? accountId),
    categoryId: categoryId,
    relatedTransactionId: relatedTransactionId,
    merchant: merchant,
    note: note,
    tags: tags,
    blocked: blocked,
    warnings: warnings,
    evidence: {
      ...evidence,
      'family_event_id': ?eventId,
      'family_role': ?role?.name,
    },
    familyEventId: eventId,
    familyRole: role,
    confidence: confidence,
  );

  TransactionDraft withBatchEdits({
    String? accountId,
    String? categoryId,
    List<String>? tags,
    String? ledgerId,
  }) => TransactionDraft(
    raw: raw,
    ledgerId: ledgerId ?? this.ledgerId,
    type: type,
    amountMinor: amountMinor,
    occurredDate: occurredDate,
    accountId: accountId ?? this.accountId,
    categoryId: categoryId ?? this.categoryId,
    relatedTransactionId: relatedTransactionId,
    merchant: merchant,
    note: note,
    tags: tags ?? this.tags,
    blocked: blocked,
    warnings: warnings,
    evidence: evidence,
    familyEventId: familyEventId,
    familyRole: familyRole,
    confidence: confidence,
  );

  TransactionDraft withMerchantKnowledge({
    required String merchant,
    String? categoryId,
    String? evidenceText,
  }) => TransactionDraft(
    raw: raw,
    ledgerId: ledgerId,
    type: type,
    amountMinor: amountMinor,
    occurredDate: occurredDate,
    accountId: accountId,
    categoryId: categoryId ?? this.categoryId,
    relatedTransactionId: relatedTransactionId,
    merchant: merchant,
    note: note,
    tags: tags,
    blocked: blocked,
    warnings: warnings
        .where((value) => categoryId == null || !value.startsWith('分类未确定'))
        .toList(),
    evidence: {...evidence, 'merchant_knowledge': ?evidenceText},
    familyEventId: familyEventId,
    familyRole: familyRole,
    confidence: confidence,
  );

  Map<String, Object?> toJson() => {
    'type': type.name,
    'amount_minor': amountMinor,
    'occurred_date': occurredDate.toIso8601String(),
    'account_id': accountId,
    'category_id': categoryId,
    'related_transaction_id': relatedTransactionId,
    'merchant': merchant,
    'note': note,
    'tags': tags,
    'warnings': warnings,
    'evidence': evidence,
    'blocked': blocked,
    if (familyEventId != null) 'family_event_id': familyEventId,
    if (familyRole != null) 'family_role': familyRole!.name,
    if (confidence != null) 'confidence': confidence!.toJson(),
  };
}

class PendingDraft {
  const PendingDraft({
    required this.id,
    required this.ledgerId,
    required this.raw,
    this.storedWarnings = const [],
    this.familyEventId,
    this.familyRole,
    this.confidence,
    this.batchAccountId,
    this.batchCategoryId,
    this.batchTags,
  });
  final List<String> storedWarnings;
  final String id;
  final String ledgerId;
  final RawTransaction raw;
  final String? familyEventId;
  final FamilyLocalRole? familyRole;
  final TransactionConfidence? confidence;
  final String? batchAccountId;
  final String? batchCategoryId;
  final List<String>? batchTags;
}

class TransactionParser {
  final _numbers = ChineseNumberParser();
  final _merchants = MerchantNormalizer();
  static const _n = r'[0-9零〇一二两三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟萬点.]+';

  TransactionDraft parse(
    RawTransaction raw, {
    required String ledgerId,
    required List<Account> accounts,
    required List<Category> categories,
  }) {
    final warnings = <String>[];
    final evidence = <String, String>{};
    var text = raw.text.trim();
    final today = DateTime(
      raw.capturedAt.year,
      raw.capturedAt.month,
      raw.capturedAt.day,
      raw.capturedAt.hour,
      raw.capturedAt.minute,
      raw.capturedAt.second,
    );
    var date = today;
    var type = TransactionType.expense;
    var blocked = false;
    String? relatedTransactionId;
    if (text.isEmpty || text.length > 4000) {
      return TransactionDraft(
        raw: raw,
        ledgerId: ledgerId,
        type: type,
        occurredDate: today,
        warnings: const ['请输入 1～4000 字的单笔账单描述'],
        evidence: const {},
        blocked: true,
      );
    }
    // Preserve the original text; normalized text is only used during parsing.
    text = String.fromCharCodes(
      text.runes.map((c) => c >= 0xff10 && c <= 0xff19 ? c - 0xff10 + 0x30 : c),
    );
    text = text.replaceAll('．', '.').replaceAll('，', ',');
    text = text.replaceAll('圆', '元').replaceAll('圓', '元');
    text = text.replaceAll('支护宝', '支付宝');
    OcrReceipt? payment;
    if (raw.source == TransactionSource.ocr ||
        raw.source == TransactionSource.notification) {
      text = text.replaceAll(
        RegExp(r'(?<=[\u3400-\u9fff])[ \t]+(?=[\u3400-\u9fff])'),
        '',
      );
      text = text.replaceAllMapped(
        RegExp(r'(\d)[ 	]+(?=[年月日:/-])'),
        (m) => m[1]!,
      );
      text = text.replaceAllMapped(
        RegExp(r'([年月日:/-])[ 	]+(?=\d)'),
        (m) => m[1]!,
      );
      payment = OcrReceiptParser().parse(text);
      if (payment != null) {
        text = payment.text;
        warnings.addAll(payment.warnings);
        evidence.addAll(payment.evidence);
        blocked = payment.blocked;
      }
    }
    final relatedMatch = RegExp(
      r'原交易编号\s*[:：]?\s*([a-f0-9-]{36})',
      caseSensitive: false,
    ).firstMatch(raw.text);
    relatedTransactionId = relatedMatch?[1];
    final accountText = payment?.accountText ?? text;
    final mentionedPlatforms = creditPlatforms
        .where((p) => p.aliases.any(accountText.contains))
        .toList();
    if (RegExp(r'报销(?:款)?(?:到账|收入|收款)|收到.*报销|报销.*到账').hasMatch(text)) {
      blocked = true;
      warnings.add('报销到账需关联原支出，请到管理→报销管理记录，不计普通收入');
    }
    final refund =
        payment?.type == TransactionType.refund ||
        RegExp(
          r'退款成功|已退款|已全额退款|退款到账|退款记录|退款(?:金额\s*[:：]?)?\s*[¥￥]?\s*\d+(?:\.\d{1,2})?\s*元?',
        ).hasMatch(text);
    final partialNet = int.tryParse(evidence['net_amount_minor'] ?? '');
    final partialRefund = int.tryParse(evidence['refund_amount_minor'] ?? '');
    final partialOrder =
        refund &&
        partialNet != null &&
        partialNet > 0 &&
        partialRefund != null &&
        partialRefund > 0;
    if (partialOrder && relatedTransactionId == null) {
      type = TransactionType.expense;
      blocked = false;
      warnings.removeWhere(
        (warning) =>
            warning.contains('已识别退款') ||
            warning.contains('退款已识别') ||
            warning.contains('退款、'),
      );
      warnings.add('${evidence['amount_breakdown'] ?? '订单包含部分退款'}，已按净消费生成，请核对');
      evidence['type'] = '部分退款订单净消费';
    } else if (refund) {
      type = TransactionType.refund;
      if (relatedTransactionId == null) {
        blocked = true;
        warnings.add('退款已识别，尚未唯一匹配原消费，请选择原交易');
      } else {
        blocked = false;
        warnings.removeWhere(
          (warning) => warning.contains('已识别退款') || warning.contains('退款、'),
        );
        warnings.add('已自动关联原消费，请核对退款金额后保存');
        evidence['type'] = '退款记录';
      }
    }
    if (RegExp(r'转账|转入|转出|还款|借款|借钱|放款|贷款').hasMatch(text) ||
        mentionedPlatforms.any((p) => p.kind == AccountKind.loan)) {
      blocked = true;
      warnings.add('退款、转账、借款和还款请使用手动入口；本金到账和归还属于账户转账');
    }
    if (RegExp(
      r'美元|美金|USD|日元|JPY|欧元|EUR|港币|HKD|\$|€',
      caseSensitive: false,
    ).hasMatch(text)) {
      blocked = true;
      warnings.add('当前仅支持人民币，不会把其他币种自动转换为人民币');
    }
    // Payment screenshots name the payee as 收款商户/收款方. These field
    // labels describe the counterparty, not income for the user.
    final directionText = text.replaceAll(
      RegExp(r'收款\s*(?:商户|方|单位|账户|人|码)'),
      '',
    );
    final income = payment != null
        ? payment.type == TransactionType.income
        : RegExp(r'工资|奖金|兼职收入|收入|收款|到账').hasMatch(directionText);
    final expense = payment != null
        ? payment.type == TransactionType.expense
        : RegExp(r'消费|付款|支付(?!宝)|花了|支出').hasMatch(text);
    if (income && expense) {
      blocked = true;
      warnings.add('同时出现收入和支出，请拆成单笔描述');
    } else if (income && !refund) {
      type = TransactionType.income;
      evidence['type'] = '收入关键词';
    }
    final explicitDates = RegExp(
      r'(?<!\d)(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?(?!\d)',
    ).allMatches(text).toList();
    final relativeDates = RegExp(r'大前天|前天|昨天|今天').allMatches(text).toList();
    if (explicitDates.length + relativeDates.length > 1) {
      warnings.add('出现多个日期，暂用今天，请核对');
    } else if (explicitDates.length == 1) {
      final m = explicitDates.single;
      final y = int.parse(m[1]!);
      final mo = int.parse(m[2]!);
      final d = int.parse(m[3]!);
      final candidate = DateTime(
        y,
        mo,
        d,
        today.hour,
        today.minute,
        today.second,
      );
      if (y >= 1900 &&
          y <= 2100 &&
          candidate.year == y &&
          candidate.month == mo &&
          candidate.day == d) {
        date = candidate;
        evidence['date'] = m[0]!;
      } else {
        warnings.add('日期无效，暂用今天，请核对');
      }
    } else if (relativeDates.length == 1) {
      final word = relativeDates.single[0]!;
      final offset = {'今天': 0, '昨天': 1, '前天': 2, '大前天': 3}[word]!;
      date = DateTime(
        today.year,
        today.month,
        today.day - offset,
        today.hour,
        today.minute,
        today.second,
      );
      evidence['date'] = word;
    } else {
      warnings.add('未识别日期，暂用今天');
    }
    final explicitTimes = RegExp(
      r'(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?!\d)',
    ).allMatches(text).toList();
    if (explicitTimes.length == 1) {
      final clock = explicitTimes.single;
      date = DateTime(
        date.year,
        date.month,
        date.day,
        int.parse(clock[1]!),
        int.parse(clock[2]!),
        int.tryParse(clock[3] ?? '') ?? 0,
      );
      evidence['time'] = clock[0]!;
    } else if (explicitTimes.length > 1) {
      warnings.add('出现多个时间，暂用采集时间，请核对');
    }
    // The receipt parser has already selected the highest-ranked payment time.
    // Keep its seconds even when the normalized receipt text contains another
    // informational clock that would otherwise make the generic scan ambiguous.
    final receiptDateText = payment?.date ?? '';
    final preferredReceiptDate = partialOrder && relatedTransactionId == null
        ? evidence['payment_date'] ?? receiptDateText
        : evidence['refund_date'] ?? receiptDateText;
    final receiptDateTime = DateTime.tryParse(preferredReceiptDate);
    if (preferredReceiptDate.contains('T') && receiptDateTime != null) {
      date = receiptDateTime;
      evidence['time'] = preferredReceiptDate.substring(11);
    }
    text = text.replaceAll(RegExp(r'\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?'), ' ');
    text = text.replaceAll(RegExp(r'\d{1,2}:\d{2}(?::\d{2})?'), ' ');
    text = text.replaceAll(
      RegExp(r'(订单号|交易号|流水号|尾号)\s*[:：]?\s*[A-Za-z0-9-]+'),
      ' ',
    );
    // Remove valid grouped thousands, never use double to parse the result.
    text = text.replaceAllMapped(
      RegExp(r'(?<!\d)\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?(?!\d)'),
      (m) => m[0]!.replaceAll(',', ''),
    );
    int? amount;
    if (payment != null) {
      amount = partialOrder && relatedTransactionId == null
          ? partialNet
          : partialOrder
          ? partialRefund
          : payment.amountMinor;
    } else {
      final amountPattern = RegExp(
        '(?:[¥￥]\\s*)?(?:$_n(?:元|块钱|块)(?:$_n(?:角|毛)(?:$_n分?)?|$_n分?)?|$_n(?:角|毛)(?:$_n分?)?|$_n分)|[¥￥]\\s*$_n',
      );
      final matches = amountPattern.allMatches(text).toList();
      if (matches.length == 1) {
        final m = matches.single;
        final before = text.substring(0, m.start).trimRight();
        var expression = m[0]!;
        // A count after a currency marker is not fractional money: 38元一杯.
        if (RegExp(r'^(个|杯|份|件|人|笔|次|瓶|包|张)').hasMatch(text.substring(m.end))) {
          expression = expression.replaceFirst(RegExp('(?<=[元块角毛])$_n\$'), '');
        }
        amount = _numbers.parseMinor(expression);
        if (before.endsWith('-') ||
            before.endsWith('负') ||
            before.endsWith(',')) {
          amount = null;
        }
        if (amount != null) evidence['amount'] = expression;
      } else if (matches.length > 1) {
        warnings.add('识别到多个金额，请手动选择本笔交易金额');
      } else {
        final bare = RegExp(
          '(?<![0-9.])$_n(?![0-9.])',
        ).allMatches(text).toList();
        if (bare.length == 1 &&
            (RegExp(r'[0-9十百千万亿]').hasMatch(bare.single[0]!) ||
                RegExp(r'金额|消费|付款|花了|支出').hasMatch(text)) &&
            !RegExp(r'编号|订单|数量|件|杯|人|号|年|月|日|折|%|负|-').hasMatch(text)) {
          amount = _numbers.parseMinor(bare.single[0]!);
          if (amount != null) {
            evidence['amount'] = bare.single[0]!;
            warnings.add('金额未注明元，按人民币理解，请核对');
          }
        }
      }
      if (amount == null) warnings.add('金额未确定，请在确认表单中填写');
    }
    if (amount == null && !warnings.contains('金额未确定，请在确认表单中填写')) {
      warnings.add('金额未确定，请在确认表单中填写');
    }
    final merchants = _merchants.find(payment?.merchant ?? text);
    var merchant = payment?.merchant ?? '';
    if (merchant.isNotEmpty) evidence['merchant'] = '商户全称：$merchant';
    String? suggestedCategory;
    if (merchants.length == 1) {
      merchant = merchants.single.name;
      suggestedCategory = merchants.single.category;
      evidence['merchant'] = merchants.single.evidence;
    } else if (merchants.length > 1) {
      warnings.add('出现多个商户，请手动选择');
    }
    final accountResolution = const PaymentAccountResolver().resolve(
      accountText,
      raw.sourceApp,
      accounts,
    );
    final accountId = accountResolution.account?.id;
    if (accountResolution.account != null) {
      evidence['account'] =
          '${accountResolution.account!.displayName}（${accountResolution.reason}）';
    } else {
      warnings.add(accountResolution.ambiguous ? '出现多个可能账户，请选择' : '未识别到账户，请选择');
    }
    // Explicit category words take priority over merchant suggestions.
    final eligible = categories.where((c) => c.type == type).toList();
    final categoryText = payment?.categoryText ?? text;
    final explicit = eligible
        .where((c) => categoryText.contains(c.name))
        .toList();
    // A child may include its parent's name. Keep the most specific match.
    final specific = explicit
        .where((c) => !explicit.any((child) => child.parentId == c.id))
        .toList();
    String? categoryId;
    if (specific.length == 1) {
      categoryId = specific.single.id;
      evidence['category'] = '关键词：${specific.single.name}';
    } else if (specific.isEmpty && type == TransactionType.expense) {
      suggestedCategory ??= payment == null
          ? null
          : _receiptCategory(categoryText);
      final suggestions = eligible
          .where((c) => c.name == suggestedCategory)
          .toList();
      if (suggestions.length == 1) {
        categoryId = suggestions.single.id;
        evidence['category'] = '商户建议：${suggestions.single.name}';
      }
    }
    if (categoryId == null && type != TransactionType.refund) {
      warnings.add('分类未确定，请选择');
    }
    final sourceAppName = raw.sourceApp.isNotEmpty
        ? paymentCaptureSourceName(raw.sourceApp)
        : '';
    final refundAmount = partialRefund ?? (refund ? amount : null);
    final refundNote = refund
        ? (refundAmount != null && refundAmount > 0
            ? '${sourceAppName.isNotEmpty ? "$sourceAppName · " : ""}有退款 退款金额: ${refundAmount ~/ 100}.${(refundAmount % 100).toString().padLeft(2, '0')}元'
            : '${sourceAppName.isNotEmpty ? "$sourceAppName · " : ""}有退款')
        : (sourceAppName.isNotEmpty ? '来源: $sourceAppName' : '');
    var note =
        RegExp(
          r'^(?:备注|付款备注|转账备注|说明)\s*[:：]?\s*([^\n]+)',
          multiLine: true,
        ).firstMatch(text)?[1]?.trim() ??
        '';
    if (refundNote.isNotEmpty) {
      note = note.isEmpty
          ? refundNote
          : (note.contains(refundNote) ? note : '$refundNote | $note');
    }
    return TransactionDraft(
      raw: raw,
      ledgerId: ledgerId,
      type: type,
      amountMinor: amount,
      occurredDate: date,
      accountId: accountId,
      categoryId: categoryId,
      relatedTransactionId: relatedTransactionId,
      merchant: merchant,
      note: note,
      warnings: List.unmodifiable(warnings.toSet()),
      evidence: Map.unmodifiable(evidence),
      blocked: blocked,
    );
  }

  String? _receiptCategory(String text) {
    const groups = {
      '咖啡': '咖啡|coffee',
      '外卖': '外卖',
      '餐饮': '餐馆|餐厅|饭店|小吃|早餐|午餐|晚餐|美食|奶茶',
      '交通': '单车|骑行|地铁|公交|出行',
      '打车': '打车|出租车',
      '日用品': '日用品|生活用品',
    };
    final matches = groups.entries
        .where((e) => RegExp(e.value, caseSensitive: false).hasMatch(text))
        .toList();
    return matches.length == 1 ? matches.single.key : null;
  }
}
