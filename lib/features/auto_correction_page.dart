import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../automation/payment_apps.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tags.dart';
import 'action_form.dart' show showError;
import 'widgets.dart';

Future<void> showAutoCorrectionPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const AutoCorrectionPage()));

class AutoCorrectionPage extends ConsumerStatefulWidget {
  const AutoCorrectionPage({super.key});

  @override
  ConsumerState<AutoCorrectionPage> createState() => _AutoCorrectionPageState();
}

class _AutoCorrectionPageState extends ConsumerState<AutoCorrectionPage> {
  final _search = TextEditingController();
  List<AutoCorrectionRule>? _rules;
  bool _searching = false;
  bool _showTip = true;
  Map<String, String> _accountNames = {};
  Map<String, String> _categoryNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = ref.read(ledgerProvider);
      final values = await state.repository.autoCorrectionRules(
        state.ledgerId,
        allLedgers: true,
      );
      final accountNames = <String, String>{};
      final categoryNames = <String, String>{};
      for (final ledger in state.ledgers.keys) {
        for (final value in await state.repository.accounts(
          ledger,
          includeArchived: true,
        )) {
          accountNames[value.id] = value.displayName;
        }
        for (final value in await state.repository.categories(
          ledger,
          includeArchived: true,
        )) {
          categoryNames[value.id] = value.name;
        }
      }
      if (mounted) {
        setState(() {
          _rules = values;
          _accountNames = accountNames;
          _categoryNames = categoryNames;
        });
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _edit([AutoCorrectionRule? rule]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => AutoCorrectionEditor(rule: rule),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(AutoCorrectionRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除自动修正规则？'),
        content: Text('“${rule.merchantPattern}”之后将不再自动套用，已有账单不会改变。'),
        actions: [
          IconButton(
            tooltip: '规则建议',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RuleSuggestionsPage(),
              ),
            ),
            icon: const Icon(Icons.lightbulb_outline),
          ),
          IconButton(
            tooltip: '商户知识库',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MerchantKnowledgePage(),
              ),
            ),
            icon: const Icon(Icons.storefront_outlined),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.deleteAutoCorrectionRule(rule.ledgerId, rule.id);
      await state.load();
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _batch(AutoCorrectionRule rule) async {
    try {
      final state = ref.read(ledgerProvider);
      final preview = await state.repository.previewAutoCorrectionBatch(
        rule.id,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('批量修正旧账单'),
          content: Text(
            '共命中 ${preview.matched} 笔，可安全修正 ${preview.eligible} 笔。${preview.skipped == 0 ? '' : '\n${preview.skipped} 笔有关联退款、外币、分组或缺少目标账户/分类，将跳过。'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: preview.eligible == 0
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('开始修正'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final result = await state.repository.applyAutoCorrectionBatch(rule.id);
      await state.load();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已修正 ${result.eligible} 笔，跳过 ${result.skipped} 笔'),
          ),
        );
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _undoLearning(AutoCorrectionRule rule) async {
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.undoLatestAutoCorrectionLearning(rule.id);
      await state.load();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已撤销最近一次自动学习')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final query = _search.text.trim().toLowerCase();
    final rules = (_rules ?? const <AutoCorrectionRule>[]).where((rule) {
      if (query.isEmpty) return true;
      final account = _accountNames[rule.accountId];
      final category = _categoryNames[rule.categoryId];
      return [
        rule.merchantPattern,
        account ?? '',
        category ?? '',
        ...rule.tags,
      ].any((value) => value.toLowerCase().contains(query));
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索商户、账户、分类或标签',
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('自动修正管理'),
        actions: [
          IconButton(
            tooltip: '命中记录',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AutoCorrectionHistoryPage(),
              ),
            ),
            icon: const Icon(Icons.history),
          ),
          TextButton(onPressed: () => _edit(), child: const Text('新增')),
          IconButton(
            tooltip: _searching ? '关闭搜索' : '搜索',
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
        ],
      ),
      body: _rules == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  if (_showTip) ...[
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '系统先进行影子学习；同一商户累计至少3次且选择一致率达到80%才会提出建议，接受后规则才生效。',
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭提示',
                            onPressed: () => setState(() => _showTip = false),
                            icon: const Icon(Icons.close, size: 19),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (rules.isEmpty)
                    EmptyView(
                      title: query.isEmpty ? '暂无自动修正规则' : '没有匹配的规则',
                      description: query.isEmpty
                          ? '确认带商户的账单后会自动学习，也可以点右上角新增。'
                          : '换个关键词试试。',
                    )
                  else
                    for (final rule in rules) ...[
                      _RuleCard(
                        rule: rule,
                        ledgerName: state.ledgers[rule.ledgerId] ?? '当前账本',
                        accountName: _accountNames[rule.accountId],
                        categoryName: _categoryNames[rule.categoryId],
                        onEdit: () => _edit(rule),
                        onDelete: () => _delete(rule),
                        onBatch: () => _batch(rule),
                        onUndoLearning: rule.learned
                            ? () => _undoLearning(rule)
                            : null,
                        onToggle: (enabled) async {
                          try {
                            await state.repository.setAutoCorrectionEnabled(
                              rule.ledgerId,
                              rule.id,
                              enabled,
                            );
                            await state.load();
                            await _load();
                          } catch (error) {
                            if (context.mounted) showError(context, error);
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.ledgerName,
    required this.accountName,
    required this.categoryName,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
    required this.onBatch,
    this.onUndoLearning,
  });

  final AutoCorrectionRule rule;
  final String ledgerName;
  final String? accountName;
  final String? categoryName;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;
  final VoidCallback onBatch;
  final VoidCallback? onUndoLearning;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      rule.type == TransactionType.expense ? '支出' : '收入',
      ?categoryName,
      ?accountName,
      ledgerName,
      ...rule.tags.map((tag) => '#$tag'),
      if (rule.sourceKey.isNotEmpty) _sourceLabel(rule.sourceKey),
      if (rule.minAmountMinor != null || rule.maxAmountMinor != null)
        '${rule.minAmountMinor == null ? '不限' : money(rule.minAmountMinor!)}～${rule.maxAmountMinor == null ? '不限' : money(rule.maxAmountMinor!)}',
      if (rule.paymentMethodPattern.isNotEmpty)
        '付款方式含 ${rule.paymentMethodPattern}',
      if (rule.startMinute != null || rule.endMinute != null)
        '${_clock(rule.startMinute) ?? '00:00'}～${_clock(rule.endMinute) ?? '23:59'}',
      if (rule.weekdaysMask != 127) _weekdayLabel(rule.weekdaysMask),
      if (rule.sourceAccountId != null) '限指定来源账户',
    ];
    return SectionCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            rule.merchantPattern,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        if (rule.learned)
                          const Text(
                            '自动学习',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      details.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: rule.enabled
                            ? Colors.grey
                            : Colors.grey.shade400,
                      ),
                    ),
                    if (rule.matchMode == AutoCorrectionMatchMode.contains)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          '包含匹配',
                          style: TextStyle(fontSize: 11, color: Colors.teal),
                        ),
                      ),
                  ],
                ),
              ),
              Switch.adaptive(value: rule.enabled, onChanged: onToggle),
              PopupMenuButton<String>(
                tooltip: '更多操作',
                onSelected: (value) {
                  if (value == 'edit') onEdit();
                  if (value == 'batch') onBatch();
                  if (value == 'undo') onUndoLearning?.call();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem(value: 'batch', child: Text('批量修正旧账单')),
                  if (onUndoLearning != null)
                    const PopupMenuItem(value: 'undo', child: Text('撤销最近学习')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? _clock(int? minute) => minute == null
    ? null
    : '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

String _weekdayLabel(int mask) => [
  for (var day = 1; day <= 7; day++)
    if ((mask & (1 << (day - 1))) != 0)
      ['一', '二', '三', '四', '五', '六', '日'][day - 1],
].map((value) => '周$value').join('、');

String _sourceLabel(String value) {
  if (value.startsWith('app:')) {
    final packageName = value.substring(4);
    for (final app in paymentApps) {
      if (app.packageName == packageName) return app.name;
    }
  }
  return switch (value) {
    'channel:ocr' => 'OCR截图',
    'channel:speech' => '语音',
    'channel:notification' => '支付通知',
    'channel:import' => '导入',
    _ => value,
  };
}

class AutoCorrectionEditor extends ConsumerStatefulWidget {
  const AutoCorrectionEditor({super.key, this.rule, this.suggestion});
  final AutoCorrectionRule? rule;
  final AutoCorrectionSuggestion? suggestion;

  @override
  ConsumerState<AutoCorrectionEditor> createState() =>
      _AutoCorrectionEditorState();
}

class _AutoCorrectionEditorState extends ConsumerState<AutoCorrectionEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _merchant;
  late final TextEditingController _tags;
  late final TextEditingController _priority;
  late final TextEditingController _minAmount;
  late final TextEditingController _maxAmount;
  late final TextEditingController _paymentMethod;
  late final TextEditingController _startTime;
  late final TextEditingController _endTime;
  late TransactionType _type;
  late AutoCorrectionMatchMode _mode;
  late String _ledger;
  String _sourceKey = '';
  String? _account;
  String? _category;
  String? _sourceAccount;
  late Set<int> _weekdays;
  List<Account> _accounts = const [];
  List<({Account account, String ledgerName})> _sourceAccounts = const [];
  List<Category> _categories = const [];
  bool _enabled = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    final suggestion = widget.suggestion;
    _merchant = TextEditingController(
      text: rule?.merchantPattern ?? suggestion?.merchantPattern ?? '',
    );
    _tags = TextEditingController(
      text: (rule?.tags ?? suggestion?.tags)?.join('，') ?? '',
    );
    _priority = TextEditingController(text: '${rule?.priority ?? 0}');
    _minAmount = TextEditingController(
      text: rule?.minAmountMinor == null
          ? ''
          : (rule!.minAmountMinor! / 100).toStringAsFixed(2),
    );
    _maxAmount = TextEditingController(
      text: rule?.maxAmountMinor == null
          ? ''
          : (rule!.maxAmountMinor! / 100).toStringAsFixed(2),
    );
    _paymentMethod = TextEditingController(
      text: rule?.paymentMethodPattern ?? '',
    );
    String clock(int? minute) => minute == null
        ? ''
        : '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
    _startTime = TextEditingController(text: clock(rule?.startMinute));
    _endTime = TextEditingController(text: clock(rule?.endMinute));
    _weekdays = {
      for (var day = 1; day <= 7; day++)
        if (((rule?.weekdaysMask ?? 127) & (1 << (day - 1))) != 0) day,
    };
    _type = rule?.type ?? suggestion?.type ?? TransactionType.expense;
    _mode = rule?.matchMode ?? AutoCorrectionMatchMode.exact;
    _ledger =
        rule?.ledgerId ??
        suggestion?.ledgerId ??
        ref.read(ledgerProvider).ledgerId;
    _sourceKey = rule?.sourceKey ?? suggestion?.sourceKey ?? '';
    _account = rule?.accountId ?? suggestion?.accountId;
    _category = rule?.categoryId ?? suggestion?.categoryId;
    _sourceAccount = rule?.sourceAccountId;
    _enabled = rule?.enabled ?? true;
    _loadTarget();
  }

  Future<void> _loadTarget() async {
    final state = ref.read(ledgerProvider);
    final repository = state.repository;
    final accounts = await repository.accounts(_ledger);
    final categories = await repository.categories(_ledger);
    final sourceAccounts = <({Account account, String ledgerName})>[];
    for (final ledger in state.ledgers.entries) {
      for (final account in await repository.accounts(ledger.key)) {
        sourceAccounts.add((account: account, ledgerName: ledger.value));
      }
    }
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _sourceAccounts = sourceAccounts;
      _categories = categories;
      if (!_accounts.any((value) => value.id == _account)) _account = null;
      if (!_sourceAccounts.any((value) => value.account.id == _sourceAccount)) {
        _sourceAccount = null;
      }
      if (!_categories.any(
        (value) => value.id == _category && value.type == _type,
      )) {
        _category = null;
      }
    });
  }

  @override
  void dispose() {
    _merchant.dispose();
    _tags.dispose();
    _priority.dispose();
    _minAmount.dispose();
    _maxAmount.dispose();
    _paymentMethod.dispose();
    _startTime.dispose();
    _endTime.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _saving) return;
    setState(() => _saving = true);
    try {
      final state = ref.read(ledgerProvider);
      if (widget.suggestion != null) {
        await state.repository.acceptAutoCorrectionSuggestion(
          widget.suggestion!.id,
          merchantPattern: _merchant.text,
          accountId: _account,
          categoryId: _category,
          tags: parseTagInput(_tags.text),
        );
      } else {
        int? minute(String value) {
          if (value.trim().isEmpty) return null;
          final parts = value.trim().split(':');
          if (parts.length != 2) throw const LedgerException('时间需使用 HH:mm 格式');
          final hour = int.tryParse(parts[0]),
              valueMinute = int.tryParse(parts[1]);
          if (hour == null ||
              valueMinute == null ||
              hour > 23 ||
              valueMinute > 59) {
            throw const LedgerException('时间需使用 HH:mm 格式');
          }
          return hour * 60 + valueMinute;
        }

        await state.repository.saveAutoCorrectionRule(
          _ledger,
          id: widget.rule?.id,
          merchantPattern: _merchant.text,
          type: _type,
          accountId: _account,
          categoryId: _category,
          matchMode: _mode,
          tags: parseTagInput(_tags.text),
          enabled: _enabled,
          priority: int.parse(_priority.text.trim()),
          sourceKey: _sourceKey,
          minAmountMinor: _minAmount.text.trim().isEmpty
              ? null
              : parseMoney(_minAmount.text),
          maxAmountMinor: _maxAmount.text.trim().isEmpty
              ? null
              : parseMoney(_maxAmount.text),
          paymentMethodPattern: _paymentMethod.text,
          startMinute: minute(_startTime.text),
          endMinute: minute(_endTime.text),
          weekdaysMask: _weekdays.fold(
            0,
            (mask, day) => mask | (1 << (day - 1)),
          ),
          sourceAccountId: _sourceAccount,
        );
      }
      await state.load();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final categories = _categories
        .where((value) => value.type == _type)
        .toList();
    if (_category != null &&
        !categories.any((value) => value.id == _category)) {
      _category = null;
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.suggestion != null
                    ? '编辑并接受建议'
                    : widget.rule == null
                    ? '新增自动修正'
                    : '编辑自动修正',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _merchant,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: '商户匹配词',
                  hintText: '例如：KKV、某某便利店',
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入商户匹配词' : null,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _ledger,
                decoration: const InputDecoration(
                  labelText: '目标账本',
                  helperText: '规则可从任意账本命中，并把账单归入这里',
                ),
                items: [
                  for (final entry in state.ledgers.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) {
                  if (value == null || value == _ledger) return;
                  setState(() {
                    _ledger = value;
                    _account = null;
                    _category = null;
                  });
                  _loadTarget();
                },
              ),
              const SizedBox(height: 12),
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
                onSelectionChanged: (values) => setState(() {
                  _type = values.single;
                  _category = null;
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AutoCorrectionMatchMode>(
                initialValue: _mode,
                decoration: const InputDecoration(labelText: '匹配方式'),
                items: const [
                  DropdownMenuItem(
                    value: AutoCorrectionMatchMode.exact,
                    child: Text('精确匹配（推荐）'),
                  ),
                  DropdownMenuItem(
                    value: AutoCorrectionMatchMode.contains,
                    child: Text('商户名称包含匹配词'),
                  ),
                ],
                onChanged: (value) => setState(() => _mode = value!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _sourceKey,
                decoration: const InputDecoration(labelText: '支付软件或来源'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部来源')),
                  for (final app in paymentApps)
                    DropdownMenuItem(
                      value: 'app:${app.packageName}',
                      child: Text(app.name),
                    ),
                  const DropdownMenuItem(
                    value: 'channel:ocr',
                    child: Text('OCR截图'),
                  ),
                  const DropdownMenuItem(
                    value: 'channel:speech',
                    child: Text('语音记账'),
                  ),
                  const DropdownMenuItem(
                    value: 'channel:notification',
                    child: Text('支付通知'),
                  ),
                  const DropdownMenuItem(
                    value: 'channel:import',
                    child: Text('账单导入'),
                  ),
                  const DropdownMenuItem(
                    value: 'channel:text',
                    child: Text('手动/文本'),
                  ),
                ],
                onChanged: (value) => setState(() => _sourceKey = value ?? ''),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _minAmount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '最低金额',
                        prefixText: '¥ ',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _maxAmount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '最高金额',
                        prefixText: '¥ ',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _paymentMethod,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: '付款方式包含（可选）',
                  hintText: '例如：花呗、招商银行、零钱',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _startTime,
                      decoration: const InputDecoration(
                        labelText: '开始时间',
                        hintText: 'HH:mm',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _endTime,
                      decoration: const InputDecoration(
                        labelText: '结束时间',
                        hintText: 'HH:mm',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                children: [
                  for (final entry in const {
                    1: '一',
                    2: '二',
                    3: '三',
                    4: '四',
                    5: '五',
                    6: '六',
                    7: '日',
                  }.entries)
                    FilterChip(
                      label: Text('周${entry.value}'),
                      selected: _weekdays.contains(entry.key),
                      onSelected: (selected) => setState(
                        () => selected
                            ? _weekdays.add(entry.key)
                            : _weekdays.remove(entry.key),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _sourceAccount,
                decoration: const InputDecoration(labelText: '识别到的来源账户条件'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('不限来源账户')),
                  for (final value in _sourceAccounts)
                    DropdownMenuItem(
                      value: value.account.id,
                      child: Text(
                        '${value.ledgerName} · ${value.account.displayName}',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _sourceAccount = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _account,
                decoration: const InputDecoration(labelText: '自动修正账户'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('不修改账户')),
                  for (final account in _accounts)
                    DropdownMenuItem(
                      value: account.id,
                      child: Text(account.displayName),
                    ),
                ],
                onChanged: (value) => setState(() => _account = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _category,
                decoration: const InputDecoration(labelText: '自动修正分类'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('不修改分类')),
                  for (final category in categories)
                    DropdownMenuItem(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (value) => setState(() => _category = value),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tags,
                decoration: const InputDecoration(
                  labelText: '自动修正标签（可选）',
                  helperText: '用逗号或空格分隔，最多10个',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _priority,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '优先级',
                  helperText: '多个包含规则同时匹配时，数值大的优先',
                ),
                validator: (value) {
                  final parsed = int.tryParse(value?.trim() ?? '');
                  return parsed == null || parsed < -1000 || parsed > 1000
                      ? '请输入 -1000～1000 的整数'
                      : null;
                },
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用此规则'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? '保存中…' : '保存规则'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RuleSuggestionsPage extends ConsumerStatefulWidget {
  const RuleSuggestionsPage({super.key});
  @override
  ConsumerState<RuleSuggestionsPage> createState() =>
      _RuleSuggestionsPageState();
}

class _RuleSuggestionsPageState extends ConsumerState<RuleSuggestionsPage> {
  List<AutoCorrectionSuggestion>? _items;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await ref
        .read(ledgerProvider)
        .repository
        .autoCorrectionSuggestions();
    if (mounted) setState(() => _items = values);
  }

  Future<void> _accept(
    AutoCorrectionSuggestion item, {
    bool edit = false,
  }) async {
    if (edit) {
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => AutoCorrectionEditor(suggestion: item),
      );
    } else {
      await ref
          .read(ledgerProvider)
          .repository
          .acceptAutoCorrectionSuggestion(item.id);
    }
    await ref.read(ledgerProvider).load();
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('规则建议')),
    body: _items == null
        ? const Center(child: CircularProgressIndicator())
        : _items!.isEmpty
        ? const EmptyView(
            title: '暂无稳定建议',
            description: '至少3次相同选择且一致率达到80%后才会出现。',
          )
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _items!.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final item = _items![index];
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.merchantPattern,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.sampleCount}个样本 · 一致率 ${(item.consistencyBps / 100).toStringAsFixed(0)}% · ${item.reason}',
                    ),
                    if (item.conflicts.isNotEmpty)
                      Text(
                        '另有 ${item.conflicts.length} 组不同选择，将不会写入本规则',
                        style: const TextStyle(color: Colors.orange),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () async {
                            await ref
                                .read(ledgerProvider)
                                .repository
                                .rejectAutoCorrectionSuggestion(item.id);
                            await _load();
                          },
                          child: const Text('拒绝'),
                        ),
                        TextButton(
                          onPressed: () => _accept(item, edit: true),
                          child: const Text('编辑'),
                        ),
                        FilledButton(
                          onPressed: () => _accept(item),
                          child: const Text('接受'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
  );
}

class MerchantKnowledgePage extends ConsumerStatefulWidget {
  const MerchantKnowledgePage({super.key});
  @override
  ConsumerState<MerchantKnowledgePage> createState() =>
      _MerchantKnowledgePageState();
}

class _MerchantKnowledgePageState extends ConsumerState<MerchantKnowledgePage> {
  List<MerchantKnowledge>? _items;
  Future<void> _load() async {
    final state = ref.read(ledgerProvider);
    final values = await state.repository.merchantKnowledge(state.ledgerId);
    if (mounted) setState(() => _items = values);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _edit([MerchantKnowledge? item]) async {
    final state = ref.read(ledgerProvider);
    final name = TextEditingController(text: item?.canonicalName ?? '');
    final aliases = TextEditingController(text: item?.aliases.join('，') ?? '');
    final categories = await state.repository.categories(state.ledgerId);
    if (!mounted) {
      name.dispose();
      aliases.dispose();
      return;
    }
    String? category = item?.defaultCategoryId;
    String sourceKey = item?.sourceKey ?? '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(item == null ? '新增商户知识' : '编辑商户知识'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '标准商户名'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: aliases,
                  decoration: const InputDecoration(labelText: '别名（逗号分隔）'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '默认分类'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('不指定')),
                    for (final value in categories)
                      DropdownMenuItem(
                        value: value.id,
                        child: Text(value.name),
                      ),
                  ],
                  onChanged: (value) => setDialogState(() => category = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: sourceKey,
                  decoration: const InputDecoration(labelText: '来源映射'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部来源')),
                    for (final app in paymentApps)
                      DropdownMenuItem(
                        value: 'app:${app.packageName}',
                        child: Text(app.name),
                      ),
                    const DropdownMenuItem(
                      value: 'channel:ocr',
                      child: Text('OCR截图'),
                    ),
                    const DropdownMenuItem(
                      value: 'channel:notification',
                      child: Text('支付通知/无障碍'),
                    ),
                    const DropdownMenuItem(
                      value: 'channel:import',
                      child: Text('账单导入'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => sourceKey = value ?? ''),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await state.repository.saveMerchantKnowledge(
        state.ledgerId,
        id: item?.id,
        canonicalName: name.text,
        aliases: parseTagInput(aliases.text),
        defaultCategoryId: category,
        sourceKey: sourceKey,
      );
      await _load();
    }
    name.dispose();
    aliases.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('商户知识库'),
      actions: [TextButton(onPressed: () => _edit(), child: const Text('新增'))],
    ),
    body: _items == null
        ? const Center(child: CircularProgressIndicator())
        : _items!.isEmpty
        ? const EmptyView(title: '暂无本地商户', description: '可维护标准名称、别名、默认分类和来源映射。')
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _items!.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (_, index) {
              final item = _items![index];
              return ListTile(
                title: Text(item.canonicalName),
                subtitle: Text(item.aliases.join(' · ')),
                onTap: () => _edit(item),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ref
                        .read(ledgerProvider)
                        .repository
                        .deleteMerchantKnowledge(item.id);
                    await _load();
                  },
                ),
              );
            },
          ),
  );
}

class AutoCorrectionHistoryPage extends ConsumerWidget {
  const AutoCorrectionHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.read(ledgerProvider).repository;
    final ledgers = ref.watch(ledgerProvider).ledgers;
    return Scaffold(
      appBar: AppBar(title: const Text('自动修正记录')),
      body: FutureBuilder<List<AutoCorrectionEvent>>(
        future: repository.autoCorrectionEvents(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final values = snapshot.data!;
          if (values.isEmpty) {
            return const EmptyView(
              title: '暂无记录',
              description: '规则命中、自动学习、批量修正和撤销都会显示在这里。',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: values.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final event = values[index];
              final title = switch (event.eventType) {
                'match' => '规则命中',
                'learn_created' => '新学习规则',
                'learn_updated' => '更新学习',
                'batch' => '批量修正旧账单',
                'undo' => '撤销学习',
                _ => event.eventType,
              };
              final source =
                  ledgers[event.sourceLedgerId] ?? event.sourceLedgerId;
              final target =
                  ledgers[event.targetLedgerId] ?? event.targetLedgerId;
              return SectionCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '$title · ${event.merchant.isEmpty ? '未命名商户' : event.merchant}',
                  ),
                  subtitle: Text(
                    '${event.amountMinor == null ? '' : '${money(event.amountMinor!)} · '}'
                    '${source == target ? target : '$source → $target'}'
                    '${event.sourceKey.isEmpty ? '' : ' · ${_sourceLabel(event.sourceKey)}'}\n'
                    '${event.createdAt.toLocal().toString().substring(0, 19)}'
                    '${event.undoneAt == null ? '' : ' · 已撤销'}',
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
