import 'dart:async';

import 'money_privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../finance/analysis.dart';
import '../transaction/transaction_identity.dart';
import 'transaction_editor.dart';
import 'widgets.dart';
import 'manage_page.dart';
import 'smart_input.dart';
import 'review_inbox.dart';
import 'ocr_page.dart';
import '../automation/capture_bridge.dart';
import '../automation/automation_bridge.dart';
import '../automation/notification_shortcuts.dart';
import 'analysis_page.dart';
import 'attachments_page.dart';
import 'year_month_picker.dart';
import 'transaction_templates_page.dart';
import 'recurring_rules_page.dart';
import 'bill_tools_page.dart';
import 'budget_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  bool _captureOpening = false, _captureStarting = false;
  late final CaptureBridge _capture;
  late final AutomationBridge _automation;
  late final NotificationShortcutsBridge _shortcuts;
  late final LedgerController _ledger;
  Timer? _shortcutSync;
  int _tab = 0;
  final _search = TextEditingController();
  TransactionType? _filter;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capture = ref.read(captureBridgeProvider)..listen(_openCapture);
    _shortcuts = ref.read(notificationShortcutsProvider)..listen(_openShortcut);
    _ledger = ref.read(ledgerProvider)..addListener(_ledgerUpdated);
    _automation = ref.read(automationBridgeProvider)
      ..listen(() async {
        if (mounted) await ref.read(ledgerProvider).load();
      });
    Future.microtask(() async {
      await ref.read(ledgerProvider).load();
      await _openCapture();
      await _openShortcut();
      await _syncTodayNotification();
      await _automation.status();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _capture.dispose();
    _shortcuts.dispose();
    _shortcutSync?.cancel();
    _ledger.removeListener(_ledgerUpdated);
    _automation.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(ledgerProvider).load();
      _automation.status();
      _openCapture();
      _openShortcut();
      _syncTodayNotification();
    }
  }

  void _ledgerUpdated() {
    if (_ledger.loading || _ledger.summary == null) return;
    _shortcutSync?.cancel();
    _shortcutSync = Timer(
      const Duration(milliseconds: 150),
      _syncTodayNotification,
    );
  }

  int _todayExpense() => todayExpenseTotal(_ledger.entries, DateTime.now());

  Future<void> _syncTodayNotification() async {
    try {
      await _shortcuts.updateToday(_todayExpense(), _ledger.ledgerId);
    } catch (_) {
      // Notification permission/configuration is optional.
    }
  }

  Future<void> _openShortcut() async {
    if (!mounted || _ledger.summary == null) return;
    final action = await _shortcuts.takePending();
    if (!mounted || action == null) return;
    switch (action) {
      case 'voice':
        await showVoiceInput(context);
        break;
      case 'today':
        await _showTodayExpense();
        break;
      case 'smart':
        await showSmartInput(context);
        break;
      case 'capture':
        await _startCapture();
        break;
      case 'templates':
        await showTransactionTemplates(context, choose: true);
        break;
      case 'recurring':
        await showRecurringRules(context, RecurringKind.incomeExpense);
        break;
      default:
        await showTransactionEditor(
          context,
          onSwitchToSmart: () => showSmartInput(context),
        );
        break;
    }
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openShortcut());
    }
  }

  Future<void> _showTodayExpense() async {
    final now = DateTime.now();
    final entries = _ledger.entries.where((entry) {
      final date = entry.occurredDate;
      return !entry.deleted &&
          (entry.type == TransactionType.expense ||
              entry.type == TransactionType.refund) &&
          date.year == now.year &&
          date.month == now.month &&
          date.day == now.day;
    }).toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('今日消费', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                visibleMoney(context, _todayExpense()),
                style: const TextStyle(
                  color: teal,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Divider(height: 24),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text('今天还没有消费记录'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length.clamp(0, 8).toInt(),
                    itemBuilder: (_, index) {
                      final entry = entries[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          entry.merchant.isEmpty
                              ? entry.categoryName ?? typeLabel(entry.type)
                              : entry.merchant,
                        ),
                        subtitle: Text(
                          '${entry.accountName}${entry.discountMinor != null && entry.discountMinor! > 0 ? ' · 优惠${visibleMoney(context, entry.discountMinor!)}' : ''}',
                        ),
                        trailing: Text(
                          '${entry.type == TransactionType.refund ? '+' : '-'}${visibleMoney(context, entry.amountMinor)}',
                        ),
                      );
                    },
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    setState(() => _tab = 1);
                  },
                  child: const Text('查看全部流水'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startCapture() async {
    if (_captureStarting || _captureOpening) return;
    setState(() => _captureStarting = true);
    try {
      final started = await _capture.startCapture();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自动截图支持Android，请从OCR模型与图片导入入口选择截图。')),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _captureStarting = false);
    }
  }

  Future<void> _openCapture() async {
    if (!mounted ||
        _captureOpening ||
        ref.read(ledgerProvider).summary == null) {
      return;
    }
    _captureOpening = true;
    bool opened = false;
    try {
      final image = await _capture.takePending();
      if (image != null && mounted) {
        opened = true;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => OcrPage(capture: image)),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _captureOpening = false;
      if (opened && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _openCapture());
      }
    }
  }

  Future<void> _entryActions(LedgerEntry entry) async {
    final ordinary = const [
      TransactionType.expense,
      TransactionType.income,
    ].contains(entry.type);
    final activeMerge = ordinary
        ? await ref
              .read(ledgerProvider)
              .repository
              .latestActiveMerge(ref.read(ledgerProvider).ledgerId, entry.id)
        : null;
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${entry.merchant.isEmpty ? entry.categoryName ?? typeLabel(entry.type) : entry.merchant} · ${visibleMoney(context, entry.amountMinor)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text('${dateKey(entry.occurredDate)} · ${entry.accountName}'),
              if (entry.note.isNotEmpty) Text(entry.note),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑账目'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              if (entry.reimbursable)
                Text(
                  '${entry.reimbursementStatus} · 已到账 ${visibleMoney(context, entry.reimbursedMinor)} · 剩余 ${visibleMoney(context, entry.reimbursementRemaining)}',
                ),
              if (entry.reimbursable && entry.reimbursementRemaining > 0)
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Text('记录报销到账'),
                  onTap: () => Navigator.pop(context, 'reimbursement'),
                ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text('图片附件 · ${entry.attachmentCount}'),
                onTap: () => Navigator.pop(context, 'attachments'),
              ),
              if (entry.type == TransactionType.expense)
                ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('记录退款'),
                  onTap: () => Navigator.pop(context, 'refund'),
                ),
              if (entry.type != TransactionType.transfer)
                ListTile(
                  leading: const Icon(Icons.call_split_outlined),
                  title: const Text('拆分账单 / AA'),
                  subtitle: const Text('按参与人分摊并标记结清状态'),
                  onTap: () => Navigator.pop(context, 'split'),
                ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('加入账单分组'),
                onTap: () => Navigator.pop(context, 'group'),
              ),
              if (ordinary)
                ListTile(
                  leading: const Icon(Icons.merge_outlined),
                  title: const Text('合并为同一笔'),
                  subtitle: const Text('按订单号或金额、商户、时间、账户和方向查找候选'),
                  onTap: () => Navigator.pop(context, 'merge'),
                ),
              if (activeMerge != null)
                ListTile(
                  leading: const Icon(Icons.undo_outlined),
                  title: const Text('撤销上次合并'),
                  subtitle: const Text('恢复被合并的账单及其来源证据'),
                  onTap: () => Navigator.pop(context, 'undoMerge'),
                ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('删除账目'),
                subtitle: const Text('可在回收站恢复'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      await _editEntry(entry);
      return;
    }
    if (action == 'reimbursement') {
      await showTransactionEditor(
        context,
        refundOf: entry,
        reimbursement: true,
      );
      return;
    }
    if (action == 'attachments') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AttachmentsPage(
            ledger: ref.read(ledgerProvider).ledgerId,
            transactionId: entry.id,
          ),
        ),
      );
      return;
    }
    if (action == 'refund') {
      await showTransactionEditor(context, refundOf: entry);
      return;
    }
    if (action == 'split') {
      await showBillSplitPage(context, entry);
      return;
    }
    if (action == 'group') {
      await showTransactionGroupPicker(context, ref, entry);
      return;
    }
    if (action == 'merge') {
      await _mergeEntry(entry);
      return;
    }
    if (action == 'undoMerge' && activeMerge != null) {
      await _undoMerge(activeMerge);
      return;
    }
    if (action == 'delete') {
      await _deleteEntry(entry);
    }
  }

  Future<void> _editEntry(LedgerEntry entry) =>
      showTransactionEditor(context, entry: entry);

  Future<void> _mergeEntry(LedgerEntry target) async {
    final state = ref.read(ledgerProvider);
    try {
      final candidates = await state.repository.transactionMergeCandidates(
        state.ledgerId,
        target.id,
      );
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有找到可合并候选；系统不会仅凭金额推荐合并')));
        return;
      }
      final selected = await showModalBottomSheet<TransactionMergeCandidate>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              Text('选择同一笔账单', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('订单号优先；没有订单号时，必须同时匹配金额、商户、同日、账户和方向。'),
              const SizedBox(height: 12),
              for (final candidate in candidates)
                Card(
                  child: ListTile(
                    title: Text(
                      candidate.transaction.merchant.isEmpty
                          ? candidate.transaction.categoryName ?? '账单'
                          : candidate.transaction.merchant,
                    ),
                    subtitle: Text(
                      [
                        '${candidate.matchedByOrder ? '订单号匹配' : '多字段候选'} · ${dateTimeLabel(candidate.transaction.occurredDate)}',
                        if (candidate.evidence.isNotEmpty)
                          '证据：${candidate.evidence.map((item) => item.sourceLabel).toSet().join('、')}',
                        if (candidate.differences.isNotEmpty)
                          '差异：${candidate.differences.join('；')}',
                      ].join('\n'),
                    ),
                    trailing: Text(
                      visibleMoney(context, candidate.transaction.amountMinor),
                    ),
                    isThreeLine: true,
                    onTap: () => Navigator.pop(context, candidate),
                  ),
                ),
            ],
          ),
        ),
      );
      if (selected == null || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认合并为同一笔？'),
          content: Text(
            [
              '将保留当前账单，并隐藏所选重复账单；两边的来源证据会合并保存。',
              if (selected.differences.isNotEmpty)
                '检测到证据差异：\n${selected.differences.map((item) => '• $item').join('\n')}',
              '合并后仍可从当前账单的操作菜单撤销。',
            ].join('\n\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认合并'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final mergeId = await state.repository.mergeTransactions(
        state.ledgerId,
        targetTransactionId: target.id,
        sourceTransactionId: selected.transaction.id,
        acceptConflicts: selected.hasConflict,
      );
      await state.load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已合并为同一笔，来源证据已保留'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              try {
                await state.repository.undoTransactionMerge(
                  state.ledgerId,
                  mergeId,
                );
                await state.load();
              } catch (error) {
                if (mounted) showError(context, error);
              }
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _undoMerge(TransactionMergeUndo merge) async {
    final state = ref.read(ledgerProvider);
    try {
      await state.repository.undoTransactionMerge(state.ledgerId, merge.id);
      await state.load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已撤销合并，被合并账单和来源证据已恢复')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Widget _addMenuButton(bool wide, LedgerController state) => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        leadingIcon: const Icon(Icons.edit_note_outlined),
        onPressed: () => showTransactionEditor(
          context,
          onSwitchToSmart: () => showSmartInput(context),
        ),
        child: const Text('手动记账'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.mic_none),
        onPressed: () => showVoiceInput(context),
        child: const Text('语音记账'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.auto_awesome_outlined),
        onPressed: () => showSmartInput(context),
        child: const Text('一句话记账'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.document_scanner_outlined),
        onPressed: state.loading || _captureStarting ? null : _startCapture,
        child: const Text('OCR截图记账'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.dashboard_customize_outlined),
        onPressed: () => showTransactionTemplates(context, choose: true),
        child: const Text('模板记账'),
      ),
    ],
    builder: (context, controller, child) => wide
        ? FloatingActionButton.extended(
            tooltip: '记一笔',
            onPressed: controller.isOpen ? controller.close : controller.open,
            icon: const Icon(Icons.add),
            label: const Text('记一笔'),
          )
        : FloatingActionButton.small(
            tooltip: '记一笔',
            onPressed: controller.isOpen ? controller.close : controller.open,
            child: const Icon(Icons.add),
          ),
  );

  Future<void> _deleteEntry(LedgerEntry entry) async {
    try {
      await ref.read(ledgerProvider).delete(entry.id);
      if (!mounted) return;
      final controller = ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: const Text('账目已移入回收站'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              try {
                await ref.read(ledgerProvider).restore(entry.id);
              } catch (e) {
                if (mounted) showError(context, e);
              }
            },
          ),
        ),
      );
      // SnackBars with actions otherwise remain indefinitely when Android
      // accessibility navigation is enabled. Deletion undo is always five
      // seconds, including when this app's accessibility service is on.
      final timer = Timer(const Duration(seconds: 5), controller.close);
      unawaited(controller.closed.whenComplete(timer.cancel));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    return Scaffold(
      body: SafeArea(
        bottom: wide,
        child: Row(
          children: [
            if (wide)
              SizedBox(
                width: 216,
                child: Material(
                  color: colors.surfaceContainerLowest,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
                        child: Row(
                          children: [
                            Icon(
                              Icons.auto_stories,
                              color: colors.primary,
                              size: 30,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '知账',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: colors.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (final item in [
                        (0, '总览', Icons.grid_view_outlined),
                        (1, '流水', Icons.receipt_long_outlined),
                        (2, '账户', Icons.account_balance_wallet_outlined),
                        (3, '分析', Icons.bar_chart_outlined),
                        (4, '管理', Icons.tune),
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: ListTile(
                            selected: _tab == item.$1,
                            selectedTileColor: colors.primaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            leading: Icon(
                              item.$3,
                              color: _tab == item.$1
                                  ? colors.onPrimaryContainer
                                  : colors.onSurfaceVariant,
                            ),
                            title: Text(
                              item.$2,
                              style: TextStyle(
                                fontWeight: _tab == item.$1
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            onTap: () => setState(() => _tab = item.$1),
                          ),
                        ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Row(
                          children: [
                            Icon(
                              Icons.cloud_off_outlined,
                              size: 16,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '离线记账 · 本地保存',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 36 : 16,
                      wide ? 20 : 10,
                      wide ? 36 : 16,
                      wide ? 16 : 6,
                    ),
                    child: Row(
                      children: [
                        if (!wide) ...[
                          Icon(Icons.auto_stories, color: colors.primary),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            ['财务总览', '全部流水', '我的账户', '收支分析', '账本管理'][_tab],
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                        if (state.ledgers.isNotEmpty)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: wide ? 220 : 140,
                            ),
                            child: DropdownButton<String>(
                              value: state.ledgerId,
                              isExpanded: true,
                              borderRadius: BorderRadius.circular(16),
                              underline: const SizedBox(),
                              items: state.ledgers.entries
                                  .map(
                                    (e) => DropdownMenuItem(
                                      value: e.key,
                                      child: Text(
                                        e.value,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: state.loading
                                  ? null
                                  : (v) {
                                      if (v != null) state.selectLedger(v);
                                    },
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (state.loading)
                    const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: state.error != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(state.error!),
                                TextButton(
                                  onPressed: state.load,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          )
                        : state.summary == null
                        ? const Center(child: CircularProgressIndicator())
                        : RefreshIndicator(
                            onRefresh: state.load,
                            child: ListView(
                              padding: EdgeInsets.fromLTRB(
                                wide ? 36 : 16,
                                4,
                                wide ? 36 : 16,
                                88,
                              ),
                              children: [
                                Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1080,
                                    ),
                                    child: switch (_tab) {
                                      0 => _overview(state),
                                      1 => _transactions(state),
                                      2 => AccountsPage(state: state),
                                      3 => AnalysisPage(state: state),
                                      _ => const ManagePage(),
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : SafeArea(
              top: false,
              child: NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (v) => setState(() => _tab = v),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.grid_view_outlined),
                    selectedIcon: Icon(Icons.grid_view_rounded),
                    label: '总览',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    selectedIcon: Icon(Icons.receipt_long),
                    label: '流水',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.account_balance_wallet_outlined),
                    selectedIcon: Icon(Icons.account_balance_wallet),
                    label: '账户',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.bar_chart_outlined),
                    selectedIcon: Icon(Icons.bar_chart),
                    label: '分析',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.tune_outlined),
                    selectedIcon: Icon(Icons.tune),
                    label: '管理',
                  ),
                ],
              ),
            ),
      floatingActionButton: state.summary == null
          ? null
          : _addMenuButton(wide, state),
    );
  }

  Widget _overview(LedgerController state) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final summary = state.summary!;
    final recent = state.entries
        .where(
          (e) =>
              e.occurredDate.year == state.month.year &&
              e.occurredDate.month == state.month.month,
        )
        .take(5)
        .toList();
    final groups = summary.categoryExpenses.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.pendingDrafts.isNotEmpty) ...[
          SectionCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.inbox_outlined, color: colors.primary),
              title: Text('待确认账单 · ${state.pendingDrafts.length}'),
              subtitle: const Text('确认后才计入余额和统计'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showReviewInbox(context),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: InkWell(
                key: const ValueKey('home_month_picker'),
                borderRadius: BorderRadius.circular(10),
                onTap: state.loading
                    ? null
                    : () async {
                        final selected = await showYearMonthPicker(
                          context,
                          initial: state.month,
                        );
                        if (selected != null) await state.selectMonth(selected);
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '${state.month.year} 年 ${state.month.month} 月',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.expand_more,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '上个月',
              visualDensity: VisualDensity.compact,
              onPressed: state.loading ? null : () => state.changeMonth(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: '下个月',
              visualDensity: VisualDensity.compact,
              onPressed: state.loading ? null : () => state.changeMonth(1),
              icon: const Icon(Icons.chevron_right),
            ),
            Icon(Icons.shield_outlined, size: 15, color: colors.primary),
            const SizedBox(width: 5),
            Text('本地保存', style: TextStyle(fontSize: 12, color: colors.primary)),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '本月消费净额',
                style: TextStyle(
                  color: colors.onPrimary.withValues(alpha: .8),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              FittedBox(
                child: Text(
                  visibleMoney(context, summary.expenseMinor),
                  style: TextStyle(
                    color: colors.onPrimary,
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      '本月收入',
                      visibleMoney(context, summary.incomeMinor),
                    ),
                  ),
                  Expanded(
                    child: _metric(
                      '本月结余',
                      visibleMoney(context, summary.surplusMinor),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '预算 · ${state.budgets.length}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (state.budgets.isEmpty)
                          Text(
                            '设置总额或分类预算，可按月、季、年结转',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => showBudgetPlansPage(context),
                    child: Text(state.budgets.isEmpty ? '设置' : '管理'),
                  ),
                ],
              ),
              if (state.budgets.isNotEmpty) ...[
                if (state.budgets.any((value) => value.warning))
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: colors.tertiaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      state.budgets.any((value) => value.exceeded)
                          ? '预算超支，请查看预算明细'
                          : '预算已接近提醒比例',
                      style: TextStyle(
                        color: colors.onTertiaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                for (final budget in state.budgets.take(3)) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          budget.plan.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        '剩余 ${visibleMoney(context, budget.remainingMinor)}',
                        style: TextStyle(
                          color: budget.exceeded
                              ? colors.error
                              : colors.onSurface,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: MoneyPrivacy.of(context) ? 0 : budget.progress,
                    minHeight: 5,
                    color: budget.exceeded || budget.warning
                        ? colors.tertiary
                        : colors.primary,
                    backgroundColor: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  const SizedBox(height: 7),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final spending = SectionCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '支出分类',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  if (groups.isEmpty)
                    const EmptyView(
                      title: '还没有消费记录',
                      description: '记下第一笔，看看钱花在哪里。',
                    )
                  else
                    for (final group in groups.take(6))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(
                                  categoryIcon(group.key),
                                  size: 18,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: Text(group.key)),
                                Text(
                                  visibleMoney(context, group.value),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              minHeight: 4,
                              borderRadius: BorderRadius.circular(4),
                              value: summary.expenseMinor > 0
                                  ? (group.value / summary.expenseMinor).clamp(
                                      0,
                                      1,
                                    )
                                  : 0,
                              color: colors.primary,
                              backgroundColor: colors.surfaceContainerHighest,
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            );
            final activity = SectionCard(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '近期账目',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _tab = 1),
                        child: const Text('查看全部'),
                      ),
                    ],
                  ),
                  if (recent.isEmpty)
                    EmptyView(
                      title: '从一笔开始',
                      description: '午饭、咖啡、通勤，都值得记录。',
                      action: FilledButton.icon(
                        onPressed: () => showTransactionEditor(
                          context,
                          onSwitchToSmart: () => showSmartInput(context),
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('记第一笔'),
                      ),
                    )
                  else
                    for (final entry in recent)
                      EntryTile(
                        entry: entry,
                        onTap: () => _entryActions(entry),
                        onEdit: () => _editEntry(entry),
                        onDelete: () => _deleteEntry(entry),
                      ),
                ],
              ),
            );
            return constraints.maxWidth > 720
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: spending),
                      const SizedBox(width: 12),
                      Expanded(child: activity),
                    ],
                  )
                : Column(
                    children: [activity, const SizedBox(height: 12), spending],
                  );
          },
        ),
        const SizedBox(height: 16),
        Text(
          '消费净额 = 支出 − 当月到账退款；转账不计入收支。',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _metric(String label, String value) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.onPrimary.withValues(alpha: .8),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          child: Text(
            value,
            style: TextStyle(
              color: colors.onPrimary,
              fontSize: 21,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _transactions(LedgerController state) {
    final colors = Theme.of(context).colorScheme;
    final query = _search.text.trim().toLowerCase();
    final entries = state.entries
        .where(
          (e) =>
              (_filter == null || _filter == e.type) &&
              (e.merchant.toLowerCase().contains(query) ||
                  e.note.toLowerCase().contains(query) ||
                  e.tags.any((tag) => tag.toLowerCase().contains(query))),
        )
        .toList();
    String previousDate = '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search),
            hintText: '搜索商户或备注',
            contentPadding: EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: const Text('全部'),
                selected: _filter == null,
                onSelected: (_) => setState(() => _filter = null),
              ),
              for (final type in [
                TransactionType.expense,
                TransactionType.income,
                TransactionType.transfer,
                TransactionType.refund,
              ]) ...[
                const SizedBox(width: 6),
                ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(typeLabel(type)),
                  selected: _filter == type,
                  onSelected: (_) => setState(() => _filter = type),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (entries.isEmpty)
          const SectionCard(
            child: EmptyView(title: '没有找到记录', description: '记一笔账，或换个搜索条件。'),
          )
        else
          SectionCard(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '左滑显示编辑与删除',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final entry in entries) ...[
                  if (dateKey(entry.occurredDate) != previousDate)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 2),
                      child: Text(
                        previousDate = dateKey(entry.occurredDate),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  EntryTile(
                    entry: entry,
                    onTap: () => _entryActions(entry),
                    onEdit: () => _editEntry(entry),
                    onDelete: () => _deleteEntry(entry),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
