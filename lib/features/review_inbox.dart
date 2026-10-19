import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/advanced_finance_repository.dart';
import '../domain/family_payment.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/pending_batch.dart';
import '../domain/tags.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/auto_correction.dart';
import 'action_form.dart' show showError;
import 'family_cards_page.dart';
import 'money_privacy.dart';
import 'refund_review.dart';
import 'smart_input.dart';
import 'transaction_editor.dart';
import 'widgets.dart';

Future<void> showReviewInbox(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const ReviewInbox()));

class ReviewInbox extends ConsumerStatefulWidget {
  const ReviewInbox({super.key});

  @override
  ConsumerState<ReviewInbox> createState() => _ReviewInboxState();
}

class _ReviewInboxState extends ConsumerState<ReviewInbox> {
  final _selected = <String>{};
  List<PendingDraft>? _ignored;
  List<PendingDuplicateGroup>? _duplicateGroups;
  bool _busy = false;

  AdvancedFinanceRepository get _advanced =>
      AdvancedFinanceRepository(ref.read(repositoryProvider).db);

  @override
  void initState() {
    super.initState();
    _loadIgnored();
    _loadDuplicateGroups();
  }

  Future<void> _loadDuplicateGroups() async {
    try {
      final values = await ref
          .read(repositoryProvider)
          .pendingDuplicateGroups(ref.read(ledgerProvider).ledgerId);
      if (mounted) setState(() => _duplicateGroups = values);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _loadIgnored() async {
    try {
      final values = await _advanced.ignoredDrafts(
        ref.read(ledgerProvider).ledgerId,
      );
      if (mounted) setState(() => _ignored = values);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  TransactionDraft _parse(PendingDraft item) {
    final state = ref.read(ledgerProvider);
    var parsed = TransactionParser().parse(
      item.raw,
      ledgerId: item.ledgerId,
      accounts: state.accounts,
      categories: state.categories,
    );
    parsed = applyAutoCorrection(parsed, state.autoCorrectionRules);
    if (item.raw.source == TransactionSource.notification) {
      parsed = parsed.withWarnings(
        {...parsed.warnings, ...item.storedWarnings}.toList(),
      );
    }
    if (item.familyEventId != null || item.familyRole != null) {
      parsed = parsed.withFamilyBinding(
        eventId: item.familyEventId,
        role: item.familyRole,
        clearAccountForBeneficiary:
            item.familyRole == FamilyLocalRole.beneficiary,
      );
    }
    if (item.batchAccountId != null ||
        item.batchCategoryId != null ||
        item.batchTags != null) {
      parsed = parsed.withBatchEdits(
        ledgerId: item.ledgerId,
        accountId: item.batchAccountId,
        categoryId: item.batchCategoryId,
        tags: item.batchTags,
      );
    }
    return parsed;
  }

  void _toggle(String id) => setState(() {
    if (!_selected.add(id)) _selected.remove(id);
  });

  Future<void> _ignoreSelected() async {
    if (_selected.isEmpty || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量忽略预览'),
        content: Text(
          '预计忽略 ${_selected.length} 笔待确认账单。\n\n若任一账单已被处理，本次操作将全部回滚；忽略后仍可在“已忽略”中恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认忽略'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _advanced.ignoreDrafts(
        ref.read(ledgerProvider).ledgerId,
        _selected,
      );
      _selected.clear();
      await ref.read(ledgerProvider).load();
      await _loadIgnored();
      await _loadDuplicateGroups();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmSelected() async {
    if (_selected.isEmpty || _busy) return;
    final state = ref.read(ledgerProvider);
    final candidates = state.pendingDrafts
        .where((item) => _selected.contains(item.id))
        .map((item) => (item, _parse(item)))
        .toList();
    String? skipReason((PendingDraft, TransactionDraft) pair) {
      final item = pair.$1;
      final value = pair.$2;
      if (item.familyEventId != null || value.familyEventId != null) {
        return '亲情卡账单需逐笔审核';
      }
      if (value.blocked) return '解析结果已阻止直接入账';
      if (value.warnings.isNotEmpty) return value.warnings.first;
      if (value.amountMinor == null) return '缺少金额';
      if (value.accountId == null) return '缺少账户';
      if (value.categoryId == null) return '缺少分类';
      if (!const [
        TransactionType.expense,
        TransactionType.income,
      ].contains(value.type)) {
        return '转账或退款需逐笔核对';
      }
      return null;
    }

    final eligible = candidates
        .where((pair) => skipReason(pair) == null)
        .toList();
    final skipped = candidates
        .where((pair) => skipReason(pair) != null)
        .toList();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量确认预览'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('预计入账 ${eligible.length} 笔，跳过 ${skipped.length} 笔。'),
                if (skipped.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('跳过原因：'),
                  for (final pair in skipped)
                    Text(
                      '• ${pair.$2.merchant.isEmpty ? '待核对账单' : pair.$2.merchant}：${skipReason(pair)}',
                    ),
                ],
                const SizedBox(height: 12),
                const Text('入账在同一个数据库事务内执行；任一笔失败时不会保留部分结果。'),
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
            onPressed: eligible.isEmpty
                ? null
                : () => Navigator.pop(dialogContext, true),
            child: const Text('确认处理'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await state.repository.db.transaction(() async {
        for (final pair in eligible) {
          final item = pair.$1;
          final value = pair.$2;
          await state.repository.confirmDraft(
            item.ledgerId,
            item.id,
            TransactionInput(
              type: value.type,
              amountMinor: value.amountMinor!,
              accountId: value.accountId!,
              categoryId: value.categoryId,
              occurredDate: value.occurredDate,
              merchant: value.merchant,
              tags: value.tags,
            ),
          );
        }
      });
      _selected.clear();
      await state.load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已确认 ${eligible.length} 笔，跳过 ${skipped.length} 笔'),
          ),
        );
      }
      await _loadDuplicateGroups();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editSelected() async {
    if (_selected.isEmpty || _busy) return;
    final patch = await showModalBottomSheet<PendingDraftBatchPatch>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BatchDraftEditSheet(
        currentLedgerId: ref.read(ledgerProvider).ledgerId,
      ),
    );
    if (patch == null || !mounted) return;
    try {
      final repository = ref.read(repositoryProvider);
      final ledger = ref.read(ledgerProvider).ledgerId;
      final preview = await repository.previewPendingDraftBatch(
        ledger,
        _selected,
        patch,
      );
      if (!mounted) return;
      final confirmed = await _showBatchEditPreview(preview);
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);
      final applied = await repository.applyPendingDraftBatch(
        ledger,
        _selected,
        patch,
      );
      _selected.clear();
      await ref.read(ledgerProvider).load();
      await _loadDuplicateGroups();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已修改 ${applied.eligible} 笔，跳过 ${applied.skipped} 笔'),
          ),
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _showBatchEditPreview(PendingDraftBatchPreview preview) =>
      showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('批量修改预览'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('预计修改 ${preview.eligible} 笔，跳过 ${preview.skipped} 笔。'),
                  const SizedBox(height: 12),
                  for (final item in preview.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        item.eligible
                            ? '✓ ${item.title}：${item.changes.join('；')}'
                            : '— ${item.title}：${item.skipReason}',
                      ),
                    ),
                  const Text('全部修改在同一事务内执行，执行失败会完整回滚。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('返回修改'),
            ),
            FilledButton(
              onPressed: preview.eligible == 0
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('确认执行'),
            ),
          ],
        ),
      );

  Future<void> _reviewDuplicateGroup(PendingDuplicateGroup group) async {
    final state = ref.read(ledgerProvider);
    final drafts = state.pendingDrafts
        .where((item) => group.draftIds.contains(item.id))
        .toList();
    if (drafts.isEmpty) return;
    String? keepId = group.existingTransactionCount > 0
        ? null
        : drafts.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('成组审核重复候选'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 440),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.matchedByOrder
                        ? '这些采集具有相同订单号证据。'
                        : '这些采集的金额、商户、时间、账户和方向一致。',
                  ),
                  if (group.existingTransactionCount > 0)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('已经存在正式账单；确认后将忽略本组全部待处理候选。'),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('请选择保留继续核对的一笔，其余候选将移入已忽略。'),
                    ),
                  const SizedBox(height: 8),
                  for (final draft in drafts)
                    ListTile(
                      leading: Icon(
                        keepId == draft.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      onTap: group.existingTransactionCount > 0
                          ? null
                          : () => setDialogState(() => keepId = draft.id),
                      title: Text(
                        _parse(draft).merchant.isEmpty
                            ? '待核对账单'
                            : _parse(draft).merchant,
                      ),
                      subtitle: Text(dateTimeLabel(draft.raw.capturedAt)),
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
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认分组处理'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final ignored = drafts
        .where((draft) => draft.id != keepId)
        .map((draft) => draft.id)
        .toSet();
    if (ignored.isEmpty) return;
    try {
      await _advanced.ignoreDrafts(state.ledgerId, ignored);
      await state.load();
      await _loadIgnored();
      await _loadDuplicateGroups();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已忽略 ${ignored.length} 个重复候选')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _restoreIgnored(String id) async {
    try {
      await _advanced.restoreIgnoredDraft(
        ref.read(ledgerProvider).ledgerId,
        id,
      );
      await ref.read(ledgerProvider).load();
      await _loadIgnored();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _clearIgnored() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空忽略记录？'),
        content: const Text('将永久删除当前账本全部已忽略的采集记录，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final count = await _advanced.clearIgnoredDrafts(
        ref.read(ledgerProvider).ledgerId,
      );
      await _loadIgnored();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已清理 $count 条忽略记录')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _selected.isEmpty ? '待处理账单' : '已选择 ${_selected.length} 笔',
          ),
          actions: _selected.isEmpty
              ? null
              : [
                  IconButton(
                    tooltip: '批量修改',
                    onPressed: _busy ? null : _editSelected,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '批量确认安全账单',
                    onPressed: _busy ? null : _confirmSelected,
                    icon: const Icon(Icons.done_all),
                  ),
                  IconButton(
                    tooltip: '批量忽略',
                    onPressed: _busy ? null : _ignoreSelected,
                    icon: const Icon(Icons.visibility_off_outlined),
                  ),
                  IconButton(
                    tooltip: '退出多选',
                    onPressed: () => setState(_selected.clear),
                    icon: const Icon(Icons.close),
                  ),
                ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '待确认'),
              Tab(text: '重复候选'),
              Tab(text: '已忽略'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _pendingList(state),
            _duplicateList(state),
            _ignoredList(),
          ],
        ),
      ),
    );
  }

