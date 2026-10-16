import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/core/security/source_privacy.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  final image = Platform.environment['RECEIPT_IMAGE'];
  final models = Platform.environment['OCR_REFERENCE_MODELS'];
  for (final mode in [
    ('light', 'chi_sim', ''),
    ('balanced', 'chi_sim+eng', ''),
    ('accurate', 'chi_sim+eng', '/best'),
  ]) {
    test(
      'real ${mode.$1} OCR reads the supplied WeChat bicycle receipt',
      () async {
        final db = AppDatabase.memory();
        try {
          final repo = LedgerRepository(db);
          await repo.initialize();
          final result = await Process.run('tesseract', [
            image!,
            'stdout',
            '--tessdata-dir',
            '$models${mode.$3}',
            '-l',
            mode.$2,
            '--psm',
            '11',
          ]);
          expect(result.exitCode, 0);
          final draft = TransactionParser().parse(
            RawTransaction(
              text: sanitizeSourceText(result.stdout.toString()),
              capturedAt: DateTime(2026, 10, 5),
              source: TransactionSource.ocr,
            ),
            ledgerId: 'personal',
            accounts: await repo.accounts('personal'),
            categories: await repo.categories('personal'),
          );
          expect(draft.amountMinor, 350);
          expect(draft.merchant, '松果出行');
          expect(draft.blocked, isFalse);
          expect(draft.occurredDate, DateTime(2026, 10, 4));
          expect(
            (await repo.accounts(
              'personal',
            )).firstWhere((a) => a.id == draft.accountId).kind,
            AccountKind.wechat,
          );
          expect(
            (await repo.categories(
              'personal',
            )).firstWhere((c) => c.id == draft.categoryId).name,
            '交通',
          );
          final id = await repo.storeDraft(draft);
          expect(await repo.entries('personal'), isEmpty);
          await repo.confirmDraft(
            'personal',
            id,
            TransactionInput(
              type: draft.type,
              amountMinor: draft.amountMinor!,
              accountId: draft.accountId!,
              categoryId: draft.categoryId,
              occurredDate: draft.occurredDate,
              merchant: draft.merchant,
            ),
          );
          expect((await repo.entries('personal')).single.amountMinor, 350);
        } finally {
          await db.close();
        }
      },
      skip: image == null || models == null
          ? 'Provide a local authorized screenshot and separately downloaded models'
          : false,
    );
  }
}
