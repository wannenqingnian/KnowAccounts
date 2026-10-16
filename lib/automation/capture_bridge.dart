import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CapturedScreenshot {
  const CapturedScreenshot(this.path, this.capturedAt);
  final String path;
  final DateTime capturedAt;
}

final captureBridgeProvider = Provider<CaptureBridge>((ref) => CaptureBridge());

class CaptureBridge {
  static const channel = MethodChannel('smart_ledger/capture');
  void listen(Future<void> Function() available) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await available();
    });
  }

  void dispose() => channel.setMethodCallHandler(null);
  Future<CapturedScreenshot?> takePending() async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'takePending',
      );
      if (result == null) return null;
      final path = result['path'];
      final time = result['capturedAt'];
      if (path is! String || path.isEmpty || time is! int || time <= 0) {
        return null;
      }
      return CapturedScreenshot(
        path,
        DateTime.fromMillisecondsSinceEpoch(time),
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> startCapture() async {
    try {
      return await channel.invokeMethod<bool>('startCapture') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> addTile() async {
    try {
      return await channel.invokeMethod<bool>('addTile') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
