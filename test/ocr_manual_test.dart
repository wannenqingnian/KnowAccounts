import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/features/review_inbox.dart';
import 'package:smart_ledger/features/transaction_editor.dart';
import 'package:smart_ledger/main.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  testWidgets(
    'blocked OCR can explicitly become one manual draft without posting',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final d = TransactionParser().parse(
        RawTransaction(
          text: '收入100元 支出50元',
          source: TransactionSource.ocr,
          capturedAt: DateTime(2026, 10, 5),
        ),
        ledgerId: 'personal',
        accounts: await repo.accounts('personal'),
        categories: await repo.categories('personal'),
      );
      expect(d.blocked, isTrue);
      final id = await repo.storeDraft(d);
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
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);
      showReviewInbox(context);
      await tester.pumpAndSettle();
      await tester.tap(find.text('处理识别问题'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('手动填写单笔收支'));
      await tester.tap(find.text('手动填写单笔收支'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsOneWidget);
      final manual = tester
          .widget<TransactionEditor>(find.byType(TransactionEditor))
          .draft!;
      expect(manual.blocked, isFalse);
      expect(manual.amountMinor, isNull);
      expect(manual.accountId, isNull);
      expect(manual.categoryId, isNull);
      expect(await repo.entries('personal'), isEmpty);
      final pending = await repo.pendingDrafts('personal');
      expect(pending, hasLength(1));
      expect(pending.single.id, id);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );
}
