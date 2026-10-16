import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/advanced_finance_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'action_form.dart' show showError;
import 'money_privacy.dart';
import 'widgets.dart';

Future<void> showFinancialAssetsPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const FinancialAssetsPage()));

const _assetLabels = <FinancialAssetKind, String>{
  FinancialAssetKind.stock: '股票',
  FinancialAssetKind.fund: '基金',
  FinancialAssetKind.fixedDeposit: '定期存款',
  FinancialAssetKind.mortgage: '房贷',
  FinancialAssetKind.installment: '分期',
  FinancialAssetKind.lent: '借出 / 收回',
  FinancialAssetKind.creditCard: '信用卡账单周期',
};

bool _isLiability(FinancialAssetKind kind) => const {
  FinancialAssetKind.mortgage,
  FinancialAssetKind.installment,
  FinancialAssetKind.creditCard,
}.contains(kind);

class FinancialAssetsPage extends ConsumerStatefulWidget {
  const FinancialAssetsPage({super.key});

  @override
  ConsumerState<FinancialAssetsPage> createState() =>
      _FinancialAssetsPageState();
}

class _FinancialAssetsPageState extends ConsumerState<FinancialAssetsPage> {
  List<FinancialAsset>? _assets;
  List<CurrencyDefinition> _currencies = const [];
  bool _showArchived = false;

  AdvancedFinanceRepository get _repository =>
      AdvancedFinanceRepository(ref.read(repositoryProvider).db);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ledger = ref.read(ledgerProvider).ledgerId;
      final results = await Future.wait([
        _repository.assets(ledger, includeArchived: _showArchived),
        _repository.currencies(ledger),
      ]);
      if (!mounted) return;
      setState(() {
        _assets = results[0] as List<FinancialAsset>;
        _currencies = results[1] as List<CurrencyDefinition>;
      });
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  int _cnyValue(FinancialAsset asset) {
    final currency = _currencies
        .where((value) => value.code == asset.currency)
        .firstOrNull;
    return AdvancedFinanceRepository.convertToCny(
      asset.currentMinor,
      currency?.rateToCnyMicros ?? 1000000,
    );
  }

