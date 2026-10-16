import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/security/source_privacy.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/ocr/ocr_text_selector.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  final models = Platform.environment['PPOCR_REFERENCE_MODELS'];
  final tier = Platform.environment['PPOCR_TIER'] ?? 'balanced';
  final shaxian = Platform.environment['RECEIPT_IMAGE'];
  final cases = [
    ('test/fixtures/ocr-receipts/order.png', 3120, '远方咖啡店', 'ali'),
    ('test/fixtures/ocr-receipts/retail.png', 3250, '', 'wx'),
    ('test/fixtures/ocr-receipts/bank.png', 123456, '城市书店', 'cmb'),
  ];
  if (shaxian != null) cases.add((shaxian, 1600, '精品沙县小吃', 'wx'));
  for (final c in cases) {
    test(
      'PP-OCR $tier detection, recognition and receipt parsing: ${c.$1.split('/').last}',
      () async {
        final result = await Process.run('python3', [
          'tool/paddle_ocr_reference.py',
          c.$1,
          models!,
          tier,
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final variants =
            ((jsonDecode(result.stdout.toString()) as Map)['texts'] as List)
                .cast<String>();
        final text = selectOcrText(variants);
        final d = TransactionParser().parse(
          RawTransaction(
            text: sanitizeSourceText(text),
            source: TransactionSource.ocr,
            capturedAt: DateTime(2026, 10, 5),
          ),
          ledgerId: 'personal',
          accounts: const [
            Account(
              id: 'wx',
              name: '微信',
              kind: AccountKind.wechat,
              openingMinor: 0,
              balanceMinor: 0,
            ),
            Account(
              id: 'ali',
              name: '支付宝',
              kind: AccountKind.alipay,
              openingMinor: 0,
              balanceMinor: 0,
            ),
            Account(
              id: 'cmb',
              name: '招商银行',
              kind: AccountKind.bank,
              bankId: 'cmb',
              cardLast4: '1234',
              openingMinor: 0,
              balanceMinor: 0,
            ),
          ],
          categories: const [],
        );
        expect(d.amountMinor, c.$2);
        expect(d.accountId, c.$4);
        expect(d.blocked, isFalse);
        if (c.$3.isNotEmpty) expect(d.merchant, c.$3);
        expect(d.occurredDate, DateTime(2026, 10, 3));
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: models == null ? 'Provide separately downloaded OCR models' : false,
    );
  }
}
