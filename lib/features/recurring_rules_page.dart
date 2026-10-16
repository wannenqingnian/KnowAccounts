import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../automation/recurring_background.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tags.dart';
import 'date_time_picker.dart';
import 'widgets.dart';
import 'action_form.dart' show showError;

const _kindLabels = <RecurringKind, String>{
  RecurringKind.incomeExpense: '周期收支',
  RecurringKind.transfer: '周期转账',
  RecurringKind.investment: '周期投资',
};

const _frequencyLabels = <RecurrenceFrequency, String>{
  RecurrenceFrequency.daily: '天',
  RecurrenceFrequency.weekly: '周',
  RecurrenceFrequency.monthly: '月',
  RecurrenceFrequency.yearly: '年',
};

Future<void> showRecurringRules(BuildContext context, RecurringKind kind) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RecurringRulesPage(kind: kind)),
    );

class RecurringRulesPage extends ConsumerStatefulWidget {
  const RecurringRulesPage({super.key, required this.kind});
  final RecurringKind kind;

  @override
  ConsumerState<RecurringRulesPage> createState() => _RecurringRulesPageState();
}

class _RecurringRulesPageState extends ConsumerState<RecurringRulesPage> {
  List<RecurringRule>? _rules;

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final rules = await state.repository.recurringRules(
      state.ledgerId,
      kind: widget.kind,
    );
    if (mounted) setState(() => _rules = rules);
  }

  Future<void> _sync() async {
    try {
      await RecurringBackground.sync(ref.read(ledgerProvider).repository);
    } catch (_) {
      // Desktop builds have no Android alarm service.
    }
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _edit([RecurringRule? rule]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _RecurringRuleEditor(kind: widget.kind, rule: rule),
    );
    if (saved == true) {
      await _sync();
      await _load();
    }
  }

  Future<void> _run(RecurringRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('立即生成账单？'),
        content: Text(
          '将按计划时间 ${dateTimeLabel(rule.nextAt)} 生成“${rule.name}”，并自动推进到下一周期。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('生成账单'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.runRecurringRule(state.ledgerId, rule.id);
      await _sync();
      await state.load();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('账单已生成，计划已推进到下一周期')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _delete(RecurringRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除周期计划？'),
        content: Text('只删除“${rule.name}”计划，不会删除已生成的账单。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final state = ref.read(ledgerProvider);
    await state.repository.deleteRecurringRule(state.ledgerId, rule.id);
    await _sync();
    await _load();
  }

  Future<void> _skip(RecurringRule rule) async {
    final state = ref.read(ledgerProvider);
    await state.repository.skipRecurringRule(state.ledgerId, rule.id);
    await _sync();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本期已跳过，计划已推进到下一周期')));
    }
  }

  Future<void> _retry(RecurringRule rule) async {
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.retryRecurringRule(state.ledgerId, rule.id);
      await state.load();
      await _sync();
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _history(RecurringRule rule) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => _RecurringHistoryPage(rule: rule)),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_kindLabels[widget.kind]!)),
    body: _rules == null
        ? const Center(child: CircularProgressIndicator())
        : _rules!.isEmpty
        ? EmptyView(
            title: '还没有${_kindLabels[widget.kind]}计划',
            description: '启用后由系统后台按时生成账单，并提供提醒、失败重试与执行记录。',
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
            itemCount: _rules!.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final rule = _rules![index];
              return Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: CircleAvatar(
                        child: Icon(
                          widget.kind == RecurringKind.investment
                              ? Icons.trending_up
                              : widget.kind == RecurringKind.transfer
                              ? Icons.swap_horiz
                              : Icons.event_repeat,
                        ),
                      ),
                      title: Text(rule.name),
                      subtitle: Text(
                        '${typeLabel(rule.type)} · ¥${(rule.amountMinor / 100).toStringAsFixed(2)} · 已执行 ${rule.runCount} 次\n下次 ${dateTimeLabel(rule.nextAt)} · 每${rule.interval}${_frequencyLabels[rule.frequency]}${rule.lastError.isEmpty ? '' : '\n失败：${rule.lastError}（已重试 ${rule.retryCount} 次）'}',
                      ),
                      isThreeLine: rule.lastError.isNotEmpty,
                      trailing: Switch.adaptive(
                        value: rule.enabled,
                        onChanged: (value) async {
                          final state = ref.read(ledgerProvider);
                          await state.repository.setRecurringRuleEnabled(
                            state.ledgerId,
                            rule.id,
                            value,
                          );
                          await _sync();
                          await _load();
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => _run(rule),
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('立即记账'),
                        ),
                        if (rule.lastError.isNotEmpty)
                          TextButton(
                            onPressed: () => _retry(rule),
                            child: const Text('重试'),
                          ),
                        TextButton(
                          onPressed: () => _edit(rule),
                          child: const Text('编辑'),
                        ),
                        TextButton(
                          onPressed: () => _skip(rule),
                          child: const Text('跳过本期'),
                        ),
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'history') _history(rule);
                            if (value == 'delete') _delete(rule);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'history',
                              child: Text('执行历史'),
                            ),
                            PopupMenuItem(value: 'delete', child: Text('删除计划')),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _edit,
      icon: const Icon(Icons.add),
      label: const Text('新建计划'),
    ),
  );
}

