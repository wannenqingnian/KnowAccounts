enum TransactionType { expense, income, transfer, refund, adjustment }

enum RecurringKind { incomeExpense, transfer, investment }

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

enum AccountKind { cash, bank, wechat, alipay, credit, creditPayment, loan }

enum FinancialAssetKind {
  stock,
  fund,
  fixedDeposit,
  mortgage,
  installment,
  lent,
  creditCard,
}

enum AssetTransactionKind {
  buy,
  sell,
  dividend,
  interest,
  deposit,
  withdraw,
  lend,
  collect,
  repayment,
  fee,
  adjustment,
}

enum AssetScheduleStatus { pending, paid, overdue, waived }

enum RepaymentMethod { equalInstallment, equalPrincipal }

enum CreditCardStatementStatus { open, reconciled, paid }

enum BudgetPeriodKind { monthly, quarterly, yearly, custom }

enum BudgetRolloverMode { none, positive, all }

enum AutoCorrectionMatchMode { exact, contains }

class AutoCorrectionRule {
  const AutoCorrectionRule({
    required this.id,
    required this.ledgerId,
    required this.merchantPattern,
    required this.normalizedPattern,
    required this.type,
    required this.accountId,
    required this.categoryId,
    required this.updatedAt,
    this.matchMode = AutoCorrectionMatchMode.exact,
    this.tags = const [],
    this.enabled = true,
    this.learned = false,
    this.priority = 0,
    this.useCount = 0,
    this.lastUsedAt,
    this.sourceKey = '',
    this.minAmountMinor,
    this.maxAmountMinor,
    this.paymentMethodPattern = '',
    this.startMinute,
    this.endMinute,
    this.weekdaysMask = 127,
    this.sourceAccountId,
  });

  final String id;
  final String ledgerId;
  final String merchantPattern;
  final String normalizedPattern;
  final TransactionType type;
  final String? accountId;
  final String? categoryId;
  final AutoCorrectionMatchMode matchMode;
  final List<String> tags;
  final bool enabled;
  final bool learned;
  final int priority;
  final int useCount;
  final DateTime updatedAt;
  final DateTime? lastUsedAt;

  /// Empty matches every source. Other values use `channel:<name>` or
  /// `app:<package>` so rules remain stable when the display name changes.
  final String sourceKey;
  final int? minAmountMinor;
  final int? maxAmountMinor;
  final String paymentMethodPattern;
  final int? startMinute;
  final int? endMinute;

  /// Monday is bit 0 and Sunday is bit 6.
  final int weekdaysMask;
  final String? sourceAccountId;
}

enum RuleSuggestionStatus { pending, accepted, rejected }

class AutoCorrectionSuggestion {
  const AutoCorrectionSuggestion({
    required this.id,
    required this.ledgerId,
    required this.merchantPattern,
    required this.type,
    required this.createdAt,
    this.accountId,
    this.categoryId,
    this.tags = const [],
    this.sourceKey = '',
    this.paymentMethodPattern = '',
    this.status = RuleSuggestionStatus.pending,
    this.reason = '',
    this.sampleCount = 0,
    this.consistencyBps = 0,
    this.conflicts = const [],
  });
  final String id;
  final String ledgerId;
  final String merchantPattern;
  final TransactionType type;
  final String? accountId;
  final String? categoryId;
  final List<String> tags;
  final String sourceKey;
  final String paymentMethodPattern;
  final RuleSuggestionStatus status;
  final String reason;
  final int sampleCount;
  final int consistencyBps;
  final List<Map<String, Object?>> conflicts;
  final DateTime createdAt;
}

class MerchantKnowledge {
  const MerchantKnowledge({
    required this.id,
    required this.ledgerId,
    required this.canonicalName,
    required this.aliases,
    this.defaultCategoryId,
    this.sourceKey = '',
    this.enabled = true,
  });
  final String id;
  final String ledgerId;
  final String canonicalName;
  final List<String> aliases;
  final String? defaultCategoryId;
  final String sourceKey;
  final bool enabled;
}

