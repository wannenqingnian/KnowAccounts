import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/confidence/confidence_calibration.dart';
import 'package:smart_ledger/transaction/confidence/confidence_engine.dart';
import 'package:smart_ledger/transaction/confidence/confidence_models.dart';
import 'package:smart_ledger/transaction/confidence/confidence_profile_bundle.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  const fields = <String, FieldConfidence>{
    'amount': FieldConfidence(score: .98, reasons: ['test']),
    'merchant': FieldConfidence(score: .96, reasons: ['test']),
    'account': FieldConfidence(score: .97, reasons: ['test']),
    'time': FieldConfidence(score: .96, reasons: ['test']),
    'completion': FieldConfidence(score: .99, reasons: ['test']),
    'category': FieldConfidence(score: .94, reasons: ['test']),
    'direction': FieldConfidence(score: .94, reasons: ['test']),
    'source': FieldConfidence(score: .94, reasons: ['test']),
  };

  TransactionConfidence report({double overall = .96}) => TransactionConfidence(
    engineVersion: 'confidence-rule-v2',
    source: 'notification/notification',
    modelVersion: 'source-profile-v1',
    overall: overall,
    decision: ConfidenceDecision.autoPost,
    fields: fields,
    reasons: const ['test'],
  );

  LabeledConfidenceSample sample(int index, {bool correct = true}) =>
      LabeledConfidenceSample(
        sampleId: 'sample-$index',
        sourceKind: 'notification',
        modelVersion: 'source-profile-v1',
        confidence: report(),
        correct: correct,
        autoPostEligible: true,
      );

  test('replay is deterministic and exposes conservative false-post bound', () {
    final samples = [for (var index = 0; index < 500; index++) sample(index)];
    final first = const ConfidenceCalibration().replay(
      samples,
      sourceKind: 'notification',
      modelVersion: 'source-profile-v1',
      thresholds: const ConfidenceThresholds(),
    );
    final second = const ConfidenceCalibration().replay(
      samples,
      sourceKind: 'notification',
      modelVersion: 'source-profile-v1',
      thresholds: const ConfidenceThresholds(),
    );

    expect(first.toJson(), second.toJson());
    expect(first.autoPostCount, 500);
    expect(first.falsePostCount, 0);
    expect(first.falsePostUpperBound, lessThan(.01));
  });

  test('small sample set cannot create deployable calibration', () {
    final profile = const ConfidenceCalibration().recommend(
      [for (var index = 0; index < 50; index++) sample(index)],
      version: 'notification-2026-10',
      sourceKind: 'notification',
      modelVersion: 'source-profile-v1',
      createdAt: DateTime.utc(2026, 10, 14),
    );
    expect(profile, isNull);
  });

  test('runtime only applies a matching profile that passes safety gate', () {
    final profile = ConfidenceCalibrationProfile(
      version: 'notification-2026-10',
      sourceKind: 'notification',
      modelVersion: 'source-profile-v1',
      thresholds: const ConfidenceThresholds(autoPost: .95),
      sampleCount: 500,
      autoPostCount: 500,
      falsePostCount: 0,
      createdAt: DateTime.utc(2026, 10, 14),
    );
    final draft = TransactionDraft(
      raw: RawTransaction(
        text: 'redacted',
        source: TransactionSource.notification,
        capturedAt: DateTime.utc(2026, 10, 14, 12),
      ),
      ledgerId: 'personal',
      type: TransactionType.expense,
      amountMinor: 100,
      occurredDate: DateTime.utc(2026, 10, 14, 11, 59),
      accountId: 'account',
      categoryId: 'category',
      merchant: 'merchant',
      warnings: const [],
      evidence: const {
        'amount': 'present',
        'merchant': 'present',
        'account': 'present',
        'category': 'present',
        'date': 'present',
      },
    );
    final calibrated = const ConfidenceEngine().evaluate(
      draft,
      context: ConfidenceContext(
        sourceKind: 'notification',
        modelVersion: 'source-profile-v1',
        completed: true,
        calibrationProfile: profile,
      ),
    );
    final mismatched = const ConfidenceEngine().evaluate(
      draft,
      context: ConfidenceContext(
        sourceKind: 'accessibility',
        modelVersion: 'source-profile-v1',
        completed: true,
        calibrationProfile: profile,
      ),
    );

    expect(calibrated.calibrated, isTrue);
    expect(calibrated.calibrationVersion, profile.version);
    expect(calibrated.thresholds['auto_post'], .95);
    expect(calibrated.reasons, contains(contains('脱敏样本校准')));
    expect(mismatched.calibrated, isFalse);
    expect(mismatched.calibrationVersion, isEmpty);
    expect(mismatched.reasons, contains(contains('已忽略')));
  });

  test('profile cannot lower fail-closed baseline thresholds', () {
    const thresholds = ConfidenceThresholds(
      autoPost: .80,
      criticalField: .70,
      manualField: .30,
    );
    expect(thresholds.isValid, isFalse);
  });

  test(
    'bundle accepts one safe profile and rejects duplicate or unsafe data',
    () {
      final safe = ConfidenceCalibrationProfile(
        version: 'notification-2026-10',
        sourceKind: 'notification',
        modelVersion: 'source-profile-v1',
        thresholds: const ConfidenceThresholds(),
        sampleCount: 500,
        autoPostCount: 500,
        falsePostCount: 0,
        createdAt: DateTime.utc(2026, 10, 14),
      ).toJson();
      final unsafe = ConfidenceCalibrationProfile(
        version: 'accessibility-unsafe',
        sourceKind: 'accessibility',
        modelVersion: 'source-profile-v1',
        thresholds: const ConfidenceThresholds(),
        sampleCount: 500,
        autoPostCount: 100,
        falsePostCount: 5,
        createdAt: DateTime.utc(2026, 10, 14),
      ).toJson();
      final parsed = ConfidenceProfileBundle.parse(
        jsonEncode({
          'profiles': [safe, safe, unsafe],
        }),
      );

      expect(parsed, hasLength(1));
      expect(parsed.single.version, 'notification-2026-10');
      expect(parsed.single.passesSafetyGate, isTrue);
    },
  );
}
