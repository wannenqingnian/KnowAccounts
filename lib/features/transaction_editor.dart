import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tags.dart';
import '../domain/attachment.dart';
import 'attachment_panel.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/transaction_pipeline.dart';
import 'date_time_picker.dart';

Future<void> showTransactionEditor(
  BuildContext context, {
  LedgerEntry? entry,
  LedgerEntry? refundOf,
  bool reimbursement = false,
  TransactionDraft? draft,
  TransactionTemplate? template,
  Account? repaymentTo,
  String? draftId,
  VoidCallback? onSwitchToSmart,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  builder: (_) => TransactionEditor(
    entry: entry,
    refundOf: refundOf,
    reimbursement: reimbursement,
    draft: draft,
    template: template,
    repaymentTo: repaymentTo,
    draftId: draftId,
    onSwitchToSmart: onSwitchToSmart,
  ),
);

class TransactionEditor extends ConsumerStatefulWidget {
  const TransactionEditor({
    super.key,
    this.entry,
    this.refundOf,
    this.reimbursement = false,
    this.draft,
    this.template,
    this.repaymentTo,
    this.draftId,
    this.onSwitchToSmart,
  });
  final LedgerEntry? entry;
  final LedgerEntry? refundOf;
  final bool reimbursement;
  final TransactionDraft? draft;
  final TransactionTemplate? template;
  final Account? repaymentTo;
  final String? draftId;
  final VoidCallback? onSwitchToSmart;
  @override
  ConsumerState<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends ConsumerState<TransactionEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _note;
  late final TextEditingController _tags;
  late TransactionType _type;
  late DateTime _date;
  String? _account;
  String? _target;
  String? _category;
  bool _reimbursable = false;
  late bool _isReimbursement;
  List<ImageAttachment> _attachments = [];
  bool _attachmentsReady = true;
  String? _attachmentLedger;
  bool _saving = false;
  bool _archivedSelection = false;
  String? _error;
  String? _correctionHint;
  int _correctionRequest = 0;

  @override
  void initState() {
    super.initState();
    final state = ref.read(ledgerProvider);
    final entry = widget.entry;
    final original = widget.refundOf;
    final draft = widget.draft;
    final template = widget.template;
    _isReimbursement =
        widget.reimbursement || (entry?.isReimbursement ?? false);
    _type = original != null
        ? TransactionType.refund
        : entry?.type ??
              draft?.type ??
              template?.type ??
              TransactionType.expense;
    final initialAccountId =
        entry?.accountId ??
        original?.accountId ??
        template?.accountId ??
        draft?.accountId;
    final initialAccount = state.allAccounts
        .where((account) => account.id == initialAccountId)
        .firstOrNull;
    String amountText(int minor, {int? decimals}) => currencyMoney(
      minor,
      symbol: '',
      decimals: decimals ?? 2,
      showSymbol: false,
    );
    final refundBase = original == null
        ? null
        : (_isReimbursement
              ? original.reimbursementRemaining
              : original.amountMinor -
                    original.refundedMinor -
                    original.reimbursedMinor);
    final refundLocal = original == null
        ? null
        : original.currency == 'CNY'
        ? refundBase
        : (refundBase! * 1000000 + original.exchangeRateMicros ~/ 2) ~/
              original.exchangeRateMicros;
    _amount = TextEditingController(
      text: entry != null
          ? amountText(
              entry.displayAmountMinor,
              decimals: initialAccount?.currencyDecimals ?? 2,
            )
          : original != null
          ? amountText(
              refundLocal!,
              decimals: initialAccount?.currencyDecimals ?? 2,
            )
          : draft?.amountMinor != null
          ? amountText(draft!.amountMinor!)
          : template != null && template.amountMinor > 0
          ? amountText(
              template.amountMinor,
              decimals: initialAccount?.currencyDecimals ?? 2,
            )
          : '',
    );
    _merchant = TextEditingController(
      text:
          entry?.merchant ??
          original?.merchant ??
          draft?.merchant ??
          template?.merchant ??
          '',
    );
    _note = TextEditingController(text: entry?.note ?? template?.note ?? '');
    _tags = TextEditingController(
      text:
          entry?.tags.join('，') ??
          draft?.tags.join('，') ??
          template?.tags.join('，') ??
          '',
    );
    _date = entry?.occurredDate ?? draft?.occurredDate ?? DateTime.now();
    _attachmentLedger = state.ledgerId;
    if (entry != null) {
      _attachmentsReady = false;
      _loadAttachments();
    }
    _account =
        entry?.accountId ??
        original?.accountId ??
        template?.accountId ??
        (draft == null ? state.accounts.firstOrNull?.id : draft.accountId);
    _target =
        entry?.targetAccountId ??
        template?.targetAccountId ??
        state.accounts.where((a) => a.id != _account).firstOrNull?.id;
    _category =
        entry?.categoryId ??
        template?.categoryId ??
        (draft == null
            ? state.categories.where((c) => c.type == _type).firstOrNull?.id
            : draft.categoryId);
    _reimbursable = entry?.reimbursable ?? false;
    if (widget.repaymentTo != null) {
      _type = TransactionType.transfer;
      _target = widget.repaymentTo!.id;
      _account = state.accounts
          .where((a) => !a.kind.isDebt && a.id != _target)
          .firstOrNull
          ?.id;
      _category = null;
      _note.text = '本金还款';
    }
    if (_account != null && !state.accounts.any((a) => a.id == _account)) {
      _account = null;
      _archivedSelection = true;
    }
    if (_target != null && !state.accounts.any((a) => a.id == _target)) {
      _target = null;
      _archivedSelection = true;
    }
    if (_category != null && !state.categories.any((c) => c.id == _category)) {
      _category = null;
      _archivedSelection = true;
    }
  }

  Future<void> _loadAttachments() async {
    try {
      final images = await ref
          .read(ledgerProvider)
          .repository
          .attachments(_attachmentLedger!, widget.entry!.id);
      if (mounted) {
        setState(() {
          _attachments = images;
          _attachmentsReady = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '附件读取失败，请关闭后重试，原附件不会被覆盖。';
        });
      }
    }
  }

  Future<void> _autoCorrectMerchant(String value) async {
    final request = ++_correctionRequest;
    if (widget.entry != null ||
        !const [
          TransactionType.expense,
          TransactionType.income,
        ].contains(_type)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || request != _correctionRequest) return;
    final state = ref.read(ledgerProvider);
    final draft = TransactionDraft(
      raw: RawTransaction(text: value, capturedAt: DateTime.now()),
      ledgerId: state.ledgerId,
      type: _type,
      occurredDate: _date,
      accountId: _account,
      categoryId: _category,
      merchant: value,
      warnings: const [],
      evidence: const {},
    );
    try {
      final corrected = await state.repository.applyAutoCorrectionRule(
        draft,
        rules: state.autoCorrectionRules,
      );
      if (!mounted || request != _correctionRequest) return;
      final hint = corrected.evidence['auto_correction'];
      if (hint == null) {
        setState(() => _correctionHint = null);
        return;
      }
      setState(() {
        _account = corrected.accountId;
        _category = corrected.categoryId;
        _tags.text = corrected.tags.join('，');
        _correctionHint = hint;
      });
    } catch (_) {
      // A stale or archived rule must never block manual entry.
    }
  }

  bool get _canSwitchLedger =>
      widget.entry == null &&
      widget.refundOf == null &&
      widget.draft == null &&
      widget.template == null &&
      widget.repaymentTo == null;

  Future<void> _selectLedger(String? id) async {
    if (!_canSwitchLedger || id == null || id == _attachmentLedger) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(ledgerProvider).selectLedger(id);
      if (!mounted) return;
      final state = ref.read(ledgerProvider);
      setState(() {
        _attachmentLedger = id;
        _account = state.accounts.firstOrNull?.id;
        _target = state.accounts.where((a) => a.id != _account).firstOrNull?.id;
        _category = state.categories
            .where((c) => c.type == _type)
            .firstOrNull
            ?.id;
        _archivedSelection = false;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is LedgerException ? e.message : '账本切换失败，请重试';
      });
    }
  }

  void _setType(TransactionType value) {
    final state = ref.read(ledgerProvider);
    setState(() {
      _type = value;
      _category = state.categories
          .where((c) => c.type == value)
          .firstOrNull
          ?.id;
      if (value == TransactionType.transfer) {
        _target = state.accounts.where((a) => a.id != _account).firstOrNull?.id;
      }
    });
  }

  IconData _categoryIcon(Category category) {
    final value = '${category.iconKey}${category.name}';
    if (value.contains(RegExp('餐|吃|饮|食'))) return Icons.restaurant;
    if (value.contains(RegExp('交通|车|出行'))) return Icons.directions_car;
    if (value.contains(RegExp('购物|百货'))) return Icons.shopping_bag;
    if (value.contains(RegExp('果|菜|生鲜'))) return Icons.eco;
    if (value.contains(RegExp('居家|住房|物业'))) return Icons.home;
    if (value.contains(RegExp('娱乐|游戏'))) return Icons.sports_esports;
    if (value.contains(RegExp('医疗|健康'))) return Icons.favorite;
    if (value.contains(RegExp('学习|教育'))) return Icons.school;
    if (value.contains(RegExp('人情|礼物'))) return Icons.card_giftcard;
    if (value.contains(RegExp('工资|收入'))) return Icons.payments;
    return Icons.category;
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_attachmentsReady || !_form.currentState!.validate()) return;
    final missingSelections = [
      if (_account == null) '请选择账户',
      if ((_type == TransactionType.expense ||
              _type == TransactionType.income) &&
          _category == null)
        '请选择分类',
    ];
    if (missingSelections.isNotEmpty) {
      setState(() => _error = missingSelections.join('；'));
      return;
    }
    if (ref.read(ledgerProvider).ledgerId != _attachmentLedger) {
      setState(() => _error = "账本已变化，请重新打开记账表单");
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final input = TransactionInput(
      type: _type,
      amountMinor: parseMinorUnits(
        _amount.text,
        ref
                .read(ledgerProvider)
                .accounts
                .where((account) => account.id == _account)
                .firstOrNull
                ?.currencyDecimals ??
            2,
      ),
      accountId: _account!,
      targetAccountId: _type == TransactionType.transfer ? _target : null,
      categoryId: _category,
      occurredDate: _date,
      merchant: _merchant.text,
      note: _note.text,
      tags: parseTagInput(_tags.text),
      reimbursable: _reimbursable,
      isReimbursement: _isReimbursement,
      relatedTransactionId:
          widget.refundOf?.id ??
          widget.entry?.relatedTransactionId ??
          widget.draft?.relatedTransactionId,
    );
    try {
      if (widget.draft != null &&
          (widget.draft!.blocked ||
              ref.read(ledgerProvider).ledgerId != widget.draft!.ledgerId)) {
        throw const LedgerException('账本已变化或草稿不支持保存，请重新解析');
      }
      await ref
          .read(ledgerProvider)
          .save(
            input,
            id: widget.entry?.id,
            draftId: widget.draftId,
            attachments: _attachments,
          );
      if (mounted) Navigator.pop(context);
    } on PossibleDuplicateTransactionException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('疑似重复账单'),
          content: Text('${e.assessment.message}\n\n是否仍然保存为另一笔账单？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('仍然保存'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      setState(() => _saving = true);
      try {
        await ref
            .read(ledgerProvider)
            .save(
              input,
              id: widget.entry?.id,
              draftId: widget.draftId,
              attachments: _attachments,
              allowPossibleDuplicate: true,
            );
        if (mounted) Navigator.pop(context);
      } catch (retryError) {
        if (mounted) {
          setState(() {
            _saving = false;
            _error = retryError is LedgerException
                ? retryError.message
                : '保存失败，请重试';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is LedgerException ? e.message : '保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final categories = state.categories.where((c) => c.type == _type).toList();
    final refund = _type == TransactionType.refund;
    final selectedAccount = state.accounts
        .where((account) => account.id == _account)
        .firstOrNull;
    final targetAccount = state.accounts
        .where((account) => account.id == _target)
        .firstOrNull;
    final colors = Theme.of(context).colorScheme;
    final primary = colors.primary;
    final ink = colors.onSurface;
    final muted = colors.onSurfaceVariant;
    final soft = colors.surfaceContainerHighest;
    final roots = categories
        .where(
          (category) =>
              category.parentId == null ||
              !categories.any((parent) => parent.id == category.parentId),
        )
        .toList();
    final selectedCategory = categories
        .where((category) => category.id == _category)
        .firstOrNull;
    final selectedRoot = selectedCategory?.parentId == null
        ? selectedCategory
        : categories
              .where((category) => category.id == selectedCategory?.parentId)
              .firstOrNull;
    final children = selectedRoot == null
        ? <Category>[]
        : categories
              .where((category) => category.parentId == selectedRoot.id)
              .toList();
    final visibleRoots = roots.take(9).toList();

    Future<void> pickAccount() async {
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('选择账户'),
          children: state.accounts
              .map(
                (account) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, account.id),
                  child: Text(account.displayName),
                ),
              )
              .toList(),
        ),
      );
      if (!mounted || value == null || value == _account) return;
      final oldCurrency = selectedAccount?.currency;
      final nextCurrency = state.accounts
          .where((account) => account.id == value)
          .firstOrNull
          ?.currency;
      setState(() {
        _account = value;
        _error = null;
        if (oldCurrency != null &&
            nextCurrency != null &&
            oldCurrency != nextCurrency) {
          _amount.clear();
        }
      });
    }

    Future<void> pickCategory() async {
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('全部分类'),
          children: categories.map((category) {
            final parent = state.categories
                .where((item) => item.id == category.parentId)
                .firstOrNull;
            return SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, category.id),
              child: Text(
                parent == null
                    ? category.name
                    : '${parent.name} / ${category.name}',
              ),
            );
          }).toList(),
        ),
      );
      if (!mounted || value == null) return;
      setState(() {
        _category = value;
        _error = null;
      });
    }

    Widget typeTab(TransactionType value, String label) {
      final selected = _type == value;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _saving ? null : () => _setType(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: selected
                  ? colors.surfaceContainerLowest
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: .08),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected ? primary : muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    Widget categoryTile(Category category) {
      final selected = selectedRoot?.id == category.id;
      return InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _saving ? null : () => setState(() => _category = category.id),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: selected ? primary : soft,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                _categoryIcon(category),
                color: selected ? colors.onPrimary : muted,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              category.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? primary : muted,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    final title = refund
        ? (_isReimbursement ? '记录报销到账' : '关联退款')
        : widget.entry == null
        ? '记一笔'
        : '编辑账目';
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .92,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Form(
            key: _form,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      if (!refund && widget.repaymentTo == null)
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: soft,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              children: [
                                typeTab(TransactionType.expense, '支出'),
                                typeTab(TransactionType.income, '收入'),
                                typeTab(TransactionType.transfer, '转账'),
                              ],
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      TextButton(
                        onPressed: _saving || widget.onSwitchToSmart == null
                            ? null
                            : () {
                                final callback = widget.onSwitchToSmart!;
                                Navigator.pop(context);
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => callback(),
                                );
                              },
                        child: const Text('AI速记'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      16,
                      20,
                      24 + MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.menu_book_outlined,
                              size: 18,
                              color: primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '记入账本',
                              style: TextStyle(
                                color: muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value:
                                    state.ledgers.containsKey(_attachmentLedger)
                                    ? _attachmentLedger
                                    : state.ledgerId,
                                borderRadius: BorderRadius.circular(16),
                                icon: const Icon(Icons.expand_more, size: 18),
                                style: TextStyle(
                                  color: ink,
                                  fontWeight: FontWeight.w700,
                                ),
                                items: state.ledgers.entries
                                    .map(
                                      (entry) => DropdownMenuItem(
                                        value: entry.key,
                                        child: Text(entry.value),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _canSwitchLedger && !_saving
                                    ? _selectLedger
                                    : null,
                              ),
                            ),
                          ],
                        ),
                        if (_archivedSelection)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('关联账户或分类已归档，请重新选择可用项。'),
                          ),
                        if (widget.repaymentTo != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '向 ${widget.repaymentTo!.name} 还本金，按转账记账，不重复计算支出。',
                            ),
                          ),
                        if (widget.draft != null) ...[
                          const SizedBox(height: 8),
                          const Text('请核对识别结果，保存后才会计入账本。'),
                          if (widget.draft!.warnings.isNotEmpty)
                            Text(
                              widget.draft!.warnings.join('；'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                        if (!refund && _type != TransactionType.transfer) ...[
                          const SizedBox(height: 12),
                          GridView.count(
                            crossAxisCount: 5,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            childAspectRatio: .82,
                            children: [
                              ...visibleRoots.map(categoryTile),
                              InkWell(
                                key: const ValueKey(
                                  'transaction_all_categories',
                                ),
                                borderRadius: BorderRadius.circular(18),
                                onTap: _saving ? null : pickCategory,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: soft,
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(18),
                                        ),
                                      ),
                                      child: SizedBox(
                                        width: 54,
                                        height: 54,
                                        child: Icon(Icons.tune, color: muted),
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    const Text(
                                      '全部分类',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (children.isNotEmpty) ...[
                            const Divider(height: 18),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(top: 7),
                                  child: Text(
                                    '二级子类：',
                                    style: TextStyle(
                                      color: muted,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: children
                                        .map(
                                          (category) => ChoiceChip(
                                            label: Text(category.name),
                                            selected: _category == category.id,
                                            selectedColor: primary,
                                            labelStyle: TextStyle(
                                              color: _category == category.id
                                                  ? colors.onPrimary
                                                  : muted,
                                            ),
                                            onSelected: _saving
                                                ? null
                                                : (_) => setState(
                                                    () =>
                                                        _category = category.id,
                                                  ),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (selectedCategory == null)
                            Text(
                              '请选择分类',
                              style: TextStyle(color: colors.error),
                            ),
                        ],
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLowest,
                            border: Border.all(color: colors.outlineVariant),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            children: [
                              TextFormField(
                                key: const ValueKey('transaction_amount'),
                                controller: _amount,
                                enabled: !_saving,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9.]'),
                                  ),
                                ],
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                  color: primary,
                                  fontSize: 36,
                                  fontWeight: FontWeight.w800,
                                ),
                                decoration: InputDecoration(
                                  labelText: '金额',
                                  prefixText:
                                      '${selectedAccount?.currencySymbol ?? '¥'} ',
                                  suffixText:
                                      selectedAccount?.currency ?? 'CNY',
                                  hintText:
                                      (selectedAccount?.currencyDecimals ??
                                              2) ==
                                          0
                                      ? '0'
                                      : '0.${List.filled(selectedAccount?.currencyDecimals ?? 2, '0').join()}',
                                  border: InputBorder.none,
                                ),
                                validator: (value) {
                                  try {
                                    parseMinorUnits(
                                      value ?? '',
                                      selectedAccount?.currencyDecimals ?? 2,
                                    );
                                    return null;
                                  } catch (e) {
                                    return e.toString();
                                  }
                                },
                              ),
                              const Divider(height: 1),
                              TextFormField(
                                controller: _merchant,
                                enabled: !_saving,
                                maxLength: 100,
                                onChanged: _autoCorrectMerchant,
                                decoration: InputDecoration(
                                  icon: Icon(Icons.edit_note, color: primary),
                                  hintText: '商户或说明（选填）',
                                  counterText: '',
                                  helperText: _correctionHint,
                                  border: InputBorder.none,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    ActionChip(
                                      key: const ValueKey(
                                        'transaction_account_chip',
                                      ),
                                      avatar: const Icon(
                                        Icons.account_balance_wallet_outlined,
                                        size: 17,
                                      ),
                                      label: Text(
                                        selectedAccount?.displayName ?? '请选择账户',
                                      ),
                                      onPressed: _saving ? null : pickAccount,
                                    ),
                                    ActionChip(
                                      avatar: const Icon(
                                        Icons.calendar_today_outlined,
                                        size: 17,
                                      ),
                                      label: Text(dateTimeLabel(_date)),
                                      onPressed: _saving
                                          ? null
                                          : () async {
                                              final date =
                                                  await showSecondDateTimePicker(
                                                    context,
                                                    initial: _date,
                                                  );
                                              if (date != null && mounted) {
                                                setState(() => _date = date);
                                              }
                                            },
                                    ),
                                    if (_reimbursable)
                                      const Chip(label: Text('可报销')),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          childrenPadding: const EdgeInsets.only(bottom: 12),
                          title: const Text(
                            '更多信息',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: const Text('备注、标签、报销与附件'),
                          children: [
                            if (_type == TransactionType.transfer) ...[
                              DropdownButtonFormField<String>(
                                key: ValueKey(
                                  'target_${state.ledgerId}_$_target',
                                ),
                                initialValue: _target,
                                decoration: const InputDecoration(
                                  labelText: '转入账户',
                                ),
                                items: state.accounts
                                    .map(
                                      (account) => DropdownMenuItem(
                                        value: account.id,
                                        child: Text(account.displayName),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _saving
                                    ? null
                                    : (value) =>
                                          setState(() => _target = value),
                                validator: (value) =>
                                    value == null || value == _account
                                    ? '转入与转出账户必须不同'
                                    : null,
                              ),
                              if (selectedAccount != null &&
                                  targetAccount != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    selectedAccount.currency ==
                                            targetAccount.currency
                                        ? '同币种转账，转入金额与转出金额一致。'
                                        : '跨币种转账按当前汇率换算并记录本次汇率。',
                                  ),
                                ),
                            ],
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _note,
                              enabled: !_saving,
                              maxLength: 1000,
                              decoration: const InputDecoration(
                                labelText: '备注（选填）',
                                counterText: '',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const ValueKey('transaction_tags'),
                              controller: _tags,
                              enabled: !_saving,
                              maxLength: 210,
                              decoration: const InputDecoration(
                                labelText: '标签（可选）',
                                hintText: '通勤，旅行，公司报销',
                                helperText: '用逗号或空格分隔，最多10个标签',
                              ),
                              validator: (value) {
                                try {
                                  parseTagInput(value ?? '');
                                  return null;
                                } catch (e) {
                                  return e.toString();
                                }
                              },
                            ),
                            if (_type == TransactionType.expense)
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('标记待报销'),
                                subtitle: const Text('支持部分/多次报销；到账后冲减消费和预算支出'),
                                value: _reimbursable,
                                onChanged: _saving
                                    ? null
                                    : (value) =>
                                          setState(() => _reimbursable = value),
                              ),
                            if (widget.draft?.raw.source ==
                                TransactionSource.ocr)
                              ExpansionTile(
                                title: const Text('查看OCR识别原文'),
                                children: [Text(widget.draft!.raw.text)],
                              ),
                            AttachmentPanel(
                              images: _attachments,
                              loading: !_attachmentsReady,
                              onChanged: _saving || !_attachmentsReady
                                  ? null
                                  : (images) =>
                                        setState(() => _attachments = images),
                            ),
                          ],
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _saving || !_attachmentsReady
                                ? null
                                : _save,
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check),
                            label: Text(_saving ? '保存中…' : '保存账目'),
                            style: FilledButton.styleFrom(
                              backgroundColor: primary,
                              padding: const EdgeInsets.all(18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
