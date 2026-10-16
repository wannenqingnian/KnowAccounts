import 'package:flutter/services.dart';

/// Uses the user-downloaded SenseVoiceSmall model. No audio is retained.
class SpeechInput {
  const SpeechInput();

  static const _channel = MethodChannel('smart_ledger/speech');

  /// Explicitly warms and validates the recognizer from the model-management
  /// screen. Normal voice entry records immediately and loads in parallel.
  Future<void> prepare(String modelPath) => _channel.invokeMethod<void>(
    'prepareLocal',
    {'modelPath': modelPath, 'language': 'zh'},
  );

  Future<String> listen(String modelPath) async {
    final value = await _channel.invokeMethod<String>('listenLocal', {
      'modelPath': modelPath,
      'language': 'zh',
    });
    return _normalizeResult(value);
  }

  /// Ends the active local recording. Recognition continues with the audio
  /// already held in native memory.
  Future<bool> stop() async =>
      await _channel.invokeMethod<bool>('stopLocal') ?? false;

  /// Zero means recording waits for the user to tap "done". A non-zero value
  /// is an optional safety limit configured by the user (5 to 300 seconds).
  Future<int> recordingLimitSeconds() async {
    try {
      return await _channel.invokeMethod<int>('getRecordingLimit') ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }

  Future<void> setRecordingLimitSeconds(int seconds) async {
    if (seconds != 0 && (seconds < 5 || seconds > 300)) {
      throw const SpeechInputException('最长录音时长需为5到300秒');
    }
    await _channel.invokeMethod<int>('setRecordingLimit', {'seconds': seconds});
  }

  Future<bool> silenceAutoFinish() async {
    try {
      return await _channel.invokeMethod<bool>('getSilenceAutoFinish') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> setSilenceAutoFinish(bool enabled) =>
      _channel.invokeMethod<bool>('setSilenceAutoFinish', {'enabled': enabled});

  /// Consecutive silence required after detected speech before recording ends.
  Future<int> silenceFinishSeconds() async {
    try {
      return await _channel.invokeMethod<int>('getSilenceFinishSeconds') ?? 2;
    } on MissingPluginException {
      return 2;
    }
  }

  Future<void> setSilenceFinishSeconds(int seconds) async {
    if (seconds < 1 || seconds > 10) {
      throw const SpeechInputException('静音结束时长需为1到10秒');
    }
    await _channel.invokeMethod<int>('setSilenceFinishSeconds', {
      'seconds': seconds,
    });
  }

  /// Explicit fallback. Android's recognizer may use the network according to
  /// the phone's own speech-service settings.
  Future<String> listenSystem() async {
    final value = await _channel.invokeMethod<String>('listenSystem', const {
      'locale': 'zh-CN',
      'preferOffline': true,
    });
    return _normalizeResult(value);
  }

  String _normalizeResult(String? value) {
    final text = normalizeSpeechLedgerText(value ?? '');
    if (text.isEmpty) {
      throw const SpeechInputException('没有听清，请靠近麦克风再说一次');
    }
    return text;
  }
}

class SpeechInputException implements Exception {
  const SpeechInputException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Corrects a deliberately small set of common bookkeeping ASR homophones.
/// The original audio is never stored and the corrected sentence remains
/// editable before it enters TransactionParser.
String normalizeSpeechLedgerText(String source) {
  var text = source.trim().replaceAll(RegExp(r'\s+'), ' ');
  const replacements = {
    '支护宝': '支付宝',
    '支付包': '支付宝',
    '花被': '花呗',
    '瑞信': '瑞幸',
    '威信支付': '微信支付',
    '微性支付': '微信支付',
    '花贝': '花呗',
    '京东白条条': '京东白条',
    '美团月付付': '美团月付',
    '滴滴打车车': '滴滴打车',
    '星八克': '星巴克',
  };
  for (final entry in replacements.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  return text;
}
