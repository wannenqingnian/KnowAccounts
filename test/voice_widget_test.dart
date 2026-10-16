import 'dart:io';
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/main.dart';
import 'package:smart_ledger/features/speech_model_page.dart';
import 'package:smart_ledger/speech/speech_model_service.dart';

class _ReadySpeechModels extends SpeechModelService {
  _ReadySpeechModels()
    : super(
        directory: () async => Directory.systemTemp,
        platformSupported: true,
      );

  @override
  Future<String?> recordingPath() async => '/models/active-v1';

  @override
  Future<bool> isReady() async => true;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home microphone turns speech into a persisted review draft', (
    tester,
  ) async {
    const channel = MethodChannel('smart_ledger/speech');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return '昨天晚上滴滴四十二块五，支付包付的';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final db = AppDatabase.memory();
    final repository = LedgerRepository(db);
    await repository.initialize();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repository),
          speechModelServiceProvider.overrideWithValue(_ReadySpeechModels()),
        ],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音记账'));
    await tester.pumpAndSettle();

    expect(find.text('语音记账'), findsOneWidget);
    expect(find.text('¥42.50'), findsOneWidget);
    final pending = await repository.pendingDrafts('personal');
    expect(pending, hasLength(1));
    expect(pending.single.raw.text, '昨天晚上滴滴四十二块五，支付宝付的');
    expect(pending.single.raw.source.name, 'speech');
    expect(calls, ['listenLocal']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local voice starts recording before recognition and can stop', (
    tester,
  ) async {
    const channel = MethodChannel('smart_ledger/speech');
    final recognition = Completer<String>();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'listenLocal') return recognition.future;
          if (call.method == 'stopLocal') {
            recognition.complete('今天午饭二十元，微信支付');
            return true;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final db = AppDatabase.memory();
    final repository = LedgerRepository(db);
    await repository.initialize();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repository),
          speechModelServiceProvider.overrideWithValue(_ReadySpeechModels()),
        ],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音记账'));
    await tester.pumpAndSettle();

    expect(calls, ['listenLocal']);
    expect(find.text('完成录音'), findsOneWidget);
    expect(find.textContaining('正在录音'), findsOneWidget);
    await tester.tap(find.text('完成录音'));
    await tester.pumpAndSettle();

    expect(calls, ['listenLocal', 'stopLocal']);
    expect(find.text('¥20.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('speech model page exposes independent silence finish switch', (
    tester,
  ) async {
    const channel = MethodChannel('smart_ledger/speech');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getRecordingLimit') return 0;
          if (call.method == 'getSilenceAutoFinish') return false;
          if (call.method == 'getSilenceFinishSeconds') return 2;
          if (call.method == 'setSilenceAutoFinish') return true;
          if (call.method == 'setSilenceFinishSeconds') {
            return (call.arguments as Map)['seconds'];
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          speechModelServiceProvider.overrideWithValue(_ReadySpeechModels()),
        ],
        child: const MaterialApp(home: SpeechModelPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('静音后自动结束'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('speech_silence_auto_finish_switch')),
    );
    await tester.pumpAndSettle();
    expect(calls.last.method, 'setSilenceAutoFinish');
    expect(calls.last.arguments, {'enabled': true});
    expect(find.textContaining('连续静音 2 秒'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('edit_speech_silence_seconds')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('speech_silence_seconds_input')),
      '4',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'setSilenceFinishSeconds');
    expect(calls.last.arguments, {'seconds': 4});
    expect(find.textContaining('连续静音 4 秒'), findsOneWidget);
  });
}
