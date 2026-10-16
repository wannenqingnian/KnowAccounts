import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/database/app_database.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../transaction/parser/transaction_parser.dart';

class AdvancedFinanceRepository {
  AdvancedFinanceRepository(this.db);

  final AppDatabase db;
  static const _uuid = Uuid();

  Future<List<QueryRow>> _query(String sql, [List<Object> args = const []]) =>
      db
          .customSelect(
            sql,
            variables: args
                .map<Variable>(
                  (value) => value is int
                      ? Variable<int>(value)
                      : Variable<String>(value as String),
                )
                .toList(),
          )
          .get();

  Future<List<CurrencyDefinition>> currencies(String ledger) async =>
      (await _query(
            'SELECT * FROM currencies WHERE ledger_id=? ORDER BY code',
            [ledger],
          ))
          .map(
            (row) => CurrencyDefinition(
              code: row.read('code'),
              name: row.read('name'),
              symbol: row.read('symbol'),
              rateToCnyMicros: row.read('rate_to_cny_micros'),
              decimals: row.read('decimals'),
              updatedAt: DateTime.tryParse(row.read('updated_at')),
            ),
          )
          .toList();

  Future<CurrencyDefinition> currency(String ledger, String code) async {
    final rows = await _query(
      'SELECT * FROM currencies WHERE ledger_id=? AND code=?',
      [ledger, code],
    );
    if (rows.isEmpty) throw const LedgerException('币种不存在');
    final row = rows.single;
    return CurrencyDefinition(
      code: row.read('code'),
      name: row.read('name'),
      symbol: row.read('symbol'),
      rateToCnyMicros: row.read('rate_to_cny_micros'),
      decimals: row.read('decimals'),
      updatedAt: DateTime.tryParse(row.read('updated_at')),
    );
  }

