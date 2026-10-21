import '../transaction/parser/transaction_parser.dart';

/// Compares what the parser recognized with what was actually stored.
///
/// The score mirrors the dimensions used by established bookkeeping apps:
/// amount, category and account carry most of the weight; the merchant text is
/// only a hint. Dimensions that the parser never produced are excluded and the
/// remaining weights are normalized, so a sparse notification is not punished
/// for fields it could not possibly contain.
class PaymentQuality {
  const PaymentQuality({
    required this.score,
    this.amountMatch,
    this.categoryMatch,
    this.accountMatch,
    this.remarkSimilarity,
  });

  final int score;
  final bool? amountMatch;
  final bool? categoryMatch;
  final bool? accountMatch;

  /// 0..1, or null when the recognized capture had no merchant text.
  final double? remarkSimilarity;

  bool get needsReview => score < 70;
  int get dimensionCount => [
    amountMatch,
    categoryMatch,
    accountMatch,
    remarkSimilarity,
  ].where((value) => value != null).length;

  String get grade => switch (score) {
    >= 95 => '识别准确',
    >= 85 => '基本准确',
    >= 70 => '略有修正',
    _ => '建议复核',
  };

  String get summary => [
    if (amountMatch != null) '金额 ${amountMatch! ? '一致' : '被修正'}',
    if (categoryMatch != null) '分类 ${categoryMatch! ? '一致' : '被修正'}',
    if (accountMatch != null) '账户 ${accountMatch! ? '一致' : '被修正'}',
    if (remarkSimilarity != null) '备注 ${(remarkSimilarity! * 100).round()}%',
  ].join(' · ');

  /// Only allowlisted numeric/boolean metrics leave the device boundary of the
  /// worker. Merchant, account and category names are never included here.
  Map<String, String> toTraceFields() => {
    'qualityScore': '$score',
    if (amountMatch != null) 'amountMatch': amountMatch! ? '1' : '0',
    if (categoryMatch != null) 'categoryMatch': categoryMatch! ? '1' : '0',
    if (accountMatch != null) 'accountMatch': accountMatch! ? '1' : '0',
    if (remarkSimilarity != null)
      'remarkScore': '${(remarkSimilarity! * 100).round()}',
  };

  static PaymentQuality? tryParse(Map<String, String> fields) {
    final score = int.tryParse(fields['qualityScore'] ?? '');
    if (score == null || score < 0 || score > 100) return null;
    bool? flag(String key) => switch (fields[key]) {
      '1' => true,
      '0' => false,
      _ => null,
    };
    final remark = int.tryParse(fields['remarkScore'] ?? '');
    return PaymentQuality(
      score: score,
      amountMatch: flag('amountMatch'),
      categoryMatch: flag('categoryMatch'),
      accountMatch: flag('accountMatch'),
      remarkSimilarity: remark == null
          ? null
          : remark.clamp(0, 100).toDouble() / 100,
    );
  }

  static PaymentQuality evaluate({
    required TransactionDraft recognized,
    required TransactionDraft saved,
  }) {
    final amountMinor = recognized.amountMinor;
    final hasAmount = amountMinor != null;
    final amountMatch = hasAmount && saved.amountMinor == amountMinor;

    final categoryId = recognized.categoryId;
    final hasCategory = categoryId != null && categoryId.isNotEmpty;
    final categoryMatch = hasCategory && saved.categoryId == categoryId;

    final accountId = recognized.accountId;
    final hasAccount = accountId != null && accountId.isNotEmpty;
    final accountMatch = hasAccount && saved.accountId == accountId;

    final recognizedMerchant = recognized.merchant.trim();
    final hasRemark = recognizedMerchant.isNotEmpty;
    final remarkSimilarity = hasRemark
        ? _similarity(recognizedMerchant, saved.merchant.trim())
        : null;

    var weighted = 0.0;
    var weight = 0.0;
    if (hasAmount) {
      weight += 0.3;
      if (amountMatch) weighted += 0.3;
    }
    if (hasCategory) {
      weight += 0.3;
      if (categoryMatch) weighted += 0.3;
    }
    if (hasAccount) {
      weight += 0.3;
      if (accountMatch) weighted += 0.3;
    }
    if (hasRemark) {
      weight += 0.1;
      weighted += 0.1 * remarkSimilarity!;
    }
    final score = weight == 0
        ? 0
        : (weighted / weight * 100).round().clamp(0, 100).toInt();

    return PaymentQuality(
      score: score,
      amountMatch: hasAmount ? amountMatch : null,
      categoryMatch: hasCategory ? categoryMatch : null,
      accountMatch: hasAccount ? accountMatch : null,
      remarkSimilarity: remarkSimilarity,
    );
  }

  static double _similarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    final left = a.toLowerCase().runes.toList();
    final right = b.toLowerCase().runes.toList();
    var previous = List<int>.generate(right.length + 1, (i) => i);
    for (var i = 0; i < left.length; i++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = i + 1;
      for (var j = 0; j < right.length; j++) {
        final substitution = previous[j] + (left[i] == right[j] ? 0 : 1);
        final insertion = current[j] + 1;
        final deletion = previous[j + 1] + 1;
        current[j + 1] = substitution < insertion
            ? (substitution < deletion ? substitution : deletion)
            : (insertion < deletion ? insertion : deletion);
      }
      previous = current;
    }
    final distance = previous[right.length];
    final longest = left.length > right.length ? left.length : right.length;
    return (1 - distance / longest).clamp(0, 1).toDouble();
  }
}

class PaymentProcessResult {
  const PaymentProcessResult(
    this.outcome, [
    this.quality,
    this.duplicateBasis = '',
  ]);

  final String outcome;
  final PaymentQuality? quality;

  /// Non-empty when a possible duplicate was held for review. Values match
  /// [TransactionDuplicateAssessment.matchBasis]: order, semantic, same_day
  /// or amount_time.
  final String duplicateBasis;
}
