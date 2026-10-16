import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/capture_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(CaptureBridge.channel, null),
  );
  test(
    'direct screenshot request is forwarded once, without consuming a capture',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(CaptureBridge.channel, (call) async {
        calls.add(call.method);
        return true;
      });
      expect(await CaptureBridge().startCapture(), isTrue);
      expect(calls, ['startCapture']);
    },
  );
  test(
    'capture is consumed once, preserves timestamp and forwards tile request',
    () async {
      Map<String, Object>? pending = {
        'path': '/private/cache/captures/payment.png',
        'capturedAt': 1791169200000,
      };
      var adds = 0;
      messenger.setMockMethodCallHandler(CaptureBridge.channel, (call) async {
        if (call.method == 'addTile') {
          adds++;
          return true;
        }
        final result = pending;
        pending = null;
        return result;
      });
      final bridge = CaptureBridge();
      final shot = await bridge.takePending();
      expect(shot!.path, '/private/cache/captures/payment.png');
      expect(shot.capturedAt.millisecondsSinceEpoch, 1791169200000);
      expect(await bridge.takePending(), isNull);
      expect(await bridge.addTile(), isTrue);
      expect(adds, 1);
    },
  );
  test(
    'unsupported platforms and malformed handoff do not crash startup',
    () async {
      final bridge = CaptureBridge();
      expect(await bridge.takePending(), isNull);
      expect(await bridge.addTile(), isFalse);
      expect(await bridge.startCapture(), isFalse);
      messenger.setMockMethodCallHandler(
        CaptureBridge.channel,
        (_) async => {'path': '', 'capturedAt': -1},
      );
      expect(await bridge.takePending(), isNull);
    },
  );
}
