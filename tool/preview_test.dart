import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/main.dart';
import 'package:smart_ledger/ocr/ocr_service.dart';

void main() {
  testWidgets('capture real Flutter overview with isolated sample data', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    final repo = LedgerRepository(db);
    await repo.initialize();
    final accounts = await repo.accounts('personal');
    final categories = await repo.categories('personal');
    final now = DateTime.now();
    for (final sample in [
      ('瑞幸咖啡', '咖啡', 3850),
      ('地铁出行', '公交地铁', 600),
      ('午间便当', '午餐', 2800),
    ]) {
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: sample.$3,
          accountId: accounts[2].id,
          categoryId: categories.firstWhere((c) => c.name == sample.$2).id,
          merchant: sample.$1,
          occurredDate: now,
        ),
      );
    }
    await repo.save(
      'personal',
      TransactionInput(
        type: TransactionType.income,
        amountMinor: 1200000,
        accountId: accounts[1].id,
        categoryId: categories.firstWhere((c) => c.name == '工资').id,
        occurredDate: now,
      ),
    );
    await repo.setBudget('personal', now, 500000);
    await repo.addAccount(
      'personal',
      '招商银行 4567',
      AccountKind.bank,
      100000,
      bankId: 'cmb',
      cardLast4: '4567',
    );
    await repo.addAccount(
      'personal',
      '花呗',
      AccountKind.creditPayment,
      -5680,
      providerId: 'huabei',
      repaymentDay: 9,
    );
    await repo.addAccount(
      'personal',
      '京东白条',
      AccountKind.creditPayment,
      -21000,
      providerId: 'baitiao',
      repaymentDay: 15,
    );
    final fontPath = Platform.environment['PREVIEW_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        final fontData = await File(fontPath).readAsBytes();
        final loader = FontLoader('PreviewSans')
          ..addFont(Future.value(ByteData.sublistView(fontData)));
        await loader.load();
        final iconPath = Platform.environment['PREVIEW_ICONS'];
        if (iconPath != null) {
          final icons = await File(iconPath).readAsBytes();
          await (FontLoader(
            'MaterialIcons',
          )..addFont(Future.value(ByteData.sublistView(icons)))).load();
        }
      });
    }
    final key = GlobalKey();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final layout in [
      ('desktop', const Size(1440, 1040)),
      ('mobile', const Size(430, 1100)),
    ]) {
      tester.view.physicalSize = layout.$2;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWithValue(repo),
            ocrServiceProvider.overrideWithValue(
              OcrService(
                directory: () async => Directory(
                  '${Directory.systemTemp.path}/ledger-empty-model-preview',
                ),
                platformSupported: true,
              ),
            ),
          ],
          child: RepaintBoundary(
            key: key,
            child: const SmartLedgerApp(fontFamily: 'PreviewSans'),
          ),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'docs/previews/${layout.$1}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      if (layout.$1 == 'mobile') {
        await tester.tap(find.byTooltip('一句话记账'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('smart_input_text')),
          '昨天晚上滴滴四十二块五，支付宝付的',
        );
        await tester.tap(find.text('识别账单'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/smart-input.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tapAt(const Offset(20, 100));
        await tester.pumpAndSettle();
        await tester.tap(find.text('账户').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/credit-accounts.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('新增账户'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<AccountKind>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('贷款 / 现金借款').last);
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(390, 900);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/account-dialog.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        final bankEdit = find.byKey(ValueKey('edit_account_${accounts[1].id}'));
        await tester.ensureVisible(bankEdit);
        await tester.pumpAndSettle();
        await tester.tap(bankEdit);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/edit-account.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('分析').last);
        await tester.pumpAndSettle();
        // Scroll positions are shared by the shell across tabs.
        await tester.ensureVisible(find.text('按月'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/analysis.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.ensureVisible(find.text('分类占比').first);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/analysis-categories.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.text('总览').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('待确认账单 · 1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('待确认账单 · 1'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/review-inbox.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('截图记账'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('截图记账'));
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/ocr-models.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<String>),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/previews/ocr-tiers.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}
