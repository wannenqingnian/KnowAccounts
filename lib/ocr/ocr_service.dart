import 'ocr_text_selector.dart';
import 'ocr_recognition.dart';
export 'ocr_recognition.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../domain/models.dart';

/// PaddleOCR weights converted to ONNX by RapidOCR. No weights are bundled.
class OcrModel {
  const OcrModel(
    this.name,
    this.bytes,
    this.sha256, {
    this.downloadUrl,
    this.role = 'aux',
  });
  final String name, sha256, role;
  final int bytes;
  final String? downloadUrl;
  String get fileName => '$name.onnx';
  Uri get url => Uri.parse(downloadUrl ?? 'https://example.invalid/$fileName');
}

const ppModel0 = OcrModel(
  'PP-OCRv6_det_tiny',
  1829618,
  'f42c0fbd294d95eac1a550e131b277dac97462c8025fa4b6c3cec1b7894bd3d5',
  role: 'det',
  downloadUrl:
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/det/PP-OCRv6_det_tiny.onnx',
);
const ppModel1 = OcrModel(
  'PP-OCRv6_rec_tiny',
  4489813,
  'e16e242de5937ad92609223f19bc2aff3727ee40b095f996907c24749bad251b',
  role: 'rec',
  downloadUrl:
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/rec/PP-OCRv6_rec_tiny.onnx',
);
const ppModel2 = OcrModel(
  'PP-OCRv6_det_small',
  9929594,
  '090f04abcd9d9a7498bc4ebf677e4cb9bdce1fe4197ddb7e529f1ef44e1ff94f',
  role: 'det',
  downloadUrl:
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx',
);
const ppModel3 = OcrModel(
  'PP-OCRv6_rec_small',
  21234383,
  '6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884',
  role: 'rec',
  downloadUrl:
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx',
);
const ppModel4 = OcrModel(
  'PP-OCRv6_det_medium',
  62119454,
  '92078b7355007ccfffcd4c8cd441a3afd4538904d06881b29a155e1e679907c2',
  role: 'det',
  downloadUrl:
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/det/PP-OCRv6_det_medium.onnx',
);
const ppModel5 = OcrModel(
  'PP-OCRv6_rec_medium',
  76629984,
  'eef444829dbbe18d7fea59a3f6eb75647518d2b3a9568d27c92e42940204894b',
  role: 'rec',
  downloadUrl:
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/rec/PP-OCRv6_rec_medium.onnx',
);

class OcrTier {
  const OcrTier(this.id, this.name, this.description, this.models);
  final String id, name, description;
  final List<OcrModel> models;
  int get bytes => models.fold(0, (v, m) => v + m.bytes);
}

const ocrTiers = [
  OcrTier('light', '轻量档', 'PP-OCRv6 tiny 检测＋识别，速度最快，适合清晰账单截图。', [
    ppModel0,
    ppModel1,
  ]),
  OcrTier('balanced', '均衡档', 'PP-OCRv6 small 检测＋识别，推荐日常账单使用。', [
    ppModel2,
    ppModel3,
  ]),
  OcrTier('accurate', '高精度档', 'PP-OCRv6 medium 检测＋识别，下载更大、运行更慢，效果仍需核对。', [
    ppModel4,
    ppModel5,
  ]),
];

typedef ModelFetcher = Stream<List<int>> Function(Uri url);
typedef ImageRecognizer =
    Future<String> Function(String imagePath, String modelPath, String tierId);
typedef DetailedImageRecognizer =
    Future<OcrRecognition> Function(
      String imagePath,
      String modelPath,
      String tierId,
    );
final ocrServiceProvider = Provider<OcrService>(
  (ref) => OcrService(
    directory: () async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'ocr_models'),
    ),
  ),
);