class _RecurringHistoryPage extends ConsumerStatefulWidget {
  const _RecurringHistoryPage({required this.rule});
  final RecurringRule rule;

  @override
  ConsumerState<_RecurringHistoryPage> createState() =>
      _RecurringHistoryPageState();
}

class _RecurringHistoryPageState extends ConsumerState<_RecurringHistoryPage> {
  List<RecurringExecution>? _items;

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final values = await state.repository.recurringExecutions(
      state.ledgerId,
      widget.rule.id,
    );
    if (mounted) setState(() => _items = values);
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${widget.rule.name} · 执行历史')),
    body: _items == null
        ? const Center(child: CircularProgressIndicator())
        : _items!.isEmpty
        ? const EmptyView(title: '暂无执行记录', description: '自动执行、立即执行和跳过本期都会记录。')
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _items!.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = _items![index];
              final (icon, label, color) = switch (item.status) {
                'success' => (Icons.check_circle_outline, '已生成', teal),
                'skipped' => (Icons.skip_next_outlined, '已跳过', Colors.orange),
                _ => (Icons.error_outline, '执行失败', Colors.red),
              };
              return ListTile(
                leading: Icon(icon, color: color),
                title: Text('$label · ${dateTimeLabel(item.scheduledAt)}'),
                subtitle: Text(
                  item.errorMessage.isEmpty
                      ? '完成于 ${dateTimeLabel(item.finishedAt)}'
                      : '${item.errorMessage} · 重试 ${item.retryCount} 次',
                ),
              );
            },
          ),
  );
}

class _RecurringRuleEditor extends ConsumerStatefulWidget {
  const _RecurringRuleEditor({required this.kind, this.rule});
  final RecurringKind kind;
  final RecurringRule? rule;

  @override
  ConsumerState<_RecurringRuleEditor> createState() =>
      _RecurringRuleEditorState();
}

