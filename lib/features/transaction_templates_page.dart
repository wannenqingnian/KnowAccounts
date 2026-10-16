import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tags.dart';
import 'transaction_editor.dart';
import 'widgets.dart';
import 'action_form.dart' show showError;

Future<void> showTransactionTemplates(
  BuildContext context, {
  bool choose = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => TransactionTemplatesPage(choose: choose),
  ),
);

class TransactionTemplatesPage extends ConsumerStatefulWidget {
  const TransactionTemplatesPage({super.key, this.choose = false});
  final bool choose;

  @override
  ConsumerState<TransactionTemplatesPage> createState() =>
      _TransactionTemplatesPageState();
}

class _TransactionTemplatesPageState
    extends ConsumerState<TransactionTemplatesPage> {
  List<TransactionTemplate>? _items;

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final items = await state.repository.transactionTemplates(state.ledgerId);
    if (mounted) setState(() => _items = items);
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _edit([TransactionTemplate? template]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _TemplateEditor(template: template),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(TransactionTemplate template) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模板？'),
        content: Text('“${template.name}”删除后不可恢复。'),
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
    await state.repository.deleteTransactionTemplate(
      state.ledgerId,
      template.id,
    );
    await _load();
  }

  Future<void> _use(TransactionTemplate template) async {
    await showTransactionEditor(context, template: template);
    if (widget.choose && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.choose ? '选择记账模板' : '记账模板'),
      actions: [
        IconButton(
          tooltip: '新增模板',
          onPressed: _edit,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: _items == null
        ? const Center(child: CircularProgressIndicator())
        : _items!.isEmpty
        ? const EmptyView(
            title: '还没有记账模板',
            description: '把常用的收支、转账、账户、分类和标签组合保存下来。',
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
            itemCount: _items!.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = _items![index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(
                      item.type == TransactionType.transfer
                          ? Icons.swap_horiz
                          : item.type == TransactionType.income
                          ? Icons.south_west
                          : Icons.north_east,
                    ),
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    '${typeLabel(item.type)}${item.amountMinor == 0 ? ' · 每次填写金额' : ' · ¥${(item.amountMinor / 100).toStringAsFixed(2)}'}${item.tags.isEmpty ? '' : ' · #${item.tags.join(' #')}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _use(item),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) => value == 'edit'
                        ? _edit(item)
                        : value == 'delete'
                        ? _delete(item)
                        : _use(item),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'use', child: Text('使用模板')),
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              );
            },
          ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _edit,
      icon: const Icon(Icons.add),
      label: const Text('新建模板'),
    ),
  );
}

class _TemplateEditor extends ConsumerStatefulWidget {
  const _TemplateEditor({this.template});
  final TransactionTemplate? template;

  @override
  ConsumerState<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends ConsumerState<_TemplateEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _note;
  late final TextEditingController _tags;
  late TransactionType _type;
  String? _account, _target, _category;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final item = widget.template;
    _name = TextEditingController(text: item?.name ?? '');
    _amount = TextEditingController(
      text: item == null || item.amountMinor == 0
          ? ''
          : (item.amountMinor / 100).toStringAsFixed(2),
    );
    _merchant = TextEditingController(text: item?.merchant ?? '');
    _note = TextEditingController(text: item?.note ?? '');
    _tags = TextEditingController(text: item?.tags.join('，') ?? '');
    _type = item?.type ?? TransactionType.expense;
    _account = item?.accountId;
    _target = item?.targetAccountId;
    _category = item?.categoryId;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.saveTransactionTemplate(
        state.ledgerId,
        TransactionTemplate(
          id: widget.template?.id ?? '',
          name: _name.text,
          type: _type,
          amountMinor: _amount.text.trim().isEmpty
              ? 0
              : parseMoney(_amount.text.trim()),
          accountId: _account,
          targetAccountId: _type == TransactionType.transfer ? _target : null,
          categoryId: _type == TransactionType.transfer ? null : _category,
          merchant: _merchant.text,
          note: _note.text,
          tags: parseTagInput(_tags.text),
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
              widget.template == null ? '新建记账模板' : '编辑记账模板',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '模板名称'),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? '请输入模板名称' : null,
            ),
            const SizedBox(height: 10),
            SegmentedButton<TransactionType>(
              segments: const [
                ButtonSegment(
                  value: TransactionType.expense,
                  label: Text('支出'),
                ),
                ButtonSegment(value: TransactionType.income, label: Text('收入')),
                ButtonSegment(
                  value: TransactionType.transfer,
                  label: Text('转账'),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() {
                _type = v.first;
                _category = null;
              }),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '金额（选填）',
                hintText: '留空则使用时填写',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              initialValue: _account,
              decoration: const InputDecoration(labelText: '默认账户（选填）'),
              items: [
                const DropdownMenuItem(value: null, child: Text('使用时选择')),
                for (final account in state.accounts)
                  DropdownMenuItem(
                    value: account.id,
                    child: Text(account.displayName),
                  ),
              ],
              onChanged: (v) => setState(() => _account = v),
            ),
            const SizedBox(height: 10),
            if (_type == TransactionType.transfer)
              DropdownButtonFormField<String?>(
                initialValue: _target,
                decoration: const InputDecoration(labelText: '默认转入账户（选填）'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('使用时选择')),
                  for (final account in state.accounts.where(
                    (a) => a.id != _account,
                  ))
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(account.displayName),
                    ),
                ],
                onChanged: (v) => setState(() => _target = v),
              )
            else
              DropdownButtonFormField<String?>(
                initialValue: categories.any((c) => c.id == _category)
                    ? _category
                    : null,
                decoration: const InputDecoration(labelText: '默认分类（选填）'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('使用时选择')),
                  for (final category in categories)
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (v) => setState(() => _category = v),
              ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _merchant,
              decoration: const InputDecoration(labelText: '商户/对方（选填）'),
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
              label: Text(_saving ? '保存中…' : '保存模板'),
            ),
          ],
        ),
      ),
    );
  }
}
