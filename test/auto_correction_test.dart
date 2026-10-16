import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/features/auto_correction_page.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/transaction/transaction_identity.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repository;

  setUp(() async {
    db = AppDatabase.memory();
    repository = LedgerRepository(db);
    await repository.initialize();
  });

  tearDown(() => db.close());

  test(
    'stable observations create a reviewable suggestion before a rule',
    () async {
      final account = (await repository.accounts('personal')).first;
      final category = (await repository.categories(
        'personal',
      )).firstWhere((value) => value.type == TransactionType.expense);
      for (var index = 0; index < 3; index++) {
        await repository.submitStructuredTransaction(
          'personal',
          TransactionInput(
            type: TransactionType.expense,
            amountMinor: 1200 + index,
            accountId: account.id,
            categoryId: category.id,
            occurredDate: DateTime(2026, 10, 10 + index, 12, 30, 15),
            merchant: 'KKV',
            tags: const ['日常'],
          ),
          identitySeed: TransactionIdentitySeed(
            source: TransactionEvidenceSource.ocr,
            captureId: 'learn-$index',
          ),
        );
      }
      expect(await repository.autoCorrectionRules('personal'), isEmpty);
      final suggestions = await repository.autoCorrectionSuggestions();
      expect(suggestions, hasLength(1));
      expect(suggestions.single.sampleCount, 3);
      expect(suggestions.single.consistencyBps, 10000);
      await repository.acceptAutoCorrectionSuggestion(suggestions.single.id);
      final rules = await repository.autoCorrectionRules('personal');
      expect(rules, hasLength(1));

      final corrected = await repository.applyAutoCorrectionRule(
        TransactionDraft(
          raw: RawTransaction(
            text: '支付成功 12元 KKV',
            capturedAt: DateTime(2026, 10, 14),
            source: TransactionSource.ocr,
          ),
          ledgerId: 'personal',
          type: TransactionType.expense,
          amountMinor: 1200,
          occurredDate: DateTime(2026, 10, 14),
          merchant: ' K K V ',
          warnings: const ['未识别到账户，请选择', '分类未确定，请选择'],
          evidence: const {},
        ),
      );
      expect(corrected.accountId, account.id);
      expect(corrected.categoryId, category.id);
      expect(corrected.tags, ['日常']);
      expect(corrected.warnings, isEmpty);
      expect(corrected.evidence['auto_correction'], contains('KKV'));
    },
  );

  test('manual contains rule has priority and can be disabled', () async {
    final accounts = await repository.accounts('personal');
    final categories = await repository.categories('personal');
    final category = categories.firstWhere(
      (value) => value.type == TransactionType.expense,
    );
    final id = await repository.saveAutoCorrectionRule(
      'personal',
      merchantPattern: '便利店',
      type: TransactionType.expense,
      accountId: accounts.last.id,
      categoryId: category.id,
      matchMode: AutoCorrectionMatchMode.contains,
      tags: const ['夜宵'],
      priority: 20,
    );
    final source = TransactionDraft(
      raw: RawTransaction(text: '付款成功', capturedAt: DateTime.now()),
      ledgerId: 'personal',
      type: TransactionType.expense,
      occurredDate: DateTime.now(),
      merchant: '裕家便利店（测试店）',
      warnings: const [],
      evidence: const {},
    );
    expect(
      (await repository.applyAutoCorrectionRule(source)).accountId,
      accounts.last.id,
    );
    await repository.setAutoCorrectionEnabled('personal', id, false);
    expect(
      (await repository.applyAutoCorrectionRule(source)).accountId,
      isNull,
    );
  });

  test(
    'local merchant aliases normalize names and provide a category',
    () async {
      final category = (await repository.categories(
        'personal',
      )).firstWhere((value) => value.type == TransactionType.expense);
      await repository.saveMerchantKnowledge(
        'personal',
        canonicalName: '本地咖啡馆',
        aliases: const ['咖啡测试商户有限公司'],
        defaultCategoryId: category.id,
        sourceKey: 'channel:ocr',
      );
      final corrected = await repository.applyAutoCorrectionRule(
        TransactionDraft(
          raw: RawTransaction(
            text: '支付成功',
            capturedAt: DateTime(2026, 10, 13),
            source: TransactionSource.ocr,
          ),
          ledgerId: 'personal',
          type: TransactionType.expense,
          occurredDate: DateTime(2026, 10, 13, 12),
          merchant: '咖啡测试商户有限公司',
          warnings: const ['分类未确定，请选择'],
          evidence: const {},
        ),
      );
      expect(corrected.merchant, '本地咖啡馆');
      expect(corrected.categoryId, category.id);
      expect(corrected.warnings, isEmpty);
    },
  );

  test('rule conditions can route a matching payment across ledgers', () async {
    await repository.createLedger('工作账本');
    final ledgers = await repository.ledgers();
    final target = ledgers.entries
        .firstWhere((value) => value.value == '工作账本')
        .key;
    final account = (await repository.accounts(target)).first;
    final sourceAccount = (await repository.accounts('personal')).first;
    final category = (await repository.categories(
      target,
    )).firstWhere((value) => value.type == TransactionType.expense);
    await repository.saveAutoCorrectionRule(
      target,
      merchantPattern: '测试商户',
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
      sourceKey: 'app:com.eg.android.AlipayGphone',
      minAmountMinor: 1000,
      maxAmountMinor: 2000,
      paymentMethodPattern: '花呗',
      startMinute: 10 * 60,
      endMinute: 15 * 60,
      weekdaysMask: 1 << (DateTime(2026, 10, 13).weekday - 1),
      sourceAccountId: sourceAccount.id,
    );
    TransactionDraft draft({required int amount, required String payment}) =>
        TransactionDraft(
          raw: RawTransaction(
            text: '支付成功',
            capturedAt: DateTime(2026, 10, 13),
            source: TransactionSource.notification,
            sourceApp: 'com.eg.android.AlipayGphone',
            paymentMethod: payment,
          ),
          ledgerId: 'personal',
          type: TransactionType.expense,
          amountMinor: amount,
          accountId: sourceAccount.id,
          occurredDate: DateTime(2026, 10, 13, 12),
          merchant: '测试商户',
          warnings: const [],
          evidence: const {},
        );
    expect(
      (await repository.applyAutoCorrectionRule(
        draft(amount: 1500, payment: '花呗'),
      )).ledgerId,
      target,
    );
    expect(
      (await repository.applyAutoCorrectionRule(
        draft(amount: 900, payment: '花呗'),
      )).ledgerId,
      'personal',
    );
    expect(
      (await repository.applyAutoCorrectionRule(
        draft(amount: 1500, payment: '余额'),
      )).ledgerId,
      'personal',
    );
    expect(await repository.autoCorrectionEvents(), hasLength(1));
  });

  test(
    'unreviewed learning stays inactive and old bills can be batch corrected',
    () async {
      final sourceAccount = (await repository.accounts('personal')).first;
      final sourceCategory = (await repository.categories(
        'personal',
      )).firstWhere((value) => value.type == TransactionType.expense);
      await repository.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 2500,
          accountId: sourceAccount.id,
          categoryId: sourceCategory.id,
          occurredDate: DateTime(2026, 10, 12),
          merchant: '历史商户',
        ),
      );
      expect(await repository.autoCorrectionRules('personal'), isEmpty);

      await repository.createLedger('公司账本');
      final target = (await repository.ledgers()).entries
          .firstWhere((value) => value.value == '公司账本')
          .key;
      final account = (await repository.accounts(target)).first;
      final category = (await repository.categories(
        target,
      )).firstWhere((value) => value.type == TransactionType.expense);
      final rule = await repository.saveAutoCorrectionRule(
        target,
        merchantPattern: '历史商户',
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
      );
      final preview = await repository.previewAutoCorrectionBatch(rule);
      expect(preview.eligible, 1);
      expect((await repository.applyAutoCorrectionBatch(rule)).eligible, 1);
      expect(await repository.entries('personal'), isEmpty);
      expect((await repository.entries(target)).single.merchant, '历史商户');
      expect(
        (await repository.autoCorrectionEvents()).any(
          (value) => value.eventType == 'batch',
        ),
        isTrue,
      );
    },
  );

  test('auto correction rules survive encrypted backup', () async {
    final account = (await repository.accounts('personal')).first;
    final category = (await repository.categories('personal')).first;
    await repository.saveAutoCorrectionRule(
      'personal',
      merchantPattern: '小米景明科技有限公司',
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
      tags: const ['数码'],
    );
    final bytes = await BackupService(db).export('12345678');
    final restored = AppDatabase.memory();
    addTearDown(restored.close);
    final restoredRepository = LedgerRepository(restored);
    await restoredRepository.initialize();
    await BackupService(restored).restore(bytes, '12345678');
    final rules = await restoredRepository.autoCorrectionRules('personal');
    expect(rules.single.merchantPattern, '小米景明科技有限公司');
    expect(rules.single.tags, ['数码']);
  });

  test('schema 7 database migrates with an empty rule table', () async {
    final directory = await Directory.systemTemp.createTemp('ledger-v7-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ledger.sqlite');
    final legacy = sqlite.sqlite3.open(file.path);
    for (final statement in schemaStatements.where(
      (statement) => !autoCorrectionSchemaStatements.contains(statement),
    )) {
      legacy.execute(statement);
    }
    legacy.execute('PRAGMA user_version=7');
    legacy.dispose();
    final migrated = AppDatabase(NativeDatabase(file));
    addTearDown(migrated.close);
    final migratedRepository = LedgerRepository(migrated);
    await migratedRepository.initialize();
    expect(await migratedRepository.autoCorrectionRules('personal'), isEmpty);
  });

  testWidgets('management page lists learned rules and opens search', (
    tester,
  ) async {
    final account = (await repository.accounts('personal')).first;
    final category = (await repository.categories('personal')).first;
    await repository.saveAutoCorrectionRule(
      'personal',
      merchantPattern: '测试便利店',
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
    );
    final state = LedgerController(repository);
    await state.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repository),
          ledgerProvider.overrideWith((ref) => state),
        ],
        child: const MaterialApp(home: AutoCorrectionPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('自动修正管理'), findsOneWidget);
    expect(find.text('测试便利店'), findsOneWidget);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索商户、账户、分类或标签'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    expect(find.text('新增自动修正'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
