import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/ocr/ocr_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final reference = Platform.environment['OCR_REFERENCE_MODELS'];
  for (final tier in ocrTiers) {
    test(
      'real ${tier.name} models recognize a synthetic payment image and confirm one correct expense',
      () async {
        final root = await Directory.systemTemp.createTemp('ocr-real-');
        final db = AppDatabase.memory();
        try {
          final service = OcrService(
            directory: () async => root,
            recognizer: (image, models, languages) async {
              final result = await Process.run('tesseract', [
                image,
                'stdout',
                '--tessdata-dir',
                '$models/tessdata',
                '-l',
                languages,
                '--oem',
                '1',
                '--psm',
                '11',
              ]);
              expect(result.exitCode, 0, reason: result.stderr.toString());
              return result.stdout.toString();
            },
          );
          expect(await service.isReady(), isFalse);
          await service.importFiles({
            for (final model in tier.models)
              model.fileName: File(
                '${tier.id == 'accurate' ? '$reference/best' : reference}/${model.fileName}',
              ),
          }, tierId: tier.id);
          expect(await service.isReady(), isTrue);
          final text = await service.recognize(
            File('test/fixtures/ocr-payment.png').absolute.path,
          );
          if (tier.id != 'light') expect(text, contains('38.50'));
          expect(RegExp(r'瑞\s*幸\s*咖\s*啡').hasMatch(text), isTrue);
          final repo = LedgerRepository(db);
          await repo.initialize();
          var draft = TransactionParser().parse(
            RawTransaction(
              text: text,
              capturedAt: DateTime(2026, 10, 5),
              source: TransactionSource.ocr,
            ),
            ledgerId: 'personal',
            accounts: await repo.accounts('personal'),
            categories: await repo.categories('personal'),
          );
          if (tier.id == 'light') {
            // The lightweight model genuinely misreads this synthetic currency
            // line. Require a user correction, never silently repair money.
            expect(draft.amountMinor, isNull);
            draft = TransactionParser().parse(
              RawTransaction(
                text: text.replaceAll('半38.250', '¥38.50'),
                capturedAt: DateTime(2026, 10, 5),
                source: TransactionSource.ocr,
              ),
              ledgerId: 'personal',
              accounts: await repo.accounts('personal'),
              categories: await repo.categories('personal'),
            );
          }
          expect(draft.amountMinor, 3850);
          expect(draft.merchant, '瑞幸咖啡');
          expect(draft.blocked, isFalse);
          final id = await repo.storeDraft(draft);
          expect(await repo.entries('personal'), isEmpty);
          expect(
            (await repo.pendingDrafts('personal')).single.raw.source,
            TransactionSource.ocr,
          );
          await repo.confirmDraft(
            'personal',
            id,
            TransactionInput(
              type: draft.type,
              amountMinor: draft.amountMinor!,
              accountId: draft.accountId!,
              categoryId: draft.categoryId,
              merchant: draft.merchant,
              occurredDate: draft.occurredDate,
            ),
          );
          final e = (await repo.entries('personal')).single;
          expect(e.amountMinor, 3850);
          expect(e.accountName, '支付宝');
          expect(e.categoryName, '咖啡');
        } finally {
          await db.close();
          await root.delete(recursive: true);
        }
      },
      skip: reference == null
          ? 'Set OCR_REFERENCE_MODELS to downloaded reference models'
          : false,
    );
  }
}
