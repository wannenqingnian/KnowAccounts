import '../domain/models.dart';
import 'parser/transaction_parser.dart';

String normalizeMerchantPattern(String value) => value
    .toLowerCase()
    .replaceAll('（', '(')
    .replaceAll('）', ')')
    .replaceAll(RegExp(r'[^0-9a-z\u3400-\u9fff]'), '');

bool autoCorrectionMatches(AutoCorrectionRule rule, String merchant) {
  final value = normalizeMerchantPattern(merchant);
  if (value.isEmpty || rule.normalizedPattern.isEmpty) return false;
  return switch (rule.matchMode) {
    AutoCorrectionMatchMode.exact => value == rule.normalizedPattern,
    AutoCorrectionMatchMode.contains => value.contains(rule.normalizedPattern),
  };
}

String autoCorrectionSourceKey(TransactionDraft draft) =>
    draft.raw.sourceApp.trim().isNotEmpty
    ? 'app:${draft.raw.sourceApp.trim()}'
    : 'channel:${draft.raw.source.name}';

bool autoCorrectionConditionsMatch(
  AutoCorrectionRule rule,
  TransactionDraft draft,
) {
  if (!autoCorrectionMatches(rule, draft.merchant)) return false;
  final amount = draft.amountMinor;
  if (rule.minAmountMinor != null &&
      (amount == null || amount < rule.minAmountMinor!)) {
    return false;
  }
  if (rule.maxAmountMinor != null &&
      (amount == null || amount > rule.maxAmountMinor!)) {
    return false;
  }
  if (rule.sourceKey.isNotEmpty &&
      rule.sourceKey != autoCorrectionSourceKey(draft) &&
      rule.sourceKey != 'channel:${draft.raw.source.name}') {
    return false;
  }
  if (rule.sourceAccountId != null && rule.sourceAccountId != draft.accountId) {
    return false;
  }
  final weekdayBit = 1 << (draft.occurredDate.weekday - 1);
  if ((rule.weekdaysMask & weekdayBit) == 0) return false;
  final minute = draft.occurredDate.hour * 60 + draft.occurredDate.minute;
  if (rule.startMinute != null && rule.endMinute != null) {
    final start = rule.startMinute!, end = rule.endMinute!;
    final inWindow = start <= end
        ? minute >= start && minute <= end
        : minute >= start || minute <= end;
    if (!inWindow) return false;
  } else if (rule.startMinute != null && minute < rule.startMinute!) {
    return false;
  } else if (rule.endMinute != null && minute > rule.endMinute!) {
    return false;
  }
  final payment = normalizeMerchantPattern(draft.raw.paymentMethod);
  final requiredPayment = normalizeMerchantPattern(rule.paymentMethodPattern);
  return requiredPayment.isEmpty || payment.contains(requiredPayment);
}

AutoCorrectionRule? bestAutoCorrection(
  Iterable<AutoCorrectionRule> rules,
  TransactionDraft draft,
) {
  if (!const [
        TransactionType.expense,
        TransactionType.income,
      ].contains(draft.type) ||
      draft.merchant.trim().isEmpty) {
    return null;
  }
  final matches = rules
      .where(
        (rule) =>
            rule.enabled &&
            rule.type == draft.type &&
            autoCorrectionConditionsMatch(rule, draft),
      )
      .toList();
  matches.sort((left, right) {
    final priority = right.priority.compareTo(left.priority);
    if (priority != 0) return priority;
    final manual = left.learned == right.learned
        ? 0
        : left.learned
        ? 1
        : -1;
    if (manual != 0) return manual;
    final specificity = right.normalizedPattern.length.compareTo(
      left.normalizedPattern.length,
    );
    if (specificity != 0) return specificity;
    return right.updatedAt.compareTo(left.updatedAt);
  });
  return matches.firstOrNull;
}

TransactionDraft applyAutoCorrection(
  TransactionDraft draft,
  Iterable<AutoCorrectionRule> rules,
) {
  final rule = bestAutoCorrection(rules, draft);
  if (rule == null) return draft;
  final accountId = rule.accountId ?? draft.accountId;
  final categoryId = rule.categoryId ?? draft.categoryId;
  final warnings = draft.warnings.where((warning) {
    if (accountId != null &&
        (warning.startsWith('未识别到账户') || warning.startsWith('出现多个可能账户'))) {
      return false;
    }
    if (categoryId != null && warning.startsWith('分类未确定')) return false;
    return true;
  }).toList();
  return TransactionDraft(
    raw: draft.raw,
    ledgerId: rule.ledgerId,
    type: draft.type,
    amountMinor: draft.amountMinor,
    occurredDate: draft.occurredDate,
    accountId: accountId,
    categoryId: categoryId,
    relatedTransactionId: draft.relatedTransactionId,
    merchant: draft.merchant,
    note: draft.note,
    tags: rule.tags,
    blocked: draft.blocked,
    warnings: warnings,
    evidence: {
      ...draft.evidence,
      'auto_correction': '已套用“${rule.merchantPattern}”自动修正规则',
      'auto_correction_rule_id': rule.id,
      'auto_correction_source_ledger': draft.ledgerId,
    },
    confidence: draft.confidence,
  );
}
