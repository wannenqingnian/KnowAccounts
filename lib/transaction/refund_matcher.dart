import '../data/ledger_repository.dart';
import '../domain/models.dart';
import '../automation/payment_apps.dart';
import 'parser/transaction_parser.dart';

/// Keeps refunds distinct from income and links them to one original expense.
/// Matching is intentionally conservative: ties remain for human review.
class RefundMatcher {
  const RefundMatcher._();

  static List<LedgerEntry> candidates(
    TransactionDraft draft,
    List<LedgerEntry> entries,
  ) {
    if (draft.type != TransactionType.refund || draft.amountMinor == null) {
      return const [];
    }
    final amount = draft.amountMinor!;
    final candidates = entries.where((entry) {
      if (entry.type != TransactionType.expense || entry.deleted) return false;
      if (entry.reimbursementRemaining < amount) return false;
      if (entry.occurredDate.isAfter(draft.occurredDate)) return false;
      if (draft.accountId != null && entry.accountId != draft.accountId) {
        return false;
      }
      return true;
    }).toList();
    candidates.sort((left, right) {
      final score = _score(draft, right).compareTo(_score(draft, left));
      if (score != 0) return score;
      return right.occurredDate.compareTo(left.occurredDate);
    });
    return candidates;
  }

  static Future<TransactionDraft> resolve(
    LedgerRepository repository,
    TransactionDraft draft,
  ) async {
    final gross = int.tryParse(draft.evidence['original_amount_minor'] ?? '');
    final refund = int.tryParse(draft.evidence['refund_amount_minor'] ?? '');
    if (gross != null && gross > 0 && refund != null && refund > 0) {
      final refundDraft = _partialAsRefund(draft, refund);
      final matches = candidates(
        refundDraft,
        await repository.entries(draft.ledgerId),
      ).where((entry) => entry.amountMinor == gross).toList();
      if (matches.isEmpty) return draft;
      final best = _score(refundDraft, matches.first);
      final tied =
          matches.length > 1 && _score(refundDraft, matches[1]) == best;
      if (best < 8 || tied) return draft;
      return link(
        refundDraft,
        matches.first.id,
        await repository.accounts(draft.ledgerId),
        await repository.categories(draft.ledgerId),
      );
    }
    if (draft.type != TransactionType.refund ||
        draft.relatedTransactionId != null) {
      return draft;
    }
    final matches = candidates(draft, await repository.entries(draft.ledgerId));
    if (matches.isEmpty) return draft;
    final best = _score(draft, matches.first);
    final tied = matches.length > 1 && _score(draft, matches[1]) == best;
    // An account/date match alone is intentionally insufficient for automatic
    // linking. Merchant similarity or an exact amount must also agree; all
    // other plausible expenses remain available for manual confirmation.
    if (best < 8 || tied) return draft;
    return link(
      draft,
      matches.first.id,
      await repository.accounts(draft.ledgerId),
      await repository.categories(draft.ledgerId),
    );
  }