  Future<void> saveCurrency(
    String ledger,
    CurrencyDefinition value, {
    String? originalCode,
  }) async {
    final code = value.code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
      throw const LedgerException('币种代码必须为3位英文字母');
    }
    if (value.name.trim().isEmpty || value.name.trim().length > 30) {
      throw const LedgerException('币种名称需为1～30字');
    }
    if (value.symbol.trim().isEmpty || value.symbol.trim().length > 6) {
      throw const LedgerException('币种符号需为1～6字');
    }
    if (value.rateToCnyMicros <= 0 || value.rateToCnyMicros > 1000000000000) {
      throw const LedgerException('汇率超出有效范围');
    }
    if (value.decimals < 0 || value.decimals > 4) {
      throw const LedgerException('小数位必须为0～4');
    }
    if (code == 'CNY' &&
        (value.rateToCnyMicros != 1000000 || value.decimals != 2)) {
      throw const LedgerException('人民币基准汇率固定为1，小数位固定为2');
    }
    if (originalCode != null && originalCode != code) {
      final used = await _query(
        '''SELECT 1 FROM accounts WHERE ledger_id=? AND currency=?
        UNION ALL SELECT 1 FROM financial_assets WHERE ledger_id=? AND currency=? LIMIT 1''',
        [ledger, originalCode, ledger, originalCode],
      );
      if (used.isNotEmpty) throw const LedgerException('币种已被账户或资产使用，不能修改代码');
      await db.customStatement(
        'DELETE FROM currencies WHERE ledger_id=? AND code=?',
        [ledger, originalCode],
      );
    }
    await db.customStatement(
      '''INSERT INTO currencies
      (ledger_id,code,name,symbol,rate_to_cny_micros,decimals,updated_at)
      VALUES (?,?,?,?,?,?,?) ON CONFLICT(ledger_id,code) DO UPDATE SET
      name=excluded.name,symbol=excluded.symbol,
      rate_to_cny_micros=excluded.rate_to_cny_micros,
      decimals=excluded.decimals,updated_at=excluded.updated_at''',
      [
        ledger,
        code,
        value.name.trim(),
        value.symbol.trim(),
        value.rateToCnyMicros,
        value.decimals,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  Future<void> deleteCurrency(String ledger, String code) async {
    if (code == 'CNY') throw const LedgerException('人民币为基准币种，不能删除');
    final used = await _query(
      '''SELECT 1 FROM accounts WHERE ledger_id=? AND currency=?
      UNION ALL SELECT 1 FROM financial_assets WHERE ledger_id=? AND currency=?
      UNION ALL SELECT 1 FROM transaction_fx fx JOIN transactions t ON t.id=fx.transaction_id
        WHERE t.ledger_id=? AND (fx.source_currency=? OR fx.target_currency=?) LIMIT 1''',
      [ledger, code, ledger, code, ledger, code, code],
    );
    if (used.isNotEmpty) throw const LedgerException('币种已有账户、资产或交易，不能删除');
    await db.customStatement(
      'DELETE FROM currencies WHERE ledger_id=? AND code=?',
      [ledger, code],
    );
  }

  static int convertToCny(int amountMinor, int rateMicros) =>
      (amountMinor * rateMicros + 500000) ~/ 1000000;

  static int convertFromCny(int cnyMinor, int rateMicros) =>
      (cnyMinor * 1000000 + rateMicros ~/ 2) ~/ rateMicros;

  Future<List<FinancialAsset>> assets(
    String ledger, {
    bool includeArchived = false,
  }) async => (await _query(
    '''SELECT * FROM financial_assets WHERE ledger_id=?
            ${includeArchived ? '' : 'AND archived_at IS NULL'}
            ORDER BY archived_at IS NOT NULL,kind,name''',
    [ledger],
  )).map(_asset).toList();

  FinancialAsset _asset(QueryRow row) => FinancialAsset(
    id: row.read('id'),
    kind: FinancialAssetKind.values.byName(row.read('kind')),
    name: row.read('name'),
    accountId: row.readNullable('account_id'),
    currency: row.read('currency'),
    principalMinor: row.read('principal_minor'),
    currentMinor: row.read('current_minor'),
    quantityMicros: row.read('quantity_micros'),
    interestBps: row.read('interest_bps'),
    startDate: _date(row.readNullable('start_date')),
    maturityDate: _date(row.readNullable('maturity_date')),
    totalPeriods: row.read('total_periods'),
    completedPeriods: row.read('completed_periods'),
    billingDay: row.readNullable('billing_day'),
    repaymentDay: row.readNullable('repayment_day'),
    counterparty: row.read('counterparty'),
    note: row.read('note'),
    archived: row.readNullable<String>('archived_at') != null,
  );

  DateTime? _date(String? value) =>
      value == null ? null : DateTime.parse(value);

  Future<String> saveAsset(String ledger, FinancialAsset value) async {
    final name = value.name.trim();
    if (name.isEmpty || name.length > 80) {
      throw const LedgerException('资产名称需为1～80字');
    }
    if ([
      value.principalMinor,
      value.currentMinor,
      value.quantityMicros,
    ].any((number) => number < 0 || number > 999999999999999)) {
      throw const LedgerException('资产金额或数量超出有效范围');
    }
    if (value.interestBps < 0 || value.interestBps > 100000) {
      throw const LedgerException('年利率超出有效范围');
    }
    if (value.totalPeriods < 0 ||
        value.completedPeriods < 0 ||
        value.completedPeriods > value.totalPeriods) {
      throw const LedgerException('期数进度无效');
    }
    if (value.startDate != null &&
        value.maturityDate != null &&
        value.maturityDate!.isBefore(value.startDate!)) {
      throw const LedgerException('到期日期不能早于开始日期');
    }
    if ((await _query('SELECT 1 FROM currencies WHERE ledger_id=? AND code=?', [
      ledger,
      value.currency,
    ])).isEmpty) {
      throw const LedgerException('资产币种不存在');
    }
    if (value.accountId != null &&
        (await _query('SELECT 1 FROM accounts WHERE ledger_id=? AND id=?', [
          ledger,
          value.accountId!,
        ])).isEmpty) {
      throw const LedgerException('关联账户不存在');
    }
    final id = value.id.isEmpty ? _uuid.v4() : value.id;
    await db.customStatement(
      '''INSERT INTO financial_assets
      (id,ledger_id,kind,name,account_id,currency,principal_minor,current_minor,
       quantity_micros,interest_bps,start_date,maturity_date,total_periods,
       completed_periods,billing_day,repayment_day,counterparty,note,archived_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,name=excluded.name,
      account_id=excluded.account_id,currency=excluded.currency,
      principal_minor=excluded.principal_minor,current_minor=excluded.current_minor,
      quantity_micros=excluded.quantity_micros,interest_bps=excluded.interest_bps,
      start_date=excluded.start_date,maturity_date=excluded.maturity_date,
      total_periods=excluded.total_periods,completed_periods=excluded.completed_periods,
      billing_day=excluded.billing_day,repayment_day=excluded.repayment_day,
      counterparty=excluded.counterparty,note=excluded.note,
      archived_at=excluded.archived_at,updated_at=excluded.updated_at
      WHERE financial_assets.ledger_id=excluded.ledger_id''',
      [
        id,
        ledger,
        value.kind.name,
        name,
        value.accountId,
        value.currency,
        value.principalMinor,
        value.currentMinor,
        value.quantityMicros,
        value.interestBps,
        value.startDate == null ? null : dateKey(value.startDate!),
        value.maturityDate == null ? null : dateKey(value.maturityDate!),
        value.totalPeriods,
        value.completedPeriods,
        value.billingDay,
        value.repaymentDay,
        value.counterparty.trim(),
        value.note.trim(),
        value.archived ? DateTime.now().toUtc().toIso8601String() : null,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return id;
  }

  Future<void> setAssetArchived(String ledger, String id, bool archived) async {
    final archivedAt = archived
        ? DateTime.now().toUtc().toIso8601String()
        : null;
    final changed = await db.customUpdate(
      archivedAt == null
          ? 'UPDATE financial_assets SET archived_at=NULL,updated_at=? WHERE id=? AND ledger_id=?'
          : 'UPDATE financial_assets SET archived_at=?,updated_at=? WHERE id=? AND ledger_id=?',
      variables: [
        if (archivedAt != null) Variable<String>(archivedAt),
        Variable<String>(DateTime.now().toUtc().toIso8601String()),
        Variable<String>(id),
        Variable<String>(ledger),
      ],
    );
    if (changed != 1) throw const LedgerException('资产不存在');
  }

  Future<FinancialAsset> asset(String ledger, String id) async {
    final rows = await _query(
      'SELECT * FROM financial_assets WHERE ledger_id=? AND id=?',
      [ledger, id],
    );
    if (rows.isEmpty) throw const LedgerException('资产不存在');
    return _asset(rows.single);
  }

  Future<List<AssetTransaction>> assetTransactions(
    String assetId,
  ) async => (await _query(
    'SELECT * FROM asset_transactions WHERE asset_id=? ORDER BY occurred_at DESC,created_at DESC',
    [assetId],
  )).map(_assetTransaction).toList();

  AssetTransaction _assetTransaction(QueryRow row) => AssetTransaction(
    id: row.read('id'),
    assetId: row.read('asset_id'),
    kind: AssetTransactionKind.values.byName(row.read('kind')),
    occurredAt: DateTime.parse(row.read('occurred_at')),
    amountMinor: row.read('amount_minor'),
    quantityMicros: row.read('quantity_micros'),
    unitPriceMicros: row.read('unit_price_micros'),
    costBasisMinor: row.read('cost_basis_minor'),
    principalMinor: row.read('principal_minor'),
    interestMinor: row.read('interest_minor'),
    feeMinor: row.read('fee_minor'),
    accountId: row.readNullable('account_id'),
    transactionId: row.readNullable('transaction_id'),
    note: row.read('note'),
  );

  Future<List<AssetValuation>> valuations(String assetId) async =>
      (await _query(
            'SELECT * FROM asset_valuations WHERE asset_id=? ORDER BY valued_at DESC',
            [assetId],
          ))
          .map(
            (row) => AssetValuation(
              id: row.read('id'),
              assetId: row.read('asset_id'),
              valuedAt: DateTime.parse(row.read('valued_at')),
              unitValueMicros: row.read('unit_value_micros'),
              totalValueMinor: row.read('total_value_minor'),
              source: row.read('source'),
              note: row.read('note'),
            ),
          )
          .toList();

  /// Records an auditable asset event and updates the summary card atomically.
  /// Sell cost is frozen with weighted-average cost so later edits to the
  /// holding do not rewrite historical realized profit.
  Future<String> recordAssetTransaction(
    String ledger,
    String assetId, {
    required AssetTransactionKind kind,
    required DateTime occurredAt,
    int amountMinor = 0,
    int quantityMicros = 0,
    int unitPriceMicros = 0,
    int principalMinor = 0,
    int interestMinor = 0,
    int feeMinor = 0,
    String? accountId,
    String? transactionId,
    String note = '',
  }) => db.transaction(() async {
    final value = await asset(ledger, assetId);
    if ([
      amountMinor,
      quantityMicros,
      unitPriceMicros,
      principalMinor,
      interestMinor,
      feeMinor,
    ].any((number) => number < 0 || number > 999999999999999)) {
      throw const LedgerException('资产流水金额或数量超出有效范围');
    }
    if (amountMinor == 0 &&
        quantityMicros == 0 &&
        principalMinor == 0 &&
        interestMinor == 0 &&
        feeMinor == 0) {
      throw const LedgerException('资产流水不能全部为零');
    }
    if ((kind == AssetTransactionKind.collect ||
            kind == AssetTransactionKind.repayment) &&
        amountMinor < principalMinor + interestMinor + feeMinor) {
      throw const LedgerException('总额不能小于本金、利息与费用之和');
    }
    if (accountId != null &&
        (await _query('SELECT 1 FROM accounts WHERE ledger_id=? AND id=?', [
          ledger,
          accountId,
        ])).isEmpty) {
      throw const LedgerException('流水关联账户不存在');
    }
    if (transactionId != null &&
        (await _query('SELECT 1 FROM transactions WHERE ledger_id=? AND id=?', [
          ledger,
          transactionId,
        ])).isEmpty) {
      throw const LedgerException('关联账单不存在');
    }

    var principal = value.principalMinor;
    var current = value.currentMinor;
    var quantity = value.quantityMicros;
    var costBasis = 0;
    var storedUnitPrice = unitPriceMicros;
    switch (kind) {
      case AssetTransactionKind.buy:
        if (!const {
              FinancialAssetKind.stock,
              FinancialAssetKind.fund,
            }.contains(value.kind) ||
            amountMinor <= 0 ||
            quantityMicros <= 0) {
          throw const LedgerException('买入需填写大于零的金额和份额');
        }
        principal += amountMinor + feeMinor;
        current += amountMinor;
        quantity += quantityMicros;
        storedUnitPrice = storedUnitPrice > 0
            ? storedUnitPrice
            : (amountMinor * 10000000000 + quantityMicros ~/ 2) ~/
                  quantityMicros;
      case AssetTransactionKind.sell:
        if (!const {
              FinancialAssetKind.stock,
              FinancialAssetKind.fund,
            }.contains(value.kind) ||
            amountMinor <= 0 ||
            quantityMicros <= 0 ||
            quantityMicros > quantity) {
          throw const LedgerException('卖出份额不能超过当前持仓');
        }
        costBasis = quantity == 0
            ? 0
            : (principal * quantityMicros + quantity ~/ 2) ~/ quantity;
        final valueReduction = quantity == 0
            ? 0
            : (current * quantityMicros + quantity ~/ 2) ~/ quantity;
        principal = math.max(0, principal - costBasis);
        current = math.max(0, current - valueReduction);
        quantity -= quantityMicros;
        storedUnitPrice = storedUnitPrice > 0
            ? storedUnitPrice
            : (amountMinor * 10000000000 + quantityMicros ~/ 2) ~/
                  quantityMicros;
      case AssetTransactionKind.dividend:
        if (!const {
              FinancialAssetKind.stock,
              FinancialAssetKind.fund,
            }.contains(value.kind) ||
            amountMinor <= 0) {
          throw const LedgerException('分红金额必须大于零');
        }
      case AssetTransactionKind.deposit:
        if (value.kind != FinancialAssetKind.fixedDeposit || amountMinor <= 0) {
          throw const LedgerException('存入金额必须大于零');
        }
        principal += amountMinor;
        current += amountMinor;
      case AssetTransactionKind.withdraw:
        if (value.kind != FinancialAssetKind.fixedDeposit ||
            amountMinor <= 0 ||
            amountMinor > current) {
          throw const LedgerException('取出金额不能超过当前余额');
        }
        current -= amountMinor;
        principal = math.max(0, principal - amountMinor);
      case AssetTransactionKind.interest:
        if (amountMinor <= 0) throw const LedgerException('利息必须大于零');
        if (value.kind == FinancialAssetKind.fixedDeposit ||
            value.kind == FinancialAssetKind.lent) {
          current += amountMinor;
        }
      case AssetTransactionKind.lend:
        if (value.kind != FinancialAssetKind.lent || amountMinor <= 0) {
          throw const LedgerException('借出金额必须大于零');
        }
        principal += amountMinor;
        current += amountMinor;
      case AssetTransactionKind.collect:
        if (value.kind != FinancialAssetKind.lent ||
            principalMinor <= 0 ||
            principalMinor > current) {
          throw const LedgerException('收回本金不能超过未收余额');
        }
        current -= principalMinor;
        principal = math.max(0, principal - principalMinor);
      case AssetTransactionKind.repayment:
        if (!const {
              FinancialAssetKind.mortgage,
              FinancialAssetKind.installment,
              FinancialAssetKind.creditCard,
            }.contains(value.kind) ||
            principalMinor <= 0 ||
            principalMinor > current) {
          throw const LedgerException('偿还本金不能超过剩余负债');
        }
        current -= principalMinor;
      case AssetTransactionKind.fee:
      case AssetTransactionKind.adjustment:
        // Fees and adjustments remain in the audit trail. Summary changes are
        // intentionally explicit through the editor or a valuation.
        break;
    }
    if (storedUnitPrice > 999999999999999) {
      throw const LedgerException('成交单价超出有效范围');
    }
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      '''INSERT INTO asset_transactions
      (id,asset_id,kind,occurred_at,amount_minor,quantity_micros,unit_price_micros,
       cost_basis_minor,principal_minor,interest_minor,fee_minor,account_id,
       transaction_id,note,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        assetId,
        kind.name,
        occurredAt.toUtc().toIso8601String(),
        amountMinor,
        quantityMicros,
        storedUnitPrice,
        costBasis,
        principalMinor,
        interestMinor,
        feeMinor,
        accountId,
        transactionId,
        note.trim(),
        now,
      ],
    );
    await db.customStatement(
      '''UPDATE financial_assets SET principal_minor=?,current_minor=?,
      quantity_micros=?,updated_at=? WHERE id=? AND ledger_id=?''',
      [principal, current, quantity, now, assetId, ledger],
    );
    return id;
  });

  Future<String> addValuation(
    String ledger,
    String assetId, {
    required DateTime valuedAt,
    int unitValueMicros = 0,
    int? totalValueMinor,
    String source = 'manual',
    String note = '',
  }) => db.transaction(() async {
    final value = await asset(ledger, assetId);
    if (!const {
      FinancialAssetKind.stock,
      FinancialAssetKind.fund,
    }.contains(value.kind)) {
      throw const LedgerException('只有股票和基金支持净值历史');
    }
    final calculated =
        totalValueMinor ??
        (value.quantityMicros * unitValueMicros + 5000000000) ~/ 10000000000;
    if (calculated < 0 || (calculated == 0 && value.quantityMicros > 0)) {
      throw const LedgerException('净值或总估值必须大于零');
    }
    final id = _uuid.v4();
    await db.customStatement(
      '''INSERT INTO asset_valuations
      (id,asset_id,valued_at,unit_value_micros,total_value_minor,source,note)
      VALUES (?,?,?,?,?,?,?)''',
      [
        id,
        assetId,
        valuedAt.toUtc().toIso8601String(),
        unitValueMicros,
        calculated,
        source,
        note.trim(),
      ],
    );
    await db.customStatement(
      'UPDATE financial_assets SET current_minor=?,updated_at=? WHERE id=? AND ledger_id=?',
      [calculated, DateTime.now().toUtc().toIso8601String(), assetId, ledger],
    );
    return id;
  });

  Future<FinancialAssetSummary> assetSummary(
    String ledger,
    String assetId,
  ) async {
    final value = await asset(ledger, assetId);
    final totals = (await _query(
      '''SELECT COUNT(*) AS activity_count,
      COALESCE(SUM(CASE WHEN kind='sell' THEN amount_minor-cost_basis_minor-fee_minor ELSE 0 END),0) AS realized,
      COALESCE(SUM(CASE WHEN kind='sell' THEN cost_basis_minor ELSE 0 END),0) AS sold_basis,
      COALESCE(SUM(CASE WHEN kind IN ('dividend','interest') THEN amount_minor+interest_minor ELSE 0 END),0) AS income
      FROM asset_transactions WHERE asset_id=?''',
      [assetId],
    )).single;
    final realized = totals.read<int>('realized');
    final income = totals.read<int>('income');
    final unrealized =
        const {
          FinancialAssetKind.stock,
          FinancialAssetKind.fund,
        }.contains(value.kind)
        ? value.currentMinor - value.principalMinor
        : 0;
    final total = realized + income + unrealized;
    final returnBasis = value.principalMinor + totals.read<int>('sold_basis');
    final next = (await schedule(assetId, pendingOnly: true)).firstOrNull;
    return FinancialAssetSummary(
      asset: value,
      realizedMinor: realized,
      incomeMinor: income,
      unrealizedMinor: unrealized,
      totalReturnMinor: total,
      returnBps: returnBasis == 0 ? 0 : (total * 10000 / returnBasis).round(),
      activityCount: totals.read('activity_count'),
      nextDue: next,
    );
  }

  Future<List<AssetScheduleItem>> schedule(
    String assetId, {
    bool pendingOnly = false,
  }) async => (await _query(
    '''SELECT * FROM asset_schedule_items WHERE asset_id=?
    ${pendingOnly ? "AND status IN ('pending','overdue')" : ''}
    ORDER BY period_no''',
    [assetId],
  )).map(_scheduleItem).toList();

  AssetScheduleItem _scheduleItem(QueryRow row) => AssetScheduleItem(
    id: row.read('id'),
    assetId: row.read('asset_id'),
    periodNo: row.read('period_no'),
    dueAt: DateTime.parse(row.read('due_at')),
    principalMinor: row.read('principal_minor'),
    interestMinor: row.read('interest_minor'),
    feeMinor: row.read('fee_minor'),
    status: AssetScheduleStatus.values.byName(row.read('status')),
    paidAt: _date(row.readNullable('paid_at')),
    transactionId: row.readNullable('transaction_id'),
    note: row.read('note'),
  );

  Future<void> generateRepaymentSchedule(
    String ledger,
    String assetId, {
    required DateTime firstDueDate,
    required int periods,
    required RepaymentMethod method,
    int? annualInterestBps,
    int monthlyFeeMinor = 0,
  }) => db.transaction(() async {
    final value = await asset(ledger, assetId);
    if (!const {
      FinancialAssetKind.mortgage,
      FinancialAssetKind.installment,
    }.contains(value.kind)) {
      throw const LedgerException('只有房贷和分期支持自动生成还款计划');
    }
    if (periods < 1 || periods > 600 || value.currentMinor <= 0) {
      throw const LedgerException('期数需为1～600且剩余本金必须大于零');
    }
    final existingPaid = await _query(
      "SELECT 1 FROM asset_schedule_items WHERE asset_id=? AND status='paid' LIMIT 1",
      [assetId],
    );
    if (existingPaid.isNotEmpty) throw const LedgerException('已有已还明细，不能重新生成计划');
    await db.customStatement(
      'DELETE FROM asset_schedule_items WHERE asset_id=?',
      [assetId],
    );
    final rateBps = annualInterestBps ?? value.interestBps;
    final monthlyRate = rateBps / 10000 / 12;
    final opening = value.currentMinor;
    var remaining = opening;
    final payment = monthlyRate == 0
        ? opening / periods
        : opening *
              monthlyRate *
              math.pow(1 + monthlyRate, periods) /
              (math.pow(1 + monthlyRate, periods) - 1);
    for (var index = 0; index < periods; index++) {
      final interest = (remaining * monthlyRate).round();
      final principal = index == periods - 1
          ? remaining
          : method == RepaymentMethod.equalPrincipal
          ? (opening / periods).round().clamp(0, remaining)
          : (payment.round() - interest).clamp(0, remaining);
      final due = _addMonths(firstDueDate, index);
      await db.customStatement(
        '''INSERT INTO asset_schedule_items
        (id,asset_id,period_no,due_at,principal_minor,interest_minor,fee_minor,status,note)
        VALUES (?,?,?,?,?,?,?,'pending','')''',
        [
          _uuid.v4(),
          assetId,
          index + 1,
          dateKey(due),
          principal,
          interest,
          monthlyFeeMinor,
        ],
      );
      remaining -= principal;
    }
    await db.customStatement(
      '''UPDATE financial_assets SET total_periods=?,completed_periods=0,
      interest_bps=?,repayment_day=?,updated_at=? WHERE id=? AND ledger_id=?''',
      [
        periods,
        rateBps,
        firstDueDate.day,
        DateTime.now().toUtc().toIso8601String(),
        assetId,
        ledger,
      ],
    );
  });

  static DateTime _addMonths(DateTime value, int count) {
    final monthStart = DateTime(value.year, value.month + count, 1);
    final lastDay = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    return DateTime(
      monthStart.year,
      monthStart.month,
      math.min(value.day, lastDay),
    );
  }

  Future<void> markSchedulePaid(
    String ledger,
    String itemId, {
    DateTime? paidAt,
    String? transactionId,
  }) => db.transaction(() async {
    final rows = await _query(
      '''SELECT s.*,f.current_minor,f.id AS financial_asset_id FROM asset_schedule_items s
      JOIN financial_assets f ON f.id=s.asset_id WHERE s.id=? AND f.ledger_id=?''',
      [itemId, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('还款明细不存在');
    final row = rows.single;
    if (row.read<String>('status') == 'paid') return;
    final principal = row.read<int>('principal_minor');
    final assetId = row.read<String>('financial_asset_id');
    final when = (paidAt ?? DateTime.now()).toUtc().toIso8601String();
    await db.customStatement(
      "UPDATE asset_schedule_items SET status='paid',paid_at=?,transaction_id=? WHERE id=?",
      [when, transactionId, itemId],
    );
    await db.customStatement(
      '''UPDATE financial_assets SET current_minor=MAX(0,current_minor-?),
      completed_periods=(SELECT COUNT(*) FROM asset_schedule_items WHERE asset_id=? AND status='paid'),
      updated_at=? WHERE id=?''',
      [principal, assetId, when, assetId],
    );
    await db.customStatement(
      '''INSERT INTO asset_transactions
      (id,asset_id,kind,occurred_at,amount_minor,principal_minor,interest_minor,
       fee_minor,transaction_id,note,created_at)
      VALUES (?,?, 'repayment',?,?,?,?,?,?,?,?)''',
      [
        _uuid.v4(),
        assetId,
        when,
        principal +
            row.read<int>('interest_minor') +
            row.read<int>('fee_minor'),
        principal,
        row.read<int>('interest_minor'),
        row.read<int>('fee_minor'),
        transactionId,
        '第${row.read<int>('period_no')}期还款',
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  });

  Future<List<CreditCardStatement>> creditCardStatements(
    String assetId,
  ) async => (await _query(
    '''SELECT s.*,
    (SELECT COUNT(*) FROM credit_card_statement_items i WHERE i.statement_id=s.id) AS item_count,
    (SELECT COUNT(*) FROM credit_card_statement_items i WHERE i.statement_id=s.id AND i.checked=1) AS checked_count
    FROM credit_card_statements s WHERE s.asset_id=? ORDER BY period_end DESC''',
    [assetId],
  )).map(_creditCardStatement).toList();

  CreditCardStatement _creditCardStatement(QueryRow row) => CreditCardStatement(
    id: row.read('id'),
    assetId: row.read('asset_id'),
    periodStart: DateTime.parse(row.read('period_start')),
    periodEnd: DateTime.parse(row.read('period_end')),
    dueAt: DateTime.parse(row.read('due_at')),
    statementMinor: row.read('statement_minor'),
    ledgerMinor: row.read('ledger_minor'),
    paidMinor: row.read('paid_minor'),
    status: CreditCardStatementStatus.values.byName(row.read('status')),
    note: row.read('note'),
    itemCount: row.read('item_count'),
    checkedCount: row.read('checked_count'),
  );

  /// Creates a statement and snapshots every ledger transaction posted to the
  /// linked credit-card account in the selected period. Incoming refunds and
  /// repayments reduce the ledger total instead of disappearing from review.
  Future<String> createCreditCardStatement(
    String ledger,
    String assetId, {
    required DateTime periodStart,
    required DateTime periodEnd,
    required DateTime dueAt,
    required int statementMinor,
    String note = '',
  }) => db.transaction(() async {
    final value = await asset(ledger, assetId);
    if (value.kind != FinancialAssetKind.creditCard ||
        value.accountId == null) {
      throw const LedgerException('信用卡账单必须先关联信用卡账户');
    }
    if (periodEnd.isBefore(periodStart) || dueAt.isBefore(periodEnd)) {
      throw const LedgerException('账期或还款日期无效');
    }
    if (statementMinor < 0 || statementMinor > 999999999999999) {
      throw const LedgerException('账单金额无效');
    }
    final entries = await _query(
      '''SELECT t.id,p.delta_minor FROM transactions t
      JOIN transaction_postings p ON p.transaction_id=t.id
      WHERE t.ledger_id=? AND p.account_id=? AND t.deleted_at IS NULL
      AND t.occurred_date>=? AND t.occurred_date<? ORDER BY t.occurred_date''',
      [
        ledger,
        value.accountId!,
        DateTime(
          periodStart.year,
          periodStart.month,
          periodStart.day,
        ).toIso8601String(),
        DateTime(
          periodEnd.year,
          periodEnd.month,
          periodEnd.day + 1,
        ).toIso8601String(),
      ],
    );
    final net = entries.fold<int>(
      0,
      (sum, row) => sum - row.read<int>('delta_minor'),
    );
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      '''INSERT INTO credit_card_statements
      (id,asset_id,period_start,period_end,due_at,statement_minor,ledger_minor,
       paid_minor,status,note,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,0,'open',?,?,?)''',
      [
        id,
        assetId,
        dateKey(periodStart),
        dateKey(periodEnd),
        dateKey(dueAt),
        statementMinor,
        math.max(0, net),
        note.trim(),
        now,
        now,
      ],
    );
    for (final row in entries) {
      await db.customStatement(
        '''INSERT INTO credit_card_statement_items
        (statement_id,transaction_id,checked) VALUES (?,?,0)''',
        [id, row.read<String>('id')],
      );
    }
    return id;
  });

  Future<List<CreditCardStatementLine>> creditCardStatementLines(
    String statementId,
  ) async =>
      (await _query(
            '''SELECT t.id,t.occurred_date,t.amount_minor,t.merchant,t.type,i.checked
    FROM credit_card_statement_items i JOIN transactions t ON t.id=i.transaction_id
    WHERE i.statement_id=? ORDER BY t.occurred_date,t.id''',
            [statementId],
          ))
          .map(
            (row) => CreditCardStatementLine(
              transactionId: row.read('id'),
              occurredAt: DateTime.parse(row.read('occurred_date')),
              amountMinor: row.read('amount_minor'),
              merchant: row.read('merchant'),
              type: TransactionType.values.byName(row.read('type')),
              checked: row.read<int>('checked') == 1,
            ),
          )
          .toList();

  Future<void> setStatementLineChecked(
    String statementId,
    String transactionId,
    bool checked,
  ) async {
    final changed = await db.customUpdate(
      '''UPDATE credit_card_statement_items SET checked=?
      WHERE statement_id=? AND transaction_id=?''',
      variables: [
        Variable<int>(checked ? 1 : 0),
        Variable<String>(statementId),
        Variable<String>(transactionId),
      ],
    );
    if (changed != 1) throw const LedgerException('账单明细不存在');
  }

  Future<void> finishStatementReconciliation(
    String statementId, {
    int? paidMinor,
  }) => db.transaction(() async {
    final rows = await _query(
      '''SELECT s.*,(SELECT COUNT(*) FROM credit_card_statement_items i
      WHERE i.statement_id=s.id AND i.checked=0) AS unchecked
      FROM credit_card_statements s WHERE s.id=?''',
      [statementId],
    );
    if (rows.isEmpty) throw const LedgerException('信用卡账单不存在');
    final row = rows.single;
    if (row.read<int>('unchecked') > 0) {
      throw const LedgerException('仍有账单明细未核对');
    }
    final statement = row.read<int>('statement_minor');
    final previousPaid = row.read<int>('paid_minor');
    final paid = paidMinor ?? row.read<int>('paid_minor');
    if (paid < 0 || paid > statement) throw const LedgerException('还款金额无效');
    final status = paid >= statement ? 'paid' : 'reconciled';
    await db.customStatement(
      'UPDATE credit_card_statements SET paid_minor=?,status=?,updated_at=? WHERE id=?',
      [paid, status, DateTime.now().toUtc().toIso8601String(), statementId],
    );
    final paidDelta = paid - previousPaid;
    if (paidDelta > 0) {
      final assetId = row.read<String>('asset_id');
      final now = DateTime.now().toUtc().toIso8601String();
      await db.customStatement(
        'UPDATE financial_assets SET current_minor=MAX(0,current_minor-?),updated_at=? WHERE id=?',
        [paidDelta, now, assetId],
      );
      await db.customStatement(
        '''INSERT INTO asset_transactions
        (id,asset_id,kind,occurred_at,amount_minor,principal_minor,note,created_at)
        VALUES (?,?,'repayment',?,?,?,?,?)''',
        [_uuid.v4(), assetId, now, paidDelta, paidDelta, '信用卡账单还款', now],
      );
    }
  });

  Future<List<TransactionGroup>> groups(String ledger) async =>
      (await _query(
            '''SELECT g.*,COUNT(i.transaction_id) AS transaction_count,
            COALESCE(SUM(t.amount_minor),0) AS total_minor
            FROM transaction_groups g
            LEFT JOIN transaction_group_items i ON i.group_id=g.id
            LEFT JOIN transactions t ON t.id=i.transaction_id AND t.deleted_at IS NULL
            WHERE g.ledger_id=? GROUP BY g.id ORDER BY g.created_at DESC''',
            [ledger],
          ))
          .map(
            (row) => TransactionGroup(
              id: row.read('id'),
              name: row.read('name'),
              note: row.read('note'),
              transactionCount: row.read('transaction_count'),
              totalMinor: row.read('total_minor'),
            ),
          )
          .toList();

  Future<String> saveGroup(
    String ledger, {
    String? id,
    required String name,
    String note = '',
  }) async {
    if (name.trim().isEmpty || name.trim().length > 60) {
      throw const LedgerException('分组名称需为1～60字');
    }
    final value = id ?? _uuid.v4();
    await db.customStatement(
      '''INSERT INTO transaction_groups (id,ledger_id,name,note,created_at)
      VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,
      note=excluded.note WHERE transaction_groups.ledger_id=excluded.ledger_id''',
      [
        value,
        ledger,
        name.trim(),
        note.trim(),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return value;
  }

  Future<void> assignToGroup(
    String ledger,
    String transactionId,
    String? groupId,
  ) => db.transaction(() async {
    if ((await _query('SELECT 1 FROM transactions WHERE ledger_id=? AND id=?', [
      ledger,
      transactionId,
    ])).isEmpty) {
      throw const LedgerException('账单不存在');
    }
    await db.customStatement(
      'DELETE FROM transaction_group_items WHERE transaction_id=?',
      [transactionId],
    );
    if (groupId != null) {
      if ((await _query(
        'SELECT 1 FROM transaction_groups WHERE ledger_id=? AND id=?',
        [ledger, groupId],
      )).isEmpty) {
        throw const LedgerException('账单分组不存在');
      }
      await db.customStatement(
        'INSERT INTO transaction_group_items VALUES (?,?)',
        [groupId, transactionId],
      );
    }
  });

  Future<String?> transactionGroup(String ledger, String transactionId) async {
    final rows = await _query(
      '''SELECT i.group_id FROM transaction_group_items i
      JOIN transaction_groups g ON g.id=i.group_id
      WHERE g.ledger_id=? AND i.transaction_id=? LIMIT 1''',
      [ledger, transactionId],
    );
    return rows.isEmpty ? null : rows.single.read<String>('group_id');
  }

  Future<void> deleteGroup(
    String ledger,
    String id,
  ) => db.transaction(() async {
    await db.customStatement(
      'DELETE FROM transaction_group_items WHERE group_id IN (SELECT id FROM transaction_groups WHERE id=? AND ledger_id=?)',
      [id, ledger],
    );
    await db.customStatement(
      'DELETE FROM transaction_groups WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
  });

  Future<List<TransactionSplit>> splits(
    String ledger,
    String transactionId,
  ) async =>
      (await _query(
            '''SELECT s.* FROM transaction_splits s
            JOIN transactions t ON t.id=s.transaction_id
            WHERE t.ledger_id=? AND t.id=? ORDER BY s.rowid''',
            [ledger, transactionId],
          ))
          .map(
            (row) => TransactionSplit(
              id: row.read('id'),
              participant: row.read('participant'),
              amountMinor: row.read('amount_minor'),
              settled: row.read<int>('settled') == 1,
              note: row.read('note'),
            ),
          )
          .toList();

  Future<void> replaceSplits(
    String ledger,
    String transactionId,
    List<TransactionSplit> values,
  ) => db.transaction(() async {
    final transactions = await _query(
      "SELECT amount_minor,type FROM transactions WHERE ledger_id=? AND id=? AND deleted_at IS NULL",
      [ledger, transactionId],
    );
    if (transactions.isEmpty) throw const LedgerException('账单不存在');
    if (transactions.single.read<String>('type') == 'transfer') {
      throw const LedgerException('转账账单不支持拆分或AA');
    }
    if (values.isEmpty || values.length > 100) {
      throw const LedgerException('拆分明细需为1～100项');
    }
    final participants = <String>{};
    var total = 0;
    for (final value in values) {
      final participant = value.participant.trim();
      if (participant.isEmpty || participant.length > 40) {
        throw const LedgerException('参与人名称需为1～40字');
      }
      if (!participants.add(participant)) {
        throw const LedgerException('参与人不能重复');
      }
      if (value.amountMinor <= 0) throw const LedgerException('拆分金额必须大于0');
      total += value.amountMinor;
    }
    if (total != transactions.single.read<int>('amount_minor')) {
      throw const LedgerException('拆分金额合计必须等于账单人民币金额');
    }
    await db.customStatement(
      'DELETE FROM transaction_splits WHERE transaction_id=?',
      [transactionId],
    );
    for (final value in values) {
      await db.customStatement(
        '''INSERT INTO transaction_splits
        (id,transaction_id,participant,amount_minor,settled,note)
        VALUES (?,?,?,?,?,?)''',
        [
          value.id.isEmpty ? _uuid.v4() : value.id,
          transactionId,
          value.participant.trim(),
          value.amountMinor,
          value.settled ? 1 : 0,
          value.note.trim(),
        ],
      );
    }
  });

  Future<void> clearSplits(String ledger, String transactionId) async {
    final changed = await _query(
      'SELECT 1 FROM transactions WHERE ledger_id=? AND id=?',
      [ledger, transactionId],
    );
    if (changed.isEmpty) throw const LedgerException('账单不存在');
    await db.customStatement(
      'DELETE FROM transaction_splits WHERE transaction_id=?',
      [transactionId],
    );
  }

  static List<TransactionSplit> equalSplits(
    int totalMinor,
    Iterable<String> names,
  ) {
    final values = names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (totalMinor <= 0 ||
        values.isEmpty ||
        values.toSet().length != values.length) {
      throw const LedgerException('请输入不重复的参与人');
    }
    final base = totalMinor ~/ values.length;
    var remainder = totalMinor % values.length;
    return [
      for (final name in values)
        TransactionSplit(
          id: '',
          participant: name,
          amountMinor: base + (remainder-- > 0 ? 1 : 0),
        ),
    ];
  }

  Future<List<PendingDraft>> ignoredDrafts(String ledger) async =>
      (await _query(
            "SELECT d.id AS draft_id,d.parsed_json,r.* FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE r.ledger_id=? AND d.status='ignored' ORDER BY d.updated_at DESC",
            [ledger],
          ))
          .map(
            (row) => PendingDraft(
              id: row.read('draft_id'),
              ledgerId: ledger,
              raw: RawTransaction(
                text: row.read('raw_text'),
                capturedAt: DateTime.parse(row.read('captured_at')),
                source: TransactionSource.values.byName(row.read('source')),
              ),
            ),
          )
          .toList();

  Future<void> ignoreDrafts(String ledger, Iterable<String> ids) =>
      db.transaction(() async {
        for (final id in ids.toSet()) {
          final changed = await db.customUpdate(
            '''UPDATE transaction_drafts SET status='ignored',updated_at=?
            WHERE id=? AND status='pending' AND raw_id IN
            (SELECT id FROM raw_transactions WHERE ledger_id=?)''',
            variables: [
              Variable<String>(DateTime.now().toUtc().toIso8601String()),
              Variable<String>(id),
              Variable<String>(ledger),
            ],
          );
          if (changed != 1) throw const LedgerException('部分草稿已被处理，请刷新后重试');
        }
      });

  Future<void> restoreIgnoredDraft(String ledger, String id) async {
    final changed = await db.customUpdate(
      '''UPDATE transaction_drafts SET status='pending',updated_at=?
      WHERE id=? AND status='ignored' AND raw_id IN
      (SELECT id FROM raw_transactions WHERE ledger_id=?)''',
      variables: [
        Variable<String>(DateTime.now().toUtc().toIso8601String()),
        Variable<String>(id),
        Variable<String>(ledger),
      ],
    );
    if (changed != 1) throw const LedgerException('忽略记录不存在');
  }

  Future<int> clearIgnoredDrafts(String ledger) => db.transaction(() async {
    final raw = await _query(
      '''SELECT d.raw_id FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id
      WHERE r.ledger_id=? AND d.status='ignored' ''',
      [ledger],
    );
    await db.customStatement(
      '''DELETE FROM transaction_drafts WHERE status='ignored' AND raw_id IN
      (SELECT id FROM raw_transactions WHERE ledger_id=?)''',
      [ledger],
    );
    for (final row in raw) {
      await db.customStatement(
        'DELETE FROM raw_transactions WHERE id=? AND NOT EXISTS (SELECT 1 FROM transaction_drafts WHERE raw_id=?)',
        [row.read<String>('raw_id'), row.read<String>('raw_id')],
      );
    }
    return raw.length;
  });
}
