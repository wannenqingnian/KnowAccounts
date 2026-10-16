import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/tag_repository.dart';
import '../domain/models.dart';
import 'action_form.dart';
import 'transaction_editor.dart';
import 'widgets.dart';

Future<void> showTagManager(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const TagManagerPage()));

class TagManagerPage extends ConsumerStatefulWidget {
  const TagManagerPage({super.key});

  @override
  ConsumerState<TagManagerPage> createState() => _TagManagerPageState();
}

class _TagManagerPageState extends ConsumerState<TagManagerPage> {
  List<TagDefinition>? _tags;
  bool _showHidden = false;

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final values = await TagRepository(
      state.repository.db,
    ).definitions(state.ledgerId, includeHidden: true);
    if (mounted) setState(() => _tags = values);
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _edit([TagDefinition? tag]) async {
    final state = ref.read(ledgerProvider);
    await actionForm(
      context,
      title: tag == null ? '新增标签' : '编辑标签',
      fields: [
        InputSpec('name', '标签名称', initial: tag?.name ?? ''),
        InputSpec('pattern', '智能匹配词（可选）', initial: tag?.smartPattern ?? ''),
      ],
      description: '多个智能匹配词用逗号分隔；商户或备注命中后会自动添加该标签。',
      submit: (values) async {
        await TagRepository(state.repository.db).save(
          state.ledgerId,
          id: tag?.id,
          name: values['name']!,
          smartPattern: values['pattern']!,
        );
        await state.load();
      },
    );
    await _load();
  }

  Future<void> _merge(TagDefinition source) async {
    final choices = (_tags ?? const [])
        .where((tag) => tag.id != source.id && !tag.hidden)
        .toList();
    if (choices.isEmpty) {
      showError(context, const LedgerException('请先创建另一个可用标签'));
      return;
    }
    String target = choices.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('合并“${source.name}”'),
          content: DropdownButtonFormField<String>(
            initialValue: target,
            decoration: const InputDecoration(labelText: '合并到'),
            items: [
              for (final tag in choices)
                DropdownMenuItem(value: tag.id, child: Text(tag.name)),
            ],
            onChanged: (value) {
              if (value != null) setDialogState(() => target = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('合并'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final state = ref.read(ledgerProvider);
    await TagRepository(
      state.repository.db,
    ).merge(state.ledgerId, source.id, target);
    await state.load();
    await _load();
  }

  Future<void> _hide(TagDefinition tag) async {
    final state = ref.read(ledgerProvider);
    await TagRepository(
      state.repository.db,
    ).setHidden(state.ledgerId, tag.id, !tag.hidden);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = (_tags ?? const [])
        .where((tag) => _showHidden || !tag.hidden)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('标签管理'),
        actions: [
          IconButton(
            tooltip: '新增标签',
            onPressed: _edit,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _tags == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SwitchListTile(
                  title: const Text('显示已隐藏标签'),
                  value: _showHidden,
                  onChanged: (value) => setState(() => _showHidden = value),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '点击标签查看对应账单；智能标签会在新账单保存时自动匹配。',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? const EmptyView(
                          title: '暂无标签',
                          description: '点击右上角新增，或在记账时填写标签。',
                        )
                      : ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final tag = rows[index];
                            return ListTile(
                              leading: Icon(
                                tag.smartPattern.isEmpty
                                    ? Icons.label_outline
                                    : Icons.auto_awesome_outlined,
                                color: tag.hidden ? Colors.grey : teal,
                              ),
                              title: Text(tag.name),
                              subtitle: Text(
                                '${tag.usageCount} 笔账单${tag.smartPattern.isEmpty ? '' : ' · 智能：${tag.smartPattern}'}${tag.hidden ? ' · 已隐藏' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => _TagEntriesPage(tag: tag),
                                ),
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'edit') _edit(tag);
                                  if (value == 'merge') _merge(tag);
                                  if (value == 'hide') _hide(tag);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('改名与智能规则'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'merge',
                                    child: Text('合并到其他标签'),
                                  ),
                                  PopupMenuItem(
                                    value: 'hide',
                                    child: Text(tag.hidden ? '取消隐藏' : '隐藏标签'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _TagEntriesPage extends ConsumerStatefulWidget {
  const _TagEntriesPage({required this.tag});
  final TagDefinition tag;

  @override
  ConsumerState<_TagEntriesPage> createState() => _TagEntriesPageState();
}

class _TagEntriesPageState extends ConsumerState<_TagEntriesPage> {
  List<LedgerEntry>? _entries;

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final entries = await TagRepository(
      state.repository.db,
    ).entries(state.ledgerId, widget.tag.name);
    if (mounted) setState(() => _entries = entries);
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('#${widget.tag.name}')),
    body: _entries == null
        ? const Center(child: CircularProgressIndicator())
        : _entries!.isEmpty
        ? const EmptyView(title: '暂无账单', description: '使用此标签的账单会显示在这里。')
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _entries!.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = _entries![index];
              return EntryTile(
                entry: entry,
                onTap: () async {
                  await showTransactionEditor(context, entry: entry);
                  await _load();
                },
              );
            },
          ),
  );
}
