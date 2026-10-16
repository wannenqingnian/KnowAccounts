enum FamilyCardPlatform { wechat, alipay }

enum FamilyLocalRole { payer, beneficiary }

enum FamilyPaymentStatus { observed, needsReview, confirmed, refunded, voided }

enum FamilyFundingState { unknown, inferred, confirmed }

extension FamilyCardPlatformInfo on FamilyCardPlatform {
  String get label => switch (this) {
    FamilyCardPlatform.wechat => '微信亲属卡',
    FamilyCardPlatform.alipay => '支付宝亲情卡',
  };

  String get packageName => switch (this) {
    FamilyCardPlatform.wechat => 'com.tencent.mm',
    FamilyCardPlatform.alipay => 'com.eg.android.AlipayGphone',
  };
}

extension FamilyLocalRoleInfo on FamilyLocalRole {
  String get label => switch (this) {
    FamilyLocalRole.payer => '发送方 / 代付方',
    FamilyLocalRole.beneficiary => '使用方 / 用款方',
  };
}

extension FamilyPaymentStatusInfo on FamilyPaymentStatus {
  String get label => switch (this) {
    FamilyPaymentStatus.observed => '已捕获',
    FamilyPaymentStatus.needsReview => '待审核',
    FamilyPaymentStatus.confirmed => '已确认',
    FamilyPaymentStatus.refunded => '已退款',
    FamilyPaymentStatus.voided => '已撤销',
  };
}

extension FamilyFundingStateInfo on FamilyFundingState {
  String get label => switch (this) {
    FamilyFundingState.unknown => '未确认',
    FamilyFundingState.inferred => '自动推断',
    FamilyFundingState.confirmed => '已确认',
  };
}

class FamilyCardAccount {
  const FamilyCardAccount({
    required this.id,
    required this.ledgerId,
    required this.platform,
    required this.displayName,
    required this.localRole,
    required this.senderLimitMinor,
    required this.userLimitMinor,
    required this.createdAt,
    required this.updatedAt,
    this.payerLabel = '',
    this.beneficiaryLabel = '',
    this.defaultFundingAccountId,
    this.defaultCategoryId,
    this.autoSaveEnabled = false,
    this.archivedAt,
  });

  final String id;
  final String ledgerId;
  final FamilyCardPlatform platform;
  final String displayName;
  final FamilyLocalRole localRole;
  final String payerLabel;
  final String beneficiaryLabel;

  /// Monthly limits are configuration values, never real account balances.
  final int senderLimitMinor;
  final int userLimitMinor;
  final String? defaultFundingAccountId;
  final String? defaultCategoryId;
  final bool autoSaveEnabled;
  final DateTime? archivedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  int get activeLimitMinor =>
      localRole == FamilyLocalRole.payer ? senderLimitMinor : userLimitMinor;
}

class FamilyCardAccountSummary {
  const FamilyCardAccountSummary({
    required this.card,
    required this.usedMinor,
    required this.pendingCount,
    this.unassignedUsedMinor = 0,
    this.unassignedPendingCount = 0,
  });

  final FamilyCardAccount card;
  final int usedMinor;
  final int pendingCount;
  final int unassignedUsedMinor;
  final int unassignedPendingCount;

  int get availableMinor =>
      (card.activeLimitMinor - usedMinor).clamp(0, card.activeLimitMinor);
}

class FamilyPaymentEvidence {
  const FamilyPaymentEvidence({
    required this.id,
    required this.eventId,
    required this.captureId,
    required this.sourceKind,
    required this.sourcePackage,
    required this.confidence,
    required this.observedAt,
    this.amountMinor,
    this.merchantHint = '',
    this.redactedExcerpt = '',
  });

  final String id;
  final String eventId;
  final String captureId;
  final String sourceKind;
  final String sourcePackage;
  final int? amountMinor;
  final String merchantHint;
  final int confidence;
  final DateTime observedAt;
  final String redactedExcerpt;

  String get confidenceLabel => confidence >= 80
      ? '高'
      : confidence >= 60
      ? '中'
      : '低';

  bool get hasConflict => redactedExcerpt.startsWith('冲突：');
}

class FamilyPaymentEvent {
  const FamilyPaymentEvent({
    required this.id,
    required this.ledgerId,
    required this.platform,
    required this.amountMinor,
    required this.fundingState,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.cardId,
    this.externalOrderHash,
    this.refundedMinor = 0,
    this.merchant = '',
    this.occurredAt,
    this.localRole,
    this.fundingAccountId,
    this.transactionId,
    this.evidence = const [],
  });

  final String id;
  final String ledgerId;
  final String? cardId;
  final FamilyCardPlatform platform;
  final String? externalOrderHash;
  final int amountMinor;
  final int refundedMinor;
  final String merchant;
  final DateTime? occurredAt;
  final FamilyLocalRole? localRole;
  final String? fundingAccountId;
  final FamilyFundingState fundingState;
  final FamilyPaymentStatus status;
  final String? transactionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<FamilyPaymentEvidence> evidence;

  int get netAmountMinor => (amountMinor - refundedMinor).clamp(0, amountMinor);

  bool get hasConflict => evidence.any((item) => item.hasConflict);

  List<String> get conflictMessages => [
    for (final item in evidence)
      if (item.hasConflict) item.redactedExcerpt,
  ];

  String? get candidateMergeEventId {
    for (final item in evidence) {
      if (item.redactedExcerpt.startsWith('候选合并：')) {
        final target = item.redactedExcerpt.substring('候选合并：'.length).trim();
        if (target.isNotEmpty) return target;
      }
    }
    return null;
  }

  int get confidence => evidence.isEmpty
      ? 0
      : evidence.map((e) => e.confidence).reduce((a, b) => a > b ? a : b);

  String get confidenceLabel => confidence >= 80
      ? '高'
      : confidence >= 60
      ? '中'
      : '低';
}

class FamilyPaymentDetection {
  const FamilyPaymentDetection({
    required this.platform,
    required this.marker,
    this.roleHint,
    this.cardHint,
  });

  final FamilyCardPlatform platform;
  final String marker;
  final FamilyLocalRole? roleHint;
  final String? cardHint;
}
