import 'dart:math' as math;

import 'confidence_models.dart';

/// Thresholds produced by an offline replay of labelled, redacted samples.
class ConfidenceThresholds {
  const ConfidenceThresholds({
    this.autoPost = .90,
    this.criticalField = .85,
    this.manualField = .55,
  });

  final double autoPost;
  final double criticalField;
  final double manualField;

  bool get isValid =>
      autoPost >= .90 &&
      autoPost <= 1 &&
      criticalField >= .85 &&
      criticalField <= 1 &&
      manualField >= .55 &&
      criticalField >= manualField &&
      manualField < autoPost;

  Map<String, double> toJson() => {
    'auto_post': autoPost,
    'critical_field': criticalField,
    'manual_field': manualField,
  };

  factory ConfidenceThresholds.fromJson(Map<Object?, Object?> json) =>
      ConfidenceThresholds(
        autoPost: (json['auto_post'] as num?)?.toDouble() ?? .90,
        criticalField: (json['critical_field'] as num?)?.toDouble() ?? .85,
        manualField: (json['manual_field'] as num?)?.toDouble() ?? .55,
      );
}

/// A deployable calibration result. Counts are retained so the runtime can
/// verify the safety gate instead of trusting a claimed error percentage.
class ConfidenceCalibrationProfile {
  const ConfidenceCalibrationProfile({
    required this.version,
    required this.sourceKind,
    required this.modelVersion,
    required this.thresholds,
    required this.sampleCount,
    required this.autoPostCount,
    required this.falsePostCount,
    required this.createdAt,
  });

  static const minimumSamples = 200;
  static const minimumAutoPosts = 100;
  static const maximumFalsePostUpperBound = .01;

  final String version;
  final String sourceKind;
  final String modelVersion;
  final ConfidenceThresholds thresholds;
  final int sampleCount;
  final int autoPostCount;
  final int falsePostCount;
  final DateTime createdAt;

  double get falsePostRate =>
      autoPostCount == 0 ? 0 : falsePostCount / autoPostCount;

  double get falsePostUpperBound =>
      wilsonUpperBound(successes: falsePostCount, trials: autoPostCount);

  bool get passesSafetyGate =>
      version.trim().isNotEmpty &&
      sourceKind.trim().isNotEmpty &&
      thresholds.isValid &&
      sampleCount >= minimumSamples &&
      autoPostCount >= minimumAutoPosts &&
      falsePostCount >= 0 &&
      falsePostCount <= autoPostCount &&
      falsePostUpperBound <= maximumFalsePostUpperBound;

  bool matches({required String sourceKind, required String modelVersion}) =>
      this.sourceKind == sourceKind &&
      (this.modelVersion.isEmpty || this.modelVersion == modelVersion);

  Map<String, Object?> toJson() => {
    'version': version,
    'source_kind': sourceKind,
    'model_version': modelVersion,
    'thresholds': thresholds.toJson(),
    'sample_count': sampleCount,
    'auto_post_count': autoPostCount,
    'false_post_count': falsePostCount,
    'false_post_rate': double.parse(falsePostRate.toStringAsFixed(6)),
    'false_post_upper_bound': double.parse(
      falsePostUpperBound.toStringAsFixed(6),
    ),
    'created_at': createdAt.toUtc().toIso8601String(),
    'passes_safety_gate': passesSafetyGate,
  };