  static TransactionDraft link(
    TransactionDraft draft,
    String originalId,
    List<Account> accounts,
    List<Category> categories,
  ) {
    final withoutOldMarker = draft.raw.text.replaceAll(
      RegExp(r'\n?原交易编号\s*[:：]?\s*[a-f0-9-]{36}', caseSensitive: false),
      '',
    );
    final raw = RawTransaction(
      text: '$withoutOldMarker\n原交易编号 $originalId',
      capturedAt: draft.raw.capturedAt,
      source: draft.raw.source,
      sourceApp: draft.raw.sourceApp,
      paymentMethod: draft.raw.paymentMethod,
    );
    final linked = TransactionParser().parse(
      raw,
      ledgerId: draft.ledgerId,
      accounts: accounts,
      categories: categories,
    );
    final sourceApp =
        linked.raw.sourceApp.isNotEmpty ? linked.raw.sourceApp : draft.raw.sourceApp;
    final sourceAppName =
        sourceApp.isNotEmpty ? paymentCaptureSourceName(sourceApp) : '';
    final amount = linked.amountMinor ?? draft.amountMinor;
    final amountText = amount != null
        ? '${amount ~/ 100}.${(amount % 100).toString().padLeft(2, '0')}元'
        : '';
    final refundNote = amountText.isNotEmpty
        ? '${sourceAppName.isNotEmpty ? "$sourceAppName · " : ""}有退款 退款金额: $amountText'
        : '${sourceAppName.isNotEmpty ? "$sourceAppName · " : ""}有退款';
    final existingNote = linked.note.isNotEmpty ? linked.note : draft.note;
    final finalNote = existingNote.isEmpty
        ? refundNote
        : (existingNote.contains(refundNote)
              ? existingNote
              : '$existingNote | $refundNote');

    return TransactionDraft(
      raw: linked.raw,
      ledgerId: linked.ledgerId,
      type: linked.type,
      amountMinor: linked.amountMinor,
      occurredDate: linked.occurredDate,
      accountId: linked.accountId,
      categoryId: linked.categoryId,
      relatedTransactionId: linked.relatedTransactionId ?? originalId,
      merchant: linked.merchant,
      note: finalNote,
      tags: linked.tags,
      blocked: false,
      warnings: linked.warnings,
      evidence: linked.evidence,
      familyEventId: linked.familyEventId,
      familyRole: linked.familyRole,
      confidence: linked.confidence,
    );
  }

  static int _score(TransactionDraft draft, LedgerEntry entry) {
    var score = 0;
    if (draft.accountId != null && entry.accountId == draft.accountId) {
      score += 5;
    }
    final merchant = _compact(draft.merchant);
    final original = _compact(entry.merchant);
    if (merchant.isNotEmpty && original == merchant) {
      score += 6;
    } else if (merchant.isNotEmpty &&
        original.isNotEmpty &&
        (merchant.contains(original) || original.contains(merchant))) {
      score += 3;
    }
    if (draft.amountMinor != null && entry.amountMinor == draft.amountMinor) {
      score += 10;
    }
    final days = draft.occurredDate.difference(entry.occurredDate).inDays;
    if (days >= 0 && days <= 60) score += 3;
    return score;
  }

  static TransactionDraft _partialAsRefund(TransactionDraft draft, int refund) {
    final sourceAppName =
        draft.raw.sourceApp.isNotEmpty ? paymentCaptureSourceName(draft.raw.sourceApp) : '';
    final amountText =
        '${refund ~/ 100}.${(refund % 100).toString().padLeft(2, '0')}元';
    final refundNote = amountText.isNotEmpty
        ? '${sourceAppName.isNotEmpty ? "$sourceAppName · " : ""}有退款 退款金额: $amountText'
        : '${sourceAppName.isNotEmpty ? "$sourceAppName · " : ""}有退款';
    final existingNote = draft.note;
    final finalNote = existingNote.isEmpty
        ? refundNote
        : (existingNote.contains(refundNote)
              ? existingNote
              : '$existingNote | $refundNote');

    return TransactionDraft(
      raw: draft.raw,
      ledgerId: draft.ledgerId,
      type: TransactionType.refund,
      amountMinor: refund,
      occurredDate:
          DateTime.tryParse(draft.evidence['refund_date'] ?? '') ??
          draft.occurredDate,
      accountId: draft.accountId,
      categoryId: null,
      merchant: draft.merchant,
      note: finalNote,
      tags: draft.tags,
      blocked: true,
      evidence: {...draft.evidence, 'type': '部分退款'},
      warnings: const ['退款已识别，尚未唯一匹配原消费，请选择原交易'],
      familyEventId: draft.familyEventId,
      familyRole: draft.familyRole,
      confidence: draft.confidence,
    );
  }

  static String _compact(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^0-9a-z\u3400-\u9fff]'), '');
}
