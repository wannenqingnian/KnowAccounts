import '../ocr/ocr_recognition.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/confidence/confidence_engine.dart';
import '../transaction/confidence/confidence_models.dart';

/// Fail closed: a missing field or an uncertain OCR result opens the editor.
TransactionConfidence ocrConfidence(
  TransactionDraft draft,
  OcrRecognition recognition,
) {
  final completed = RegExp(
    r'支付成功|付款成功|交易成功|消费成功|扣款成功|收款成功|到账成功',
  ).hasMatch(draft.raw.text);
  return const ConfidenceEngine().evaluate(
    draft,
    context: ConfidenceContext(
      sourceKind: 'screenshot',
      modelVersion: recognition.modelVersion.isEmpty
          ? 'PP-OCRv6/unknown-tier'
          : recognition.modelVersion,
      completed: completed,
      ocrRecognition: recognition,
    ),
  );
}

bool canAutoBookkeep(TransactionDraft draft, OcrRecognition recognition) {
  final report = ocrConfidence(draft, recognition);
  return report.decision == ConfidenceDecision.autoPost &&
      !draft.occurredDate.isAfter(
        DateTime(
          draft.raw.capturedAt.year,
          draft.raw.capturedAt.month,
          draft.raw.capturedAt.day,
          draft.raw.capturedAt.hour,
          draft.raw.capturedAt.minute,
          draft.raw.capturedAt.second,
        ),
      );
}
