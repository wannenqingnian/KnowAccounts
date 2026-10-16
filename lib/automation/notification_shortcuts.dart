import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const shortcutActions = <String, String>{
  'capture': 'OCR截图记账',
  'quick': '快捷记账',
  'voice': '语音记账',
  'today': '今日消费',
};

const desktopShortcutActions = <String, String>{
  'quick': '手动记账',
  'voice': '语音记账',
  'smart': '一句话记账',
  'capture': 'OCR截图记账',
  'templates': '模板记账',
  'recurring': '周期计划',
};

final notificationShortcutsProvider = Provider<NotificationShortcutsBridge>(
  (ref) => NotificationShortcutsBridge(),
);

class NotificationShortcutsBridge {
  static const channel = MethodChannel('smart_ledger/shortcuts');

  Future<Map<String, dynamic>> status() async {
    try {
      return await channel.invokeMapMethod<String, dynamic>('status') ?? {};
    } on MissingPluginException {
      return {};
    }
  }

  Future<void> configure(
    List<String> actions,
    int todayExpenseMinor,
    String ledgerId,
  ) => channel.invokeMethod('configure', {
    'actions': actions,
    'todayExpenseMinor': todayExpenseMinor,
    'ledgerId': ledgerId,
  });

  Future<void> updateToday(int todayExpenseMinor, String ledgerId) =>
      channel.invokeMethod('updateToday', {
        'todayExpenseMinor': todayExpenseMinor,
        'ledgerId': ledgerId,
      });

  Future<bool> requestPermission() async =>
      await channel.invokeMethod<bool>('requestPermission') ?? false;

  Future<String?> takePending() async {
    try {
      return await channel.invokeMethod<String>('takePending');
    } on MissingPluginException {
      return null;
    }
  }

  Future<Map<String, dynamic>> desktopStatus() async {
    try {
      return await channel.invokeMapMethod<String, dynamic>('desktopStatus') ??
          {};
    } on MissingPluginException {
      return {};
    }
  }

  Future<void> configureDesktop(List<String> actions) =>
      channel.invokeMethod('configureDesktop', {'actions': actions});

  Future<bool> pinDesktopShortcut(String action) async =>
      await channel.invokeMethod<bool>('pinShortcut', {'action': action}) ??
      false;

  Future<bool> pinWidget() async =>
      await channel.invokeMethod<bool>('pinWidget') ?? false;

  void listen(Future<void> Function() available) =>
      channel.setMethodCallHandler((call) async {
        if (call.method == 'available') await available();
      });

  void dispose() => channel.setMethodCallHandler(null);
}
