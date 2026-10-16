import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

typedef SpeechModelFetcher = Stream<List<int>> Function(Uri url);
typedef SpeechModelInstaller =
    Future<void> Function(
      String archivePath,
      String vadPath,
      String outputPath,
    );

class SpeechModelFile {
  const SpeechModelFile(this.name, this.bytes, this.sha256, this.url);
  final String name, sha256, url;
  final int bytes;
}

class SpeechModelBundle {
  const SpeechModelBundle({
    required this.archive,
    required this.vad,
    required this.modelBytes,
    required this.modelSha256,
    required this.tokensBytes,
    required this.tokensSha256,
  });

  final SpeechModelFile archive, vad;
  final int modelBytes, tokensBytes;
  final String modelSha256, tokensSha256;
  int get downloadBytes => archive.bytes + vad.bytes;
  int get installedBytes => modelBytes + tokensBytes + vad.bytes;
}

const senseVoiceSmallBundle = SpeechModelBundle(
  archive: SpeechModelFile(
    'sensevoice-small-int8.tar.bz2',
    163002883,
    '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e',
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
  ),
  vad: SpeechModelFile(
    'silero_vad.int8.onnx',
    212860,
    'c36d490aff5ab924ca6c7aeec4d8f6bd3d22db6fa17611b9c5b17eae58ac3a20',
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
        'silero_vad.int8.onnx',
  ),
  modelBytes: 239233841,
  modelSha256:
      'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
  tokensBytes: 315894,
  tokensSha256:
      'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
);

final speechModelServiceProvider = Provider<SpeechModelService>(
  (_) => SpeechModelService(
    directory: () async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'speech_models'),
    ),
  ),
);

class SpeechModelService {
  SpeechModelService({
    required this.directory,
    this.bundle = senseVoiceSmallBundle,
    SpeechModelFetcher? fetcher,
    SpeechModelInstaller? installer,
    this.platformSupported,
  }) : fetcher = fetcher ?? fetchSpeechModel,
       installer = installer ?? installSpeechModelNative;

  final Future<Directory> Function() directory;
  final SpeechModelBundle bundle;
  final SpeechModelFetcher fetcher;
  final SpeechModelInstaller installer;
  final bool? platformSupported;
  bool _busy = false;

  bool get supported => platformSupported ?? Platform.isAndroid;

  Future<Directory> _active() async =>
      Directory(p.join((await directory()).path, 'active-v1'));

  Future<String?> installedPath() async {
    final active = await _active();
    try {
      if (!await _hasExpectedManifest(active)) return null;
      await _validateInstalled(active);
      return active.path;
    } catch (_) {
      return null;
    }
  }

