import 'dart:convert';

import 'package:flutter/services.dart';

import 'confidence_calibration.dart';

class ConfidenceProfileBundle {
  const ConfidenceProfileBundle._();

  static const assetPath = 'assets/confidence_profiles.json';

  /// Invalid, duplicated or statistically unsafe profiles are ignored. An
  /// empty result deliberately keeps the runtime on the fail-closed baseline.
  static List<ConfidenceCalibrationProfile> parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['profiles'] is! List) return const [];
    final result = <ConfidenceCalibrationProfile>[];
    final identities = <String>{};
    for (final item in decoded['profiles'] as List) {
      if (item is! Map) continue;
      final profile = ConfidenceCalibrationProfile.fromJson(
        item.cast<Object?, Object?>(),
      );
      final identity = '${profile.sourceKind}\u0000${profile.modelVersion}';
      if (profile.passesSafetyGate && identities.add(identity)) {
        result.add(profile);
      }
    }
    return List.unmodifiable(result);
  }

  static Future<List<ConfidenceCalibrationProfile>> loadBundled() async {
    try {
      return parse(await rootBundle.loadString(assetPath));
    } catch (_) {
      return const [];
    }
  }
}