class OcrService {
  OcrService({
    required this.directory,
    List<OcrModel>? models,
    List<OcrTier>? tiers,
    ModelFetcher? fetcher,
    ImageRecognizer? recognizer,
    DetailedImageRecognizer? detailedRecognizer,
    this.platformSupported,
  }) : tiers =
           tiers ??
           (models == null
               ? ocrTiers
               : [OcrTier('balanced', '均衡档', '测试模型', models)]),
       fetcher = fetcher ?? fetchModel,
       detailedRecognizer =
           detailedRecognizer ??
           (recognizer == null
               ? recognizeNativeDetailed
               : ((image, models, tier) async =>
                     OcrRecognition(await recognizer(image, models, tier))));
  final Future<Directory> Function() directory;
  final List<OcrTier> tiers;
  final ModelFetcher fetcher;
  final DetailedImageRecognizer detailedRecognizer;
  bool _busy = false;
  final bool? platformSupported;
  bool get supported => platformSupported ?? Platform.isAndroid;
  OcrTier tier(String id) => tiers.firstWhere(
    (t) => t.id == id,
    orElse: () => throw const LedgerException('不支持此模型档位'),
  );
  int get downloadBytes => tier('balanced').bytes;
  Future<Directory> _bundle() async =>
      Directory(p.join((await directory()).path, 'active-v2'));

