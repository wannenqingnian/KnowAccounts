import '../domain/family_payment.dart';

/// A reporting-only view of family-card events.
///
/// Payer totals describe real money paid from this ledger. Beneficiary totals
/// describe sponsored consumption and must never be added to ordinary expense
/// totals or account balances.
class FamilyPaymentAnalysis {
  FamilyPaymentAnalysis(
    Iterable<FamilyPaymentEvent> events,
    Iterable<FamilyCardAccountSummary> cards,
    this.start,
    this.end,
  ) {
    final names = {
      for (final summary in cards) summary.card.id: summary.card.displayName,
    };
    for (final event in events) {
      final occurredAt = event.occurredAt ?? event.createdAt;
      if (occurredAt.isBefore(start) || !occurredAt.isBefore(end)) continue;
      if (event.status == FamilyPaymentStatus.observed ||
          event.status == FamilyPaymentStatus.needsReview) {
        pendingCount++;
        pendingMinor += event.netAmountMinor;
        continue;
      }
      if (event.status == FamilyPaymentStatus.voided) continue;
      final role = event.localRole;
      if (role == null) {
        pendingCount++;
        pendingMinor += event.netAmountMinor;
        continue;
      }
      final platform = event.platform.label;
      final card = event.cardId == null
          ? '未分配${event.platform.label}'
          : (names[event.cardId] ?? '已归档亲情卡');
      if (role == FamilyLocalRole.payer) {
        payerGrossMinor += event.amountMinor;
        payerRefundMinor += event.refundedMinor;
        payerCount++;
        payerByPlatform[platform] =
            (payerByPlatform[platform] ?? 0) + event.netAmountMinor;
        payerByCard[card] = (payerByCard[card] ?? 0) + event.netAmountMinor;
      } else {
        beneficiaryGrossMinor += event.amountMinor;
        beneficiaryRefundMinor += event.refundedMinor;
        beneficiaryCount++;
        beneficiaryByPlatform[platform] =
            (beneficiaryByPlatform[platform] ?? 0) + event.netAmountMinor;
        beneficiaryByCard[card] =
            (beneficiaryByCard[card] ?? 0) + event.netAmountMinor;
      }
    }
  }

  final DateTime start;
  final DateTime end;
  int payerGrossMinor = 0;
  int payerRefundMinor = 0;
  int payerCount = 0;
  int beneficiaryGrossMinor = 0;
  int beneficiaryRefundMinor = 0;
  int beneficiaryCount = 0;
  int pendingMinor = 0;
  int pendingCount = 0;
  final Map<String, int> payerByPlatform = {};
  final Map<String, int> beneficiaryByPlatform = {};
  final Map<String, int> payerByCard = {};
  final Map<String, int> beneficiaryByCard = {};

  int get payerNetMinor => payerGrossMinor - payerRefundMinor;
  int get beneficiaryNetMinor => beneficiaryGrossMinor - beneficiaryRefundMinor;
  bool get isEmpty =>
      payerCount == 0 && beneficiaryCount == 0 && pendingCount == 0;
}