class AutoCorrectionEvent {
  const AutoCorrectionEvent({
    required this.id,
    required this.eventType,
    required this.merchant,
    required this.sourceLedgerId,
    required this.targetLedgerId,
    required this.createdAt,
    this.ruleId,
    this.transactionId,
    this.amountMinor,
    this.sourceKey = '',
    this.paymentMethod = '',
    this.undoneAt,
  });
  final String id;
  final String? ruleId;
  final String eventType;
  final String? transactionId;
  final String merchant;
  final int? amountMinor;
  final String sourceLedgerId;
  final String targetLedgerId;
  final String sourceKey;
  final String paymentMethod;
  final DateTime createdAt;
  final DateTime? undoneAt;
}

class AutoCorrectionBatchPreview {
  const AutoCorrectionBatchPreview({
    required this.matched,
    required this.eligible,
    required this.skipped,
  });
  final int matched;
  final int eligible;
  final int skipped;
}

extension AccountKindInfo on AccountKind {
  bool get isDebt =>
      this == AccountKind.credit ||
      this == AccountKind.creditPayment ||
      this == AccountKind.loan;
}

class Account {
  const Account({
    required this.id,
    required this.name,
    required this.kind,
    required this.openingMinor,
    required this.balanceMinor,
    this.currency = 'CNY',
    this.currencySymbol = '¥',
    this.currencyDecimals = 2,
    this.rateToCnyMicros = 1000000,
    this.providerId,
    this.repaymentDay,
    this.dueDate,
    this.bankId,
    this.cardLast4,
    this.cardSecretId,
    this.archived = false,
  });
  final String id;
  final String name;
  final AccountKind kind;
  final int openingMinor;
  final int balanceMinor;
  final String currency;
  final String currencySymbol;
  final int currencyDecimals;
  final int rateToCnyMicros;
  final String? providerId;
  final int? repaymentDay;
  final DateTime? dueDate;
  final String? bankId;
  final String? cardLast4;
  final String? cardSecretId;
  final bool archived;
  String get displayName => cardLast4 == null || name.endsWith(' $cardLast4')
      ? name
      : '$name · 尾号 $cardLast4';

  DateTime? nextRepayment(DateTime now) {
    if (dueDate != null) return dueDate;
    if (repaymentDay == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    DateTime inMonth(int month) {
      final last = DateTime(now.year, month + 1, 0).day;
      return DateTime(
        now.year,
        month,
        repaymentDay! > last ? last : repaymentDay!,
      );
    }

    final current = inMonth(now.month);
    return current.isBefore(today) ? inMonth(now.month + 1) : current;
  }
}

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.type,
    this.parentId,
    this.archived = false,
    this.iconKey = '',
  });
  final String id;
  final String name;
  final TransactionType type;
  final String? parentId;
  final bool archived;
  final String iconKey;
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.amountMinor,
    required this.accountId,
    required this.accountName,
    required this.occurredDate,
    required this.createdAt,
    required this.version,
    this.targetAccountId,
    this.categoryId,
    this.categoryName,
    this.merchant = '',
    this.note = '',
    this.relatedTransactionId,
    this.reimbursable = false,
    this.isReimbursement = false,
    this.reimbursedMinor = 0,
    this.refundedMinor = 0,
    this.attachmentCount = 0,
    this.deleted = false,
    this.deletedAt,
    this.excludeFromReports = false,
    this.tags = const [],
    this.currency = 'CNY',
    this.originalAmountMinor,
    this.discountMinor,
    this.exchangeRateMicros = 1000000,
    this.targetCurrency,
    this.targetAmountMinor,
    this.currencySymbol = '¥',
    this.currencyDecimals = 2,
  });
  final String id;
  final TransactionType type;
  final int amountMinor;
  final String accountId;
  final String accountName;
  final String? targetAccountId;
  final String? categoryId;
  final String? categoryName;
  final DateTime occurredDate;
  final DateTime createdAt;
  final int version;
  final String merchant;
  final String note;
  final String? relatedTransactionId;
  final bool reimbursable;
  final bool isReimbursement;
  final int reimbursedMinor, refundedMinor, attachmentCount;
  int get reimbursementRemaining =>
      (amountMinor - refundedMinor - reimbursedMinor).clamp(0, amountMinor);
  String get reimbursementStatus => !reimbursable
      ? ''
      : reimbursementRemaining == 0
      ? (reimbursedMinor > 0 ? '已报销' : '已结清')
      : reimbursedMinor == 0
      ? '待报销'
      : '部分报销';
  final bool deleted;
  final DateTime? deletedAt;
  final bool excludeFromReports;
  final List<String> tags;
  final String currency;
  final int? originalAmountMinor;

  /// Coupon/立减 amount shown on the receipt. The paid [amountMinor] remains
  /// the amount used for balances, budgets and reports.
  final int? discountMinor;
  final int exchangeRateMicros;
  final String? targetCurrency;
  final int? targetAmountMinor;
  final String currencySymbol;
  final int currencyDecimals;

  int get displayAmountMinor => originalAmountMinor ?? amountMinor;
}

