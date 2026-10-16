import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/automation/capture_bridge.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/features/ocr_page.dart';
import 'package:smart_ledger/features/smart_input.dart';
import 'package:smart_ledger/features/transaction_editor.dart';
import 'package:smart_ledger/main.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/ocr/ocr_service.dart';

Future<void> settleIO(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  await tester.pumpAndSettle();
}

// Model hashes are covered by ocr_service_test. Keep filesystem stream hashing
// out of the fake-clock lifecycle test; retain the actual download operation.
class CaptureTestService extends OcrService {
  CaptureTestService({
    required super.directory,
    required super.models,
    required super.fetcher,
    super.recognizer,
    super.detailedRecognizer,
  }) : super(platformSupported: true);
  bool ready = false;
  @override
  Future<OcrTier?> installedTier() async => ready ? tiers.first : null;
  @override
  Future<void> download({
    String tierId = 'balanced',
    void Function(int, int)? onProgress,
    bool Function()? cancelled,
  }) async {
    await super.download(
      tierId: tierId,
      onProgress: onProgress,
      cancelled: cancelled,
    );
    ready = true;
  }
}

class PendingCaptureBridge extends CaptureBridge {
  PendingCaptureBridge(this.pending);
  CapturedScreenshot? pending;
  int starts = 0;
  @override
  Future<bool> startCapture() async {
    starts++;
    return true;
  }

  @override
  void listen(Future<void> Function() available) {}
  @override
  void dispose() {}
  @override
  Future<CapturedScreenshot?> takePending() async {
    final next = pending;
    pending = null;
    return next;
  }
}

