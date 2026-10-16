import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/transaction/transaction_identity.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  late Account account;
  late Category expense;

  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    account = (await repo.accounts('personal')).first;
    expense = (await repo.categories(
      'personal',
    )).firstWhere((item) => item.type == TransactionType.expense);
  });

  tearDown(() => db.close());

  TransactionInput input({
    int amount = 2000,
    String merchant = '金冠智充',
    DateTime? date,
  }) => TransactionInput(
    type: TransactionType.expense,
    amountMinor: amount,
    accountId: account.id,
    categoryId: expense.id,
    occurredDate: date ?? DateTime(2026, 10, 11, 12, 7, 39),
    merchant: merchant,
  );

  test(
    'order number wins across import and OCR and exposes field conflicts',
    () async {
      final original = await repo.save(
        'personal',
        input(),
        identitySeed: const TransactionIdentitySeed(
          source: TransactionEvidenceSource.import,
          sourceApp: 'wechat',
          captureId: 'import-row-1',
          orderId: '4500000483202610119870382192',
        ),
      );
      final raw = RawTransaction(
        text: '微信支付\n交易单号 4500000483202610119870382192\n支付成功',
        capturedAt: DateTime(2026, 10, 11, 12, 8),
        source: TransactionSource.ocr,
        sourceApp: 'com.tencent.mm',
      );
      final draft = TransactionDraft(
        raw: raw,
        ledgerId: 'personal',
        type: TransactionType.expense,
        amountMinor: 1293,
        occurredDate: raw.capturedAt,
        accountId: account.id,
        categoryId: expense.id,
        merchant: '不同商户',
        warnings: const [],
        evidence: const {'amount': 'OCR'},
      );
      final draftId = await repo.storeDraft(draft);
      final assessment = await repo.assessDraftDuplicate(
        'personal',
        draftId,
        input(amount: 1293, merchant: '不同商户', date: raw.capturedAt),
      );
      expect(assessment.candidateTransactionId, original);
      expect(assessment.matchedByOrder, isTrue);
      expect(assessment.differences, containsAll(['金额不同', '商户不同']));
    },
  );

  test('amount alone never creates a merge candidate', () async {
    final first = await repo.save('personal', input(merchant: '早餐店'));
    final second = await repo.save(
      'personal',
      input(merchant: '便利店', date: DateTime(2026, 10, 11, 12, 8)),
    );
    expect(
      (await repo.transactionMergeCandidates(
        'personal',
        first,
      )).where((item) => item.transaction.id == second),
      isEmpty,
    );
  });

  test(
    'ordinary transaction merge preserves evidence and can be undone',
    () async {
      final first = await repo.save(
        'personal',
        input(),
        identitySeed: const TransactionIdentitySeed(
          source: TransactionEvidenceSource.notification,
          sourceApp: 'com.tencent.mm',
          captureId: 'notice-1',
        ),
      );
      final second = await repo.save(
        'personal',
        input(date: DateTime(2026, 10, 11, 12, 9)),
        identitySeed: const TransactionIdentitySeed(
          source: TransactionEvidenceSource.accessibility,
          sourceApp: 'com.tencent.mm',
          captureId: 'a11y-1',
        ),
      );
      final candidate = (await repo.transactionMergeCandidates(
        'personal',
        first,
      )).singleWhere((item) => item.transaction.id == second);
      expect(candidate.matchedByOrder, isFalse);
      expect(candidate.differences, isEmpty);

      final mergeId = await repo.mergeTransactions(
        'personal',
        targetTransactionId: first,
        sourceTransactionId: second,
      );
      expect((await repo.entries('personal')).map((item) => item.id), [first]);
      expect(
        (await repo.transactionEvidence(
          'personal',
          first,
        )).map((item) => item.source).toSet(),
        {
          TransactionEvidenceSource.notification,
          TransactionEvidenceSource.accessibility,
        },
      );

      await repo.undoTransactionMerge('personal', mergeId);
      expect((await repo.entries('personal')).map((item) => item.id).toSet(), {
        first,
        second,
      });
      expect(
        (await repo.transactionEvidence('personal', second)).single.source,
        TransactionEvidenceSource.accessibility,
      );
    },
  );

  test(
    'draft sources retain notification accessibility OCR and speech separately',
    () async {
      Future<void> add(
        TransactionSource rawSource,
        TransactionEvidenceSource source,
      ) async {
        final raw = RawTransaction(
          text: '支付成功\n订单号 ABCDEFGH1234\n金额20.00',
          capturedAt: DateTime(2026, 10, 11, 12, source.index),
          source: rawSource,
        );
        await repo.storeDraft(
          TransactionDraft(
            raw: raw,
            ledgerId: 'personal',
            type: TransactionType.expense,
            amountMinor: 2000,
            occurredDate: raw.capturedAt,
            accountId: account.id,
            categoryId: expense.id,
            merchant: '测试商户',
            warnings: const [],
            evidence: const {},
          ),
          evidenceSource: source,
          evidenceCaptureId: 'capture-${source.name}',
        );
      }

      await add(
        TransactionSource.notification,
        TransactionEvidenceSource.notification,
      );
      await add(
        TransactionSource.notification,
        TransactionEvidenceSource.accessibility,
      );
      await add(TransactionSource.ocr, TransactionEvidenceSource.ocr);
      await add(TransactionSource.speech, TransactionEvidenceSource.speech);
      final rows = await db
          .customSelect(
            'SELECT DISTINCT source_kind FROM transaction_evidence_records',
          )
          .get();
      expect(rows.map((row) => row.read<String>('source_kind')).toSet(), {
        'notification',
        'accessibility',
        'ocr',
        'speech',
      });
    },
  );
}
