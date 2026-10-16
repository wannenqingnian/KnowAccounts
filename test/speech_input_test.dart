import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/speech/speech_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bookkeeping homophones are normalized without changing other text', () {
    expect(normalizeSpeechLedgerText(' 昨天 瑞信 38块，支护宝 '), '昨天 瑞幸 38块，支付宝');
    expect(normalizeSpeechLedgerText('今天工资到账五千元'), '今天工资到账五千元');
  });

  test('local recognizer receives installed model path', () async {
    const channel = MethodChannel('smart_ledger/speech');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return '今天瑞信咖啡三十八块，支付包付的';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final text = await const SpeechInput().listen('/models/active-v1');
    expect(received?.method, 'listenLocal');
    expect(received?.arguments, {
      'modelPath': '/models/active-v1',
      'language': 'zh',
    });
    expect(text, '今天瑞幸咖啡三十八块，支付宝付的');
  });

  test('model management can explicitly prewarm the local model', () async {
    const channel = MethodChannel('smart_ledger/speech');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await const SpeechInput().prepare('/models/active-v1');
    expect(received?.method, 'prepareLocal');
    expect(received?.arguments, {
      'modelPath': '/models/active-v1',
      'language': 'zh',
    });
  });

  test('local recording can finish while recognition continues', () async {
    const channel = MethodChannel('smart_ledger/speech');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(await const SpeechInput().stop(), isTrue);
    expect(received?.method, 'stopLocal');
  });

  test(
    'recording waits for manual finish by default and accepts a custom limit',
    () async {
      const channel = MethodChannel('smart_ledger/speech');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getRecordingLimit') return 0;
            if (call.method == 'getSilenceAutoFinish') return false;
            if (call.method == 'getSilenceFinishSeconds') return 2;
            if (call.method == 'setRecordingLimit') {
              return (call.arguments as Map)['seconds'];
            }
            if (call.method == 'setSilenceAutoFinish') {
              return (call.arguments as Map)['enabled'];
            }
            if (call.method == 'setSilenceFinishSeconds') {
              return (call.arguments as Map)['seconds'];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      const speech = SpeechInput();
      expect(await speech.recordingLimitSeconds(), 0);
      await speech.setRecordingLimitSeconds(75);
      expect(calls.last.method, 'setRecordingLimit');
      expect(calls.last.arguments, {'seconds': 75});
      expect(await speech.silenceAutoFinish(), isFalse);
      await speech.setSilenceAutoFinish(true);
      expect(calls.last.method, 'setSilenceAutoFinish');
      expect(calls.last.arguments, {'enabled': true});
      expect(await speech.silenceFinishSeconds(), 2);
      await speech.setSilenceFinishSeconds(4);
      expect(calls.last.method, 'setSilenceFinishSeconds');
      expect(calls.last.arguments, {'seconds': 4});
      await expectLater(
        speech.setRecordingLimitSeconds(4),
        throwsA(isA<SpeechInputException>()),
      );
      await expectLater(
        speech.setSilenceFinishSeconds(11),
        throwsA(isA<SpeechInputException>()),
      );
    },
  );

  test('system speech is an explicit fallback', () async {
    const channel = MethodChannel('smart_ledger/speech');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return '午饭二十元';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    expect(await const SpeechInput().listenSystem(), '午饭二十元');
    expect(received?.method, 'listenSystem');
  });
}
