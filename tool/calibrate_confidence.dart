import 'dart:convert';
import 'dart:io';

import 'package:smart_ledger/transaction/confidence/confidence_calibration.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 4 || arguments.length > 5) {
    stderr.writeln(
      '用法: dart run tool/calibrate_confidence.dart '
      '<samples.jsonl> <sourceKind> <modelVersion> <profileVersion> [output.json]',
    );
    exitCode = 64;
    return;
  }
  final input = File(arguments[0]);
  if (!await input.exists()) {
    stderr.writeln('样本文件不存在：${input.path}');
    exitCode = 66;
    return;
  }
  final samples = <LabeledConfidenceSample>[];
  final ids = <String>{};
  var lineNumber = 0;
  await for (final line
      in input
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    lineNumber++;
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) throw const FormatException('每行必须是 JSON 对象');
      _rejectSensitiveKeys(decoded, lineNumber);
      final sample = LabeledConfidenceSample.fromJson(
        decoded.cast<Object?, Object?>(),
      );
      if (sample.sampleId.isEmpty || !ids.add(sample.sampleId)) {
        throw const FormatException('sample_id 为空或重复');
      }
      samples.add(sample);
    } on FormatException catch (error) {
      stderr.writeln('第 $lineNumber 行无效：${error.message}');
      exitCode = 65;
      return;
    }
  }

  final calibration = const ConfidenceCalibration();
  const baseline = ConfidenceThresholds();
  final metrics = calibration.replay(
    samples,
    sourceKind: arguments[1],
    modelVersion: arguments[2],
    thresholds: baseline,
  );
  final profile = calibration.recommend(
    samples,
    version: arguments[3],
    sourceKind: arguments[1],
    modelVersion: arguments[2],
    createdAt: DateTime.now().toUtc(),
  );
  final result = <String, Object?>{
    'baseline_thresholds': baseline.toJson(),
    'baseline_metrics': metrics.toJson(),
    'deployable': profile != null,
    if (profile != null) 'profile': profile.toJson(),
    if (profile == null) 'reason': '样本量、自动入账样本量或误记率95%上界未通过安全门槛',
  };
  final formatted = const JsonEncoder.withIndent('  ').convert(result);
  if (arguments.length == 5) {
    await File(arguments[4]).writeAsString('$formatted\n');
  } else {
    stdout.writeln(formatted);
  }
}

void _rejectSensitiveKeys(Map<Object?, Object?> json, int lineNumber) {
  const forbidden = {
    'text',
    'raw',
    'merchant',
    'amount',
    'amount_minor',
    'account',
    'account_id',
    'notification',
    'ocr_text',
  };
  void visit(Object? value, List<String> path) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        final isConfidenceFieldName =
            path.length == 2 && path[0] == 'confidence' && path[1] == 'fields';
        if (!isConfidenceFieldName && forbidden.contains(key)) {
          throw FormatException('包含禁止的敏感字段 ${entry.key}', lineNumber);
        }
        visit(entry.value, [...path, key]);
      }
    } else if (value is List) {
      for (final item in value) {
        visit(item, path);
      }
    }
  }

  visit(json, const []);
}
