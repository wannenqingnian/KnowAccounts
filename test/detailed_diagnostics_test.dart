import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/automation_bridge.dart';
import 'package:smart_ledger/automation/automation_diagnostics.dart';
import 'package:smart_ledger/core/logging/app_logger.dart';
import 'package:smart_ledger/features/automation_logs_page.dart';

class DetailedLogBridge extends AutomationBridge {
  DetailedLogBridge(this.data);
  final Map data;
  @override
  Future<Map<String, dynamic>> diagnostics() async =>
      Map<String, dynamic>.from(data);
}

void main() {
  Map report(bool sensitive) => {
    'state': {'sensitiveLogging': sensitive},
    'events': [
      for (final code in [
        'queued',
        'account_missing',
        'warning_review',
        'worker_pending',
      ])
        {
          'code': code,
          'time': 1000,
          'ref': 'abcdef123456',
          'fields': {
            'merchant': '示例商店完整名称',
            'paymentText': '支付成功\n支付方式\n零钱\n商品\n早餐',
            'paymentMethod': '零钱',
            'paymentTime': '2026-10-22 08:23:03',
            'parsedFields': '{"evidence":{"account":"无匹配"}}',
            'warnings': '账户未匹配；分类未确定',
            'unknownSecret': '不得保留',
          },
        },
      {'code': 'ocr_no_match', 'time': 2000, 'source': 'accessibility'},
    ],
  };

  test('all matched details survive consent, display and export', () {
    final diagnostics = AutomationDiagnostics.fromJson(report(true));
    final record = PaymentLogRecord.fromEvents(
      diagnostics.events,
    ).firstWhere((r) => r.reference == 'abcdef123456');
    expect(record.detailText, contains('支付页面读取内容'));
    expect(record.detailText, contains('早餐'));
    expect(record.detailText, contains('2026-10-22'));
    expect(record.detailText, contains('无匹配'));
    expect(record.reason, contains('账户未匹配'));
    expect(record.exportText, contains('早餐'));
    expect(diagnostics.text(), contains('无匹配'));
    expect(diagnostics.text(), isNot(contains('不得保留')));
    expect(PaymentLogRecord.fromEvents(diagnostics.events).length, 2);
  });

  test('sensitive details disappear when consent is off', () {
    final diagnostics = AutomationDiagnostics.fromJson(report(false));
    expect(diagnostics.text(), isNot(contains('早餐')));
    expect(diagnostics.text(), isNot(contains('无匹配')));
    expect(
      diagnostics.events.every((e) => !e.fields.containsKey('parsedFields')),
      isTrue,
    );
  });

  testWidgets('full details expand on a small dark screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          automationBridgeProvider.overrideWithValue(
            DetailedLogBridge(report(true)),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: AutomationLogsPage(
            appLogger: AppLogger.memory(),
            liveRefresh: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('待确认账单'), 250);
    await tester.tap(find.text('待确认账单'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data?.contains('支付页面读取内容') ?? false),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
