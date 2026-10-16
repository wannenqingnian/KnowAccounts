import 'package:drift/drift.dart' show Variable;
import '../data/ledger_repository.dart';
import '../data/family_payment_repository.dart';
import '../domain/family_payment.dart';
import '../domain/models.dart';
import '../transaction/refund_matcher.dart';
import '../transaction/confidence/confidence_calibration.dart';
import '../transaction/transaction_identity.dart';
import 'payment_apps.dart';
import 'payment_capture_parser.dart';

class PaymentCaptureProcessor {
  const PaymentCaptureProcessor(
    this.repository, {
    this.calibrationProfiles = const [],
  });
  final LedgerRepository repository;
  final List<ConfidenceCalibrationProfile> calibrationProfiles;
  Future<String> process(PaymentCapture capture, {DateTime? now}) =>
      repository.db.transaction(() async {
        if (capture.packageName == manualOcrPackage &&
            capture.kind == 'screenshot' &&
            !PaymentCaptureParser.isLikelyBillScreenshot(capture.text)) {
          return 'discarded';
        }
        final stableId = 'auto-${capture.id}';
        final old = await repository.db
            .customSelect(
              "SELECT id FROM transaction_drafts WHERE id = ?",
              variables: [Variable<String>(stableId)],
            )
            .get();
        if (old.isNotEmpty) return 'repeated';
        if (!(await repository.ledgers()).containsKey(capture.ledgerId)) {
          return 'discarded';
        }
        final parsed = PaymentCaptureParser().parse(
          capture,
          await repository.accounts(capture.ledgerId),
          await repository.categories(capture.ledgerId),
          now: now,
          autoCorrections: await repository.autoCorrectionRules(
            capture.ledgerId,
            onlyApplicable: true,
            allLedgers: true,
          ),
          calibrationProfile: _profileFor(capture),
        );
        final corrected = await repository.applyAutoCorrectionRule(
          parsed.draft,
        );
        var resolved = await RefundMatcher.resolve(repository, corrected);
        if (resolved.confidence == null) {
          resolved = resolved.withConfidence(parsed.confidence);
        }
        if (parsed.familyPayment != null) {
          final familyRepo = FamilyPaymentRepository(repository.db);
          final eventId = await familyRepo.observeCapture(
            captureId: capture.id,
            ledgerId: capture.ledgerId,
            platform: parsed.familyPayment!.platform,
            sourceKind: capture.kind,
            sourcePackage: capture.packageName,
            amountMinor: resolved.amountMinor,
            merchant: resolved.merchant,
            occurredAt: resolved.occurredDate,
            rawText: capture.text,
          );
          if (eventId != null) {
            final ev = await familyRepo.event(capture.ledgerId, eventId);
            final role = ev?.localRole ?? parsed.familyPayment!.roleHint;
            resolved = resolved.withFamilyBinding(
              eventId: eventId,
              role: role,
              resolvedAccountId: ev?.fundingAccountId,
              clearAccountForBeneficiary: role == FamilyLocalRole.beneficiary,
            );
          }
        }
        final identitySource = switch (capture.kind) {
          'accessibility' => TransactionEvidenceSource.accessibility,
          'screenshot' || 'ocr' => TransactionEvidenceSource.ocr,
          _ => TransactionEvidenceSource.notification,
        };
        await repository.storeDraft(
          resolved,
          captureId: stableId,
          evidenceSource: identitySource,
          evidenceCaptureId: capture.id,
        );
        if (!parsed.canAutoSave ||
            parsed.familyPayment != null ||
            resolved.type == TransactionType.refund) {
          return 'pending';
        }
        try {
          final draft = resolved;
          final posted = await repository.autoConfirmDraft(
            resolved.ledgerId,
            stableId,
            TransactionInput(
              type: draft.type,
              amountMinor: draft.amountMinor!,
              accountId: draft.accountId!,
              categoryId: draft.categoryId,
              occurredDate: draft.occurredDate,
              merchant: draft.merchant,
              tags: draft.tags,
            ),
          );
          if (posted != null) return 'posted';
          await repository.storeDraft(
            draft.withWarnings([
              ...draft.warnings,
              '疑似重复账单：已有同日、同账户、同商户、同金额的收支，请核对或忽略。',
            ]),
            id: stableId,
            evidenceSource: identitySource,
            evidenceCaptureId: capture.id,
          );
        } on LedgerException {
          await repository.storeDraft(
            resolved.withWarnings([...resolved.warnings, '账户或分类已变化，请重新核对。']),
            id: stableId,
            evidenceSource: identitySource,
            evidenceCaptureId: capture.id,
          );
        }
        return 'pending';
      });

  ConfidenceCalibrationProfile? _profileFor(PaymentCapture capture) {
    final modelVersion = capture.kind == 'screenshot'
        ? 'PP-OCRv6/unknown-tier'
        : 'source-profile-v1';
    for (final profile in calibrationProfiles) {
      if (profile.passesSafetyGate &&
          profile.matches(
            sourceKind: capture.kind,
            modelVersion: modelVersion,
          )) {
        return profile;
      }
    }
    return null;
  }
}
