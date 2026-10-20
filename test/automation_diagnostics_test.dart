import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/automation_bridge.dart';
import 'package:smart_ledger/automation/payment_apps.dart';
import 'package:smart_ledger/automation/automation_diagnostics.dart';
import 'package:smart_ledger/features/automation_logs_page.dart';
import 'package:smart_ledger/core/logging/app_logger.dart';

Map<String, dynamic> event(String code, String app, String source, int time) =>
    {
      'code': code,
      'app': app,
      'source': source,
      'time': time,
      'ref': 'abcdef123456',
      'count': 3,
      'repeats': 1,
    };

class LogBridge extends AutomationBridge {
  bool logging = true;
  int cleared = 0, configs = 0;
  List<Map<String, dynamic>> events = [
    event('money_missing', 'com.tencent.mm', 'accessibility', 1000),
    event('matched', 'com.eg.android.AlipayGphone', 'notification', 2000),
    event('worker_ready', '', '', 3000),
  ];
  @override
  Future<Map<String, dynamic>> diagnostics() async => {
    'enabled': logging,
    'appVersion': '0.14.1',
    'androidApi': 36,
    'state': {'enabled': true},
    'events': events,
  };
  @override
  Future<void> clearDiagnostics() async {
    cleared++;
    events = [];
  }

  @override
  Future<void> setDiagnosticsEnabled(bool enabled) async {
    logging = enabled;
  }

  @override
  Future<void> configure(AutomationConfig config) async {
    configs++;
  }
}