class TransactionInput {
  const TransactionInput({
    required this.type,
    required this.amountMinor,
    required this.accountId,
    required this.occurredDate,
    this.targetAccountId,
    this.categoryId,
    this.merchant = '',
    this.note = '',
    this.relatedTransactionId,
    this.reimbursable = false,
    this.isReimbursement = false,
    this.discountMinor,
    this.tags = const [],
  });
  final TransactionType type;
  final int amountMinor;
  final String accountId;
  final String? targetAccountId;
  final String? categoryId;
  final DateTime occurredDate;
  final String merchant;
  final String note;
  final String? relatedTransactionId;
  final bool reimbursable;
  final bool isReimbursement;
  final int? discountMinor;
  final List<String> tags;
}

class TransactionTemplate {
  const TransactionTemplate({
    required this.id,
    required this.name,
    required this.type,
    required this.amountMinor,
    this.accountId,
    this.targetAccountId,
    this.categoryId,
    this.merchant = '',
    this.note = '',
    this.tags = const [],
  });

  final String id;
  final String name;
  final TransactionType type;
  final int amountMinor;
  final String? accountId;
  final String? targetAccountId;
  final String? categoryId;
  final String merchant;
  final String note;
  final List<String> tags;
}

class RecurringRule {
  const RecurringRule({
    required this.id,
    required this.name,
    required this.kind,
    required this.type,
    required this.amountMinor,
    required this.accountId,
    required this.frequency,
    required this.interval,
    required this.nextAt,
    this.targetAccountId,
    this.categoryId,
    this.merchant = '',
    this.note = '',
    this.tags = const [],
    this.enabled = true,
    this.lastRunAt,
    this.endAt,
    this.maxRuns,
    this.runCount = 0,
    this.notifyEnabled = true,
    this.retryCount = 0,
    this.lastError = '',
  });

  final String id;
  final String name;
  final RecurringKind kind;
  final TransactionType type;
  final int amountMinor;
  final String accountId;
  final String? targetAccountId;
  final String? categoryId;
  final String merchant;
  final String note;
  final List<String> tags;
  final RecurrenceFrequency frequency;
  final int interval;
  final DateTime nextAt;
  final bool enabled;
  final DateTime? lastRunAt;
  final DateTime? endAt;
  final int? maxRuns;
  final int runCount;
  final bool notifyEnabled;
  final int retryCount;
  final String lastError;
}

class RecurringExecution {
  const RecurringExecution({
    required this.id,
    required this.ruleId,
    required this.scheduledAt,
    required this.status,
    required this.retryCount,
    required this.finishedAt,
    this.transactionId,
    this.errorMessage = '',
  });
  final String id;
  final String ruleId;
  final DateTime scheduledAt;
  final String status;
  final String? transactionId;
  final String errorMessage;
  final int retryCount;
  final DateTime finishedAt;
}

class RecurringProcessResult {
  const RecurringProcessResult({
    this.succeeded = 0,
    this.failed = 0,
    this.notifiableSucceeded = 0,
    this.notifiableFailed = 0,
  });
  final int succeeded;
  final int failed;
  final int notifiableSucceeded;
  final int notifiableFailed;
}

