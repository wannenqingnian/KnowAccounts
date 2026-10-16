class PendingDraftBatchPatch {
  const PendingDraftBatchPatch({
    this.targetLedgerId,
    this.accountId,
    this.categoryId,
    this.tags,
  });

  final String? targetLedgerId;
  final String? accountId;
  final String? categoryId;
  final List<String>? tags;

  bool get isEmpty =>
      targetLedgerId == null &&
      accountId == null &&
      categoryId == null &&
      tags == null;
}

class PendingDraftBatchItemPreview {
  const PendingDraftBatchItemPreview({
    required this.draftId,
    required this.title,
    required this.changes,
    this.skipReason,
  });

  final String draftId;
  final String title;
  final List<String> changes;
  final String? skipReason;

  bool get eligible => skipReason == null && changes.isNotEmpty;
}

class PendingDraftBatchPreview {
  const PendingDraftBatchPreview(this.items);

  final List<PendingDraftBatchItemPreview> items;

  int get requested => items.length;
  int get eligible => items.where((item) => item.eligible).length;
  int get skipped => requested - eligible;
}

class PendingDuplicateGroup {
  const PendingDuplicateGroup({
    required this.key,
    required this.draftIds,
    required this.matchedByOrder,
    required this.existingTransactionCount,
  });

  final String key;
  final List<String> draftIds;
  final bool matchedByOrder;
  final int existingTransactionCount;
}
