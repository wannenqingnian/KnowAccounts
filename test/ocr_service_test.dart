import 'dart:async';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/ocr/ocr_service.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late List<OcrModel> models;
  final data = {
    'chi_sim': [1, 2, 3, 4],
    'eng': [5, 6, 7, 8],
  };
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ocr-model-test-');
    models = [];
    for (final entry in data.entries) {
      final hash = (await Sha256().hash(
        entry.value,
      )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      models.add(OcrModel(entry.key, entry.value.length, hash));
    }
  });
  tearDown(() => dir.delete(recursive: true));
  OcrService service({ModelFetcher? fetcher, ImageRecognizer? recognizer}) =>
      OcrService(
        directory: () async => dir,
        models: models,
        fetcher:
            fetcher ??
            (url) =>
                Stream.value(data[url.pathSegments.last.split('.').first]!),
        recognizer: recognizer ?? (_, _, _) async => '支付宝38.50元瑞幸咖啡',
      );

  test(
    'three PP-OCR bundles have verified detector and recognizer weights',
    () {
      expect(ocrTiers.map((t) => t.id), ['light', 'balanced', 'accurate']);
      expect(ocrTiers.map((t) => t.bytes), [6319431, 31163977, 138749438]);
      for (final tier in ocrTiers) {
        expect(tier.models.map((m) => m.role), ['det', 'rec']);
        expect(
          tier.models.every(
            (m) => m.url.path.contains('/resolve/v3.10.0/onnx/PP-OCRv6/'),
          ),
          isTrue,
        );
        expect(
          tier.models.every(
            (m) => m.sha256.length == 64 && m.fileName.endsWith('.onnx'),
          ),
          isTrue,
        );
      }
      expect(ocrTiers[0].models.last.name, 'PP-OCRv6_rec_tiny');
      expect(ocrTiers[1].models.last.name, 'PP-OCRv6_rec_small');
      expect(ocrTiers[2].models.last.name, 'PP-OCRv6_rec_medium');
    },
  );
  test(
    'previous PP-OCR manifest is rejected without touching its files',
    () async {
      final s = service();
      await s.download();
      final manifest = File('${dir.path}/active-v2/model.json');
      final old = await manifest.readAsString();
      await manifest.writeAsString(
        old.replaceFirst('"version":3', '"version":2'),
      );
      expect(await service().isReady(), isFalse);
      expect(
        await File('${dir.path}/active-v2/models/chi_sim.onnx').exists(),
        isTrue,
      );
    },
  );
  test(
    'tier switching, restart and failed installation preserve the active language bundle',
    () async {
      final higher = [9, 10, 11, 12, 13];
      final hash = (await Sha256().hash(
        higher,
      )).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final tiers = [
        OcrTier('light', '轻量档', '中文', [models.first]),
        OcrTier('balanced', '均衡档', '中英', models),
        OcrTier('accurate', '高精度档', '大模型', [
          for (final m in models)
            OcrModel(
              m.name,
              5,
              hash,
              downloadUrl: 'https://example.invalid/high/${m.fileName}',
            ),
        ]),
      ];
      var fail = false;
      OcrService create() => OcrService(
        directory: () async => dir,
        tiers: tiers,
        fetcher: (u) => Stream.value(
          u.path.contains('/high/')
              ? fail
                    ? [0, 0, 0, 0, 0]
                    : higher
              : data[u.pathSegments.last.split('.').first]!,
        ),
        recognizer: (_, _, tierId) async => tierId,
      );
      final s = create();
      await s.download(tierId: 'light');
      expect((await create().installedTier())!.id, 'light');
      expect(await create().recognize('/image'), 'light');
      await s.download(tierId: 'balanced');
      expect(await s.recognize('/image'), 'balanced');
      fail = true;
      await expectLater(
        s.download(tierId: 'accurate'),
        throwsA(isA<LedgerException>()),
      );
      expect((await create().installedTier())!.id, 'balanced');
      fail = false;
      await s.download(tierId: 'accurate');
      expect((await create().installedTier())!.id, 'accurate');
      await s.download(tierId: 'light');
      expect((await create().installedTier())!.id, 'light');
      expect(
        await File('${dir.path}/active-v2/models/eng.onnx').exists(),
        isFalse,
      );
    },
  );

  test(
    'Tesseract bundles cannot run; migration commits before cleaning old files',
    () async {
      final legacy = Directory('${dir.path}/active-v1/tessdata');
      await legacy.create(recursive: true);
      await File('${legacy.path}/chi_sim.traineddata').writeAsBytes([1, 2, 3]);
      await File(
        '${dir.path}/active-v1/model.json',
      ).writeAsString('{"version":1,"tier":"balanced"}');
      expect(await service().isReady(), isFalse);
      await expectLater(
        service(fetcher: (_) => Stream.value([0])).download(),
        throwsA(isA<LedgerException>()),
      );
      expect(await legacy.exists(), isTrue);
      await service().download();
      expect(await legacy.exists(), isFalse);
      expect(await service().isReady(), isTrue);
      await service().remove();
      expect(await service().isReady(), isFalse);
    },
  );
  test(
    'no automatic model download; recognition is blocked until explicit install',
    () async {
      var fetched = 0;
      final s = service(
        fetcher: (url) {
          fetched++;
          return const Stream.empty();
        },
      );
      expect(await s.isReady(), isFalse);
      expect(fetched, 0);
      await expectLater(
        s.recognize('/image.png'),
        throwsA(isA<LedgerException>()),
      );
      expect(fetched, 0);
    },
  );
  test(
    'explicit download validates both models then recognizes offline',
    () async {
      var fetched = 0;
      final progress = <double>[];
      final s = service(
        fetcher: (url) {
          fetched++;
          return Stream.value(data[url.pathSegments.last.split('.').first]!);
        },
      );
      await s.download(onProgress: (done, total) => progress.add(done / total));
      expect(await s.isReady(), isTrue);
      expect(progress.last, 1);
      expect(fetched, 2);
      expect(await s.recognize('/image.png'), contains('38.50'));
      expect(fetched, 2);
      await s.remove();
      expect(await s.isReady(), isFalse);
    },
  );
  test(
    'wrong hash, truncation and excess bytes never replace an installed model',
    () async {
      await service().download();
      for (final bytes in [
        [9, 9, 9, 9],
        [1],
        [1, 2, 3, 4, 5],
      ]) {
        final bad = service(fetcher: (url) => Stream.value(bytes));
        await expectLater(bad.download(), throwsA(isA<LedgerException>()));
        expect(await service().isReady(), isTrue);
        expect(
          (await dir.list().toList()).any((x) => x.path.contains('.download-')),
          isFalse,
        );
      }
    },
  );
  test(
    'cancellation and failed network discard staging and preserve previous models',
    () async {
      await service().download();
      var cancel = false;
      await expectLater(
        service().download(
          cancelled: () => cancel,
          onProgress: (_, _) => cancel = true,
        ),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        service(
          fetcher: (_) => Stream.error(const SocketException('offline')),
        ).download(),
        throwsA(isA<SocketException>()),
      );
      expect(await service().isReady(), isTrue);
      expect((await dir.list().toList()).length, 1);
    },
  );
  test(
    'file import checks names and checksum, delete does not change source files',
    () async {
      final source = await Directory.systemTemp.createTemp('ocr-import-');
      try {
        final files = <String, File>{};
        for (final model in models) {
          final f = File('${source.path}/${model.fileName}');
          await f.writeAsBytes(data[model.name]!);
          files[model.fileName] = f;
        }
        final s = service();
        await expectLater(s.importFiles({}), throwsA(isA<LedgerException>()));
        await s.importFiles(files);
        expect(await s.isReady(), isTrue);
        await s.remove();
        expect(await files.values.first.exists(), isTrue);
      } finally {
        await source.delete(recursive: true);
      }
    },
  );
  test(
    'delete is blocked during recognition, and empty or excessive text is rejected',
    () async {
      final completer = Completer<String>();
      final s = service(recognizer: (_, _, _) => completer.future);
      await s.download();
      final pending = s.recognize('/image');
      // Wait for checksum validation before asserting the recognizer lock.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(s.remove(), throwsA(isA<LedgerException>()));
      completer.complete('消费38元');
      expect(await pending, '消费38元');
      await expectLater(
        service(recognizer: (_, _, _) async => '').recognize('/image'),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        service(recognizer: (_, _, _) async => '字' * 4001).recognize('/image'),
        throwsA(isA<LedgerException>()),
      );
    },
  );
  test(
    'method channel passes private model path and returns native text; native failure is explained',
    () async {
      const channel = MethodChannel('smart_ledger/ocr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'recognize');
            expect(call.arguments, {
              'imagePath': '/image.png',
              'modelPath': '/private/model',
              'engine': 'ppocr',
              'tier': 'balanced',
            });
            return '支付38.50元';
          });
      expect(await recognizeNative('/image.png', '/private/model'), '支付38.50元');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async =>
                throw PlatformException(code: 'bad_image', message: '图片无法读取'),
          );
      await expectLater(
        recognizeNative('/image.png', '/private/model'),
        throwsA(isA<LedgerException>()),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  test(
    'native PP-OCR envelope carries scores; incomplete metadata cannot enable auto-save',
    () async {
      const channel = MethodChannel('smart_ledger/ocr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {
              'engine': 'ppocr',
              'texts': ['付款成功\n实付金额 16.00元'],
              'lines': [
                {
                  'text': '付款成功',
                  'confidence': .99,
                  'box': [10, 20, 80, 40],
                },
                {
                  'text': '实付金额 16.00元',
                  'confidence': .99,
                  'box': [10, 50, 200, 70],
                },
                {
                  'text': 'bad',
                  'confidence': .99,
                  'box': [10],
                },
              ],
            },
          );
      final result = await recognizeNativeDetailed(
        '/image.png',
        '/private/model',
      );
      expect(result.lines, hasLength(2));
      expect(result.hasClearBody, isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => '付款成功');
      expect(
        (await recognizeNativeDetailed(
          '/image.png',
          '/private/model',
        )).hasClearBody,
        isFalse,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  test('native candidate envelope keeps differing prices unresolved', () async {
    const channel = MethodChannel('smart_ledger/ocr');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'texts': [
              '付款成功\n支付金额 16.00元\n支付时间 2026-10-03',
              '付款成功\n支付金额 18.00元\n支付时间 2026-10-03',
            ],
          },
        );
    final text = await recognizeNative('/image.png', '/private/model');
    expect(text, contains('金额校验：不一致'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