class TagDefinition {
  const TagDefinition({
    required this.id,
    required this.name,
    this.hidden = false,
    this.smartPattern = '',
    this.usageCount = 0,
  });
  final String id;
  final String name;
  final bool hidden;
  final String smartPattern;
  final int usageCount;
}

class MonthlySummary {
  const MonthlySummary({
    required this.expenseMinor,
    required this.incomeMinor,
    required this.budgetMinor,
    required this.categoryExpenses,
  });
  final int expenseMinor;
  final int incomeMinor;
  final int budgetMinor;
  final Map<String, int> categoryExpenses;
  int get remainingMinor => budgetMinor - expenseMinor;
  int get surplusMinor => incomeMinor - expenseMinor;
}

class BudgetPlan {
  const BudgetPlan({
    required this.id,
    required this.name,
    required this.amountMinor,
    required this.periodKind,
    required this.startsOn,
    required this.rolloverMode,
    required this.alertBps,
    this.categoryId,
    this.categoryName,
    this.customEndOn,
    this.alertEnabled = true,
    this.hidden = false,
    this.archived = false,
  });

  final String id;
  final String name;
  final String? categoryId;
  final String? categoryName;
  final int amountMinor;
  final BudgetPeriodKind periodKind;
  final DateTime startsOn;
  final DateTime? customEndOn;
  final BudgetRolloverMode rolloverMode;
  final bool alertEnabled;
  final int alertBps;
  final bool hidden;
  final bool archived;
}

class BudgetPeriodSummary {
  const BudgetPeriodSummary({
    required this.plan,
    required this.periodStart,
    required this.periodEnd,
    required this.carriedMinor,
    required this.spentMinor,
  });

  final BudgetPlan plan;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int carriedMinor;
  final int spentMinor;
  int get availableMinor => plan.amountMinor + carriedMinor;
  int get remainingMinor => availableMinor - spentMinor;
  bool get exceeded => remainingMinor < 0;
  bool get warning =>
      plan.alertEnabled &&
      availableMinor > 0 &&
      spentMinor * 10000 >= availableMinor * plan.alertBps;
  double get progress => availableMinor <= 0
      ? (spentMinor > 0 ? 1 : 0)
      : (spentMinor / availableMinor).clamp(0, 1).toDouble();
}

class BudgetDetailEntry {
  const BudgetDetailEntry({
    required this.transactionId,
    required this.occurredAt,
    required this.amountMinor,
    required this.type,
    required this.merchant,
    required this.categoryName,
  });

  final String transactionId;
  final DateTime occurredAt;
  final int amountMinor;
  final TransactionType type;
  final String merchant;
  final String categoryName;
  int get budgetDeltaMinor =>
      type == TransactionType.refund ? -amountMinor : amountMinor;
}

class CurrencyDefinition {
  const CurrencyDefinition({
    required this.code,
    required this.name,
    required this.symbol,
    required this.rateToCnyMicros,
    this.decimals = 2,
    this.updatedAt,
  });

  final String code;
  final String name;
  final String symbol;
  final int rateToCnyMicros;
  final int decimals;
  final DateTime? updatedAt;
}

class FinancialAsset {
  const FinancialAsset({
    required this.id,
    required this.kind,
    required this.name,
    required this.currency,
    required this.principalMinor,
    required this.currentMinor,
    this.accountId,
    this.quantityMicros = 0,
    this.interestBps = 0,
    this.startDate,
    this.maturityDate,
    this.totalPeriods = 0,
    this.completedPeriods = 0,
    this.billingDay,
    this.repaymentDay,
    this.counterparty = '',
    this.note = '',
    this.archived = false,
  });

  final String id;
  final FinancialAssetKind kind;
  final String name;
  final String currency;
  final int principalMinor;
  final int currentMinor;
  final String? accountId;
  final int quantityMicros;
  final int interestBps;
  final DateTime? startDate;
  final DateTime? maturityDate;
  final int totalPeriods;
  final int completedPeriods;
  final int? billingDay;
  final int? repaymentDay;
  final String counterparty;
  final String note;
  final bool archived;
}