class _RecurringRuleEditorState extends ConsumerState<_RecurringRuleEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name,
      _amount,
      _interval,
      _merchant,
      _note,
      _tags,
      _maxRuns;
  late TransactionType _type;
  late RecurrenceFrequency _frequency;
  late DateTime _nextAt;
  DateTime? _endAt;
  String? _account, _target, _category;
  bool _saving = false,
      _notify = true,
      _useEndDate = false,
      _useMaxRuns = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    final state = ref.read(ledgerProvider);
    _name = TextEditingController(text: rule?.name ?? '');
    _amount = TextEditingController(
      text: rule == null ? '' : (rule.amountMinor / 100).toStringAsFixed(2),
    );
    _interval = TextEditingController(text: '${rule?.interval ?? 1}');
    _merchant = TextEditingController(text: rule?.merchant ?? '');
    _note = TextEditingController(text: rule?.note ?? '');
    _tags = TextEditingController(text: rule?.tags.join('，') ?? '');
    _maxRuns = TextEditingController(text: '${rule?.maxRuns ?? 12}');
    _type = widget.kind == RecurringKind.incomeExpense
        ? rule?.type ?? TransactionType.expense
        : TransactionType.transfer;
    _frequency = rule?.frequency ?? RecurrenceFrequency.monthly;
    _nextAt = rule?.nextAt ?? DateTime.now();
    _endAt = rule?.endAt;
    _useEndDate = rule?.endAt != null;
    _useMaxRuns = rule?.maxRuns != null;
    _notify = rule?.notifyEnabled ?? true;
    _account = rule?.accountId ?? state.accounts.firstOrNull?.id;
    _target =
        rule?.targetAccountId ??
        state.accounts.where((a) => a.id != _account).firstOrNull?.id;
    _category =
        rule?.categoryId ??
        state.categories.where((c) => c.type == _type).firstOrNull?.id;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _amount,
      _interval,
      _merchant,
      _note,
      _tags,
      _maxRuns,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.saveRecurringRule(
        state.ledgerId,
        RecurringRule(
          id: widget.rule?.id ?? '',
          name: _name.text,
          kind: widget.kind,
          type: _type,
          amountMinor: parseMoney(_amount.text),
          accountId: _account ?? '',
          targetAccountId: _type == TransactionType.transfer ? _target : null,
          categoryId: _type == TransactionType.transfer ? null : _category,
          merchant: _merchant.text,
          note: _note.text,
          tags: parseTagInput(_tags.text),
          frequency: _frequency,
          interval: int.parse(_interval.text),
          nextAt: _nextAt,
          enabled: widget.rule?.enabled ?? true,
          lastRunAt: widget.rule?.lastRunAt,
          endAt: _useEndDate ? _endAt : null,
          maxRuns: _useMaxRuns ? int.parse(_maxRuns.text) : null,
          runCount: widget.rule?.runCount ?? 0,
          notifyEnabled: _notify,
          retryCount: widget.rule?.retryCount ?? 0,
          lastError: widget.rule?.lastError ?? '',
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final categories = state.categories.where((c) => c.type == _type).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        0,
        18,
        MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: Form(
        key: _form,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.rule == null
                  ? '新建${_kindLabels[widget.kind]}'
                  : '编辑${_kindLabels[widget.kind]}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '计划名称'),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? '请输入计划名称' : null,
            ),
            const SizedBox(height: 10),
            if (widget.kind == RecurringKind.incomeExpense)
              SegmentedButton<TransactionType>(
                segments: const [
                  ButtonSegment(
                    value: TransactionType.expense,
                    label: Text('支出'),
                  ),
                  ButtonSegment(
                    value: TransactionType.income,
                    label: Text('收入'),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (v) => setState(() {
                  _type = v.first;
                  _category = state.categories
                      .where((c) => c.type == _type)
                      .firstOrNull
                      ?.id;
                }),
              ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '金额'),
              validator: (v) => v == null || v.trim().isEmpty ? '请输入金额' : null,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _account,
              decoration: InputDecoration(
                labelText: _type == TransactionType.transfer ? '转出账户' : '账户',
              ),
              items: [
                for (final account in state.accounts)
                  DropdownMenuItem(
                    value: account.id,
                    child: Text(account.displayName),
                  ),
              ],
              onChanged: (v) => setState(() {
                _account = v;
                if (_target == v) {
                  _target = state.accounts
                      .where((a) => a.id != v)
                      .firstOrNull
                      ?.id;
                }
              }),
              validator: (v) => v == null ? '请选择账户' : null,
            ),
            const SizedBox(height: 10),
            if (_type == TransactionType.transfer)
              DropdownButtonFormField<String>(
                initialValue:
                    state.accounts.any(
                      (a) => a.id == _target && a.id != _account,
                    )
                    ? _target
                    : null,
                decoration: const InputDecoration(labelText: '转入账户'),
                items: [
                  for (final account in state.accounts.where(
                    (a) => a.id != _account,
                  ))
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(account.displayName),
                    ),
                ],
                onChanged: (v) => setState(() => _target = v),
                validator: (v) => v == null ? '请选择不同的转入账户' : null,
              )
            else
              DropdownButtonFormField<String>(
                initialValue: categories.any((c) => c.id == _category)
                    ? _category
                    : null,
                decoration: const InputDecoration(labelText: '分类'),
                items: [
                  for (final category in categories)
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (v) => setState(() => _category = v),
                validator: (v) => v == null ? '请选择分类' : null,
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _interval,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '每隔'),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 999 ? '请输入1～999' : null;
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<RecurrenceFrequency>(
                    initialValue: _frequency,
                    decoration: const InputDecoration(labelText: '周期单位'),
                    items: [
                      for (final value in RecurrenceFrequency.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_frequencyLabels[value]!),
                        ),
                    ],
                    onChanged: (v) => setState(() => _frequency = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('下次记账时间'),
              subtitle: Text(dateTimeLabel(_nextAt)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () async {
                final value = await showSecondDateTimePicker(
                  context,
                  initial: _nextAt,
                );
                if (value != null) setState(() => _nextAt = value);
              },
            ),
            const Divider(),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('到指定时间结束'),
              value: _useEndDate,
              onChanged: (value) => setState(() {
                _useEndDate = value;
                _endAt ??= _nextAt.add(const Duration(days: 365));
              }),
            ),
            if (_useEndDate)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('结束时间'),
                subtitle: Text(dateTimeLabel(_endAt!)),
                trailing: const Icon(Icons.event_busy_outlined),
                onTap: () async {
                  final value = await showSecondDateTimePicker(
                    context,
                    initial: _endAt!,
                  );
                  if (value != null) setState(() => _endAt = value);
                },
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('达到次数后结束'),
              value: _useMaxRuns,
              onChanged: (value) => setState(() => _useMaxRuns = value),
            ),
            if (_useMaxRuns)
              TextFormField(
                controller: _maxRuns,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '总执行次数'),
                validator: (value) {
                  if (!_useMaxRuns) return null;
                  final count = int.tryParse(value ?? '');
                  return count == null || count < 1 || count > 100000
                      ? '请输入1～100000'
                      : null;
                },
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('到期与执行结果提醒'),
              subtitle: const Text('后台生成成功或失败时显示系统提醒'),
              value: _notify,
              onChanged: (value) => setState(() => _notify = value),
            ),
            TextFormField(
              controller: _merchant,
              decoration: InputDecoration(
                labelText: widget.kind == RecurringKind.investment
                    ? '投资名称（选填）'
                    : '商户/对方（选填）',
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _tags,
              decoration: const InputDecoration(labelText: '标签（逗号或空格分隔）'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _note,
              decoration: const InputDecoration(labelText: '备注（选填）'),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? '保存中…' : '保存计划'),
            ),
          ],
        ),
      ),
    );
  }
}
