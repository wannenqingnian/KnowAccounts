import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/advanced_finance_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'action_form.dart' show showError;
import 'money_privacy.dart';
import 'widgets.dart';

Future<void> showBillSplitPage(BuildContext context, LedgerEntry entry) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BillSplitPage(entry: entry)),
    );

Future<void> showBillGroupsPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const BillGroupsPage()));

Future<void> showTransactionGroupPicker(
  BuildContext context,
  WidgetRef ref,
  LedgerEntry entry,
) async {
  final state = ref.read(ledgerProvider);
  final repository = AdvancedFinanceRepository(state.repository.db);
  try {
    final groups = await repository.groups(state.ledgerId);
    final selected = await repository.transactionGroup(
      state.ledgerId,
      entry.id,
    );
    if (!context.mounted) return;
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  '加入账单分组',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('一个账单只能属于一个分组'),
              ),
              ListTile(
                leading: Icon(
                  selected == null
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: const Text('不分组'),
                onTap: () => Navigator.pop(sheetContext, '__none__'),
              ),
              for (final group in groups)
                ListTile(
                  leading: Icon(
                    selected == group.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(group.name),
                  subtitle: Text('${group.transactionCount} 笔'),
                  onTap: () => Navigator.pop(sheetContext, group.id),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('新建分组'),
                onTap: () => Navigator.pop(sheetContext, '__new__'),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    String? groupId;
    if (result == '__new__') {
      final name = await _askGroupName(context);
      if (name == null) return;
      groupId = await repository.saveGroup(state.ledgerId, name: name);
    } else if (result != '__none__') {
      groupId = result;
    }
    await repository.assignToGroup(state.ledgerId, entry.id, groupId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(groupId == null ? '已移出账单分组' : '已更新账单分组')),
      );
    }
  } catch (error) {
    if (context.mounted) showError(context, error);
  }
}

