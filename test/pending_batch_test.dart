import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/family_payment.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/pending_batch.dart';
import 'package:smart_ledger/features/review_inbox.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

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

  TransactionDraft draft({
    int second = 0,
    String merchant = '早餐店',
    String? familyEventId,
  }) {
    final raw = RawTransaction(
      text: '支付成功\n早餐店\n20.00元',
      capturedAt: DateTime(2026, 10, 15, 8, 30, second),
      source: TransactionSource.ocr,
      sourceApp: 'com.example.pay',
    );
    return TransactionDraft(
      raw: raw,
      ledgerId: 'personal',
      type: TransactionType.expense,
      amountMinor: 2000,
      occurredDate: raw.capturedAt,
      accountId: account.id,
      categoryId: category.id,
      merchant: merchant,
      warnings: const [],
      evidence: const {'amount': '20.00'},
      familyEventId: familyEventId,
      familyRole: familyEventId == null ? null : FamilyLocalRole.payer,
    );
  }

  test(
    'batch preview explains skips and persisted edits survive reload',
    () async {
      final editable = await repository.storeDraft(draft());
      final family = await repository.storeDraft(
        draft(second: 1, merchant: '亲情卡消费', familyEventId: 'family-event'),
      );
      final replacement = (await repository.accounts(
        'personal',
      )).firstWhere((item) => item.id != account.id);
      final patch = PendingDraftBatchPatch(
        accountId: replacement.id,
        categoryId: category.id,
        tags: const ['早餐', '报销', '早餐'],
      );

      final preview = await repository.previewPendingDraftBatch('personal', [
        editable,
        family,
      ], patch);
      expect(preview.requested, 2);
      expect(preview.eligible, 1);
      expect(preview.skipped, 1);
      expect(
        preview.items.singleWhere((item) => item.draftId == family).skipReason,
        contains('亲情卡'),
      );

      final result = await repository.applyPendingDraftBatch('personal', [
        editable,
        family,
      ], patch);
      expect(result.eligible, 1);
      final pending = await repository.pendingDrafts('personal');
      final edited = pending.singleWhere((item) => item.id == editable);
      expect(edited.batchAccountId, replacement.id);
      expect(edited.batchCategoryId, category.id);
      expect(edited.batchTags, ['早餐', '报销']);
      expect(
        pending.singleWhere((item) => item.id == family).batchTags,
        isNull,
      );
    },
  );

  test(
    'batch edits roll back every draft when one database write fails',
    () async {
      final first = await repository.storeDraft(draft());
      final second = await repository.storeDraft(draft(second: 1));
      final replacement = (await repository.accounts(
        'personal',
      )).firstWhere((item) => item.id != account.id);
      await db.customStatement(
        '''CREATE TRIGGER reject_second_batch BEFORE UPDATE ON transaction_drafts
      WHEN NEW.id='$second' BEGIN SELECT RAISE(ABORT,'batch failure'); END''',
      );

      await expectLater(
        repository.applyPendingDraftBatch('personal', [
          first,
          second,
        ], PendingDraftBatchPatch(accountId: replacement.id)),
        throwsA(anything),
      );
      final pending = await repository.pendingDrafts('personal');
      expect(pending.every((item) => item.batchAccountId == null), isTrue);
    },
  );

  test(
    'same transaction evidence is returned as one duplicate review group',
    () async {
      final first = await repository.storeDraft(draft());
      final second = await repository.storeDraft(draft());

      final groups = await repository.pendingDuplicateGroups('personal');
      final group = groups.singleWhere(
        (item) =>
            item.draftIds.contains(first) && item.draftIds.contains(second),
      );
      expect(group.draftIds.toSet(), {first, second});
      expect(group.existingTransactionCount, 0);
    },
  );

  testWidgets('review inbox exposes batch edit preview and duplicate tab', (
    tester,
  ) async {
    final id = await repository.storeDraft(draft());
    final state = LedgerController(repository);
    await state.load();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repository),
          ledgerProvider.overrideWith((ref) => state),
        ],
        child: const MaterialApp(home: ReviewInbox()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('重复候选'), findsOneWidget);
    expect(find.text('已忽略'), findsOneWidget);

    await tester.longPress(find.text('早餐店'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量修改'));
    await tester.pumpAndSettle();
    expect(find.text('批量修改待处理账单'), findsOneWidget);
    await tester.tap(find.text('替换标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '早餐 报销');
    await tester.tap(find.text('预览修改'));
    await tester.pumpAndSettle();
    expect(find.text('批量修改预览'), findsOneWidget);
    expect(find.textContaining('预计修改 1 笔'), findsOneWidget);
    await tester.tap(find.text('确认执行'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    final edited = (await repository.pendingDrafts(
      'personal',
    )).singleWhere((item) => item.id == id);
    expect(edited.batchTags, ['早餐', '报销']);
    expect(find.textContaining('已修改 1 笔'), findsOneWidget);
  });
}
