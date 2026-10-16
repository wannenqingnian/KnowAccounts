import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/transaction/transaction_identity.dart';
import 'package:smart_ledger/transaction/transaction_pipeline.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repository;
  late Account account;
  late Category category;

  setUp(() async {
    db = AppDatabase.memory();
    repository = LedgerRepository(db);
    await repository.initialize();
    account = (await repository.accounts('personal')).first;
    category = (await repository.categories(
      'personal',
    )).firstWhere((item) => item.type == TransactionType.expense);
  });

  tearDown(() => db.close());

  TransactionInput input() => TransactionInput(
    type: TransactionType.expense,
    amountMinor: 1680,
    accountId: account.id,
    categoryId: category.id,
    occurredDate: DateTime(2026, 10, 15, 12, 30, 8),
    merchant: '统一管线测试商户',
  );

  test(
    'manual structured entry audits confidence and requires duplicate approval',
    () async {
      const seed = TransactionIdentitySeed(
        source: TransactionEvidenceSource.manual,
        sourceApp: 'smart_ledger.manual',
        details: {'入口': '手动表单'},
      );
      final first = await repository.submitStructuredTransaction(
        'personal',
        input(),
        identitySeed: seed,
      );
      expect(first.confidence.source, contains('manual'));

      await expectLater(
        repository.submitStructuredTransaction(
          'personal',
          input(),
          identitySeed: seed,
        ),
        throwsA(isA<PossibleDuplicateTransactionException>()),
      );
      final afterRejection = await db
          .customSelect(
            'SELECT outcome FROM learning_events ORDER BY created_at',
          )
          .get();
      expect(afterRejection.map((row) => row.read<String>('outcome')), [
        'posted',
        'duplicate',
      ]);

      await repository.submitStructuredTransaction(
        'personal',
        input(),
        identitySeed: seed,
        allowPossibleDuplicate: true,
      );
      expect((await repository.entries('personal')).length, 2);
      final approved = await db
          .customSelect(
            "SELECT details_json FROM learning_events WHERE outcome='posted' ORDER BY created_at DESC LIMIT 1",
          )
          .getSingle();
      expect(
        approved.read<String>('details_json'),
        contains('duplicate_approved'),
      );
      expect(approved.read<String>('details_json'), contains('true'));
    },
  );

  test(
    'parsed draft and confirmation emit the same learning event trail',
    () async {
      final raw = RawTransaction(
        text: '午餐 16.80 元',
        capturedAt: DateTime(2026, 10, 15, 12, 30, 8),
        source: TransactionSource.speech,
        sourceApp: 'smart_ledger.voice',
      );
      final draft = TransactionDraft(
        raw: raw,
        ledgerId: 'personal',
        type: TransactionType.expense,
        amountMinor: 1680,
        occurredDate: raw.capturedAt,
        accountId: account.id,
        categoryId: category.id,
        merchant: '午餐',
        warnings: const [],
        evidence: const {'amount': '语音字段', 'merchant': '语音字段'},
      );
      final draftId = await repository.storeDraft(draft);
      await repository.confirmDraft('personal', draftId, input());

      final events = await db
          .customSelect(
            'SELECT source_kind,outcome FROM learning_events ORDER BY created_at',
          )
          .get();
      expect(events.map((row) => row.read<String>('source_kind')).toSet(), {
        'speech',
      });
      expect(events.map((row) => row.read<String>('outcome')), [
        'draft',
        'posted',
      ]);
    },
  );

  test('manual final choices win while the matching rule is audited', () async {
    await repository.addAccount('personal', '手动指定账户', AccountKind.bank, 0);
    final otherAccountId = (await repository.accounts(
      'personal',
    )).singleWhere((item) => item.name == '手动指定账户').id;
    final otherCategoryId = await repository.addCategory(
      'personal',
      '手动指定分类',
      TransactionType.expense,
    );
    await repository.saveAutoCorrectionRule(
      'personal',
      merchantPattern: '统一管线测试商户',
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
    );
    final result = await repository.submitStructuredTransaction(
      'personal',
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: 1680,
        accountId: otherAccountId,
        categoryId: otherCategoryId,
        occurredDate: DateTime(2026, 10, 15, 13),
        merchant: '统一管线测试商户',
      ),
      identitySeed: const TransactionIdentitySeed(
        source: TransactionEvidenceSource.manual,
        sourceApp: 'smart_ledger.manual',
        details: {'入口': '手动表单'},
      ),
    );
    expect(result.input.accountId, otherAccountId);
    expect(result.input.categoryId, otherCategoryId);
    final saved = (await repository.entries('personal')).single;
    expect(saved.accountId, otherAccountId);
    expect(saved.categoryId, otherCategoryId);
    final matches = await db
        .customSelect(
          "SELECT COUNT(*) AS count FROM auto_correction_events WHERE event_type='match'",
        )
        .getSingle();
    expect(matches.read<int>('count'), 1);
  });
}
