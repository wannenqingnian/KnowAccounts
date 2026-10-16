import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/automation/automation_bridge.dart';
import 'package:smart_ledger/automation/payment_apps.dart';
import 'package:smart_ledger/automation/notification_shortcuts.dart';
import 'package:smart_ledger/features/automation_page.dart';

class TestAutomationBridge extends AutomationBridge {
  AutomationConfig saved = const AutomationConfig();
  int notificationSettings = 0, accessibilitySettings = 0, overlaySettings = 0;
  @override
  Future<Map<String, dynamic>> status() async => {
    'supported': true,
    'config': saved.toJson(),
    'notificationsGranted': true,
    'accessibilityGranted': false,
    'installed': {'com.tencent.mm': true},
  };
  @override
  Future<void> configure(AutomationConfig config) async {
    saved = config;
  }

  @override
  Future<void> openNotifications() async {
    notificationSettings++;
  }

  @override
  Future<void> openOverlay() async {
    overlaySettings++;
  }

  @override
  Future<void> openAccessibility() async {
    accessibilitySettings++;
  }
}

class TestNotificationShortcuts extends NotificationShortcutsBridge {
  List<String> actions = [];
  @override
  Future<Map<String, dynamic>> status() async => {
    'supported': true,
    'granted': true,
    'actions': actions,
  };
  @override
  Future<void> configure(
    List<String> value,
    int todayExpenseMinor,
    String ledgerId,
  ) async {
    actions = [...value];
  }

  @override
  Future<bool> requestPermission() async => true;
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testWidgets('notification bar lets users choose at most three shortcuts', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    final repo = LedgerRepository(db);
    await repo.initialize();
    final state = LedgerController(repo);
    await state.load();
    final shortcuts = TestNotificationShortcuts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          ledgerProvider.overrideWith((ref) => state),
          automationBridgeProvider.overrideWithValue(TestAutomationBridge()),
          notificationShortcutsProvider.overrideWithValue(shortcuts),
        ],
        child: const MaterialApp(home: AutomationPage()),
      ),
    );
    await settle(tester);
    expect(find.text('日志记录'), findsNothing);
    for (final label in ['OCR截图记账', '快捷记账', '语音记账']) {
      await tester.tap(find.text(label));
      await settle(tester);
    }
    expect(shortcuts.actions, ['capture', 'quick', 'voice']);
    await tester.tap(find.text('今日消费'));
    await tester.pumpAndSettle();
    expect(shortcuts.actions, ['capture', 'quick', 'voice']);
    expect(find.textContaining('最多显示 3 个'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
  testWidgets(
    'global settings save target ledger and enhanced mode; accessibility requires explanatory system-settings action',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final state = LedgerController(repo);
      await state.load();
      final bridge = TestAutomationBridge();
      final shortcuts = TestNotificationShortcuts();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ledgerProvider.overrideWith((ref) => state),
            automationBridgeProvider.overrideWithValue(bridge),
            notificationShortcutsProvider.overrideWithValue(shortcuts),
          ],
          child: const MaterialApp(home: AutomationPage()),
        ),
      );
      await settle(tester);
      final enable = find.ancestor(
        of: find.text('启用自动记账'),
        matching: find.byType(SwitchListTile),
      );
      await tester.tap(enable);
      await tester.pumpAndSettle();
      final enhance = find.ancestor(
        of: find.text('无障碍增强模式'),
        matching: find.byType(SwitchListTile),
      );
      await tester.scrollUntilVisible(
        find.text('无障碍增强模式'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(enhance);
      await tester.pumpAndSettle();
      // Changes persist without pressing Save.
      await settle(tester);
      expect(bridge.saved.reviewPopup, true);
      expect(bridge.saved.enabled, true);
      expect(bridge.saved.enhanced, true);
      expect(bridge.saved.autoSave, true);
      expect(bridge.saved.screenshotFallback, false);
      expect(bridge.saved.toJson()['apps'], hasLength(paymentApps.length));
      expect(find.text('部分功能缺少权限'), findsOneWidget);
      expect(find.textContaining('对应功能暂时无法使用'), findsOneWidget);
      final fallback = find.text('支付页面本地截图OCR增强');
      await tester.scrollUntilVisible(
        fallback,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(fallback, findsOneWidget);
      expect(find.text('未启用'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('悬浮窗权限'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      final overlayTile = find.ancestor(
        of: find.text('悬浮窗权限'),
        matching: find.byType(ListTile),
      );
      final overlayButton = find.descendant(
        of: overlayTile,
        matching: find.text('系统设置'),
      );
      await tester.ensureVisible(overlayButton);
      await tester.tap(overlayButton);
      await settle(tester);
      expect(bridge.overlaySettings, 1);
      await tester.scrollUntilVisible(
        find.text('无障碍权限'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final tile = find.ancestor(
        of: find.text('无障碍权限'),
        matching: find.byType(ListTile),
      );
      final button = find.descendant(of: tile, matching: find.text('系统设置'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(bridge.accessibilitySettings, 0);
      expect(find.textContaining('不点击、不支付、不读密码、不上传'), findsOneWidget);
      await tester.tap(find.text('前往系统设置'));
      await tester.pumpAndSettle();
      expect(bridge.accessibilitySettings, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );
  testWidgets(
    'source-specific payment rule waits by default, then persists chosen account and category',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final state = LedgerController(repo);
      await state.load();
      final bridge = TestAutomationBridge();
      final shortcuts = TestNotificationShortcuts();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ledgerProvider.overrideWith((ref) => state),
            automationBridgeProvider.overrideWithValue(bridge),
            notificationShortcutsProvider.overrideWithValue(shortcuts),
          ],
          child: const MaterialApp(home: AutomationPage()),
        ),
      );
      await settle(tester);
      await tester.scrollUntilVisible(
        find.text('微信'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('微信'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('微信'));
      await settle(tester);
      expect(find.text('未识别时待确认'), findsNWidgets(2));
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(DropdownButtonFormField<String>),
            )
            .at(0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('现金').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(DropdownButtonFormField<String>),
            )
            .at(1),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('餐饮').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await settle(tester);
      await tester.tap(find.text('保存设置'));
      await settle(tester);
      expect(
        bridge.saved.rule('com.tencent.mm').accountId,
        state.accounts.first.id,
      );
      expect(
        bridge.saved.rule('com.tencent.mm').categoryId,
        state.categories.firstWhere((c) => c.name == '餐饮').id,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );
}