Future<String?> _askGroupName(BuildContext context, {String initial = ''}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(initial.isEmpty ? '新建账单分组' : '修改分组名称'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(labelText: '分组名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isNotEmpty) Navigator.pop(dialogContext, value);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

class BillSplitPage extends ConsumerStatefulWidget {
  const BillSplitPage({super.key, required this.entry});
  final LedgerEntry entry;

  @override
  ConsumerState<BillSplitPage> createState() => _BillSplitPageState();
}

class _BillSplitPageState extends ConsumerState<BillSplitPage> {
  final _rows = <_SplitRow>[];
  bool _loading = true;
  bool _saving = false;

  AdvancedFinanceRepository get _repository =>
      AdvancedFinanceRepository(ref.read(ledgerProvider).repository.db);

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final state = ref.read(ledgerProvider);
      final values = await _repository.splits(state.ledgerId, widget.entry.id);
      if (!mounted) return;
      setState(() {
        for (final value in values) {
          _rows.add(_SplitRow.from(value));
        }
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, error);
      }
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _add() => setState(() => _rows.add(_SplitRow()));

  Future<void> _createAa() async {
    var names = _rows
        .map((row) => row.name.text.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (names.isEmpty) {
      final controller = TextEditingController();
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('参与人'),
          content: TextField(
            controller: controller,
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(hintText: '每行一位，例如：\n我\n小李\n小王'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('均分'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (value == null) return;
      names = value.split(RegExp(r'[\n,，、]+'));
    }
    try {
      final values = AdvancedFinanceRepository.equalSplits(
        widget.entry.amountMinor,
        names,
      );
      setState(() {
        for (final row in _rows) {
          row.dispose();
        }
        _rows
          ..clear()
          ..addAll(values.map(_SplitRow.from));
      });
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final values = [
        for (final row in _rows)
          TransactionSplit(
            id: row.id,
            participant: row.name.text,
            amountMinor: parseMoney(row.amount.text),
            settled: row.settled,
            note: row.note.text,
          ),
      ];
      final state = ref.read(ledgerProvider);
      await _repository.replaceSplits(state.ledgerId, widget.entry.id, values);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    try {
      final state = ref.read(ledgerProvider);
      await _repository.clearSplits(state.ledgerId, widget.entry.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('拆分与 AA'),
      actions: [
        if (_rows.isNotEmpty)
          TextButton(
            onPressed: _saving ? null : _clear,
            child: const Text('清除'),
          ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                child: Row(
                  children: [
                    const Expanded(child: Text('账单人民币金额')),
                    Text(
                      visibleMoney(context, widget.entry.amountMinor),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('添加参与人'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _createAa,
                      icon: const Icon(Icons.balance_outlined),
                      label: const Text('AA 均分'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_rows.isEmpty)
                const EmptyView(
                  title: '尚未拆分',
                  description: '添加参与人，或使用 AA 均分。合计必须等于账单金额。',
                ),
              for (var index = 0; index < _rows.length; index++)
                _splitCard(index, _rows[index]),
              if (_rows.isNotEmpty) ...[
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(_saving ? '保存中…' : '保存拆分'),
                ),
              ],
            ],
          ),
  );

  Widget _splitCard(int index, _SplitRow row) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: row.name,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: '参与人',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 125,
                child: TextField(
                  controller: row.amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '金额',
                    prefixText: '¥',
                  ),
                ),
              ),
              IconButton(
                tooltip: '移除',
                onPressed: () => setState(() {
                  final removed = _rows.removeAt(index);
                  removed.dispose();
                }),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: row.note,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: '备注（可选）',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                selected: row.settled,
                label: Text(row.settled ? '已结清' : '未结清'),
                onSelected: (value) => setState(() => row.settled = value),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _SplitRow {
  _SplitRow({
    this.id = '',
    String name = '',
    String amount = '',
    String note = '',
    this.settled = false,
  }) : name = TextEditingController(text: name),
       amount = TextEditingController(text: amount),
       note = TextEditingController(text: note);

  factory _SplitRow.from(TransactionSplit value) => _SplitRow(
    id: value.id,
    name: value.participant,
    amount: (value.amountMinor / 100).toStringAsFixed(2),
    note: value.note,
    settled: value.settled,
  );

  final String id;
  final TextEditingController name;
  final TextEditingController amount;
  final TextEditingController note;
  bool settled;

  void dispose() {
    name.dispose();
    amount.dispose();
    note.dispose();
  }
}

class BillGroupsPage extends ConsumerStatefulWidget {
  const BillGroupsPage({super.key});

  @override
  ConsumerState<BillGroupsPage> createState() => _BillGroupsPageState();
}

class _BillGroupsPageState extends ConsumerState<BillGroupsPage> {
  List<TransactionGroup>? _groups;

  AdvancedFinanceRepository get _repository =>
      AdvancedFinanceRepository(ref.read(ledgerProvider).repository.db);

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final state = ref.read(ledgerProvider);
      final values = await _repository.groups(state.ledgerId);
      if (mounted) setState(() => _groups = values);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _edit([TransactionGroup? group]) async {
    final name = await _askGroupName(context, initial: group?.name ?? '');
    if (name == null) return;
    try {
      final state = ref.read(ledgerProvider);
      await _repository.saveGroup(
        state.ledgerId,
        id: group?.id,
        name: name,
        note: group?.note ?? '',
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _delete(TransactionGroup group) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除分组？'),
        content: Text('“${group.name}”中的账单不会被删除，只会移出分组。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      final state = ref.read(ledgerProvider);
      await _repository.deleteGroup(state.ledgerId, group.id);
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('账单分组')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _edit,
      icon: const Icon(Icons.add),
      label: const Text('新建分组'),
    ),
    body: _groups == null
        ? const Center(child: CircularProgressIndicator())
        : _groups!.isEmpty
        ? const EmptyView(
            title: '还没有账单分组',
            description: '可创建旅行、聚餐、装修等分组，再从账单操作中加入。',
          )
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _groups!.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final group = _groups![index];
              return SectionCard(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined, color: teal),
                  title: Text(group.name),
                  subtitle: Text(
                    '${group.transactionCount} 笔 · ${visibleMoney(context, group.totalMinor)}',
                  ),
                  onTap: () => _edit(group),
                  trailing: IconButton(
                    tooltip: '删除分组',
                    onPressed: () => _delete(group),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              );
            },
          ),
  );
}
