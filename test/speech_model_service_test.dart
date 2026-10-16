import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:smart_ledger/speech/speech_model_service.dart';

void main() {
  test(
    'speech model is downloaded, verified and atomically installed',
    () async {
      final root = await Directory.systemTemp.createTemp('speech-model-test-');
      addTearDown(() => root.delete(recursive: true));
      const spec = SpeechModelBundle(
        archive: SpeechModelFile(
          'bundle.tar.bz2',
          7,
          '0eb3e36bfb24dcd9bb1d1bece1531216b59539a8fde17ee80224af0653c92aa3',
          'https://example.test/archive',
        ),
        vad: SpeechModelFile(
          'silero_vad.int8.onnx',
          3,
          '651bfad0aa5b42c5a5b8dad76f49c4a122fe1d1658fc55cfdd1ea9923fe3fd9e',
          'https://example.test/vad',
        ),
        modelBytes: 5,
        modelSha256:
            '9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4',
        tokensBytes: 6,
        tokensSha256:
            'c51e455b41df6c017327e16001dd064b8b6733faeaa69b23d9bd79c8079237d5',
      );
      final progress = <int>[];
      final service = SpeechModelService(
        directory: () async => root,
        bundle: spec,
        platformSupported: true,
        fetcher: (url) async* {
          yield url.path.endsWith('archive')
              ? 'archive'.codeUnits
              : 'vad'.codeUnits;
        },
        installer: (archive, vad, output) async {
          expect(await File(archive).readAsString(), 'archive');
          await File(p.join(output, 'model.int8.onnx')).writeAsString('model');
          await File(p.join(output, 'tokens.txt')).writeAsString('tokens');
          await File(vad).copy(p.join(output, 'silero_vad.int8.onnx'));
        },
      );

      await service.download(
        onProgress: (received, _) => progress.add(received),
      );
      final installed = await service.installedPath();
      expect(installed, p.join(root.path, 'active-v1'));
      expect(progress.last, spec.downloadBytes);
      expect(await File(p.join(installed!, 'model.json')).exists(), isTrue);

      // The recording hot path checks metadata and file sizes only. Full
      // integrity verification remains available to model management/self-test.
      await File(
        p.join(installed, 'models', 'model.int8.onnx'),
      ).writeAsString('xxxxx');
      expect(await service.recordingPath(), installed);
      expect(await service.installedPath(), isNull);

      await service.remove();
      expect(await service.isReady(), isFalse);
    },
  );

  test(
    'corrupt downloads are rejected without replacing active model',
    () async {
      final root = await Directory.systemTemp.createTemp('speech-model-bad-');
      addTearDown(() => root.delete(recursive: true));
      final service = SpeechModelService(
        directory: () async => root,
        bundle: senseVoiceSmallBundle,
        platformSupported: true,
        fetcher: (_) async* {
          yield [1, 2, 3];
        },
        installer: (_, _, _) async {},
      );
      await expectLater(service.download(), throwsA(isA<Exception>()));
      expect(await service.isReady(), isFalse);
    },
  );
}
