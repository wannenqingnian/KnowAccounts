enum ConfidenceDecision { autoPost, review, manual }

extension ConfidenceDecisionInfo on ConfidenceDecision {
  String get label => switch (this) {
    ConfidenceDecision.autoPost => '高置信，可自动入账',
    ConfidenceDecision.review => '中置信，需要核对',
    ConfidenceDecision.manual => '低置信，仅允许人工填写',
  };
}

class FieldConfidence {
  const FieldConfidence({required this.score, required this.reasons});

  final double score;
  final List<String> reasons;

  int get percent => (score.clamp(0, 1) * 100).round();

  Map<String, Object?> toJson() => {
    'score': double.parse(score.clamp(0, 1).toStringAsFixed(4)),
    'reasons': reasons,
  };

  factory FieldConfidence.fromJson(Map<Object?, Object?> json) =>
      FieldConfidence(
        score: ((json['score'] as num?)?.toDouble() ?? 0)
            .clamp(0, 1)
            .toDouble(),
        reasons: (json['reasons'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

/// A deterministic, versioned confidence snapshot.
///
/// Version 1 is deliberately marked as uncalibrated: scores order certainty
/// and drive a fail-closed policy, but are not statistical correctness
/// probabilities until real labelled receipts have been evaluated.
class TransactionConfidence {
  const TransactionConfidence({
    required this.engineVersion,
    required this.source,
    required this.modelVersion,
    required this.overall,
    required this.decision,
    required this.fields,
    required this.reasons,
    this.calibrated = false,
    this.calibrationVersion = '',
    this.thresholds = const {},
  });

  final String engineVersion;
  final String source;
  final String modelVersion;
  final double overall;
  final ConfidenceDecision decision;
  final Map<String, FieldConfidence> fields;
  final List<String> reasons;
  final bool calibrated;
  final String calibrationVersion;
  final Map<String, double> thresholds;

  int get percent => (overall.clamp(0, 1) * 100).round();
  bool get allowsAutoPost => decision == ConfidenceDecision.autoPost;

  Map<String, Object?> toJson() => {
    'engine_version': engineVersion,
    'source': source,
    'model_version': modelVersion,
    'overall': double.parse(overall.clamp(0, 1).toStringAsFixed(4)),
    'decision': decision.name,
    'calibrated': calibrated,
    if (calibrationVersion.isNotEmpty)
      'calibration_version': calibrationVersion,
    if (thresholds.isNotEmpty) 'thresholds': thresholds,
    'fields': fields.map((key, value) => MapEntry(key, value.toJson())),
    'reasons': reasons,
  };

  factory TransactionConfidence.fromJson(Map<Object?, Object?> json) {
    final rawFields = json['fields'];
    return TransactionConfidence(
      engineVersion: json['engine_version'] as String? ?? 'unknown',
      source: json['source'] as String? ?? '',
      modelVersion: json['model_version'] as String? ?? '',
      overall: ((json['overall'] as num?)?.toDouble() ?? 0)
          .clamp(0, 1)
          .toDouble(),
      decision:
          ConfidenceDecision.values
              .where((value) => value.name == json['decision'])
              .firstOrNull ??
          ConfidenceDecision.manual,
      calibrated: json['calibrated'] == true,
      calibrationVersion: json['calibration_version'] as String? ?? '',
      thresholds: json['thresholds'] is Map
          ? (json['thresholds'] as Map).map(
              (key, value) =>
                  MapEntry(key.toString(), value is num ? value.toDouble() : 0),
            )
          : const {},
      fields: rawFields is Map
          ? rawFields.map(
              (key, value) => MapEntry(
                key.toString(),
                value is Map
                    ? FieldConfidence.fromJson(value.cast<Object?, Object?>())
                    : const FieldConfidence(score: 0, reasons: ['字段评分损坏']),
              ),
            )
          : const {},
      reasons: (json['reasons'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
