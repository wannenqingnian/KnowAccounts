import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'payment_apps.dart';

final automationBridgeProvider = Provider<AutomationBridge>(
  (ref) => AutomationBridge(),
);

class AutomationBridge {
  static const channel = MethodChannel('smart_ledger/automation');
  Future<Map<String, dynamic>> status() async {
    try {
      return await channel.invokeMapMethod<String, dynamic>('status') ?? {};
    } on MissingPluginException {
      return {};
    }
  }

  Future<void> configure(AutomationConfig config) =>
      channel.invokeMethod('configure', config.toJson());
  Future<void> openNotifications() => channel.invokeMethod('openNotifications');
  Future<void> openAccessibility() => channel.invokeMethod('openAccessibility');
  Future<void> openOverlay() => channel.invokeMethod('openOverlay');
  Future<Map<String, dynamic>> diagnostics() async =>
      await channel.invokeMapMethod<String, dynamic>('diagnostics') ?? {};
  Future<void> clearDiagnostics() => channel.invokeMethod('clearDiagnostics');
  Future<void> setDiagnosticsEnabled(bool enabled) =>
      channel.invokeMethod('setDiagnosticsEnabled', {'enabled': enabled});
  Future<void> retry() => channel.invokeMethod('retry');
  void listen(Future<void> Function() updated) =>
      channel.setMethodCallHandler((call) async {
        if (call.method == 'updated') await updated();
      });
  void dispose() => channel.setMethodCallHandler(null);
}
