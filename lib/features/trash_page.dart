import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/ledger_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'action_form.dart';
import 'money_privacy.dart';
import 'widgets.dart';

Future<void> showTrashPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const TrashPage()));

class TrashPage extends ConsumerStatefulWidget {
  const TrashPage({super.key});

  @override
  ConsumerState<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends ConsumerState<TrashPage> {
  List<LedgerEntry> _entries = const [];
  int _retentionDays = 0;
  bool _loading = true;
  bool _busy = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    try {
      await state.repository.purgeExpiredTrash();
      final values = await Future.wait<Object>([
        state.repository.entries(state.ledgerId, deleted: true),
        state.repository.trashRetentionDays(),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = values[0] as List<LedgerEntry>;
        _retentionDays = values[1] as int;
        _selectedIds.retainAll(_entries.map((entry) => entry.id));
        if (_selectedIds.isEmpty) _selectionMode = false;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _setRetention(int days) async {
    if (_busy || days == _retentionDays) return;
    if (days > 0 &&
        !await _confirm(
          '修改自动清理期限',
          '保存后，已超过 $days 天的回收站账目会立即彻底删除，且无法恢复。',
          '保存设置',
        )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(ledgerProvider).repository.setTrashRetentionDays(days);
      await ref.read(ledgerProvider).load();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(LedgerEntry entry) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(ledgerProvider).restore(entry.id);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('账目已恢复')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteForever(LedgerEntry entry) async {
    if (_busy ||
        !await _confirm('彻底删除这笔账目？', '账目、账户分录及附件将被永久删除，操作无法撤销。', '彻底删除')) {
      return;
    }
    setState(() => _busy = true);
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.permanentlyDelete(state.ledgerId, entry.id);
      await state.load();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _empty() async {
    if (_busy ||
        _entries.isEmpty ||
        !await _confirm(
          '清空回收站？',
          '当前账本回收站中的 ${_entries.length} 笔账目及附件将永久删除，操作无法撤销。',
          '全部删除',
        )) {
      return;
    }
    setState(() => _busy = true);
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.emptyTrash(state.ledgerId);
      await state.load();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startSelection(String id) {
    if (_busy) return;
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelection(String id) {
    if (_busy || !_selectionMode) return;
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _leaveSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelectAll() {
    if (_busy) return;
    setState(() {
      if (_selectedIds.length == _entries.length) {
        _selectedIds.clear();
        _selectionMode = false;
      } else {
        _selectionMode = true;
        _selectedIds
          ..clear()
          ..addAll(_entries.map((entry) => entry.id));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final selected = Set<String>.of(_selectedIds);
    if (_busy ||
        selected.isEmpty ||
        !await _confirm(
          '彻底删除选中的 ${selected.length} 笔账目？',
          '所选账目、账户分录及附件将被永久删除，操作无法撤销。',
          '删除所选',
        )) {
      return;
    }
    setState(() => _busy = true);
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.permanentlyDeleteMany(state.ledgerId, selected);
      await state.load();
      _leaveSelection();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已彻底删除 ${selected.length} 笔账目')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _retentionLabel(int days) => days == 0 ? '永不自动删除' : '保留 $days 天';

  String _deletedLabel(LedgerEntry entry) {
    final deleted = entry.deletedAt?.toLocal();
    return deleted == null ? '删除时间未知' : '删除于 ${dateKey(deleted)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(
                tooltip: '退出多选',
                onPressed: _busy ? null : _leaveSelection,
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(_selectionMode ? '已选择 ${_selectedIds.length} 项' : '回收站'),
        actions: [
          if (_selectionMode) ...[
            TextButton(
              key: const ValueKey('trash-select-all'),
              onPressed: _busy ? null : _toggleSelectAll,
              child: Text(
                _selectedIds.length == _entries.length ? '取消全选' : '全选',
              ),
            ),
            IconButton(
              key: const ValueKey('trash-delete-selected'),
              tooltip: '彻底删除所选',
              onPressed: _busy || _selectedIds.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete_forever_outlined),
            ),
          ] else if (_entries.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _empty,
              child: const Text('清空'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                SectionCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: teal.withValues(alpha: .09),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.auto_delete_outlined,
                        color: teal,
                      ),
                    ),
                    title: const Text(
                      '自动彻底删除',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text('到期后自动清理；选择“永不”则仅手动处理'),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const ValueKey('trash_retention'),
                        value: _retentionDays,
                        items: [
                          for (final days
                              in LedgerRepository.trashRetentionOptions)
                            DropdownMenuItem(
                              value: days,
                              child: Text(_retentionLabel(days)),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) {
                                if (value != null) _setRetention(value);
                              },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_entries.isEmpty)
                  const SectionCard(
                    child: EmptyView(
                      title: '回收站为空',
                      description: '删除的账目会暂存在这里，可在自动清理前恢复。',
                    ),
                  )
                else
                  SectionCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < _entries.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, indent: 62, endIndent: 10),
                          _TrashEntryTile(
                            entry: _entries[i],
                            deletedLabel: _deletedLabel(_entries[i]),
                            busy: _busy,
                            selectionMode: _selectionMode,
                            selected: _selectedIds.contains(_entries[i].id),
                            onLongPress: () => _startSelection(_entries[i].id),
                            onToggleSelection: () =>
                                _toggleSelection(_entries[i].id),
                            onRestore: () => _restore(_entries[i]),
                            onDelete: () => _deleteForever(_entries[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TrashEntryTile extends StatelessWidget {
  const _TrashEntryTile({
    required this.entry,
    required this.deletedLabel,
    required this.busy,
    required this.selectionMode,
    required this.selected,
    required this.onLongPress,
    required this.onToggleSelection,
    required this.onRestore,
    required this.onDelete,
  });

  final LedgerEntry entry;
  final String deletedLabel;
  final bool busy;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelection;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = entry.merchant.isEmpty
        ? entry.categoryName ?? typeLabel(entry.type)
        : entry.merchant;
    return ListTile(
      key: ValueKey('trash-entry-${entry.id}'),
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      selected: selected,
      selectedTileColor: teal.withValues(alpha: .06),
      onLongPress: busy ? null : onLongPress,
      onTap: selectionMode && !busy ? onToggleSelection : null,
      leading: selectionMode
          ? Checkbox(
              key: ValueKey('trash-select-${entry.id}'),
              value: selected,
              onChanged: busy ? null : (_) => onToggleSelection(),
            )
          : Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: orange.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                categoryIcon(entry.categoryName),
                color: orange,
                size: 20,
              ),
            ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${dateKey(entry.occurredDate)} · ${visibleMoney(context, entry.amountMinor)} · $deletedLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: selectionMode
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('trash-restore-${entry.id}'),
                  tooltip: '恢复账目',
                  onPressed: busy ? null : onRestore,
                  icon: const Icon(Icons.restore, color: teal),
                ),
                IconButton(
                  key: ValueKey('trash-delete-${entry.id}'),
                  tooltip: '彻底删除',
                  onPressed: busy ? null : onDelete,
                  icon: const Icon(Icons.delete_forever_outlined),
                ),
              ],
            ),
    );
  }
}
