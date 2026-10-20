import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum AppLogLevel { info, success, warning, error, fatal }

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.area,
    required this.code,
    required this.message,
    this.correlationId = '',
    this.technical = '',
  });

  final DateTime time;
  final AppLogLevel level;
  final String area;
  final String code;
  final String message;
  final String correlationId;
  final String technical;

  Map<String, Object> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'level': level.name,
    'area': area,
    'code': code,
    'message': message,
    'correlationId': correlationId,
    'technical': technical,
  };

  static AppLogEntry? fromJson(Object? source) {
    if (source is! Map<String, dynamic>) return null;
    final time = DateTime.tryParse(source['time']?.toString() ?? '');
    final level = AppLogLevel.values
        .where((value) => value.name == source['level'])
        .firstOrNull;
    final area = source['area'];
    final code = source['code'];
    final message = source['message'];
    if (time == null ||
        level == null ||
        area is! String ||
        code is! String ||
        message is! String ||
        area.length > 40 ||
        code.length > 80 ||
        message.length > 240 ||
        !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(area) ||
        !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(code)) {
      return null;
    }
    return AppLogEntry(
      time: time.toLocal(),
      level: level,
      area: area,
      code: code,
      message: message,
      correlationId: _bounded(source['correlationId'], 64),
      technical: _bounded(source['technical'], 1200),
    );
  }

  String line() =>
      '${time.toLocal().toIso8601String()} | ${level.name.toUpperCase()} | $area | $message'
      '${correlationId.isEmpty ? '' : ' | 关联 $correlationId'}'
      '${technical.isEmpty ? '' : ' | $technical'} | 事件码 $code';

  static String _bounded(Object? value, int max) {
    final text = value is String ? value : '';
    return text.length <= max ? text : text.substring(0, max);
  }
}

class AppLogger {
  AppLogger._({this.maxEntries = 1000});

  factory AppLogger.forDirectory(Directory directory, {int maxEntries = 1000}) {
    final logger = AppLogger._(maxEntries: maxEntries);
    logger._file = File(p.join(directory.path, 'app_diagnostics.jsonl'));
    return logger;
  }

  factory AppLogger.memory({int maxEntries = 1000}) {
    final logger = AppLogger._(maxEntries: maxEntries);
    logger._memory = true;
    return logger;
  }

  static final AppLogger instance = AppLogger._();
  final int maxEntries;
  File? _file;
  bool _memory = false;
  final List<AppLogEntry> _memoryEntries = [];
  Future<void> _pending = Future.value();

  Future<void> initialize() async {
    if (_memory) return;
    if (_file != null) return;
    final directory = Platform.environment['FLUTTER_TEST'] == 'true'
        ? await Directory.systemTemp.createTemp('smart_ledger_logs_')
        : await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    _file = File(p.join(directory.path, 'app_diagnostics.jsonl'));
  }

  Future<void> info(
    String area,
    String code,
    String message, {
    String correlationId = '',
  }) => _add(AppLogLevel.info, area, code, message, correlationId);

  Future<void> success(
    String area,
    String code,
    String message, {
    String correlationId = '',
  }) => _add(AppLogLevel.success, area, code, message, correlationId);

  Future<void> warning(
    String area,
    String code,
    String message, {
    String correlationId = '',
  }) => _add(AppLogLevel.warning, area, code, message, correlationId);

  Future<void> error(
    String area,
    String code,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String correlationId = '',
    bool fatal = false,
  }) => _add(
    fatal ? AppLogLevel.fatal : AppLogLevel.error,
    area,
    code,
    message,
    correlationId,
    technical: [
      if (error != null) error.runtimeType.toString(),
      if (stackTrace != null)
        stackTrace.toString().split('\n').take(8).join(' '),
    ].join(' · '),
  );

  Future<void> _add(
    AppLogLevel level,
    String area,
    String code,
    String message,
    String correlationId, {
    String technical = '',
  }) {
    final entry = AppLogEntry(
      time: DateTime.now(),
      level: level,
      area: area,
      code: code,
      message: _redact(message, 240),
      correlationId: _redact(correlationId, 64),
      technical: _redact(technical, 1200),
    );
    _pending = _pending.then((_) async {
      try {
        if (_memory) {
          _memoryEntries.add(entry);
          if (_memoryEntries.length > maxEntries) _memoryEntries.removeAt(0);
          return;
        }
        await initialize();
        final entries = await _readNow();
        entries.add(entry);
        final cutoff = DateTime.now().subtract(const Duration(days: 14));
        final retained = entries
            .where((item) => item.time.isAfter(cutoff))
            .toList();
        final start = retained.length > maxEntries
            ? retained.length - maxEntries
            : 0;
        await _file!.writeAsString(
          retained
              .skip(start)
              .map((item) => jsonEncode(item.toJson()))
              .join('\n'),
          flush: true,
        );
      } catch (_) {
        // Diagnostics must never interrupt bookkeeping.
      }
    });
    return _pending;
  }

  Future<List<AppLogEntry>> read() async {
    await _pending;
    try {
      await initialize();
      return await _readNow();
    } catch (_) {
      return [];
    }
  }

  Future<List<AppLogEntry>> _readNow() async {
    if (_memory) return List.of(_memoryEntries);
    if (_file == null || !await _file!.exists()) return [];
    final lines = await _file!.readAsLines();
    return lines
        .map((line) {
          try {
            return AppLogEntry.fromJson(jsonDecode(line));
          } catch (_) {
            return null;
          }
        })
        .whereType<AppLogEntry>()
        .toList();
  }

  Future<String> text() async =>
      (await read()).map((entry) => entry.line()).join('\n');

  Future<void> clear() async {
    await _pending;
    try {
      if (_memory) {
        _memoryEntries.clear();
        return;
      }
      await initialize();
      if (await _file!.exists()) await _file!.delete();
    } catch (_) {
      // Clearing diagnostics is best-effort.
    }
  }

  static String _redact(String value, int maxLength) {
    var result = value
        .replaceAll(
          RegExp(r'(token|password|secret)\s*[:=]\s*\S+', caseSensitive: false),
          '<redacted>',
        )
        .replaceAll(RegExp(r'\b\d{8,}\b'), '<number>')
        .replaceAll(
          RegExp(r'[a-z]:\\users\\[^\\\s]+', caseSensitive: false),
          '<user-path>',
        );
    if (result.length > maxLength) result = result.substring(0, maxLength);
    return result;
  }
}
