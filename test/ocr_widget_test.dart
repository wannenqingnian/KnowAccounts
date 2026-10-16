import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/main.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/ocr_page.dart';
import 'package:smart_ledger/ocr/ocr_service.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

class TestImagePicker extends FilePicker {
  TestImagePicker(this.path);
  final String path;
  bool cancelled = false;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => cancelled
      ? null
      : FilePickerResult([
          PlatformFile(
            name: 'payment.png',
            path: path,
            size: await File(path).length(),
          ),
        ]);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testWidgets(
    'models are optional; explicit download then OCR creates a pending editable expense',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();

      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ocr-widget-'),
      ))!;

      final payload = [1, 2, 3, 4];
      final hash = Sha256()
          .toSync()
          .hashSync(payload)
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      var downloads = 0, recognitions = 0;
      final service = OcrService(
        directory: () async => dir,
        models: [OcrModel('chi_sim', 4, hash), OcrModel('eng', 4, hash)],
        platformSupported: true,
        fetcher: (_) {
          downloads++;
          return Stream.value(payload);
        },
        recognizer: (_, _, _) async {
          recognitions++;
          return File('test/fixtures/ocr-payment.txt').readAsString();
        },
      );
      final picker = TestImagePicker(
        File('test/fixtures/ocr-payment.png').absolute.path,
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
            ocrFilePickerProvider.overrideWithValue(picker),
          ],
          child: const SmartLedgerApp(),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
        await tester.pumpAndSettle();
      }

      await settle();
      await tester.tap(find.text('管理'));
      await settle();
      await tester.tap(find.text('OCR模型与图片导入'));
      await settle();
      expect(downloads, 0);
      expect(recognitions, 0);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('ocr_pick_image')))
            .onPressed,
        isNull,
      );
      await tester.runAsync(() => tester.tap(find.textContaining('下载模型 ·')));
      await settle();
      expect(downloads, 2);
      expect(find.textContaining('模型已就绪，可离线识别'), findsOneWidget);
      picker.cancelled = true;
      await tester.ensureVisible(find.byKey(const ValueKey('ocr_pick_image')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('ocr_pick_image'))),
      );
      await settle();
      expect(recognitions, 0);
      expect(await repo.pendingDrafts('personal'), isEmpty);
      picker.cancelled = false;
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('ocr_pick_image'))),
      );
      await settle();
      expect(find.text('核对识别文字'), findsOneWidget);
      expect(recognitions, 1);
      expect(await repo.entries('personal'), isEmpty);
      // Users can correct OCR text before generating the persisted draft.
      await tester.enterText(
        find.byKey(const ValueKey('smart_input_text')),
        '支付宝付款38.60元 瑞幸咖啡 咖啡',
      );
      await tester.ensureVisible(find.text('生成账单草稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成账单草稿'));
      await settle();
      final pending = (await repo.pendingDrafts('personal')).single;
      expect(pending.raw.source, TransactionSource.ocr);
      expect(pending.raw.text, contains('38.60'));
      expect(await repo.entries('personal'), isEmpty);
      await tester.ensureVisible(find.text('核对并记账'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并记账'));
      await settle();
      await tester.ensureVisible(find.text('保存账目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存账目'));
      await settle();
      expect((await repo.entries('personal')).single.amountMinor, 3860);
      expect(await repo.pendingDrafts('personal'), isEmpty);
      expect(recognitions, 1);
      expect(downloads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets('a default account can be edited from its own card', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    final repo = LedgerRepository(db);
    await repo.initialize();
    final account = (await repo.accounts(
      'personal',
    )).firstWhere((a) => a.kind == AccountKind.bank);
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('账户').last);
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('account_row_${account.id}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.drag(row, const Offset(-180, 0));
    await tester.pumpAndSettle();
    final edit = find.byKey(ValueKey('edit_account_${account.id}'));
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('编辑账户'),
      ),
      findsOneWidget,
    );
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '账户名称',
    );
    final balance = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '当前余额',
    );
    await tester.enterText(name, '我的工资卡');
    await tester.enterText(balance, '1234.56');
    await tester.tap(find.text('保存账户'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    final updated = (await repo.accounts(
      'personal',
    )).firstWhere((a) => a.id == account.id);
    expect(updated.name, '我的工资卡');
    expect(updated.balanceMinor, 123456);
    expect(await repo.entries('personal'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