  Future<void> _edit([FinancialAsset? asset]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AssetEditor(asset: asset),
    );
    if (changed == true) await _load();
  }

  Future<void> _archive(FinancialAsset asset) async {
    try {
      await _repository.setAssetArchived(
        ref.read(ledgerProvider).ledgerId,
        asset.id,
        !asset.archived,
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _open(FinancialAsset asset) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FinancialAssetDetailPage(assetId: asset.id),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final assets = _assets;
    final assetTotal =
        assets
            ?.where((asset) => !_isLiability(asset.kind) && !asset.archived)
            .fold<int>(0, (sum, asset) => sum + _cnyValue(asset)) ??
        0;
    final liabilityTotal =
        assets
            ?.where((asset) => _isLiability(asset.kind) && !asset.archived)
            .fold<int>(0, (sum, asset) => sum + _cnyValue(asset)) ??
        0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('资产与负债'),
        actions: [
          IconButton(
            tooltip: _showArchived ? '隐藏已归档' : '显示已归档',
            onPressed: () {
              setState(() => _showArchived = !_showArchived);
              _load();
            },
            icon: Icon(
              _showArchived ? Icons.inventory : Icons.inventory_2_outlined,
            ),
          ),
          IconButton(
            tooltip: '添加资产',
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: assets == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _SummaryValue(
                          label: '资产估值',
                          value: visibleMoney(context, assetTotal),
                          color: teal,
                        ),
                      ),
                      Expanded(
                        child: _SummaryValue(
                          label: '负债余额',
                          value: visibleMoney(context, liabilityTotal),
                          color: orange,
                        ),
                      ),
                      Expanded(
                        child: _SummaryValue(
                          label: '净值',
                          value: visibleMoney(
                            context,
                            assetTotal - liabilityTotal,
                          ),
                          color: ink,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (assets.isEmpty)
                  EmptyView(
                    title: '还没有资产项目',
                    description: '可添加股票、基金、定期存款、房贷、分期、借出和信用卡账单周期。',
                    action: FilledButton.icon(
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add),
                      label: const Text('添加项目'),
                    ),
                  )
                else
                  SectionCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < assets.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, indent: 64, endIndent: 12),
                          _assetTile(assets[i]),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _assetTile(FinancialAsset asset) {
    final currency = _currencies
        .where((value) => value.code == asset.currency)
        .firstOrNull;
    final details = <String>[
      _assetLabels[asset.kind]!,
      asset.currency,
      if (asset.totalPeriods > 0)
        '${asset.completedPeriods}/${asset.totalPeriods}期',
      if (asset.billingDay != null) '${asset.billingDay}日账单',
      if (asset.repaymentDay != null) '${asset.repaymentDay}日还款',
      if (asset.archived) '已归档',
    ];
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: (_isLiability(asset.kind) ? orange : teal).withValues(
          alpha: .1,
        ),
        child: Icon(
          _assetIcon(asset.kind),
          color: _isLiability(asset.kind) ? orange : teal,
          size: 20,
        ),
      ),
      title: Text(asset.name),
      subtitle: Text(details.join(' · ')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            MoneyPrivacy.of(context)
                ? '••••'
                : currencyMoney(
                    asset.currentMinor,
                    symbol: currency?.symbol ?? asset.currency,
                    decimals: currency?.decimals ?? 2,
                  ),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: () => _open(asset),
      onLongPress: () => _archive(asset),
    );
  }
}

class FinancialAssetDetailPage extends ConsumerStatefulWidget {
  const FinancialAssetDetailPage({required this.assetId, super.key});
  final String assetId;

  @override
  ConsumerState<FinancialAssetDetailPage> createState() =>
      _FinancialAssetDetailPageState();
}

class _FinancialAssetDetailPageState
    extends ConsumerState<FinancialAssetDetailPage> {
  FinancialAssetSummary? _summary;
  List<AssetTransaction> _transactions = const [];
  List<AssetValuation> _valuations = const [];
  List<AssetScheduleItem> _schedule = const [];
  List<CreditCardStatement> _statements = const [];
  CurrencyDefinition? _currency;
  bool _loading = true;

  AdvancedFinanceRepository get _repository =>
      AdvancedFinanceRepository(ref.read(repositoryProvider).db);
  String get _ledger => ref.read(ledgerProvider).ledgerId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final summary = await _repository.assetSummary(_ledger, widget.assetId);
      final results = await Future.wait([
        _repository.assetTransactions(widget.assetId),
        _repository.valuations(widget.assetId),
        _repository.schedule(widget.assetId),
        _repository.creditCardStatements(widget.assetId),
        _repository.currency(_ledger, summary.asset.currency),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _transactions = results[0] as List<AssetTransaction>;
        _valuations = results[1] as List<AssetValuation>;
        _schedule = results[2] as List<AssetScheduleItem>;
        _statements = results[3] as List<CreditCardStatement>;
        _currency = results[4] as CurrencyDefinition;
        _loading = false;
      });
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  String _money(int value) => MoneyPrivacy.of(context)
      ? '••••'
      : currencyMoney(
          value,
          symbol: _currency?.symbol ?? '¥',
          decimals: _currency?.decimals ?? 2,
        );

  Future<void> _edit() async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AssetEditor(asset: _summary!.asset),
    );
    if (changed == true) await _load();
  }

  Future<void> _activity(
    AssetTransactionKind kind, {
    required String title,
    bool quantity = false,
    bool principal = false,
    bool interest = false,
  }) async {
    final amount = TextEditingController();
    final quantityController = TextEditingController();
    final fee = TextEditingController();
    final interestController = TextEditingController();
    final note = TextEditingController();
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: principal ? '收回/偿还总额' : '金额',
                  ),
                  validator: _positiveMoneyValidator,
                ),
                if (quantity) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '份额'),
                    validator: (value) => _positiveScaledValidator(value, 6),
                  ),
                ],
                if (principal) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: fee,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '其中本金'),
                    validator: _positiveMoneyValidator,
                  ),
                ] else if (kind == AssetTransactionKind.buy ||
                    kind == AssetTransactionKind.sell) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: fee,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '手续费（选填）'),
                  ),
                ],
                if (interest) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: interestController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '其中利息（选填）'),
                  ),
                ],
                const SizedBox(height: 10),
                TextFormField(
                  controller: note,
                  decoration: const InputDecoration(labelText: '备注（选填）'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('保存流水'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final amountMinor = _parseMoney(amount.text);
      await _repository.recordAssetTransaction(
        _ledger,
        widget.assetId,
        kind: kind,
        occurredAt: DateTime.now(),
        amountMinor: amountMinor,
        quantityMicros: quantity
            ? _parseNonNegative(quantityController.text, 6)
            : 0,
        principalMinor: principal ? _parseMoney(fee.text) : 0,
        interestMinor: interest && interestController.text.trim().isNotEmpty
            ? _parseMoney(interestController.text)
            : 0,
        feeMinor: !principal && fee.text.trim().isNotEmpty
            ? _parseMoney(fee.text)
            : 0,
        accountId: _summary!.asset.accountId,
        note: note.text,
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      amount.dispose();
      quantityController.dispose();
      fee.dispose();
      interestController.dispose();
      note.dispose();
    }
  }

  int _parseMoney(String text) =>
      _parseNonNegative(text, _currency?.decimals ?? 2);

  String? _positiveMoneyValidator(String? value) =>
      _positiveScaledValidator(value, _currency?.decimals ?? 2);

  String? _positiveScaledValidator(String? value, int decimals) {
    try {
      if (value == null || value.trim().isEmpty) return '请填写数值';
      return _parseNonNegative(value, decimals) <= 0 ? '数值必须大于零' : null;
    } catch (_) {
      return '格式不正确';
    }
  }

  Future<void> _addValuation() async {
    final unit = TextEditingController();
    final total = TextEditingController();
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('记录净值 / 市值'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: unit,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '单位净值/价格（最多6位）'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: total,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '总市值（选填，可按份额计算）'),
                validator: (value) {
                  if ((value == null || value.trim().isEmpty) &&
                      unit.text.trim().isEmpty) {
                    return '至少填写单位净值或总市值';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('记录'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await _repository.addValuation(
        _ledger,
        widget.assetId,
        valuedAt: DateTime.now(),
        unitValueMicros: unit.text.trim().isEmpty
            ? 0
            : _parseNonNegative(unit.text, 6),
        totalValueMinor: total.text.trim().isEmpty
            ? null
            : _parseMoney(total.text),
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      unit.dispose();
      total.dispose();
    }
  }

  Future<void> _generateSchedule() async {
    final periods = TextEditingController(
      text:
          (_summary!.asset.totalPeriods > 0 ? _summary!.asset.totalPeriods : 12)
              .toString(),
    );
    final fee = TextEditingController();
    var firstDue = DateTime.now().add(const Duration(days: 30));
    var method = RepaymentMethod.equalInstallment;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('生成还款计划'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: periods,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '剩余期数'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<RepaymentMethod>(
                initialValue: method,
                decoration: const InputDecoration(labelText: '还款方式'),
                items: const [
                  DropdownMenuItem(
                    value: RepaymentMethod.equalInstallment,
                    child: Text('等额本息'),
                  ),
                  DropdownMenuItem(
                    value: RepaymentMethod.equalPrincipal,
                    child: Text('等额本金'),
                  ),
                ],
                onChanged: (value) => setDialogState(() => method = value!),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: fee,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '每期手续费（选填）'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  final value = await showDatePicker(
                    context: context,
                    initialDate: firstDue,
                    firstDate: DateTime.now(),
                    lastDate: DateTime(2200),
                  );
                  if (value != null) setDialogState(() => firstDue = value);
                },
                icon: const Icon(Icons.event),
                label: Text('首期 ${dateKey(firstDue)}'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('生成'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    try {
      await _repository.generateRepaymentSchedule(
        _ledger,
        widget.assetId,
        firstDueDate: firstDue,
        periods: int.tryParse(periods.text) ?? 0,
        method: method,
        monthlyFeeMinor: fee.text.trim().isEmpty ? 0 : _parseMoney(fee.text),
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      periods.dispose();
      fee.dispose();
    }
  }

  Future<void> _createStatement() async {
    final amount = TextEditingController();
    final now = DateTime.now();
    var start = DateTime(now.year, now.month - 1, 1);
    var end = DateTime(now.year, now.month, 0);
    var due = DateTime(now.year, now.month, _summary!.asset.repaymentDay ?? 20);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建信用卡账单'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: '银行账单金额'),
              ),
              const SizedBox(height: 10),
              _DialogDateButton(
                label: '账期开始',
                value: start,
                onChanged: (value) => setDialogState(() => start = value),
              ),
              _DialogDateButton(
                label: '账期结束',
                value: end,
                onChanged: (value) => setDialogState(() => end = value),
              ),
              _DialogDateButton(
                label: '还款日',
                value: due,
                onChanged: (value) => setDialogState(() => due = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('生成并匹配流水'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    try {
      await _repository.createCreditCardStatement(
        _ledger,
        widget.assetId,
        periodStart: start,
        periodEnd: end,
        dueAt: due,
        statementMinor: _parseMoney(amount.text),
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      amount.dispose();
    }
  }

  Future<void> _reviewStatement(CreditCardStatement statement) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _StatementReviewDialog(
        repository: _repository,
        statement: statement,
        money: _money,
      ),
    );
    await _load();
  }

  Widget _action(String label, IconData icon, VoidCallback onPressed) =>
      FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  List<Widget> _actions(FinancialAsset asset) => switch (asset.kind) {
    FinancialAssetKind.stock || FinancialAssetKind.fund => [
      _action(
        '买入',
        Icons.add_chart,
        () =>
            _activity(AssetTransactionKind.buy, title: '记录买入', quantity: true),
      ),
      _action(
        '卖出',
        Icons.sell_outlined,
        () =>
            _activity(AssetTransactionKind.sell, title: '记录卖出', quantity: true),
      ),
      _action(
        '分红',
        Icons.payments_outlined,
        () => _activity(AssetTransactionKind.dividend, title: '记录分红'),
      ),
      _action('净值', Icons.show_chart, _addValuation),
    ],
    FinancialAssetKind.fixedDeposit => [
      _action(
        '存入',
        Icons.savings_outlined,
        () => _activity(AssetTransactionKind.deposit, title: '记录存入'),
      ),
      _action(
        '取出',
        Icons.outbox_outlined,
        () => _activity(AssetTransactionKind.withdraw, title: '记录取出'),
      ),
      _action(
        '利息',
        Icons.percent,
        () => _activity(AssetTransactionKind.interest, title: '记录利息'),
      ),
    ],
    FinancialAssetKind.lent => [
      _action(
        '借出',
        Icons.call_made,
        () => _activity(AssetTransactionKind.lend, title: '记录借出'),
      ),
      _action(
        '收回',
        Icons.call_received,
        () => _activity(
          AssetTransactionKind.collect,
          title: '记录收回',
          principal: true,
          interest: true,
        ),
      ),
    ],
    FinancialAssetKind.mortgage || FinancialAssetKind.installment => [
      _action('生成计划', Icons.calendar_month_outlined, _generateSchedule),
    ],
    FinancialAssetKind.creditCard => [
      _action('新建账单', Icons.receipt_long_outlined, _createStatement),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    if (_loading || summary == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final asset = summary.asset;
    return Scaffold(
      appBar: AppBar(
        title: Text(asset.name),
        actions: [
          IconButton(
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑资料',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SectionCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _assetIcon(asset.kind),
                        color: _isLiability(asset.kind) ? orange : teal,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _assetLabels[asset.kind]!,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      Text(
                        asset.currency,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _money(asset.currentMinor),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 18,
                    runSpacing: 8,
                    children: [
                      Text(
                        '${_isLiability(asset.kind) ? '原始负债' : '本金/成本'} ${_money(asset.principalMinor)}',
                      ),
                      if (asset.quantityMicros > 0)
                        Text('持仓 ${_decimal(asset.quantityMicros, 6)}'),
                      if (const {
                        FinancialAssetKind.stock,
                        FinancialAssetKind.fund,
                      }.contains(asset.kind))
                        Text(
                          '总收益 ${_money(summary.totalReturnMinor)} · ${(summary.returnBps / 100).toStringAsFixed(2)}%',
                        ),
                      if (const {
                        FinancialAssetKind.stock,
                        FinancialAssetKind.fund,
                      }.contains(asset.kind))
                        Text(
                          '已实现 ${_money(summary.realizedMinor)} · 浮动 ${_money(summary.unrealizedMinor)}',
                        ),
                      if (summary.nextDue != null)
                        Text(
                          '下期 ${dateKey(summary.nextDue!.dueAt)} · ${_money(summary.nextDue!.totalMinor)}',
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: _actions(asset)),
            if (_schedule.isNotEmpty) ...[
              const SizedBox(height: 18),
              _DetailHeading(
                title: asset.kind == FinancialAssetKind.installment
                    ? '分期明细'
                    : '还款计划',
                count: _schedule.length,
              ),
              SectionCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final item in _schedule)
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text(
                            '${item.periodNo}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        title: Text(
                          '${dateKey(item.dueAt)} · ${_money(item.totalMinor)}',
                        ),
                        subtitle: Text(
                          '本金 ${_money(item.principalMinor)} · 利息 ${_money(item.interestMinor)}${item.feeMinor > 0 ? ' · 费用 ${_money(item.feeMinor)}' : ''}',
                        ),
                        trailing: item.status == AssetScheduleStatus.paid
                            ? const Chip(label: Text('已还'))
                            : TextButton(
                                onPressed: () async {
                                  try {
                                    await _repository.markSchedulePaid(
                                      _ledger,
                                      item.id,
                                    );
                                    await _load();
                                  } catch (error) {
                                    if (mounted) showError(this.context, error);
                                  }
                                },
                                child: const Text('标记已还'),
                              ),
                      ),
                  ],
                ),
              ),
            ],
            if (_statements.isNotEmpty) ...[
              const SizedBox(height: 18),
              _DetailHeading(title: '信用卡账单核对', count: _statements.length),
              SectionCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final statement in _statements)
                      ListTile(
                        title: Text(
                          '${dateKey(statement.periodStart)} ～ ${dateKey(statement.periodEnd)}',
                        ),
                        subtitle: Text(
                          '银行 ${_money(statement.statementMinor)} · 账本 ${_money(statement.ledgerMinor)} · 差额 ${_money(statement.differenceMinor)}',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${statement.checkedCount}/${statement.itemCount}',
                            ),
                            Text(switch (statement.status) {
                              CreditCardStatementStatus.open => '待核对',
                              CreditCardStatementStatus.reconciled => '已核对',
                              CreditCardStatementStatus.paid => '已还清',
                            }, style: Theme.of(context).textTheme.labelSmall),
                          ],
                        ),
                        onTap: () => _reviewStatement(statement),
                      ),
                  ],
                ),
              ),
            ],
            if (_valuations.isNotEmpty) ...[
              const SizedBox(height: 18),
              _DetailHeading(title: '净值历史', count: _valuations.length),
              SectionCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final value in _valuations)
                      ListTile(
                        dense: true,
                        title: Text(dateKey(value.valuedAt)),
                        subtitle: value.unitValueMicros > 0
                            ? Text('单位净值 ${_decimal(value.unitValueMicros, 6)}')
                            : null,
                        trailing: Text(_money(value.totalValueMinor)),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            _DetailHeading(
              title: asset.kind == FinancialAssetKind.lent ? '借出与收回流水' : '资产流水',
              count: _transactions.length,
            ),
            if (_transactions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: Text('暂无明细，当前金额作为期初值保留')),
              )
            else
              SectionCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final entry in _transactions)
                      ListTile(
                        dense: true,
                        leading: Icon(_activityIcon(entry.kind), size: 20),
                        title: Text(_activityLabel(entry.kind)),
                        subtitle: Text(
                          '${dateKey(entry.occurredAt)}'
                          '${entry.quantityMicros > 0 ? ' · ${_decimal(entry.quantityMicros, 6)}份' : ''}'
                          '${entry.unitPriceMicros > 0 ? ' · 单价 ${_decimal(entry.unitPriceMicros, 6)}' : ''}'
                          '${entry.note.isEmpty ? '' : ' · ${entry.note}'}',
                        ),
                        trailing: Text(_money(entry.amountMinor)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeading extends StatelessWidget {
  const _DetailHeading({required this.title, required this.count});
  final String title;
  final int count;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      '$title · $count',
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _DialogDateButton extends StatelessWidget {
  const _DialogDateButton({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: Text(dateKey(value)),
    onTap: () async {
      final selected = await showDatePicker(
        context: context,
        initialDate: value,
        firstDate: DateTime(1970),
        lastDate: DateTime(2200),
      );
      if (selected != null) onChanged(selected);
    },
  );
}

String _activityLabel(AssetTransactionKind kind) => switch (kind) {
  AssetTransactionKind.buy => '买入',
  AssetTransactionKind.sell => '卖出',
  AssetTransactionKind.dividend => '分红',
  AssetTransactionKind.interest => '利息',
  AssetTransactionKind.deposit => '存入',
  AssetTransactionKind.withdraw => '取出',
  AssetTransactionKind.lend => '借出',
  AssetTransactionKind.collect => '收回',
  AssetTransactionKind.repayment => '还款',
  AssetTransactionKind.fee => '费用',
  AssetTransactionKind.adjustment => '调整',
};

IconData _activityIcon(AssetTransactionKind kind) => switch (kind) {
  AssetTransactionKind.buy ||
  AssetTransactionKind.deposit ||
  AssetTransactionKind.lend => Icons.add_circle_outline,
  AssetTransactionKind.sell ||
  AssetTransactionKind.withdraw ||
  AssetTransactionKind.collect => Icons.remove_circle_outline,
  AssetTransactionKind.dividend ||
  AssetTransactionKind.interest => Icons.payments_outlined,
  AssetTransactionKind.repayment => Icons.task_alt,
  AssetTransactionKind.fee => Icons.receipt_outlined,
  AssetTransactionKind.adjustment => Icons.tune,
};

class _StatementReviewDialog extends StatefulWidget {
  const _StatementReviewDialog({
    required this.repository,
    required this.statement,
    required this.money,
  });
  final AdvancedFinanceRepository repository;
  final CreditCardStatement statement;
  final String Function(int) money;
  @override
  State<_StatementReviewDialog> createState() => _StatementReviewDialogState();
}

class _StatementReviewDialogState extends State<_StatementReviewDialog> {
  List<CreditCardStatementLine>? _lines;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = await widget.repository.creditCardStatementLines(
      widget.statement.id,
    );
    if (mounted) setState(() => _lines = lines);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('逐笔核对账单'),
    content: SizedBox(
      width: 520,
      child: _lines == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '银行 ${widget.money(widget.statement.statementMinor)} · 账本 ${widget.money(widget.statement.ledgerMinor)}\n差额 ${widget.money(widget.statement.differenceMinor)}',
                  ),
                ),
                const Divider(),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final line in _lines!)
                        CheckboxListTile(
                          value: line.checked,
                          dense: true,
                          title: Text(
                            line.merchant.isEmpty
                                ? _activityTypeLabel(line.type)
                                : line.merchant,
                          ),
                          subtitle: Text(dateKey(line.occurredAt)),
                          secondary: Text(widget.money(line.amountMinor)),
                          onChanged: _busy
                              ? null
                              : (checked) async {
                                  await widget.repository
                                      .setStatementLineChecked(
                                        widget.statement.id,
                                        line.transactionId,
                                        checked!,
                                      );
                                  await _load();
                                },
                        ),
                    ],
                  ),
                ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      TextButton(
        onPressed:
            _busy ||
                _lines == null ||
                _lines!.any((line) => !line.checked) ||
                widget.statement.status == CreditCardStatementStatus.paid
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.repository.finishStatementReconciliation(
                    widget.statement.id,
                    paidMinor: widget.statement.statementMinor,
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (error) {
                  if (context.mounted) showError(context, error);
                  if (mounted) setState(() => _busy = false);
                }
              },
        child: const Text('核对并标记已还'),
      ),
      FilledButton(
        onPressed:
            _busy || _lines == null || _lines!.any((line) => !line.checked)
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.repository.finishStatementReconciliation(
                    widget.statement.id,
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (error) {
                  if (context.mounted) showError(context, error);
                  if (mounted) setState(() => _busy = false);
                }
              },
        child: const Text('完成核对'),
      ),
    ],
  );
}

String _activityTypeLabel(TransactionType type) => switch (type) {
  TransactionType.expense => '支出',
  TransactionType.income => '收入',
  TransactionType.transfer => '转账',
  TransactionType.refund => '退款',
  TransactionType.adjustment => '调整',
};

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    ],
  );
}

IconData _assetIcon(FinancialAssetKind kind) => switch (kind) {
  FinancialAssetKind.stock => Icons.candlestick_chart,
  FinancialAssetKind.fund => Icons.pie_chart_outline,
  FinancialAssetKind.fixedDeposit => Icons.savings_outlined,
  FinancialAssetKind.mortgage => Icons.home_work_outlined,
  FinancialAssetKind.installment => Icons.calendar_month_outlined,
  FinancialAssetKind.lent => Icons.handshake_outlined,
  FinancialAssetKind.creditCard => Icons.credit_card,
};

class _AssetEditor extends ConsumerStatefulWidget {
  const _AssetEditor({this.asset});
  final FinancialAsset? asset;

  @override
  ConsumerState<_AssetEditor> createState() => _AssetEditorState();
}

class _AssetEditorState extends ConsumerState<_AssetEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _principal;
  late final TextEditingController _current;
  late final TextEditingController _quantity;
  late final TextEditingController _rate;
  late final TextEditingController _totalPeriods;
  late final TextEditingController _completedPeriods;
  late final TextEditingController _billingDay;
  late final TextEditingController _repaymentDay;
  late final TextEditingController _counterparty;
  late final TextEditingController _note;
  FinancialAssetKind _kind = FinancialAssetKind.stock;
  String _currency = 'CNY';
  String? _accountId;
  DateTime? _startDate;
  DateTime? _maturityDate;
  List<CurrencyDefinition> _currencies = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final value = widget.asset;
    _kind = value?.kind ?? FinancialAssetKind.stock;
    _currency = value?.currency ?? 'CNY';
    _accountId = value?.accountId;
    _startDate = value?.startDate;
    _maturityDate = value?.maturityDate;
    _name = TextEditingController(text: value?.name ?? '');
    _principal = TextEditingController();
    _current = TextEditingController();
    _quantity = TextEditingController(
      text: value == null || value.quantityMicros == 0
          ? ''
          : _decimal(value.quantityMicros, 6),
    );
    _rate = TextEditingController(
      text: value == null || value.interestBps == 0
          ? ''
          : _decimal(value.interestBps, 2),
    );
    _totalPeriods = TextEditingController(
      text: value?.totalPeriods.toString() ?? '',
    );
    _completedPeriods = TextEditingController(
      text: value?.completedPeriods.toString() ?? '',
    );
    _billingDay = TextEditingController(
      text: value?.billingDay?.toString() ?? '',
    );
    _repaymentDay = TextEditingController(
      text: value?.repaymentDay?.toString() ?? '',
    );
    _counterparty = TextEditingController(text: value?.counterparty ?? '');
    _note = TextEditingController(text: value?.note ?? '');
    _loadCurrencies();
  }

  Future<void> _loadCurrencies() async {
    try {
      final ledger = ref.read(ledgerProvider).ledgerId;
      final values = await AdvancedFinanceRepository(
        ref.read(repositoryProvider).db,
      ).currencies(ledger);
      if (!mounted) return;
      final selected = values.firstWhere(
        (value) => value.code == _currency,
        orElse: () => values.first,
      );
      setState(() {
        _currencies = values;
        _currency = selected.code;
        final asset = widget.asset;
        if (asset != null) {
          _principal.text = _decimal(asset.principalMinor, selected.decimals);
          _current.text = _decimal(asset.currentMinor, selected.decimals);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '币种读取失败');
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _principal,
      _current,
      _quantity,
      _rate,
      _totalPeriods,
      _completedPeriods,
      _billingDay,
      _repaymentDay,
      _counterparty,
      _note,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  CurrencyDefinition get _selectedCurrency => _currencies.firstWhere(
    (value) => value.code == _currency,
    orElse: () => const CurrencyDefinition(
      code: 'CNY',
      name: '人民币',
      symbol: '¥',
      rateToCnyMicros: 1000000,
    ),
  );

  int _optionalMoney(TextEditingController controller) =>
      controller.text.trim().isEmpty
      ? 0
      : _parseNonNegative(controller.text, _selectedCurrency.decimals);

  int _optionalScaled(TextEditingController controller, int decimals) {
    if (controller.text.trim().isEmpty) return 0;
    return _parseNonNegative(controller.text, decimals);
  }

  int? _optionalInt(TextEditingController controller) =>
      controller.text.trim().isEmpty ? null : int.parse(controller.text);

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = widget.asset;
      await AdvancedFinanceRepository(
        ref.read(repositoryProvider).db,
      ).saveAsset(
        ref.read(ledgerProvider).ledgerId,
        FinancialAsset(
          id: existing?.id ?? '',
          kind: _kind,
          name: _name.text,
          accountId: _accountId,
          currency: _currency,
          principalMinor: _optionalMoney(_principal),
          currentMinor: _optionalMoney(_current),
          quantityMicros: _optionalScaled(_quantity, 6),
          interestBps: _optionalScaled(_rate, 2),
          startDate: _startDate,
          maturityDate: _maturityDate,
          totalPeriods: _optionalInt(_totalPeriods) ?? 0,
          completedPeriods: _optionalInt(_completedPeriods) ?? 0,
          billingDay: _optionalInt(_billingDay),
          repaymentDay: _optionalInt(_repaymentDay),
          counterparty: _counterparty.text,
          note: _note.text,
          archived: existing?.archived ?? false,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is LedgerException ? error.message : '保存失败';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(ledgerProvider).allAccounts;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(widget.asset == null ? '添加资产项目' : '编辑资产项目'),
        content: SizedBox(
          width: 520,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  DropdownButtonFormField<FinancialAssetKind>(
                    initialValue: _kind,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '项目类型'),
                    items: [
                      for (final kind in FinancialAssetKind.values)
                        DropdownMenuItem(
                          value: kind,
                          child: Text(_assetLabels[kind]!),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _kind = value!),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _name,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '名称'),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '请输入名称' : null,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue:
                        _currencies.any((value) => value.code == _currency)
                        ? _currency
                        : null,
                    decoration: const InputDecoration(labelText: '币种'),
                    items: [
                      for (final value in _currencies)
                        DropdownMenuItem(
                          value: value.code,
                          child: Text('${value.code} · ${value.name}'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _currency = value!;
                            _principal.clear();
                            _current.clear();
                          }),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: _accountId,
                    decoration: const InputDecoration(labelText: '关联账户（选填）'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('不关联账户'),
                      ),
                      for (final account in accounts)
                        DropdownMenuItem<String?>(
                          value: account.id,
                          child: Text(account.displayName),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _accountId = value),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _numberField(
                          _principal,
                          _isLiability(_kind) ? '原始负债' : '本金 / 成本',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _numberField(
                          _current,
                          _isLiability(_kind) ? '剩余负债' : '当前估值',
                        ),
                      ),
                    ],
                  ),
                  if (_kind == FinancialAssetKind.stock ||
                      _kind == FinancialAssetKind.fund) ...[
                    const SizedBox(height: 10),
                    _numberField(_quantity, '持有份额（最多6位小数）'),
                  ],
                  if (_kind == FinancialAssetKind.fixedDeposit ||
                      _kind == FinancialAssetKind.mortgage ||
                      _kind == FinancialAssetKind.installment ||
                      _kind == FinancialAssetKind.lent) ...[
                    const SizedBox(height: 10),
                    _numberField(_rate, '年利率 %（选填）'),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _dateButton(true)),
                        const SizedBox(width: 10),
                        Expanded(child: _dateButton(false)),
                      ],
                    ),
                  ],
                  if (_kind == FinancialAssetKind.mortgage ||
                      _kind == FinancialAssetKind.installment) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _intField(_totalPeriods, '总期数')),
                        const SizedBox(width: 10),
                        Expanded(child: _intField(_completedPeriods, '已完成期数')),
                      ],
                    ),
                  ],
                  if (_kind == FinancialAssetKind.creditCard) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _dayField(_billingDay, '账单日')),
                        const SizedBox(width: 10),
                        Expanded(child: _dayField(_repaymentDay, '还款日')),
                      ],
                    ),
                  ],
                  if (_kind == FinancialAssetKind.lent) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _counterparty,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: '借款人 / 对方'),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _note,
                    enabled: !_busy,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: '备注'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (widget.asset != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await AdvancedFinanceRepository(
                        ref.read(repositoryProvider).db,
                      ).setAssetArchived(
                        ref.read(ledgerProvider).ledgerId,
                        widget.asset!.id,
                        !widget.asset!.archived,
                      );
                      if (context.mounted) Navigator.pop(context, true);
                    },
              child: Text(widget.asset!.archived ? '恢复' : '归档'),
            ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy || _currencies.isEmpty ? null : _save,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }

  Widget _numberField(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        enabled: !_busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          if (value == null || value.trim().isEmpty) return null;
          try {
            if (controller == _quantity) {
              _parseNonNegative(value, 6);
            } else if (controller == _rate) {
              _parseNonNegative(value, 2);
            } else {
              _parseNonNegative(value, _selectedCurrency.decimals);
            }
            return null;
          } catch (error) {
            return error.toString();
          }
        },
      );

  Widget _intField(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        validator: (value) => value == null || value.trim().isEmpty
            ? null
            : int.tryParse(value) == null
            ? '请输入整数'
            : null,
      );

  Widget _dayField(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          if (value == null || value.trim().isEmpty) return null;
          final day = int.tryParse(value);
          return day == null || day < 1 || day > 31 ? '请输入1～31' : null;
        },
      );

  Widget _dateButton(bool start) {
    final value = start ? _startDate : _maturityDate;
    return OutlinedButton.icon(
      onPressed: _busy
          ? null
          : () async {
              final selected = await showDatePicker(
                context: context,
                initialDate: value ?? DateTime.now(),
                firstDate: DateTime(1970),
                lastDate: DateTime(2200),
              );
              if (selected != null && mounted) {
                setState(() {
                  if (start) {
                    _startDate = selected;
                  } else {
                    _maturityDate = selected;
                  }
                });
              }
            },
      icon: const Icon(Icons.calendar_today_outlined, size: 17),
      label: Text(value == null ? (start ? '开始日期' : '到期日期') : dateKey(value)),
    );
  }
}

String _decimal(int value, int decimals) =>
    currencyMoney(value, symbol: '', decimals: decimals, showSymbol: false);

int _parseNonNegative(String value, int decimals) {
  final text = value.trim();
  final zero = decimals == 0
      ? RegExp(r'^0$')
      : RegExp('^0(\\.0{1,$decimals})?\$');
  return zero.hasMatch(text) ? 0 : parseMinorUnits(text, decimals);
}