  factory ConfidenceCalibrationProfile.fromJson(Map<Object?, Object?> json) =>
      ConfidenceCalibrationProfile(
        version: json['version'] as String? ?? '',
        sourceKind: json['source_kind'] as String? ?? '',
        modelVersion: json['model_version'] as String? ?? '',
        thresholds: json['thresholds'] is Map
            ? ConfidenceThresholds.fromJson(
                (json['thresholds'] as Map).cast<Object?, Object?>(),
              )
            : const ConfidenceThresholds(),
        sampleCount: (json['sample_count'] as num?)?.toInt() ?? 0,
        autoPostCount: (json['auto_post_count'] as num?)?.toInt() ?? 0,
        falsePostCount: (json['false_post_count'] as num?)?.toInt() ?? 0,
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// A privacy-safe label: it contains the confidence snapshot and the human
/// verdict, but no amount, merchant, account, OCR text or notification body.
class LabeledConfidenceSample {
  const LabeledConfidenceSample({
    required this.sampleId,
    required this.sourceKind,
    required this.modelVersion,
    required this.confidence,
    required this.correct,
    required this.autoPostEligible,
  });

  final String sampleId;
  final String sourceKind;
  final String modelVersion;
  final TransactionConfidence confidence;
  final bool correct;
  final bool autoPostEligible;

  Map<String, Object?> toJson() => {
    'sample_id': sampleId,
    'source_kind': sourceKind,
    'model_version': modelVersion,
    'correct': correct,
    'auto_post_eligible': autoPostEligible,
    'confidence': confidence.toJson(),
  };

  factory LabeledConfidenceSample.fromJson(Map<Object?, Object?> json) =>
      LabeledConfidenceSample(
        sampleId: json['sample_id'] as String? ?? '',
        sourceKind: json['source_kind'] as String? ?? '',
        modelVersion: json['model_version'] as String? ?? '',
        correct: json['correct'] == true,
        autoPostEligible: json['auto_post_eligible'] == true,
        confidence: json['confidence'] is Map
            ? TransactionConfidence.fromJson(
                (json['confidence'] as Map).cast<Object?, Object?>(),
              )
            : const TransactionConfidence(
                engineVersion: 'missing',
                source: '',
                modelVersion: '',
                overall: 0,
                decision: ConfidenceDecision.manual,
                fields: {},
                reasons: ['样本缺少置信度快照'],
              ),
      );
}

class ConfidenceReplayMetrics {
  const ConfidenceReplayMetrics({
    required this.sampleCount,
    required this.autoPostCount,
    required this.correctAutoPostCount,
    required this.falsePostCount,
    required this.heldCorrectCount,
    required this.heldIncorrectCount,
  });

  final int sampleCount;
  final int autoPostCount;
  final int correctAutoPostCount;
  final int falsePostCount;
  final int heldCorrectCount;
  final int heldIncorrectCount;

  double get falsePostRate =>
      autoPostCount == 0 ? 0 : falsePostCount / autoPostCount;
  double get falsePostUpperBound =>
      wilsonUpperBound(successes: falsePostCount, trials: autoPostCount);
  double get reviewRate =>
      sampleCount == 0 ? 0 : (sampleCount - autoPostCount) / sampleCount;

  Map<String, Object?> toJson() => {
    'sample_count': sampleCount,
    'auto_post_count': autoPostCount,
    'correct_auto_post_count': correctAutoPostCount,
    'false_post_count': falsePostCount,
    'held_correct_count': heldCorrectCount,
    'held_incorrect_count': heldIncorrectCount,
    'false_post_rate': double.parse(falsePostRate.toStringAsFixed(6)),
    'false_post_upper_bound': double.parse(
      falsePostUpperBound.toStringAsFixed(6),
    ),
    'review_rate': double.parse(reviewRate.toStringAsFixed(6)),
  };
}

class ConfidenceCalibration {
  const ConfidenceCalibration();

  ConfidenceReplayMetrics replay(
    Iterable<LabeledConfidenceSample> samples, {
    required String sourceKind,
    required String modelVersion,
    required ConfidenceThresholds thresholds,
  }) {
    final selected = samples
        .where(
          (sample) =>
              sample.sourceKind == sourceKind &&
              (modelVersion.isEmpty || sample.modelVersion == modelVersion),
        )
        .toList(growable: false);
    var auto = 0;
    var correctAuto = 0;
    var falsePost = 0;
    var heldCorrect = 0;
    var heldIncorrect = 0;
    for (final sample in selected) {
      final fields = sample.confidence.fields.values;
      final predictsAuto =
          sample.autoPostEligible &&
          sample.confidence.overall >= thresholds.autoPost &&
          fields.isNotEmpty &&
          fields.every((field) => field.score >= thresholds.criticalField);
      if (predictsAuto) {
        auto++;
        if (sample.correct) {
          correctAuto++;
        } else {
          falsePost++;
        }
      } else if (sample.correct) {
        heldCorrect++;
      } else {
        heldIncorrect++;
      }
    }
    return ConfidenceReplayMetrics(
      sampleCount: selected.length,
      autoPostCount: auto,
      correctAutoPostCount: correctAuto,
      falsePostCount: falsePost,
      heldCorrectCount: heldCorrect,
      heldIncorrectCount: heldIncorrect,
    );
  }

  /// Chooses the least restrictive threshold that passes the conservative
  /// false-post gate. Returning null is a valid result and means more labelled
  /// samples are required; the runtime must keep using the uncalibrated policy.
  ConfidenceCalibrationProfile? recommend(
    Iterable<LabeledConfidenceSample> samples, {
    required String version,
    required String sourceKind,
    required String modelVersion,
    required DateTime createdAt,
  }) {
    for (var percent = 90; percent <= 99; percent++) {
      final thresholds = ConfidenceThresholds(autoPost: percent / 100);
      final metrics = replay(
        samples,
        sourceKind: sourceKind,
        modelVersion: modelVersion,
        thresholds: thresholds,
      );
      final profile = ConfidenceCalibrationProfile(
        version: version,
        sourceKind: sourceKind,
        modelVersion: modelVersion,
        thresholds: thresholds,
        sampleCount: metrics.sampleCount,
        autoPostCount: metrics.autoPostCount,
        falsePostCount: metrics.falsePostCount,
        createdAt: createdAt.toUtc(),
      );
      if (profile.passesSafetyGate) return profile;
    }
    return null;
  }
}

double wilsonUpperBound({required int successes, required int trials}) {
  if (trials <= 0 || successes < 0 || successes > trials) return 1;
  const z = 1.959963984540054;
  final rate = successes / trials;
  final denominator = 1 + (z * z / trials);
  final centre = rate + (z * z / (2 * trials));
  final margin =
      z *
      math.sqrt((rate * (1 - rate) / trials) + (z * z / (4 * trials * trials)));
  return ((centre + margin) / denominator).clamp(0, 1).toDouble();
}