void main() {
  test(
    'display and export drop sensitive and unexpected bridge payload fields',
    () {
      const secret = '4111111111111111私密商户聊天原文';
      final report = AutomationDiagnostics.fromJson({
        'appVersion': secret,
        'androidApi': 999,
        'raw': secret,
        'state': {
          'errorCode': secret,
          'queued': 10000,
          'enabled': true,
          'card': secret,
        },
        'events': [
          {
            ...event('money_missing', 'com.tencent.mm', 'notification', 1000),
            'text': secret,
            'amount': secret,
            'fields': {
              'amount': '3.00',
              'merchant': '三津实业（深圳）有限公司',
              'account': '招商银行信用卡1234',
              'raw': secret,
            },
          },
          {...event('worker_ready', secret, secret, 2000), 'ref': secret},
          event(secret, 'com.tencent.mm', 'notification', 3000),
        ],
      });
      expect(report.text(), isNot(contains(secret)));
      expect(report.text(), contains('金额 3.00'));
      expect(report.text(), contains('商户 三**********司'));
      expect(report.text(), contains('账户 招******1234'));
      expect(report.events.length, 2);
      expect(report.events.first.code, 'worker_ready');
      expect(report.events.first.reference, isEmpty);
      expect(report.version, '未知');
      expect(report.api, 100);
      expect(report.queued, 100);
      expect(report.text(), contains('未找到可识别的交易金额'));
      expect(report.text(), isNot(contains('发生了什么：')));
      expect(report.text(), isNot(contains('处理结果：')));
      expect(report.text(), contains('| 警告 | 微信 · 通知 |'));
      expect(report.text(), contains('| 建议：'));
      expect(report.text(), isNot(contains('worker_ready')));
      final money = report.events.singleWhere(
        (item) => item.code == 'money_missing',
      );
      expect(money.explanation.what, contains('本笔交易金额'));
      expect(money.explanation.action, contains('实付金额'));
    },
  );
  test('malformed events are rejected and report is bounded', () {
    final report = AutomationDiagnostics.fromJson({
      'events': [
        {'code': 'matched', 'time': -1},
        ...List.generate(
          600,
          (i) => event('matched', 'com.tencent.mm', 'notification', 1000 + i),
        ),
      ],
    });
    expect(report.events.length, 600);
  });
  test('fine-grained capture diagnostics are parsed and exported safely', () {
    final report = AutomationDiagnostics.fromJson({
      'state': {
        'accessibility': {
          'rootNodeCount': 42,
          'usableTextCount': 8,
          'pageSessionId': 'session-1',
          'windowPackage': 'com.tencent.mm',
        },
        'ocr': {
          'screenshotSucceeded': true,
          'recognizedLineCount': 16,
          'amountCandidateFound': true,
          'successMarkerFound': false,
          'rejectionReason': 'success_missing',
        },
        'notification': {'listenerConnected': true, 'lastConnectedAt': 123456},
      },
      'events': [
        event('node_read', 'com.tencent.mm', 'accessibility', 1000),
        event('ocr_no_match', 'com.tencent.mm', 'accessibility', 2000),
      ],
    });
    expect(report.accessibility.rootNodeCount, 42);
    expect(report.accessibility.usableTextCount, 8);
    expect(report.ocr.recognizedLineCount, 16);
    expect(report.ocr.amountCandidateFound, isTrue);
    expect(report.notification.listenerConnected, isTrue);
    expect(report.text(), contains('扫描节点数：42'));
    expect(report.text(), contains('拒绝原因：未找到明确交易成功状态'));
    expect(report.text(), contains('ocr_no_match'));
    expect(report.text(), isNot(contains('node_read')));
  });
  test(
    'background screenshot stages remain visible without financial text',
    () {
      final report = AutomationDiagnostics.fromJson({
        'events': [
          event('quick_capture_ready', manualOcrPackage, 'screenshot', 1000),
          event('quick_ocr_text_read', manualOcrPackage, 'screenshot', 2000),
        ],
      });
      expect(report.events, hasLength(2));
      expect(report.events.first.origin, 'OCR截图 · 截图');
      expect(report.text(), contains('已取得支付页面截图'));
      expect(report.text(), contains('快捷截图已读取文字行'));
    },
  );
  testWidgets(
    'phone layout expands status without overflow; filters, copies, disables and clears without touching config',
    (tester) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? clipboard;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'];
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final bridge = LogBridge();
      final appLogger = AppLogger.memory();
      await appLogger.error('database', 'database_open_failed', '本地数据库初始化失败');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [automationBridgeProvider.overrideWithValue(bridge)],
          child: MaterialApp(
            home: AutomationLogsPage(appLogger: appLogger, liveRefresh: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('诊断中心'), findsOneWidget);
      expect(find.text('日志记录已开启'), findsOneWidget);
      expect(find.text('未找到可识别的交易金额'), findsOneWidget);
      expect(find.text('已匹配交易信息'), findsOneWidget);
      expect(find.textContaining('默认隐藏内部轮询'), findsOneWidget);
      expect(find.textContaining('警告 1'), findsOneWidget);
      expect(find.textContaining('成功 2'), findsOneWidget);
      expect(find.textContaining('应用日志 · 1 条'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('levelFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '警告'));
      await tester.pumpAndSettle();
      expect(find.text('未找到可识别的交易金额'), findsOneWidget);
      expect(find.text('已匹配交易信息'), findsNothing);
      expect(find.text('后台数据库已就绪'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('levelFilter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '全部记录'),
      );
      await tester.pumpAndSettle();
      expect(find.text('已匹配交易信息'), findsOneWidget);
      expect(find.text('后台数据库已就绪'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('levelFilter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '处理中'),
      );
      await tester.pumpAndSettle();
      expect(find.text('后台数据库已就绪'), findsOneWidget);
      await tester.tap(find.textContaining('当前状态'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('sourceFilter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '微信及后台'),
      );
      await tester.pumpAndSettle();
      expect(find.text('已匹配交易信息'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sourceFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '通知'));
      await tester.pumpAndSettle();
      expect(find.text('未找到可识别的交易金额'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('logActions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制完整日志'));
      await tester.pumpAndSettle();
      expect(clipboard, contains('money_missing'));
      expect(clipboard, contains('matched'));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(bridge.logging, false);
      expect(find.text('日志记录已关闭'), findsOneWidget);
      expect(bridge.events.length, 3);
      await tester.tap(find.byKey(const ValueKey('logActions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空全部诊断日志'));
      await tester.pumpAndSettle();
      expect(bridge.cleared, 1);
      expect(bridge.configs, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('日志可展开查看实际结果和操作建议', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = LogBridge()
      ..events = [
        event('money_missing', 'com.tencent.mm', 'accessibility', 1000),
      ];
    final appLogger = AppLogger.memory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [automationBridgeProvider.overrideWithValue(bridge)],
        child: MaterialApp(
          home: AutomationLogsPage(appLogger: appLogger, liveRefresh: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final moneyTile = find.ancestor(
      of: find.text('未找到可识别的交易金额'),
      matching: find.byType(ExpansionTile),
    );
    final tileTapTarget = find.descendant(
      of: moneyTile,
      matching: find.byType(InkWell),
    );
    expect(tileTapTarget, findsOneWidget);
    await tester.tap(tileTapTarget);
    await tester.pumpAndSettle();
    expect(find.textContaining('实际结果'), findsWidgets);
    expect(find.textContaining('建议操作'), findsWidgets);
    expect(find.textContaining('实付金额'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('紧凑日志页首屏直接显示多条问题记录', (tester) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = LogBridge()
      ..events = [
        event('money_missing', 'com.tencent.mm', 'accessibility', 3000),
        event('ocr_no_match', 'com.tencent.mm', 'accessibility', 2000),
        event('success_missing', 'com.tencent.mm', 'accessibility', 1000),
      ];
    final appLogger = AppLogger.memory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [automationBridgeProvider.overrideWithValue(bridge)],
        child: MaterialApp(
          home: AutomationLogsPage(appLogger: appLogger, liveRefresh: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未找到可识别的交易金额').hitTestable(), findsOneWidget);
    expect(find.text('截图未匹配明确的已完成账单').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
