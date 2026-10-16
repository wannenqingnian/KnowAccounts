import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/budget_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'money_privacy.dart';
import 'action_form.dart' show showError;
import 'widgets.dart';

Future<void> showBudgetPlansPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const BudgetPlansPage()));

String _periodLabel(BudgetPeriodKind kind) => switch (kind) {
  BudgetPeriodKind.monthly => '每月',
  BudgetPeriodKind.quarterly => '每季',
  BudgetPeriodKind.yearly => '每年',
  BudgetPeriodKind.custom => '自定义',
};

String _rolloverLabel(BudgetRolloverMode mode) => switch (mode) {
  BudgetRolloverMode.none => '不结转',
  BudgetRolloverMode.positive => '结转剩余额度',
  BudgetRolloverMode.all => '结转余额（含超支）',
};

String _dateLabel(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

class BudgetPlansPage extends ConsumerStatefulWidget {
  const BudgetPlansPage({super.key});

  @override
  ConsumerState<BudgetPlansPage> createState() => _BudgetPlansPageState();
}

class _BudgetPlansPageState extends ConsumerState<BudgetPlansPage> {
  bool _loading = true;
  bool _showHidden = false;
  bool _showArchived = false;
  List<BudgetPlan> _plans = const [];
  Map<String, BudgetPeriodSummary> _summaries = const {};

  LedgerController get _state => ref.read(ledgerProvider);
  BudgetRepository get _repository => BudgetRepository(_state.repository.db);
  DateTime get _date => DateTime(_state.month.year, _state.month.month + 1, 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final plans = await _repository.plans(
        _state.ledgerId,
        includeHidden: _showHidden,
        includeArchived: _showArchived,
      );
      final summaries = <String, BudgetPeriodSummary>{};
      for (final plan in plans) {
        if (plan.archived) continue;
        final value = await _repository.periodSummary(
          _state.ledgerId,
          plan,
          _date,
        );
        if (value != null) summaries[plan.id] = value;
      }
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _summaries = summaries;
      });
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([BudgetPlan? plan]) async {
    final saved = await showBudgetEditor(context, _state, plan: plan);
    if (saved == true) {
      await _state.load();
      await _load();
    }
  }

  Future<void> _action(BudgetPlan plan, String action) async {
    try {
      switch (action) {
        case 'edit':
          await _edit(plan);
          return;
        case 'hide':
          await _repository.setHidden(_state.ledgerId, plan.id, !plan.hidden);
          break;
        case 'archive':
          await _repository.setArchived(
            _state.ledgerId,
            plan.id,
            !plan.archived,
          );
          break;
      }
      await _state.load();
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _summaries.values.toList();
    final exceeded = active.where((e) => e.exceeded).length;
    final warning = active.where((e) => !e.exceeded && e.warning).length;
    return Scaffold(
      appBar: AppBar(title: const Text('预算管理')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('新增预算'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '多预算概览',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text('${_state.month.year}年${_state.month.month}月'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '生效 ${active.length} 项 · 超支 $exceeded 项 · 临近 $warning 项',
                    style: TextStyle(
                      color: exceeded > 0 || warning > 0 ? orange : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        selected: _showHidden,
                        label: const Text('显示隐藏'),
                        onSelected: (value) {
                          _showHidden = value;
                          _load();
                        },
                      ),
                      FilterChip(
                        selected: _showArchived,
                        label: const Text('显示归档'),
                        onSelected: (value) {
                          _showArchived = value;
                          _load();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(36),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_plans.isEmpty)
              const SectionCard(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('还没有预算，点击右下角新增')),
                ),
              )
            else
              for (final plan in _plans) ...[
                _BudgetPlanCard(
                  plan: plan,
                  summary: _summaries[plan.id],
                  onTap: _summaries[plan.id] == null
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => BudgetDetailPage(
                              ledger: _state.ledgerId,
                              repository: _repository,
                              summary: _summaries[plan.id]!,
                            ),
                          ),
                        ),
                  onAction: (action) => _action(plan, action),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ),
      ),
    );
  }
}

class _BudgetPlanCard extends StatelessWidget {
  const _BudgetPlanCard({
    required this.plan,
    required this.summary,
    required this.onTap,
    required this.onAction,
  });

  final BudgetPlan plan;
  final BudgetPeriodSummary? summary;
  final VoidCallback? onTap;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final status = plan.archived
        ? '已归档'
        : plan.hidden
        ? '已隐藏'
        : summary?.exceeded == true
        ? '已超支'
        : summary?.warning == true
        ? '临近上限'
        : '进行中';
    final statusColor = summary?.exceeded == true || summary?.warning == true
        ? orange
        : Colors.grey;
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    plan.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  status,
                  style: TextStyle(color: statusColor, fontSize: 12),
                ),
                PopupMenuButton<String>(
                  onSelected: onAction,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(
                      value: 'hide',
                      child: Text(plan.hidden ? '取消隐藏' : '隐藏'),
                    ),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(plan.archived ? '恢复归档' : '归档'),
                    ),
                  ],
                ),
              ],
            ),
            Text(
              '${plan.categoryName ?? '全部支出'} · ${_periodLabel(plan.periodKind)} · ${_rolloverLabel(plan.rolloverMode)}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            if (summary == null)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('所选月份不在此预算周期内'),
              )
            else ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '剩余 ${visibleMoney(context, summary!.remainingMinor)}',
                      style: TextStyle(
                        color: summary!.exceeded ? orange : ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '已用 ${visibleMoney(context, summary!.spentMinor)} / ${visibleMoney(context, summary!.availableMinor)}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: MoneyPrivacy.of(context) ? 0 : summary!.progress,
                minHeight: 7,
                color: summary!.exceeded || summary!.warning ? orange : teal,
                backgroundColor: const Color(0xFFECF1E8),
                borderRadius: BorderRadius.circular(8),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<bool?> showBudgetEditor(
  BuildContext context,
  LedgerController state, {
  BudgetPlan? plan,
}) async {
  final name = TextEditingController(text: plan?.name ?? '日常预算');
  final amount = TextEditingController(
    text: plan == null ? '' : (plan.amountMinor / 100).toStringAsFixed(2),
  );
  final alert = TextEditingController(
    text: ((plan?.alertBps ?? 8000) / 100).toStringAsFixed(0),
  );
  var categoryId = plan?.categoryId;
  var period = plan?.periodKind ?? BudgetPeriodKind.monthly;
  var rollover = plan?.rolloverMode ?? BudgetRolloverMode.none;
  var alertEnabled = plan?.alertEnabled ?? true;
  var starts = plan?.startsOn ?? DateTime.now();
  var customEnd =
      plan?.customEndOn ?? DateTime(starts.year, starts.month + 1, 0);
  final categories = state.categories
      .where((c) => c.type == TransactionType.expense)
      .toList();
  String categoryName(Category category) {
    if (category.parentId == null) return category.name;
    final matches = categories.where((value) => value.id == category.parentId);
    final parent = matches.isEmpty ? null : matches.first;
    return parent == null ? category.name : '${parent.name} / ${category.name}';
  }

  try {
    return await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(plan == null ? '新增预算' : '编辑预算'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    maxLength: 60,
                    decoration: const InputDecoration(labelText: '预算名称'),
                  ),
                  TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '预算金额'),
                  ),
                  DropdownButtonFormField<String?>(
                    initialValue: categoryId,
                    decoration: const InputDecoration(labelText: '分类范围'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('全部支出'),
                      ),
                      for (final category in categories)
                        DropdownMenuItem<String?>(
                          value: category.id,
                          child: Text(categoryName(category)),
                        ),
                    ],
                    onChanged: (value) => setLocal(() => categoryId = value),
                  ),
                  DropdownButtonFormField<BudgetPeriodKind>(
                    initialValue: period,
                    decoration: const InputDecoration(labelText: '预算周期'),
                    items: [
                      for (final value in BudgetPeriodKind.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_periodLabel(value)),
                        ),
                    ],
                    onChanged: (value) =>
                        setLocal(() => period = value ?? period),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开始日期'),
                    trailing: Text(_dateLabel(starts)),
                    onTap: () async {
                      final value = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDate: starts,
                      );
                      if (value != null) setLocal(() => starts = value);
                    },
                  ),
                  if (period == BudgetPeriodKind.custom)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('结束日期'),
                      trailing: Text(_dateLabel(customEnd)),
                      onTap: () async {
                        final value = await showDatePicker(
                          context: context,
                          firstDate: starts,
                          lastDate: DateTime(2100),
                          initialDate: customEnd.isBefore(starts)
                              ? starts
                              : customEnd,
                        );
                        if (value != null) setLocal(() => customEnd = value);
                      },
                    ),
                  if (period != BudgetPeriodKind.custom)
                    DropdownButtonFormField<BudgetRolloverMode>(
                      initialValue: rollover,
                      decoration: const InputDecoration(labelText: '周期结转'),
                      items: [
                        for (final value in BudgetRolloverMode.values)
                          DropdownMenuItem(
                            value: value,
                            child: Text(_rolloverLabel(value)),
                          ),
                      ],
                      onChanged: (value) =>
                          setLocal(() => rollover = value ?? rollover),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('超支提醒'),
                    subtitle: const Text('达到预算比例时在应用内提示'),
                    value: alertEnabled,
                    onChanged: (value) => setLocal(() => alertEnabled = value),
                  ),
                  if (alertEnabled)
                    TextField(
                      controller: alert,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '提醒比例',
                        suffixText: '%',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final percent = int.tryParse(alert.text.trim());
                  if (alertEnabled &&
                      (percent == null || percent < 1 || percent > 100)) {
                    throw const LedgerException('提醒比例需为 1～100');
                  }
                  await BudgetRepository(state.repository.db).savePlan(
                    state.ledgerId,
                    BudgetPlan(
                      id: plan?.id ?? '',
                      name: name.text,
                      categoryId: categoryId,
                      amountMinor: parseMoney(amount.text),
                      periodKind: period,
                      startsOn: starts,
                      customEndOn: period == BudgetPeriodKind.custom
                          ? customEnd
                          : null,
                      rolloverMode: period == BudgetPeriodKind.custom
                          ? BudgetRolloverMode.none
                          : rollover,
                      alertEnabled: alertEnabled,
                      alertBps: (percent ?? 80) * 100,
                      hidden: plan?.hidden ?? false,
                      archived: plan?.archived ?? false,
                    ),
                  );
                  if (context.mounted) Navigator.pop(context, true);
                } catch (error) {
                  if (context.mounted) showError(context, error);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  } finally {
    name.dispose();
    amount.dispose();
    alert.dispose();
  }
}

