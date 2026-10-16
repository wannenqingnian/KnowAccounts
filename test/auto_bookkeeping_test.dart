import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/auto_bookkeeping.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/ocr/ocr_service.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

const receipt =
    '精品沙县小吃\n交易详情\n-16.00\n精品沙县小吃\n当前状态 支付成功\n支付方式 零钱\n支付时间 2026年10月03日 12:05:15';
OcrRecognition scored(String text, {double score = .99}) => OcrRecognition(
  text,
  lines: text
      .split('\n')
      .indexed
      .map((p) => OcrTextLine(p.$2, score, p.$1 * 30))
      .toList(),
);

void main() {
  late AppDatabase db;
  late LedgerRepository repo;
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
  });
  tearDown(() => db.close());
  Future<TransactionDraft> parse(String text) async =>
      TransactionParser().parse(
        RawTransaction(
          text: text,
          source: TransactionSource.ocr,
          capturedAt: DateTime(2026, 10, 5),
        ),
        ledgerId: 'personal',
        accounts: await repo.accounts('personal'),
        categories: await repo.categories('personal'),
      );
  TransactionInput input(TransactionDraft d) => TransactionInput(
    type: d.type,
    amountMinor: d.amountMinor!,
    accountId: d.accountId!,
    categoryId: d.categoryId,
    merchant: d.merchant,
    occurredDate: d.occurredDate,
  );

  test(
    'a clear, completed bill with a repeated unknown merchant can auto post',
    () async {
      expect(canAutoBookkeep(await parse(receipt), scored(receipt)), isTrue);
    },
  );
  test(
    'missing scores, low scores and missing required fields never auto post',
    () async {
      final draft = await parse(receipt);
      expect(canAutoBookkeep(draft, const OcrRecognition(receipt)), isFalse);
      expect(canAutoBookkeep(draft, scored(receipt, score: .70)), isFalse);
      expect(
        canAutoBookkeep(draft, scored(receipt, score: double.nan)),
        isFalse,
      );
      for (final text in [
        receipt.replaceAll('支付方式 零钱', ''),
        receipt.replaceAll('支付时间 2026年10月03日 12:05:15', ''),
        receipt.replaceAll('-16.00', ''),
      ]) {
        expect(canAutoBookkeep(await parse(text), scored(text)), isFalse);
      }
    },
  );
  test(
    'corrected or conflicting dates, future dates, refunds and multi-bill text require review',
    () async {
      for (final text in [
        receipt.replaceAll('2026年10月03日 12:05:15', '2026年1003日12:05:15'),
        receipt.replaceAll('2026年10月03日', '2027年10月03日'),
        '$receipt\n日期校验：不一致',
        '$receipt\n金额校验：不一致',
        receipt.replaceAll('支付成功', '退款成功'),
        '$receipt\n$receipt',
      ]) {
        expect(
          canAutoBookkeep(await parse(text), scored(text)),
          isFalse,
          reason: text,
        );
      }
    },
  );
  test(
    'uncertain footer buttons do not count as bill data but an uncertain price does',
    () async {
      final result = OcrRecognition(
        receipt,
        lines: [
          ...scored(receipt).lines,
          const OcrTextLine('交易服务', .95, 500),
          const OcrTextLine('对订单有疑惑', .55, 550),
        ],
      );
      expect(canAutoBookkeep(await parse(receipt), result), isTrue);
      final lowPrice = OcrRecognition(
        receipt,
        lines: scored(receipt).lines
            .map(
              (line) => line.text == '-16.00'
                  ? OcrTextLine(line.text, .55, line.top)
                  : line,
            )
            .toList(),
      );
      expect(canAutoBookkeep(await parse(receipt), lowPrice), isFalse);
    },
  );
  test(
    'independent repeated screenshots cannot auto create two postings; a held draft stays manually editable',
    () async {
      final draft = await parse(receipt);
      final first = await repo.storeDraft(draft),
          second = await repo.storeDraft(draft);
      final results = await Future.wait([
        repo.autoConfirmDraft('personal', first, input(draft)),
        repo.autoConfirmDraft('personal', second, input(draft)),
      ]);
      expect(results.whereType<String>(), hasLength(1));
      expect(results.where((r) => r == null), hasLength(1));
      expect(await repo.entries('personal'), hasLength(1));
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((a) => a.id == draft.accountId).balanceMinor,
        -1600,
      );
      final postedId = results[0] != null ? first : second;
      expect(
        await repo.autoConfirmDraft('personal', postedId, input(draft)),
        results.whereType<String>().single,
      );
      final held = (await repo.pendingDrafts('personal')).single;
      await repo.confirmDraft('personal', held.id, input(draft));
      expect(await repo.entries('personal'), hasLength(2));
    },
  );
  test(
    'source-link failure leaves no automatic transaction or balance change',
    () async {
      final draft = await parse(receipt),
          id = await repo.storeDraft(await parse(receipt));
      await db.customStatement(
        "CREATE TRIGGER reject_auto_link BEFORE UPDATE ON transaction_drafts WHEN NEW.status='posted' BEGIN SELECT RAISE(ABORT,'link failure'); END",
      );
      await expectLater(
        repo.autoConfirmDraft('personal', id, input(draft)),
        throwsA(anything),
      );
      expect(await repo.entries('personal'), isEmpty);
      expect(await repo.pendingDrafts('personal'), hasLength(1));
      expect(
        (await repo.accounts('personal')).every((a) => a.balanceMinor == 0),
        isTrue,
      );
    },
  );
}
