import '../domain/models.dart';
import 'confidence/confidence_models.dart';
import 'transaction_identity.dart';

/// Result returned by the common structured-transaction intake path.
///
/// Text based entrances create the same information through [TransactionDraft].
/// Manual entry and file import skip text parsing, but still receive a
/// confidence snapshot, duplicate assessment, source evidence and a learning
/// event before this result is returned.
class TransactionPipelineResult {
  const TransactionPipelineResult({
    required this.transactionId,
    required this.ledgerId,
    required this.input,
    required this.confidence,
    required this.duplicateAssessment,
  });

  final String transactionId;
  final String ledgerId;
  final TransactionInput input;
  final TransactionConfidence confidence;
  final TransactionDuplicateAssessment duplicateAssessment;
}

/// Raised before a structured transaction is posted. The caller must either
/// cancel, merge/review the candidate, or retry with explicit approval.
class PossibleDuplicateTransactionException extends LedgerException {
  PossibleDuplicateTransactionException(this.assessment)
    : super('疑似重复账单：${assessment.message}');

  final TransactionDuplicateAssessment assessment;
}