class BudgetDetailPage extends StatefulWidget {
  const BudgetDetailPage({
    super.key,
    required this.ledger,
    required this.repository,
    required this.summary,
  });

  final String ledger;
  final BudgetRepository repository;
  final BudgetPeriodSummary summary;

  @override
  State<BudgetDetailPage> createState() => _BudgetDetailPageState();
}

class _BudgetDetailPageState extends State<BudgetDetailPage> {
  late final Future<List<BudgetDetailEntry>> _details = widget.repository
      .details(widget.ledger, widget.summary);

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    return Scaffold(
      appBar: AppBar(title: Text(summary.plan.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_dateLabel(summary.periodStart)} 至 ${_dateLabel(summary.periodEnd)}',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 10),
                Text(
                  '剩余 ${visibleMoney(context, summary.remainingMinor)}',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: summary.exceeded ? orange : ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '基础 ${visibleMoney(context, summary.plan.amountMinor)} · 结转 ${visibleMoney(context, summary.carriedMinor)} · 已用 ${visibleMoney(context, summary.spentMinor)}',
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: MoneyPrivacy.of(context) ? 0 : summary.progress,
                  minHeight: 8,
                  color: summary.exceeded || summary.warning ? orange : teal,
                  borderRadius: BorderRadius.circular(8),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '预算明细',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          FutureBuilder<List<BudgetDetailEntry>>(
            future: _details,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final values = snapshot.data!;
              if (values.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('当前周期暂无预算流水')),
                );
              }
              return Column(
                children: [
                  for (final item in values)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.type == TransactionType.refund
                            ? Icons.replay
                            : Icons.receipt_long_outlined,
                        color: item.type == TransactionType.refund
                            ? teal
                            : orange,
                      ),
                      title: Text(
                        item.merchant.isEmpty
                            ? item.categoryName
                            : item.merchant,
                      ),
                      subtitle: Text(
                        '${item.categoryName} · ${dateTimeLabel(item.occurredAt)}',
                      ),
                      trailing: Text(
                        '${item.type == TransactionType.refund ? '-' : '+'}${visibleMoney(context, item.amountMinor)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