  /// Returns the installed model without reading and hashing the 239 MB model.
  ///
  /// The download/install flow already verifies every byte before committing
  /// the active directory. Voice capture uses this lightweight check so the
  /// microphone can start immediately; native model loading and any resulting
  /// model error happen concurrently with the in-memory recording.
  Future<String?> recordingPath() async {
    final active = await _active();
    try {
      if (!await _hasExpectedManifest(active)) return null;
      final models = Directory(p.join(active.path, 'models'));
      for (final spec in [
        (File(p.join(models.path, 'model.int8.onnx')), bundle.modelBytes),
        (File(p.join(models.path, 'tokens.txt')), bundle.tokensBytes),
        (File(p.join(models.path, bundle.vad.name)), bundle.vad.bytes),
      ]) {
        if (!await spec.$1.exists() || await spec.$1.length() != spec.$2) {
          return null;
        }
      }
      return active.path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasExpectedManifest(Directory active) async {
    final manifest = jsonDecode(
      await File(p.join(active.path, 'model.json')).readAsString(),
    );
    return manifest is Map &&
        manifest['engine'] == 'sherpa-onnx' &&
        manifest['model'] == 'sensevoice-small-int8' &&
        manifest['version'] == 1;
  }

  Future<bool> isReady() async => await installedPath() != null;

  Future<T> _operation<T>(Future<T> Function() run) async {
    if (_busy) throw const LedgerException('语音模型正在处理，请稍后');
    _busy = true;
    try {
      return await run();
    } finally {
      _busy = false;
    }
  }

  Future<void> download({
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
  }) => _operation(() async {
    if (!supported) throw const LedgerException('本地语音识别目前仅支持 Android');
    final root = await directory();
    await root.create(recursive: true);
    final stage = await root.createTemp('.download-');
    try {
      final downloads = Directory(p.join(stage.path, 'downloads'));
      final models = Directory(p.join(stage.path, 'models'));
      await downloads.create();
      await models.create();
      var complete = 0;
      final archive = File(p.join(downloads.path, bundle.archive.name));
      await _downloadOne(
        bundle.archive,
        archive,
        complete,
        bundle.downloadBytes,
        onProgress,
        cancelled,
      );
      complete += bundle.archive.bytes;
      final vad = File(p.join(downloads.path, bundle.vad.name));
      await _downloadOne(
        bundle.vad,
        vad,
        complete,
        bundle.downloadBytes,
        onProgress,
        cancelled,
      );
      if (cancelled?.call() ?? false) {
        throw const LedgerException('语音模型下载已取消');
      }
      await installer(archive.path, vad.path, models.path);
      await _validateInstalled(stage);
      await File(p.join(stage.path, 'model.json')).writeAsString(
        jsonEncode({
          'version': 1,
          'engine': 'sherpa-onnx',
          'model': 'sensevoice-small-int8',
          'vad': 'silero-vad-int8',
        }),
        flush: true,
      );
      if (await downloads.exists()) await downloads.delete(recursive: true);
      await _commit(stage);
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  });

  Future<void> _downloadOne(
    SpeechModelFile spec,
    File target,
    int complete,
    int total,
    void Function(int, int)? onProgress,
    bool Function()? cancelled,
  ) async {
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in fetcher(
        Uri.parse(spec.url),
      ).timeout(const Duration(seconds: 45))) {
        if (cancelled?.call() ?? false) {
          throw const LedgerException('语音模型下载已取消');
        }
        received += chunk.length;
        if (received > spec.bytes) {
          throw const LedgerException('语音模型文件大小不符，下载已取消');
        }
        sink.add(chunk);
        onProgress?.call(complete + received, total);
      }
    } finally {
      await sink.close();
    }
    if (received != spec.bytes || await _digest(target) != spec.sha256) {
      throw const LedgerException('语音模型校验失败，请检查网络后重新下载');
    }
  }

  Future<void> _validateInstalled(Directory root) async {
    final models = Directory(p.join(root.path, 'models'));
    await _validate(
      File(p.join(models.path, 'model.int8.onnx')),
      bundle.modelBytes,
      bundle.modelSha256,
    );
    await _validate(
      File(p.join(models.path, 'tokens.txt')),
      bundle.tokensBytes,
      bundle.tokensSha256,
    );
    await _validate(
      File(p.join(models.path, bundle.vad.name)),
      bundle.vad.bytes,
      bundle.vad.sha256,
    );
  }

  Future<void> _validate(File file, int bytes, String hash) async {
    if (!await file.exists() ||
        await file.length() != bytes ||
        await _digest(file) != hash) {
      throw const LedgerException('语音模型缺失或损坏，请重新下载');
    }
  }

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

  Future<void> _commit(Directory stage) async {
    final active = await _active();
    Directory? old;
    if (await active.exists()) {
      old = await active.rename(
        '${active.path}.old-${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    try {
      await stage.rename(active.path);
    } catch (_) {
      if (old != null) await old.rename(active.path);
      rethrow;
    }
    try {
      await old?.delete(recursive: true);
    } catch (_) {
      // The active, fully verified bundle remains usable.
    }
  }

  Future<void> remove() => _operation(() async {
    final active = await _active();
    if (await active.exists()) await active.delete(recursive: true);
  });
}

Stream<List<int>> fetchSpeechModel(Uri url) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 20));
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw const LedgerException('语音模型下载失败，请检查网络后重试');
    }
    yield* response;
  } finally {
    client.close(force: true);
  }
}

Future<void> installSpeechModelNative(
  String archivePath,
  String vadPath,
  String outputPath,
) async {
  try {
    await const MethodChannel('smart_ledger/speech').invokeMethod<void>(
      'installModel',
      {
        'archivePath': archivePath,
        'vadPath': vadPath,
        'outputPath': outputPath,
      },
    );
  } on MissingPluginException {
    throw const LedgerException('本地语音模型安装目前仅支持 Android');
  } on PlatformException catch (error) {
    throw LedgerException(error.message ?? '语音模型安装失败，请重新下载');
  }
}