  Widget _duplicateList(LedgerController state) {
    final groups = _duplicateGroups;
    if (groups == null) return const Center(child: CircularProgressIndicator());
    if (groups.isEmpty) {
      return const EmptyView(
        icon: Icons.rule_folder_outlined,
        title: '没有重复候选',
        description: '检测到可能重复的账单时会显示在这里。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final drafts = state.pendingDrafts
            .where((item) => group.draftIds.contains(item.id))
            .toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.matchedByOrder ? '相同订单号候选' : '相同交易多来源候选',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '${drafts.length} 个待处理采集${group.existingTransactionCount > 0 ? ' · 已有 ${group.existingTransactionCount} 笔正式账单' : ''}',
                ),
                for (final item in drafts.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '• ${_parse(item).merchant.isEmpty ? '待核对账单' : _parse(item).merchant} · ${dateTimeLabel(item.raw.capturedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: () => _reviewDuplicateGroup(group),
                  icon: const Icon(Icons.rule_folder_outlined),
                  label: const Text('成组审核'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pendingList(LedgerController state) {
    if (state.pendingDrafts.isEmpty) {
      return const EmptyView(
        icon: Icons.inbox_outlined,
        title: '没有待确认账单',
        description: '自动识别的账单会先在这里等待核对。',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: state.pendingDrafts.length,
      itemBuilder: (context, index) {
        final item = state.pendingDrafts[index];
        final parsed = _parse(item);
        final selected = _selected.contains(item.id);
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SectionCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              onLongPress: () => _toggle(item.id),
              onTap: _selected.isEmpty ? null : () => _toggle(item.id),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_selected.isNotEmpty) ...[
                      Checkbox(
                        value: selected,
                        onChanged: (_) => _toggle(item.id),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(child: _draftBody(state, item, parsed)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _draftBody(
    LedgerController state,
    PendingDraft item,
    TransactionDraft parsed,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        parsed.merchant.isEmpty ? '待核对账单' : parsed.merchant,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      Text(
        '${parsed.amountMinor == null ? '金额待确认' : visibleMoney(context, parsed.amountMinor!)} · ${dateTimeLabel(parsed.occurredDate)}',
      ),
      const SizedBox(height: 6),
      Text(item.raw.text, maxLines: 3, overflow: TextOverflow.ellipsis),
      if (parsed.warnings.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(parsed.warnings.join('；')),
        ),
      if (_selected.isEmpty) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          children: [
            if (item.familyEventId != null)
              FilledButton.icon(
                onPressed: state.loading
                    ? null
                    : () => showFamilyCardsPage(
                        context,
                        initialEventId: item.familyEventId,
                      ),
                icon: const Icon(Icons.family_restroom_outlined),
                label: const Text('审核亲情卡'),
              )
            else
              FilledButton.icon(
                onPressed:
                    state.loading ||
                        (parsed.blocked &&
                            parsed.type != TransactionType.refund &&
                            item.raw.source != TransactionSource.ocr)
                    ? null
                    : () => parsed.type == TransactionType.refund
                          ? showRefundReview(
                              context,
                              draft: parsed,
                              draftId: item.id,
                            )
                          : parsed.blocked
                          ? showOcrInput(
                              context,
                              item.raw.text,
                              item.raw.capturedAt,
                              initialDraft: parsed,
                              draftId: item.id,
                            )
                          : showTransactionEditor(
                              context,
                              draft: parsed,
                              draftId: item.id,
                            ),
                icon: const Icon(Icons.edit_outlined),
                label: Text(
                  parsed.blocked && item.raw.source == TransactionSource.ocr
                      ? '处理识别问题'
                      : '核对并记账',
                ),
              ),
            TextButton(
              onPressed: state.loading
                  ? null
                  : () async {
                      try {
                        await state.repository.ignoreDraft(
                          item.ledgerId,
                          item.id,
                        );
                        await state.load();
                        await _loadIgnored();
                      } catch (error) {
                        if (mounted) showError(context, error);
                      }
                    },
              child: const Text('忽略'),
            ),
          ],
        ),
      ],
    ],
  );

  Widget _ignoredList() {
    final values = _ignored;
    if (values == null) return const Center(child: CircularProgressIndicator());
    if (values.isEmpty) {
      return const EmptyView(
        icon: Icons.visibility_off_outlined,
        title: '没有已忽略记录',
        description: '忽略的待处理账单可以在这里恢复。',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _clearIgnored,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('清空忽略记录'),
          ),
        ),
        SectionCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < values.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  title: Text(
                    values[i].raw.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(dateTimeLabel(values[i].raw.capturedAt)),
                  trailing: TextButton(
                    onPressed: () => _restoreIgnored(values[i].id),
                    child: const Text('恢复'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BatchDraftEditSheet extends ConsumerStatefulWidget {
  const _BatchDraftEditSheet({required this.currentLedgerId});

  final String currentLedgerId;

  @override
  ConsumerState<_BatchDraftEditSheet> createState() =>
      _BatchDraftEditSheetState();
}

class _BatchDraftEditSheetState extends ConsumerState<_BatchDraftEditSheet> {
  late String _ledgerId = widget.currentLedgerId;
  bool _changeLedger = false;
  bool _changeAccount = false;
  bool _changeCategory = false;
  bool _changeTags = false;
  String? _accountId;
  String? _categoryId;
  List<Account> _accounts = const [];
  List<Category> _categories = const [];
  final _tags = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _tags.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    setState(() => _loading = true);
    try {
      final repository = ref.read(repositoryProvider);
      final values = await Future.wait<Object>([
        repository.accounts(_ledgerId),
        repository.categories(_ledgerId),
      ]);
      if (!mounted) return;
      setState(() {
        _accounts = values[0] as List<Account>;
        _categories = values[1] as List<Category>;
        _accountId = null;
        _categoryId = null;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, error);
      }
    }
  }

  void _submit() {
    if (_changeAccount && _accountId == null) {
      showError(context, const LedgerException('请选择账户'));
      return;
    }
    if (_changeCategory && _categoryId == null) {
      showError(context, const LedgerException('请选择分类'));
      return;
    }
    final patch = PendingDraftBatchPatch(
      targetLedgerId: _changeLedger ? _ledgerId : null,
      accountId: _changeAccount ? _accountId : null,
      categoryId: _changeCategory ? _categoryId : null,
      tags: _changeTags ? parseTagInput(_tags.text) : null,
    );
    if (patch.isEmpty) {
      showError(context, const LedgerException('请至少勾选一项需要修改的内容'));
      return;
    }
    Navigator.pop(context, patch);
  }

  @override
  Widget build(BuildContext context) {
    final ledgers = ref.watch(ledgerProvider).ledgers;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text('批量修改待处理账单', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('仅勾选需要统一覆盖的字段；执行前还会显示逐笔预览和跳过原因。'),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('修改账本'),
              value: _changeLedger,
              onChanged: (value) => setState(() => _changeLedger = value),
            ),
            if (_changeLedger)
              DropdownButtonFormField<String>(
                initialValue: _ledgerId,
                decoration: const InputDecoration(labelText: '目标账本'),
                items: [
                  for (final item in ledgers.entries)
                    DropdownMenuItem(value: item.key, child: Text(item.value)),
                ],
                onChanged: (value) async {
                  if (value == null || value == _ledgerId) return;
                  setState(() => _ledgerId = value);
                  await _loadOptions();
                },
              ),
            if (_changeLedger)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('跨账本修改时，原账户或分类不兼容的账单会跳过；建议同时选择目标账户和分类。'),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('修改账户'),
              value: _changeAccount,
              onChanged: (value) => setState(() => _changeAccount = value),
            ),
            if (_changeAccount)
              DropdownButtonFormField<String>(
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: '统一账户'),
                items: [
                  for (final item in _accounts)
                    DropdownMenuItem(value: item.id, child: Text(item.name)),
                ],
                onChanged: _loading
                    ? null
                    : (value) => setState(() => _accountId = value),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('修改分类'),
              value: _changeCategory,
              onChanged: (value) => setState(() => _changeCategory = value),
            ),
            if (_changeCategory)
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: '统一分类'),
                items: [
                  for (final item in _categories)
                    DropdownMenuItem(
                      value: item.id,
                      child: Text(
                        '${item.type == TransactionType.income ? '收入' : '支出'} · ${item.name}',
                      ),
                    ),
                ],
                onChanged: _loading
                    ? null
                    : (value) => setState(() => _categoryId = value),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('替换标签'),
              subtitle: const Text('留空表示清空所选账单的标签'),
              value: _changeTags,
              onChanged: (value) => setState(() => _changeTags = value),
            ),
            if (_changeTags)
              TextField(
                controller: _tags,
                decoration: const InputDecoration(
                  labelText: '标签',
                  hintText: '逗号或空格分隔，最多10个',
                ),
              ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _loading ? null : _submit,
              icon: const Icon(Icons.preview_outlined),
              label: const Text('预览修改'),
            ),
          ],
        ),
      ),
    );
  }
}
