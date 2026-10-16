import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../data/family_payment_repository.dart';
import '../domain/family_payment.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'action_form.dart';
import 'money_privacy.dart';

Future<void> showFamilyCardsPage(
  BuildContext context, {
  String? initialEventId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => FamilyCardsPage(initialEventId: initialEventId),
  ),
);

/// Opens the same role-aware account editor used by the Accounts page.
/// Event review remains available through [showFamilyCardsPage].
Future<void> showFamilyCardEditor(
  BuildContext context,
  LedgerController state, {
  FamilyCardAccount? card,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _FamilyCardEditor(state: state, card: card),
);

class FamilyCardsPage extends ConsumerStatefulWidget {
  const FamilyCardsPage({super.key, this.initialEventId});
  final String? initialEventId;

  @override
  ConsumerState<FamilyCardsPage> createState() => _FamilyCardsPageState();
}

class _FamilyCardsPageState extends ConsumerState<FamilyCardsPage> {
  bool _loading = true;
  List<FamilyCardAccountSummary> _cards = const [];
  List<FamilyPaymentEvent> _events = const [];
  bool _openedInitialEvent = false;

  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final repo = FamilyPaymentRepository(state.repository.db);
    try {
      final cards = await repo.cards(state.ledgerId, month: state.month);
      final events = await repo.events(state.ledgerId);
      if (mounted) {
        setState(() {
          _cards = cards;
          _events = events;
        });
      }
      if (!_openedInitialEvent && widget.initialEventId != null && mounted) {
        _openedInitialEvent = true;
        final target = events
            .where((item) => item.id == widget.initialEventId)
            .firstOrNull;
        if (target != null) {
          await _reviewEvent(target);
        }
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _edit([FamilyCardAccount? card]) async {
    final state = ref.read(ledgerProvider);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FamilyCardEditor(state: state, card: card),
    );
    if (mounted) await _load();
  }

  Future<void> _archive(FamilyCardAccount card) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('归档亲情卡账户？'),
        content: Text('${card.displayName} 的历史额度与消费记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final state = ref.read(ledgerProvider);
    try {
      await FamilyPaymentRepository(
        state.repository.db,
      ).archiveCard(state.ledgerId, card.id);
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _reviewEvent(FamilyPaymentEvent event) async {
    final state = ref.read(ledgerProvider);
    final mergeCandidates = _events
        .where(
          (item) =>
              item.id != event.id &&
              item.platform == event.platform &&
              (item.status == FamilyPaymentStatus.needsReview ||
                  item.status == FamilyPaymentStatus.observed) &&
              item.transactionId == null,
        )
        .toList();
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FamilyEventReviewDialog(
        state: state,
        event: event,
        cards: _cards
            .map((item) => item.card)
            .where((card) => card.platform == event.platform)
            .toList(),
        mergeCandidates: mergeCandidates,
      ),
    );
    if (changed == true && mounted) {
      await state.load();
      await _load();
    }
  }

  Future<void> _refundEvent(FamilyPaymentEvent event) async {
    final state = ref.read(ledgerProvider);
    final remaining = event.netAmountMinor;
    await actionForm(
      context,
      title: '记录亲情卡退款',
      description:
          '可退金额上限 ${visibleMoney(context, remaining)}。若为发送方已入账支出，将同步生成退款流水并恢复账户余额与月度额度。',
      fields: [
        InputSpec(
          'amount',
          '退款金额',
          numeric: true,
          initial: (remaining / 100).toStringAsFixed(2),
        ),
        const InputSpec('note', '退款说明（选填）'),
      ],
      submit: (values) async {
        final minor = parseMoney(values['amount'] ?? '');
        await FamilyPaymentRepository(state.repository.db).applyRefund(
          ledgerId: state.ledgerId,
          eventId: event.id,
          refundMinor: minor,
          note: values['note'] ?? '',
        );
        await state.load();
        await _load();
      },
    );
  }

  Future<void> _voidEvent(FamilyPaymentEvent event) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销亲情卡交易？'),
        content: const Text('撤销后不再计入亲情卡已用额度；若已生成发送方扣款流水，将一并移入回收站。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final state = ref.read(ledgerProvider);
    try {
      await FamilyPaymentRepository(
        state.repository.db,
      ).voidEvent(ledgerId: state.ledgerId, eventId: event.id);
      await state.load();
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingEvents = _events
        .where(
          (item) =>
              item.status == FamilyPaymentStatus.needsReview ||
              item.status == FamilyPaymentStatus.observed ||
              (item.cardId == null &&
                  item.status != FamilyPaymentStatus.voided),
        )
        .toList();
    final processedEvents = _events
        .where((item) => !pendingEvents.contains(item))
        .toList();
    final cardNames = {
      for (final summary in _cards) summary.card.id: summary.card.displayName,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('亲情卡账户')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('新增亲情卡'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
              children: [
                Card(
                  color: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer.withValues(alpha: .45),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      '亲情卡是代付关系和月度额度，不是真实资产余额。发送方绑定真实扣款账户；使用方只记录消费额度，不扣减本人的账户。',
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (_cards.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Column(
                      children: [
                        Icon(Icons.family_restroom_outlined, size: 48),
                        SizedBox(height: 12),
                        Text('还没有亲情卡账户'),
                        SizedBox(height: 4),
                        Text('新增后可分别管理发送方与使用方额度'),
                      ],
                    ),
                  )
                else
                  for (final summary in _cards)
                    _FamilyCardTile(
                      summary: summary,
                      onEdit: () => _edit(summary.card),
                      onArchive: () => _archive(summary.card),
                    ),
                if (pendingEvents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Text(
                      '待审核交易 · ${pendingEvents.length}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final event in pendingEvents)
                    _FamilyEventTile(
                      event: event,
                      cardName: event.cardId == null
                          ? null
                          : cardNames[event.cardId!],
                      onReview: () => _reviewEvent(event),
                      onRefund: event.netAmountMinor > 0
                          ? () => _refundEvent(event)
                          : null,
                      onVoid: () => _voidEvent(event),
                    ),
                ],
                if (processedEvents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Text(
                      '历史亲情卡记录 · ${processedEvents.length}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final event in processedEvents)
                    _FamilyEventTile(
                      event: event,
                      cardName: event.cardId == null
                          ? null
                          : cardNames[event.cardId!],
                      onReview: event.status == FamilyPaymentStatus.voided
                          ? null
                          : () => _reviewEvent(event),
                      onRefund:
                          event.status != FamilyPaymentStatus.voided &&
                              event.netAmountMinor > 0
                          ? () => _refundEvent(event)
                          : null,
                      onVoid: event.status == FamilyPaymentStatus.voided
                          ? null
                          : () => _voidEvent(event),
                    ),
                ],
              ],
            ),
    );
  }
}

class _FamilyCardTile extends StatelessWidget {
  const _FamilyCardTile({
    required this.summary,
    required this.onEdit,
    required this.onArchive,
  });

  final FamilyCardAccountSummary summary;
  final VoidCallback onEdit;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final card = summary.card;
    final limit = card.activeLimitMinor;
    final progress = limit <= 0
        ? 0.0
        : (summary.usedMinor / limit).clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  child: Icon(
                    card.platform == FamilyCardPlatform.wechat
                        ? Icons.chat_bubble_outline
                        : Icons.account_balance_wallet_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${card.platform.label} · ${card.localRole.label}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) =>
                      value == 'edit' ? onEdit() : onArchive(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑额度与绑定')),
                    PopupMenuItem(value: 'archive', child: Text('归档账户')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '本月已用 ${visibleMoney(context, summary.usedMinor)}',
                  ),
                ),
                Text(
                  limit == 0
                      ? '未设置额度'
                      : '可用 ${visibleMoney(context, summary.availableMinor)}',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '发送方额度 ${visibleMoney(context, card.senderLimitMinor)} · 使用方额度 ${visibleMoney(context, card.userLimitMinor)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (summary.pendingCount > 0)
                  Text(
                    '待确认 ${summary.pendingCount}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (summary.unassignedPendingCount > 0) ...[
                  if (summary.pendingCount > 0) const SizedBox(width: 8),
                  Text(
                    '待归属 ${summary.unassignedPendingCount}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FamilyEventTile extends StatelessWidget {
  const _FamilyEventTile({
    required this.event,
    required this.cardName,
    this.onReview,
    this.onRefund,
    this.onVoid,
  });

  final FamilyPaymentEvent event;
  final String? cardName;
  final VoidCallback? onReview;
  final VoidCallback? onRefund;
  final VoidCallback? onVoid;

  @override
  Widget build(BuildContext context) {
    final title = event.merchant.isEmpty
        ? event.platform.label
        : event.merchant;
    final roleLabel = event.localRole?.label ?? '角色待确认';
    final cardLabel = cardName ?? '未归属卡片';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  visibleMoney(context, event.netAmountMinor),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${event.platform.label} · $cardLabel · $roleLabel · ${event.status.label}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (event.refundedMinor > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '原金额 ${visibleMoney(context, event.amountMinor)} · 已退 ${visibleMoney(context, event.refundedMinor)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (event.evidence.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '证据来源 (${event.evidence.length})：${event.evidence.map((e) => e.sourceKind).toSet().join(' / ')} · 可信度${event.confidenceLabel}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (event.hasConflict)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  event.conflictMessages.join('；'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (onReview != null)
                  FilledButton.tonal(
                    onPressed: onReview,
                    child: Text(
                      event.status == FamilyPaymentStatus.needsReview ||
                              event.status == FamilyPaymentStatus.observed
                          ? '审核并确认'
                          : '查看详情',
                    ),
                  ),
                if (onRefund != null)
                  TextButton(onPressed: onRefund, child: const Text('退款')),
                if (onVoid != null)
                  TextButton(onPressed: onVoid, child: const Text('撤销')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FamilyEventReviewDialog extends StatefulWidget {
  const _FamilyEventReviewDialog({
    required this.state,
    required this.event,
    required this.cards,
    required this.mergeCandidates,
  });

  final LedgerController state;
  final FamilyPaymentEvent event;
  final List<FamilyCardAccount> cards;
  final List<FamilyPaymentEvent> mergeCandidates;

  @override
  State<_FamilyEventReviewDialog> createState() =>
      _FamilyEventReviewDialogState();
}

class _FamilyEventReviewDialogState extends State<_FamilyEventReviewDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  String? _cardId;
  late FamilyLocalRole _role;
  String? _fundingAccountId;
  String? _categoryId;
  String? _mergeSourceId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final ev = widget.event;
    _cardId = ev.cardId;
    final matchedCard = widget.cards.where((c) => c.id == _cardId).firstOrNull;
    _role =
        ev.localRole ?? matchedCard?.localRole ?? FamilyLocalRole.beneficiary;
    _fundingAccountId =
        ev.fundingAccountId ?? matchedCard?.defaultFundingAccountId;
    _categoryId =
        matchedCard?.defaultCategoryId ??
        widget.state.categories
            .where((c) => c.type == TransactionType.expense)
            .firstOrNull
            ?.id;
    _amount = TextEditingController(
      text: (ev.amountMinor / 100).toStringAsFixed(2),
    );
    _merchant = TextEditingController(text: ev.merchant);
    final suggestedTarget = ev.candidateMergeEventId;
    if (suggestedTarget != null &&
        widget.mergeCandidates.any((c) => c.id == suggestedTarget)) {
      _mergeSourceId = suggestedTarget;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = FamilyPaymentRepository(widget.state.repository.db);
      if (_mergeSourceId != null) {
        await repo.mergeEvents(
          ledgerId: widget.state.ledgerId,
          targetEventId: widget.event.id,
          sourceEventId: _mergeSourceId!,
        );
      }
      if (_cardId != null && _cardId != widget.event.cardId) {
        await repo.assignCard(
          ledgerId: widget.state.ledgerId,
          eventId: widget.event.id,
          cardId: _cardId!,
        );
      }
      await repo.confirmFamilyEvent(
        ledgerId: widget.state.ledgerId,
        eventId: widget.event.id,
        localRole: _role,
        cardId: _cardId,
        fundingAccountId: _role == FamilyLocalRole.payer
            ? _fundingAccountId
            : null,
        categoryId: _role == FamilyLocalRole.payer ? _categoryId : null,
        amountMinor: parseMoney(_amount.text),
        merchant: _merchant.text,
        allowConflict: true,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is LedgerException ? error.message : '操作失败，请核对后重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('审核亲情卡交易'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.event.platform.label} · 证据 ${widget.event.evidence.length} 条',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final ev in widget.event.evidence)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${ev.sourceKind} (${ev.sourcePackage}) ${ev.amountMinor == null ? '' : visibleMoney(context, ev.amountMinor!)} ${ev.redactedExcerpt}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _cardId,
                  decoration: const InputDecoration(labelText: '归属亲情卡'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('暂不绑定卡片')),
                    for (final card in widget.cards)
                      DropdownMenuItem(
                        value: card.id,
                        child: Text(card.displayName),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          final selected = widget.cards
                              .where((c) => c.id == value)
                              .firstOrNull;
                          setState(() {
                            _cardId = value;
                            if (selected != null) {
                              _role = selected.localRole;
                              _fundingAccountId ??=
                                  selected.defaultFundingAccountId;
                              _categoryId ??= selected.defaultCategoryId;
                            }
                          });
                        },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<FamilyLocalRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: '本机资金承担角色'),
                  items: [
                    for (final role in FamilyLocalRole.values)
                      DropdownMenuItem(value: role, child: Text(role.label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _role = value!),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '确认金额',
                    prefixText: '¥ ',
                  ),
                  validator: (value) {
                    try {
                      parseMoney(value ?? '');
                      return null;
                    } catch (e) {
                      return e.toString();
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _merchant,
                  decoration: const InputDecoration(labelText: '商户名称'),
                ),
                if (_role == FamilyLocalRole.payer) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _fundingAccountId,
                    decoration: const InputDecoration(labelText: '真实扣款账户'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('请选择扣款账户'),
                      ),
                      for (final account in widget.state.accounts)
                        DropdownMenuItem(
                          value: account.id,
                          child: Text(account.displayName),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _fundingAccountId = value),
                    validator: (value) =>
                        _role == FamilyLocalRole.payer && value == null
                        ? '发送方必须选择真实扣款账户'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: '支出分类'),
                    items: [
                      for (final cat in widget.state.categories.where(
                        (c) => c.type == TransactionType.expense,
                      ))
                        DropdownMenuItem(value: cat.id, child: Text(cat.name)),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _categoryId = value),
                  ),
                ],
                if (widget.mergeCandidates.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _mergeSourceId,
                    decoration: const InputDecoration(
                      labelText: '合并同平台待审事件（选填）',
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('不合并')),
                      for (final cand in widget.mergeCandidates)
                        DropdownMenuItem(
                          value: cand.id,
                          child: Text(
                            '${cand.merchant.isEmpty ? cand.platform.label : cand.merchant} · ${visibleMoney(context, cand.amountMinor)}',
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _mergeSourceId = value),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: Text(_busy ? '处理中…' : '确认'),
        ),
      ],
    ),
  );
}

class _FamilyCardEditor extends StatefulWidget {
  const _FamilyCardEditor({required this.state, this.card});
  final LedgerController state;
  final FamilyCardAccount? card;

  @override
  State<_FamilyCardEditor> createState() => _FamilyCardEditorState();
}

class _FamilyCardEditorState extends State<_FamilyCardEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _payer;
  late final TextEditingController _beneficiary;
  late final TextEditingController _limit;
  late FamilyCardPlatform _platform;
  late FamilyLocalRole _role;
  String? _accountId;
  String? _categoryId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final card = widget.card;
    _platform = card?.platform ?? FamilyCardPlatform.wechat;
    _role = card?.localRole ?? FamilyLocalRole.beneficiary;
    _name = TextEditingController(text: card?.displayName ?? '');
    _payer = TextEditingController(text: card?.payerLabel ?? '');
    _beneficiary = TextEditingController(text: card?.beneficiaryLabel ?? '');
    _limit = TextEditingController(
      text: ((card?.activeLimitMinor ?? 0) / 100).toStringAsFixed(2),
    );
    _accountId = card?.defaultFundingAccountId;
    _categoryId = card?.defaultCategoryId;
  }

  @override
  void dispose() {
    _name.dispose();
    _payer.dispose();
    _beneficiary.dispose();
    _limit.dispose();
    super.dispose();
  }

  int _parseLimit(TextEditingController controller) {
    final value = controller.text.trim();
    if (value.isEmpty || RegExp(r'^0(?:\.0{1,2})?$').hasMatch(value)) return 0;
    return parseMoney(value);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FamilyPaymentRepository(widget.state.repository.db).saveCard(
        id: widget.card?.id,
        ledgerId: widget.state.ledgerId,
        platform: _platform,
        displayName: _name.text,
        localRole: _role,
        payerLabel: _payer.text,
        beneficiaryLabel: _beneficiary.text,
        senderLimitMinor: _role == FamilyLocalRole.payer
            ? _parseLimit(_limit)
            : 0,
        userLimitMinor: _role == FamilyLocalRole.beneficiary
            ? _parseLimit(_limit)
            : 0,
        defaultFundingAccountId: _role == FamilyLocalRole.payer
            ? _accountId
            : null,
        defaultCategoryId: _categoryId,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is LedgerException ? error.message : '保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.card == null ? '新增亲情卡账户' : '编辑亲情卡账户'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<FamilyCardPlatform>(
                  initialValue: _platform,
                  decoration: const InputDecoration(labelText: '平台'),
                  items: [
                    for (final value in FamilyCardPlatform.values)
                      DropdownMenuItem(value: value, child: Text(value.label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _platform = value!),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '亲情卡账户名称'),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入账户名称' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<FamilyLocalRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: '我在这张卡中的角色'),
                  items: [
                    for (final value in FamilyLocalRole.values)
                      DropdownMenuItem(value: value, child: Text(value.label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _role = value!),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _payer,
                  decoration: const InputDecoration(labelText: '发送方称呼（选填）'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _beneficiary,
                  decoration: const InputDecoration(labelText: '使用方称呼（选填）'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: ValueKey('family_limit_${_role.name}'),
                  controller: _limit,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _role == FamilyLocalRole.payer
                        ? '发送方月度额度'
                        : '使用方月度额度',
                    prefixText: '¥ ',
                  ),
                ),
                if (_role == FamilyLocalRole.payer) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: _accountId,
                    decoration: const InputDecoration(labelText: '真实扣款账户（选填）'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('每次确认')),
                      for (final account in widget.state.accounts)
                        DropdownMenuItem(
                          value: account.id,
                          child: Text(account.displayName),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _accountId = value),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _categoryId,
                  decoration: const InputDecoration(labelText: '默认支出分类（选填）'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('每次确认')),
                    for (final category in widget.state.categories.where(
                      (item) => item.type == TransactionType.expense,
                    ))
                      DropdownMenuItem(
                        value: category.id,
                        child: Text(category.name),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _categoryId = value),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
