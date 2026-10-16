import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/advanced_finance_repository.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/appearance.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  late AppDatabase db;
  late LedgerRepository ledger;
  late AdvancedFinanceRepository finance;

  setUp(() async {
    db = AppDatabase.memory();
    ledger = LedgerRepository(db);
    await ledger.initialize();
    finance = AdvancedFinanceRepository(db);
  });

  tearDown(() => db.close());

  test(
    'foreign account keeps original amount and base CNY conversion',
    () async {
      await finance.saveCurrency(
        'personal',
        const CurrencyDefinition(
          code: 'USD',
          name: '美元',
          symbol: r'$',
          rateToCnyMicros: 7200000,
        ),
      );
      await ledger.addAccount(
        'personal',
        '美元现金',
        AccountKind.cash,
        10000,
        currency: 'USD',
      );
      final accounts = await ledger.accounts('personal');
      final usd = accounts.singleWhere((value) => value.currency == 'USD');
      final cny = accounts.firstWhere((value) => value.currency == 'CNY');
      final category = (await ledger.categories(
        'personal',
      )).firstWhere((value) => value.type == TransactionType.expense);

      await ledger.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 100,
          accountId: usd.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 13, 12, 30, 10),
        ),
      );
      final expense = (await ledger.entries('personal')).single;
      expect(expense.amountMinor, 720);
      expect(expense.originalAmountMinor, 100);
      expect(expense.currency, 'USD');

      await ledger.save(
        'personal',
        TransactionInput(
          type: TransactionType.transfer,
          amountMinor: 100,
          accountId: usd.id,
          targetAccountId: cny.id,
          occurredDate: DateTime(2026, 10, 13, 13),
        ),
      );
      final transfer = (await ledger.entries(
        'personal',
      )).firstWhere((value) => value.type == TransactionType.transfer);
      expect(transfer.amountMinor, 720);
      expect(transfer.targetAmountMinor, 720);
      expect(transfer.targetCurrency, 'CNY');
    },
  );

  test('assets, bill groups and exact AA splits survive backup', () async {
    final account = (await ledger.accounts('personal')).first;
    final category = (await ledger.categories(
      'personal',
    )).firstWhere((value) => value.type == TransactionType.expense);
    final transactionId = await ledger.save(
      'personal',
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: 1000,
        accountId: account.id,
        categoryId: category.id,
        occurredDate: DateTime(2026, 10, 13, 9, 8, 7),
      ),
    );
    final assetId = await finance.saveAsset(
      'personal',
      const FinancialAsset(
        id: '',
        kind: FinancialAssetKind.fund,
        name: '指数基金',
        currency: 'CNY',
        principalMinor: 100000,
        currentMinor: 105000,
        quantityMicros: 5000000,
      ),
    );
    await finance.recordAssetTransaction(
      'personal',
      assetId,
      kind: AssetTransactionKind.buy,
      occurredAt: DateTime(2026, 10, 13, 10),
      amountMinor: 1000,
      quantityMicros: 50000,
    );
    await finance.addValuation(
      'personal',
      assetId,
      valuedAt: DateTime(2026, 10, 13, 11),
      totalValueMinor: 106000,
    );
    final group = await finance.saveGroup('personal', name: '周末聚餐');
    await finance.assignToGroup('personal', transactionId, group);
    await finance.replaceSplits(
      'personal',
      transactionId,
      AdvancedFinanceRepository.equalSplits(1000, const ['我', '小李', '小王']),
    );
    final split = await finance.splits('personal', transactionId);
    expect(split.map((value) => value.amountMinor), [334, 333, 333]);

    final bytes = await BackupService(db).export('12345678');
    final restored = AppDatabase.memory();
    addTearDown(restored.close);
    final restoredLedger = LedgerRepository(restored);
    await restoredLedger.initialize();
    await BackupService(restored).restore(bytes, '12345678');
    final restoredFinance = AdvancedFinanceRepository(restored);
    expect(await restoredFinance.assets('personal'), hasLength(1));
    expect(await restoredFinance.assetTransactions(assetId), hasLength(1));
    expect(await restoredFinance.valuations(assetId), hasLength(1));
    expect(
      (await restoredFinance.groups('personal')).single.transactionCount,
      1,
    );
    expect(
      await restoredFinance.splits('personal', transactionId),
      hasLength(3),
    );
  });

  test('appearance share code validates and round-trips', () {
    const value = AppearanceSettings(
      seedColor: 0xFF2563EB,
      backgroundColor: 0xFFF5F7FA,
      font: 'serif',
      fontScale: 1.2,
      iconStyle: 'filled',
      brightness: 'dark',
    );
    final decoded = AppearanceSettings.decode(value.shareCode());
    expect(decoded.seedColor, value.seedColor);
    expect(decoded.font, 'serif');
    expect(decoded.fontScale, 1.2);
    expect(decoded.iconStyle, 'filled');
    expect(decoded.brightness, 'dark');
    expect(
      () => AppearanceSettings.decode('ZHI-THEME-1:not-valid'),
      throwsFormatException,
    );
  });

  test(
    'investment activities keep cost basis, valuation and returns',
    () async {
      final id = await finance.saveAsset(
        'personal',
        const FinancialAsset(
          id: '',
          kind: FinancialAssetKind.fund,
          name: '测试基金',
          currency: 'CNY',
          principalMinor: 0,
          currentMinor: 0,
        ),
      );
      await finance.recordAssetTransaction(
        'personal',
        id,
        kind: AssetTransactionKind.buy,
        occurredAt: DateTime(2026, 1, 1),
        amountMinor: 10000,
        feeMinor: 100,
        quantityMicros: 10000000,
      );
      await finance.addValuation(
        'personal',
        id,
        valuedAt: DateTime(2026, 2, 1),
        unitValueMicros: 12000000,
      );
      await finance.recordAssetTransaction(
        'personal',
        id,
        kind: AssetTransactionKind.sell,
        occurredAt: DateTime(2026, 3, 1),
        amountMinor: 5200,
        feeMinor: 100,
        quantityMicros: 4000000,
      );

      final asset = await finance.asset('personal', id);
      expect(asset.quantityMicros, 6000000);
      expect(asset.principalMinor, 6060);
      expect(asset.currentMinor, 7200);
      final summary = await finance.assetSummary('personal', id);
      expect(summary.realizedMinor, 1060);
      expect(summary.unrealizedMinor, 1140);
      expect(summary.totalReturnMinor, 2200);
      expect(summary.returnBps, 2178);
      expect(
        (await finance.assetTransactions(id))
            .firstWhere((entry) => entry.kind == AssetTransactionKind.sell)
            .unitPriceMicros,
        13000000,
      );
      expect(await finance.valuations(id), hasLength(1));
    },
  );

  test('loan schedule preserves principal and paid progress', () async {
    final id = await finance.saveAsset(
      'personal',
      const FinancialAsset(
        id: '',
        kind: FinancialAssetKind.mortgage,
        name: '住房贷款',
        currency: 'CNY',
        principalMinor: 120000,
        currentMinor: 120000,
        interestBps: 420,
      ),
    );
    await finance.generateRepaymentSchedule(
      'personal',
      id,
      firstDueDate: DateTime(2026, 1, 31),
      periods: 12,
      method: RepaymentMethod.equalPrincipal,
    );
    final schedule = await finance.schedule(id);
    expect(schedule, hasLength(12));
    expect(
      schedule.fold<int>(0, (sum, item) => sum + item.principalMinor),
      120000,
    );
    expect(schedule[1].dueAt, DateTime(2026, 2, 28));
    await finance.markSchedulePaid(
      'personal',
      schedule.first.id,
      paidAt: DateTime(2026, 1, 30, 8),
    );
    final asset = await finance.asset('personal', id);
    expect(asset.currentMinor, 110000);
    expect(asset.completedPeriods, 1);
    expect((await finance.schedule(id)).first.status, AssetScheduleStatus.paid);
    expect(
      (await finance.assetTransactions(id)).single.kind,
      AssetTransactionKind.repayment,
    );
  });

  test('lending flow tracks outstanding balance', () async {
    final id = await finance.saveAsset(
      'personal',
      const FinancialAsset(
        id: '',
        kind: FinancialAssetKind.lent,
        name: '借给小李',
        currency: 'CNY',
        principalMinor: 0,
        currentMinor: 0,
      ),
    );
    await finance.recordAssetTransaction(
      'personal',
      id,
      kind: AssetTransactionKind.lend,
      occurredAt: DateTime(2026, 1, 1),
      amountMinor: 50000,
    );
    await finance.recordAssetTransaction(
      'personal',
      id,
      kind: AssetTransactionKind.collect,
      occurredAt: DateTime(2026, 2, 1),
      amountMinor: 21000,
      principalMinor: 20000,
      interestMinor: 1000,
    );
    final asset = await finance.asset('personal', id);
    expect(asset.principalMinor, 30000);
    expect(asset.currentMinor, 30000);
    expect(await finance.assetTransactions(id), hasLength(2));
  });

  test(
    'credit card statement snapshots and reconciles ledger entries',
    () async {
      await ledger.addAccount('personal', '测试信用卡', AccountKind.credit, 0);
      final account = (await ledger.accounts(
        'personal',
      )).singleWhere((value) => value.displayName == '测试信用卡');
      final category = (await ledger.categories(
        'personal',
      )).firstWhere((value) => value.type == TransactionType.expense);
      await ledger.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1234,
          accountId: account.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 1, 15, 12),
          merchant: '测试商户',
        ),
      );
      final assetId = await finance.saveAsset(
        'personal',
        FinancialAsset(
          id: '',
          kind: FinancialAssetKind.creditCard,
          name: '测试信用卡账单',
          accountId: account.id,
          currency: 'CNY',
          principalMinor: 0,
          currentMinor: 1234,
        ),
      );
      final statementId = await finance.createCreditCardStatement(
        'personal',
        assetId,
        periodStart: DateTime(2026, 1, 1),
        periodEnd: DateTime(2026, 1, 31),
        dueAt: DateTime(2026, 2, 20),
        statementMinor: 1234,
      );
      var statement = (await finance.creditCardStatements(assetId)).single;
      expect(statement.ledgerMinor, 1234);
      expect(statement.differenceMinor, 0);
      final line = (await finance.creditCardStatementLines(statementId)).single;
      expect(line.merchant, '测试商户');
      await finance.setStatementLineChecked(
        statementId,
        line.transactionId,
        true,
      );
      await finance.finishStatementReconciliation(statementId);
      statement = (await finance.creditCardStatements(assetId)).single;
      expect(statement.status, CreditCardStatementStatus.reconciled);
      expect(statement.checkedCount, 1);
      await finance.finishStatementReconciliation(statementId, paidMinor: 1234);
      statement = (await finance.creditCardStatements(assetId)).single;
      expect(statement.status, CreditCardStatementStatus.paid);
      expect((await finance.asset('personal', assetId)).currentMinor, 0);
      expect(
        (await finance.assetTransactions(assetId)).single.kind,
        AssetTransactionKind.repayment,
      );
    },
  );
}
