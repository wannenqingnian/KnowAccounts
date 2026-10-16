import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../domain/models.dart';
import 'action_form.dart';
import 'widgets.dart';

Future<void> showCategoryManager(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const CategoryManager()));

class CategoryManager extends ConsumerStatefulWidget {
  const CategoryManager({super.key, this.parent});
  final Category? parent;
  @override
  ConsumerState<CategoryManager> createState() => _CategoryManagerState();
}

class _CategoryManagerState extends ConsumerState<CategoryManager> {
  late final String _ledger;
  late TransactionType _type;
  bool _archived = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _ledger = ref.read(ledgerProvider).ledgerId;
    _type = widget.parent?.type ?? TransactionType.expense;
  }

  Future<void> _run(Future<void> Function(LedgerController) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = ref.read(ledgerProvider);
      if (state.ledgerId != _ledger) {
        throw const LedgerException('账本已变化，请重新打开分类管理');
      }
      await action(state);
      await state.load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _name({Category? category}) async {
    final state = ref.read(ledgerProvider);
    await actionForm(
      context,
      title: category == null ? '新增分类' : '修改分类名称',
      fields: [InputSpec('name', '分类名称', initial: category?.name ?? '')],
      description: '支持1～40字；同级分类不能重名。',
      submit: (values) async {
        if (state.ledgerId != _ledger) {
          throw const LedgerException('账本已变化，请重新打开');
        }
        if (category == null) {
          await state.repository.addCategory(
            _ledger,
            values['name']!,
            _type,
            parentId: widget.parent?.id,
          );
        } else {
          await state.repository.renameCategory(
            _ledger,
            category.id,
            values['name']!,
          );
        }
        await state.load();
      },
    );
  }

  Future<void> _archive(Category category) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('归档“${category.name}”？'),
        content: Text(
          category.parentId == null
              ? '下级分类也会归档。历史流水和统计保留，新记账将不再显示它们。恢复时请先恢复一级分类，再按需恢复二级分类。'
              : '历史流水和统计保留，新记账将不再显示此分类。可在已归档列表中恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _run(
        (s) => s.repository.setCategoryArchived(_ledger, category.id, true),
      );
    }
  }

  Future<void> _icon(Category category) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择分类图标'),
        content: SizedBox(
          width: 360,
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 4,
            children: [
              for (final item in categoryIconLibrary.entries)
                IconButton(
                  tooltip: categoryIconLabels[item.key],
                  onPressed: () => Navigator.pop(context, item.key),
                  icon: Icon(item.value, color: teal),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      await _run(
        (state) =>
            state.repository.setCategoryIcon(_ledger, category.id, selected),
      );
    }
  }

  Future<void> _share() async {
    final state = ref.read(ledgerProvider);
    final categories = state.allCategories;
    final names = {for (final item in categories) item.id: item.name};
    final value = jsonEncode({
      'format': 'smart-ledger-categories-v1',
      'categories': [
        for (final item in categories)
          {
            'name': item.name,
            'type': item.type.name,
            'parent': item.parentId == null ? null : names[item.parentId],
            'icon': item.iconKey,
          },
      ],
    });
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('分类模板已复制，可分享给其他设备')));
    }
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入分类模板'),
        content: TextField(
          controller: controller,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '粘贴知账分类模板 JSON'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    try {
      final value = jsonDecode(text);
      if (value is! Map ||
          value['format'] != 'smart-ledger-categories-v1' ||
          value['categories'] is! List) {
        throw const FormatException();
      }
      await _applyRows((value['categories'] as List).whereType<Map>());
    } catch (_) {
      if (mounted) showError(context, const LedgerException('分类模板格式错误'));
    }
  }

  Future<void> _template() async {
    const templates = <String, List<Map<String, String?>>>{
      '日常生活': [
        {'name': '餐饮', 'type': 'expense', 'icon': 'food'},
        {'name': '交通', 'type': 'expense', 'icon': 'transport'},
        {'name': '购物', 'type': 'expense', 'icon': 'shopping'},
        {'name': '居住', 'type': 'expense', 'icon': 'home'},
        {'name': '工资', 'type': 'income', 'icon': 'salary'},
        {'name': '理财收益', 'type': 'income', 'icon': 'investment'},
      ],
      '家庭账本': [
        {'name': '家庭餐饮', 'type': 'expense', 'icon': 'food'},
        {'name': '住房水电', 'type': 'expense', 'icon': 'home'},
        {'name': '医疗健康', 'type': 'expense', 'icon': 'medical'},
        {'name': '教育育儿', 'type': 'expense', 'icon': 'child'},
        {'name': '家庭收入', 'type': 'income', 'icon': 'salary'},
      ],
      '旅行账本': [
        {'name': '交通票务', 'type': 'expense', 'icon': 'transport'},
        {'name': '住宿', 'type': 'expense', 'icon': 'travel'},
        {'name': '餐饮', 'type': 'expense', 'icon': 'food'},
        {'name': '购物伴手礼', 'type': 'expense', 'icon': 'gift'},
      ],
    };
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('应用分类模板'),
        children: [
          for (final name in templates.keys)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, name),
              child: Text(name),
            ),
        ],
      ),
    );
    if (selected != null) await _applyRows(templates[selected]!);
  }

  Future<void> _applyRows(Iterable<Map> rows) async {
    await _run((state) async {
      var categories = await state.repository.categories(
        _ledger,
        includeArchived: true,
      );
      for (final row in rows.where((row) => row['parent'] == null)) {
        final name = row['name'];
        final typeName = row['type'];
        if (name is! String ||
            typeName is! String ||
            !['expense', 'income'].contains(typeName)) {
          throw const LedgerException('分类模板字段无效');
        }
        final type = TransactionType.values.byName(typeName);
        if (categories.any(
          (item) =>
              item.parentId == null && item.type == type && item.name == name,
        )) {
          continue;
        }
        await state.repository.addCategory(
          _ledger,
          name,
          type,
          iconKey: row['icon'] is String ? row['icon'] as String : '',
        );
        categories = await state.repository.categories(
          _ledger,
          includeArchived: true,
        );
      }
      for (final row in rows.where((row) => row['parent'] != null)) {
        final name = row['name'];
        final parentName = row['parent'];
        final typeName = row['type'];
        if (name is! String || parentName is! String || typeName is! String) {
          throw const LedgerException('分类模板字段无效');
        }
        final type = TransactionType.values.byName(typeName);
        final parent = categories.where(
          (item) =>
              item.parentId == null &&
              item.type == type &&
              item.name == parentName,
        );
        if (parent.isEmpty) throw const LedgerException('分类模板缺少上级分类');
        if (categories.any(
          (item) => item.parentId == parent.first.id && item.name == name,
        )) {
          continue;
        }
        await state.repository.addCategory(
          _ledger,
          name,
          type,
          parentId: parent.first.id,
          iconKey: row['icon'] is String ? row['icon'] as String : '',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final parent = state.allCategories
        .where((c) => c.id == widget.parent?.id)
        .firstOrNull;
    final rows = state.allCategories
        .where(
          (c) =>
              c.type == _type &&
              c.parentId == widget.parent?.id &&
              c.archived == _archived,
        )
        .toList();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(parent?.name ?? '分类管理'),
          actions: [
            if (!_archived &&
                (widget.parent == null || parent?.archived == false))
              IconButton(
                tooltip: '新增分类',
                onPressed: _busy ? null : () => _name(),
                icon: const Icon(Icons.add),
              ),
            if (widget.parent == null)
              PopupMenuButton<String>(
                tooltip: '分类模板与分享',
                onSelected: (value) {
                  if (value == 'template') _template();
                  if (value == 'share') _share();
                  if (value == 'import') _import();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'template', child: Text('应用分类模板')),
                  PopupMenuItem(value: 'share', child: Text('复制并分享分类')),
                  PopupMenuItem(value: 'import', child: Text('导入分类模板')),
                ],
              ),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (widget.parent == null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SegmentedButton<TransactionType>(
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
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() => _type = v.first),
                ),
              ),
            SwitchListTile(
              title: const Text('显示已归档分类'),
              value: _archived,
              onChanged: _busy ? null : (v) => setState(() => _archived = v),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _archived ? '恢复一级分类后，二级分类可分别恢复。' : '拖动右侧手柄排序；点击一级分类管理二级分类。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(child: Text(_archived ? '暂无已归档分类' : '暂无分类，点击右上角新增'))
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: rows.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        if (_busy || _archived) return;
                        final ids = rows.map((c) => c.id).toList();
                        ids.insert(newIndex, ids.removeAt(oldIndex));
                        await _run(
                          (s) => s.repository.reorderCategories(
                            _ledger,
                            _type,
                            widget.parent?.id,
                            ids,
                          ),
                        );
                      },
                      itemBuilder: (context, index) {
                        final category = rows[index];
                        return ListTile(
                          key: ValueKey('category_row_${category.id}'),
                          leading: Icon(
                            categoryIcon(category.name, category.iconKey),
                            color: teal,
                          ),
                          title: Text(category.name),
                          subtitle: category.parentId == null
                              ? Text(
                                  '${state.allCategories.where((c) => c.parentId == category.id && c.archived == category.archived).length} 个二级分类',
                                )
                              : null,
                          onTap: category.parentId == null && !_busy
                              ? () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        CategoryManager(parent: category),
                                  ),
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PopupMenuButton<String>(
                                tooltip: '分类操作',
                                enabled: !_busy,
                                onSelected: (action) {
                                  if (action == 'rename') {
                                    _name(category: category);
                                  }
                                  if (action == 'icon') _icon(category);
                                  if (action == 'archive') _archive(category);
                                  if (action == 'restore') {
                                    _run(
                                      (s) => s.repository.setCategoryArchived(
                                        _ledger,
                                        category.id,
                                        false,
                                      ),
                                    );
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('修改名称'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'icon',
                                    child: Text('更换图标'),
                                  ),
                                  PopupMenuItem(
                                    value: category.archived
                                        ? 'restore'
                                        : 'archive',
                                    child: Text(
                                      category.archived ? '恢复分类' : '归档分类',
                                    ),
                                  ),
                                ],
                              ),
                              if (!_archived && !_busy)
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Icon(Icons.drag_handle),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