class AssetTransaction {
  const AssetTransaction({
    required this.id,
    required this.assetId,
    required this.kind,
    required this.occurredAt,
    required this.amountMinor,
    this.quantityMicros = 0,
    this.unitPriceMicros = 0,
    this.costBasisMinor = 0,
    this.principalMinor = 0,
    this.interestMinor = 0,
    this.feeMinor = 0,
    this.accountId,
    this.transactionId,
    this.note = '',
  });

  final String id;
  final String assetId;
  final AssetTransactionKind kind;
  final DateTime occurredAt;
  final int amountMinor;
  final int quantityMicros;
  final int unitPriceMicros;
  final int costBasisMinor;
  final int principalMinor;
  final int interestMinor;
  final int feeMinor;
  final String? accountId;
  final String? transactionId;
  final String note;
}

class AssetValuation {
  const AssetValuation({
    required this.id,
    required this.assetId,
    required this.valuedAt,
    required this.totalValueMinor,
    this.unitValueMicros = 0,
    this.source = 'manual',
    this.note = '',
  });

  final String id;
  final String assetId;
  final DateTime valuedAt;
  final int unitValueMicros;
  final int totalValueMinor;
  final String source;
  final String note;
}

class AssetScheduleItem {
  const AssetScheduleItem({
    required this.id,
    required this.assetId,
    required this.periodNo,
    required this.dueAt,
    required this.principalMinor,
    required this.interestMinor,
    this.feeMinor = 0,
    this.status = AssetScheduleStatus.pending,
    this.paidAt,
    this.transactionId,
    this.note = '',
  });

  final String id;
  final String assetId;
  final int periodNo;
  final DateTime dueAt;
  final int principalMinor;
  final int interestMinor;
  final int feeMinor;
  final AssetScheduleStatus status;
  final DateTime? paidAt;
  final String? transactionId;
  final String note;
  int get totalMinor => principalMinor + interestMinor + feeMinor;
}

class CreditCardStatement {
  const CreditCardStatement({
    required this.id,
    required this.assetId,
    required this.periodStart,
    required this.periodEnd,
    required this.dueAt,
    required this.statementMinor,
    required this.ledgerMinor,
    required this.paidMinor,
    required this.status,
    this.note = '',
    this.itemCount = 0,
    this.checkedCount = 0,
  });

  final String id;
  final String assetId;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime dueAt;
  final int statementMinor;
  final int ledgerMinor;
  final int paidMinor;
  final CreditCardStatementStatus status;
  final String note;
  final int itemCount;
  final int checkedCount;
  int get differenceMinor => statementMinor - ledgerMinor;
}

class CreditCardStatementLine {
  const CreditCardStatementLine({
    required this.transactionId,
    required this.occurredAt,
    required this.amountMinor,
    required this.merchant,
    required this.type,
    required this.checked,
  });

  final String transactionId;
  final DateTime occurredAt;
  final int amountMinor;
  final String merchant;
  final TransactionType type;
  final bool checked;
}

class FinancialAssetSummary {
  const FinancialAssetSummary({
    required this.asset,
    required this.realizedMinor,
    required this.incomeMinor,
    required this.unrealizedMinor,
    required this.totalReturnMinor,
    required this.returnBps,
    required this.activityCount,
    this.nextDue,
  });

  final FinancialAsset asset;
  final int realizedMinor;
  final int incomeMinor;
  final int unrealizedMinor;
  final int totalReturnMinor;
  final int returnBps;
  final int activityCount;
  final AssetScheduleItem? nextDue;
}

class TransactionSplit {
  const TransactionSplit({
    required this.id,
    required this.participant,
    required this.amountMinor,
    this.settled = false,
    this.note = '',
  });

  final String id;
  final String participant;
  final int amountMinor;
  final bool settled;
  final String note;
}

class TransactionGroup {
  const TransactionGroup({
    required this.id,
    required this.name,
    this.note = '',
    this.transactionCount = 0,
    this.totalMinor = 0,
  });

  final String id;
  final String name;
  final String note;
  final int transactionCount;
  final int totalMinor;
}

class LedgerException implements Exception {
  const LedgerException(this.message);
  final String message;
  @override
  String toString() => message;
}