void main() {
  testWidgets(
    'add menu screenshot action starts capture without a home toolbar icon',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final bridge = PendingCaptureBridge(null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            captureBridgeProvider.overrideWithValue(bridge),
          ],
          child: const SmartLedgerApp(),
        ),
      );
      await settleIO(tester);
      expect(find.byTooltip('截图记账'), findsNothing);
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OCR截图记账'));
      await settleIO(tester);
      expect(bridge.starts, 1);
      expect(find.byType(OcrPage), findsNothing);
      expect(await repo.entries('personal'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  for (final duplicate in [false, true]) {
    testWidgets(
      'complete scored capture ${duplicate ? 'holds duplicate for review' : 'auto posts and supports undo'}',
      (tester) async {
        final db = AppDatabase.memory();
        final repo = LedgerRepository(db);
        await repo.initialize();
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('capture-auto-'),
        ))!;
        final shot = File('${dir.path}/shot.png');
        await tester.runAsync(() => shot.writeAsBytes([1, 2, 3]));
        const text =
            '付款成功\n商户名称 瑞幸咖啡\n实付金额 38.50元\n付款方式 微信\n支付时间 2026-10-03 12:20';
        final lines = text
            .split('\n')
            .indexed
            .map((p) => OcrTextLine(p.$2, .99, p.$1 * 30))
            .toList();
        final service = CaptureTestService(
          directory: () async => dir,
          models: const [],
          fetcher: (_) => const Stream.empty(),
          detailedRecognizer: (_, _, _) async =>
              OcrRecognition(text, lines: lines),
        );
        service.ready = true;
        if (duplicate) {
          final draft = TransactionParser().parse(
            RawTransaction(
              text: text,
              source: TransactionSource.ocr,
              capturedAt: DateTime(2026, 10, 5),
            ),
            ledgerId: 'personal',
            accounts: await repo.accounts('personal'),
            categories: await repo.categories('personal'),
          );
          await repo.save(
            'personal',
            TransactionInput(
              type: draft.type,
              amountMinor: draft.amountMinor!,
              accountId: draft.accountId!,
              categoryId: draft.categoryId,
              merchant: draft.merchant,
              occurredDate: draft.occurredDate,
            ),
          );
        }
        final bridge = PendingCaptureBridge(
          CapturedScreenshot(shot.path, DateTime(2026, 10, 5)),
        );
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWithValue(repo),
              ocrServiceProvider.overrideWithValue(service),
              captureBridgeProvider.overrideWithValue(bridge),
            ],
            child: const SmartLedgerApp(),
          ),
        );
        await settleIO(tester);
        expect(await repo.entries('personal'), hasLength(1));
        if (duplicate) {
          expect(find.byType(TransactionEditor), findsOneWidget);
          expect(await repo.pendingDrafts('personal'), hasLength(1));
          expect(find.textContaining('疑似已有同日'), findsOneWidget);
        } else {
          expect(find.byType(TransactionEditor), findsNothing);
          expect(find.byType(OcrPage), findsNothing);
          expect(await repo.pendingDrafts('personal'), isEmpty);
          expect(find.textContaining('已自动记账'), findsOneWidget);
          expect(await tester.runAsync(() => shot.exists()), isFalse);
          await tester.tap(find.text('撤销'));
          await settleIO(tester);
          expect(await repo.entries('personal'), isEmpty);
        }
        await tester.pumpWidget(const SizedBox());
        await db.close();
        await tester.runAsync(() => dir.delete(recursive: true));
      },
    );
  }

  for (final ready in [true, false]) {
    testWidgets(
      'tile handoff with model ${ready ? "ready auto recognizes" : "missing waits for explicit download"}',
      (tester) async {
        final db = AppDatabase.memory();
        final repo = LedgerRepository(db);
        await repo.initialize();
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('capture-widget-'),
        ))!;
        final shot = File('${dir.path}/shot.png');
        await tester.runAsync(() => shot.writeAsBytes([1, 2, 3]));
        final payload = [1, 2, 3, 4];
        final hash = Sha256()
            .toSync()
            .hashSync(payload)
            .bytes
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        var downloads = 0, recognitions = 0;
        final service = CaptureTestService(
          directory: () async => dir,
          models: [OcrModel('chi_sim', 4, hash), OcrModel('eng', 4, hash)],
          fetcher: (_) {
            downloads++;
            return Stream.value(payload);
          },
          recognizer: (_, _, _) async {
            recognitions++;
            return '支付宝付款成功\n金额 ¥38.50\n收款商户：瑞幸咖啡\n付款方式 支付宝';
          },
        );
        if (ready) await tester.runAsync(() => service.download());
        downloads = 0;
        final time = DateTime(2026, 10, 5, 12, 30);
        final bridge = PendingCaptureBridge(
          CapturedScreenshot(shot.path, time),
        );
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(
          () => tester.pumpWidget(
            ProviderScope(
              overrides: [
                repositoryProvider.overrideWithValue(repo),
                ocrServiceProvider.overrideWithValue(service),
                captureBridgeProvider.overrideWithValue(bridge),
              ],
              child: const SmartLedgerApp(),
            ),
          ),
        );
        await settleIO(tester);
        expect(find.byType(OcrPage), findsOneWidget);
        expect(downloads, 0);
        if (!ready) {
          expect(recognitions, 0);
          expect(find.byType(SmartInputSheet), findsNothing);
          expect(find.text('已收到截图'), findsOneWidget);
          final download = find.text('下载模型 · 0.0MB');
          await tester.ensureVisible(download);
          await tester.pumpAndSettle();
          await tester.runAsync(() => tester.tap(download));
          await settleIO(tester);
          expect(downloads, 2);
        }
        expect(recognitions, 1);
        expect(find.byType(TransactionEditor), findsOneWidget);
        expect(find.byType(SmartInputSheet), findsNothing);
        expect(find.text('38.50'), findsOneWidget);
        expect(await repo.entries('personal'), isEmpty);
        final pending = await repo.pendingDrafts('personal');
        expect(pending, hasLength(1));
        expect(pending.single.raw.capturedAt, time);
        expect(tester.takeException(), isNull);
        // Dismissing OCR does not post the draft and deletes the private screenshot.
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        navigator.pop();
        await settleIO(tester);
        // Retrying the same screenshot updates the existing pending draft.
        final retry = find.text('重新识别这张截图');
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(retry));
        await settleIO(tester);
        expect(
          (await repo.pendingDrafts('personal')).single.id,
          pending.single.id,
        );
        expect(recognitions, 2);
        if (ready) {
          final tags = find.byKey(const ValueKey('transaction_tags'));
          await tester.ensureVisible(tags);
          await tester.pumpAndSettle();
          await tester.enterText(tags, '通勤');
          await tester.ensureVisible(find.text('保存账目'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存账目'));
          await settleIO(tester);
          expect((await repo.entries('personal')).single.tags, ['通勤']);
          expect(await repo.pendingDrafts('personal'), isEmpty);
          expect(find.text('该截图已处理'), findsOneWidget);
        } else {
          navigator.pop();
          await settleIO(tester);
        }
        navigator.pop();
        await settleIO(tester);
        expect(await tester.runAsync(() => shot.exists()), isFalse);
        expect(await repo.pendingDrafts('personal'), hasLength(ready ? 0 : 1));
        await tester.pumpWidget(const SizedBox());
        await db.close();
        await tester.runAsync(() => dir.delete(recursive: true));
      },
    );
  }
}