  Future<OcrTier?> installedTier() async {
    final bundle = await _bundle();
    try {
      final manifest = jsonDecode(
        await File(p.join(bundle.path, 'model.json')).readAsString(),
      );
      if (manifest is! Map ||
          manifest['version'] != 3 ||
          manifest['engine'] != 'ppocr') {
        return null;
      }
      final installed = tier(manifest['tier'] as String);
      await _validate(bundle, installed);
      return installed;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isReady() async => await installedTier() != null;
  Future<void> _validate(Directory bundle, OcrTier selected) async {
    for (final model in selected.models) {
      final file = File(p.join(bundle.path, 'models', model.fileName));
      if (!await file.exists() ||
          await file.length() != model.bytes ||
          await _digest(file) != model.sha256) {
        throw const LedgerException('OCR模型缺失或损坏，请重新下载或导入');
      }
    }
  }

  Future<void> _mark(Directory stage, OcrTier selected) =>
      File(p.join(stage.path, 'model.json'))
          .writeAsString(
            jsonEncode({
              'tier': selected.id,
              'version': 3,
              'engine': 'ppocr',
              'models': {
                for (final model in selected.models) model.role: model.fileName,
              },
            }),
          )
          .then((_) {});

  Future<String> _digest(File file) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    return (await sink.hash()).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<T> _operation<T>(Future<T> Function() run) async {
    if (_busy) throw const LedgerException('OCR正在处理，请稍后重试');
    _busy = true;
    try {
      return await run();
    } finally {
      _busy = false;
    }
  }

  Future<void> download({
    String tierId = 'balanced',
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) => _operation(() async {
    final selected = tier(tierId);
    final root = await directory();
    await root.create(recursive: true);
    final stage = await root.createTemp('.download-');
    try {
      await Directory(p.join(stage.path, 'models')).create();
      var complete = 0;
      for (final model in selected.models) {
        if (cancelled?.call() ?? false) throw const LedgerException('模型下载已取消');
        final sink = File(
          p.join(stage.path, 'models', model.fileName),
        ).openWrite();
        var bytes = 0;
        try {
          await for (final chunk in fetcher(
            model.url,
          ).timeout(const Duration(seconds: 30))) {
            if (cancelled?.call() ?? false) {
              throw const LedgerException('模型下载已取消');
            }
            bytes += chunk.length;
            if (bytes > model.bytes) {
              throw const LedgerException('模型文件大小不符，下载已取消');
            }
            sink.add(chunk);
            onProgress?.call(complete + bytes, selected.bytes);
          }
        } finally {
          await sink.close();
        }
        complete += bytes;
      }
      if (cancelled?.call() ?? false) throw const LedgerException('模型下载已取消');
      await _validate(stage, selected);
      await _mark(stage, selected);
      await _commit(stage);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  });

  Future<void> importFiles(
    Map<String, File> files, {
    String tierId = 'balanced',
  }) => _operation(() async {
    final selected = tier(tierId);
    if (files.length != selected.models.length ||
        selected.models.any((m) => !files.containsKey(m.fileName))) {
      throw LedgerException(
        '请按所选档位选择：${selected.models.map((m) => m.fileName).join('、')}',
      );
    }
    final root = await directory();
    await root.create(recursive: true);
    final stage = await root.createTemp('.import-');
    try {
      await Directory(p.join(stage.path, 'models')).create();
      for (final model in selected.models) {
        final file = files[model.fileName]!;
        if (await file.length() != model.bytes) {
          throw const LedgerException('模型版本或大小不符，请使用模型页面指定的文件');
        }
        await file.copy(p.join(stage.path, 'models', model.fileName));
      }
      await _validate(stage, selected);
      await _mark(stage, selected);
      await _commit(stage);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  });
  Future<void> _commit(Directory stage) async {
    final bundle = await _bundle();
    Directory? previous;
    if (await bundle.exists()) {
      previous = await bundle.rename(
        '${bundle.path}.old-${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    try {
      await stage.rename(bundle.path);
    } catch (_) {
      if (previous != null) await previous.rename(bundle.path);
      rethrow;
    }
    // Remove incompatible Tesseract weights only after the new bundle commits.
    try {
      final legacy = Directory(p.join((await directory()).path, 'active-v1'));
      if (await legacy.exists()) await legacy.delete(recursive: true);
    } catch (_) {
      /* New weights remain usable even if old cleanup fails. */
    }
    if (previous != null) {
      try {
        await previous.delete(recursive: true);
      } catch (_) {
        /* Installed model remains available. */
      }
    }
  }

  Future<void> remove() => _operation(() async {
    final bundle = await _bundle();
    if (await bundle.exists()) await bundle.delete(recursive: true);
    final legacy = Directory(p.join((await directory()).path, 'active-v1'));
    if (await legacy.exists()) await legacy.delete(recursive: true);
  });
  Future<String> recognize(String imagePath) async =>
      (await recognizeDetailed(imagePath)).text;
  Future<OcrRecognition> recognizeDetailed(String imagePath) =>
      _operation(() async {
        final bundle = await _bundle();
        final installed = await installedTier();
        if (installed == null) throw const LedgerException('OCR模型缺失或损坏，请下载或导入');
        final recognition = await detailedRecognizer(
          imagePath,
          bundle.path,
          installed.id,
        );
        final text = recognition.text;
        if (text.trim().isEmpty) {
          throw const LedgerException('没有识别到文字，请使用清晰截图或手动输入');
        }
        if (text.length > 4000) {
          throw const LedgerException('图片文字超过4000字，请裁剪到单笔账单后重试');
        }
        return recognition;
      });
}

Stream<List<int>> fetchModel(Uri url) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 20));
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw const LedgerException('模型下载失败，请重试或从文件导入模型');
    }
    yield* response;
  } finally {
    client.close(force: true);
  }
}

Future<String> recognizeNative(
  String imagePath,
  String modelPath, [
  String tierId = 'balanced',
]) async => (await recognizeNativeDetailed(imagePath, modelPath, tierId)).text;

Future<OcrRecognition> recognizeNativeDetailed(
  String imagePath,
  String modelPath, [
  String tierId = 'balanced',
]) async {
  try {
    final result = await const MethodChannel('smart_ledger/ocr')
        .invokeMethod<Object>('recognize', {
          'imagePath': imagePath,
          'modelPath': modelPath,
          'engine': 'ppocr',
          'tier': tierId,
        });
    if (result is String) {
      return OcrRecognition(
        result,
        engineVersion: 'ppocr-v6',
        modelVersion: 'PP-OCRv6/$tierId',
      );
    }
    if (result is Map && result['texts'] is List) {
      final lines = <OcrTextLine>[];
      if (result['engine'] == 'ppocr' && result['lines'] is List) {
        for (final item in result['lines'] as List) {
          if (item is! Map ||
              item['text'] is! String ||
              item['confidence'] is! num ||
              item['box'] is! List) {
            continue;
          }
          final box = item['box'] as List;
          if (box.length != 4 || box.any((n) => n is! int)) continue;
          lines.add(
            OcrTextLine(
              item['text'] as String,
              (item['confidence'] as num).toDouble(),
              box[1] as int,
            ),
          );
        }
      }
      return OcrRecognition(
        selectOcrText((result['texts'] as List).whereType<String>().toList()),
        lines: lines,
        engineVersion: 'ppocr-v6',
        modelVersion: 'PP-OCRv6/$tierId',
      );
    }
    return const OcrRecognition('');
  } on MissingPluginException {
    throw const LedgerException('本版本截图OCR暂支持Android');
  } on PlatformException catch (e) {
    throw LedgerException(e.message ?? '图片识别失败，请重试');
  }
}
