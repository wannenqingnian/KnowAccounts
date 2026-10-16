import 'package:flutter/material.dart';
import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/credit_platforms.dart';
import '../domain/banks.dart';
import '../data/advanced_finance_repository.dart';

Future<void> showAccountEditor(
  BuildContext context,
  LedgerController state, {
  Account? account,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _AccountEditor(state: state, account: account),
);

class _AccountEditor extends StatefulWidget {
  const _AccountEditor({required this.state, this.account});
  final LedgerController state;
  final Account? account;
  @override
  State<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<_AccountEditor> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _opening = TextEditingController(text: '0');
  final _day = TextEditingController();
  final _card = TextEditingController();
  String? _bank;
  List<CurrencyDefinition> _currencies = const [];
  String _currency = 'CNY';
  bool _obscureCard = true;
  bool _clearCard = false;
  late final String _ledgerId;
  AccountKind _kind = AccountKind.cash;
  String? _provider;
  DateTime? _date;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _ledgerId = widget.state.ledgerId;
    final a = widget.account;
    if (a != null) {
      _kind = a.kind;
      _bank = a.bankId;
      _currency = a.currency;
      _provider = a.providerId;
      _date = a.dueDate;
      _name.text = a.name;
      _day.text = a.repaymentDay?.toString() ?? '';
    }
    _loadCurrencies();
  }

  Future<void> _loadCurrencies() async {
    try {
      final values = await AdvancedFinanceRepository(
        widget.state.repository.db,
      ).currencies(_ledgerId);
      if (!mounted) return;
      final selected = values.firstWhere(
        (value) => value.code == _currency,
        orElse: () => values.first,
      );
      setState(() {
        _currencies = values;
        _currency = selected.code;
        final account = widget.account;
        if (account != null) {
          _opening.text = currencyMoney(
            account.balanceMinor,
            symbol: selected.symbol,
            decimals: selected.decimals,
            showSymbol: false,
          );
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = '币种读取失败，请关闭后重试');
      }
    }
  }

  CurrencyDefinition get _selectedCurrency => _currencies.firstWhere(
    (value) => value.code == _currency,
    orElse: () => const CurrencyDefinition(
      code: 'CNY',
      name: '人民币',
      symbol: '¥',
      rateToCnyMicros: 1000000,
    ),
  );

  @override
  void dispose() {
    _name.dispose();
    _opening.dispose();
    _day.dispose();
    _card.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final day = _day.text.trim().isEmpty ? null : int.parse(_day.text.trim());
      final state = widget.state;
      if (state.ledgerId != _ledgerId) {
        throw const LedgerException('账本已切换，请重新打开账户');
      }
      final rawCard = _card.text.trim().replaceAll(RegExp(r'[\s-]'), '');
      final tail = cardTailFromInput(rawCard);
      final value = _opening.text.trim();
      final editing = widget.account != null;
      if (!editing && _kind.isDebt && value.startsWith('-')) {
        throw const LedgerException('欠款请输入正数');
      }
      final unsigned = value.startsWith('-') ? value.substring(1) : value;
      final zeroPattern = _selectedCurrency.decimals == 0
          ? RegExp(r'^0$')
          : RegExp('^0(\\.0{1,${_selectedCurrency.decimals}})?\$');
      final amount = zeroPattern.hasMatch(unsigned)
          ? 0
          : parseMinorUnits(unsigned, _selectedCurrency.decimals);
      final balance = (!editing && _kind.isDebt) || value.startsWith('-')
          ? -amount
          : amount;
      if (editing) {
        await state.repository.updateAccount(
          _ledgerId,
          widget.account!.id,
          _name.text,
          _kind,
          balance,
          providerId: _provider,
          repaymentDay: _kind.isDebt ? day : null,
          dueDate: _kind.isDebt ? _date : null,
          bankId: _bank,
          cardLast4: tail,
          fullCardNumber: rawCard.length > 4 ? rawCard : null,
          replaceCard: _clearCard || rawCard.isNotEmpty,
          currency: _currency,
        );
      } else {
        await state.repository.addAccount(
          _ledgerId,
          _name.text,
          _kind,
          balance,
          providerId: _provider,
          repaymentDay: _kind.isDebt ? day : null,
          dueDate: _kind.isDebt ? _date : null,
          bankId: _bank,
          cardLast4: tail,
          fullCardNumber: rawCard.length > 4 ? rawCard : null,
          currency: _currency,
        );
      }
      await state.load();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is LedgerException ? e.message : '保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.account == null ? '新增账户' : '编辑账户'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...[
                  DropdownButtonFormField<AccountKind>(
                    initialValue: _kind,
                    isExpanded: true,
                    itemHeight: null,
                    decoration: const InputDecoration(labelText: '账户类型'),
                    items: [
                      for (final k in AccountKind.values)
                        DropdownMenuItem(
                          value: k,
                          child: Text(accountTypeLabel(k)),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (k) => setState(() {
                            _kind = k!;
                            _provider = null;
                            _bank = null;
                            _card.clear();
                            _clearCard = true;
                            _day.clear();
                            _date = null;
                          }),
                  ),
                  const SizedBox(height: 16),
                  if (_kind == AccountKind.bank ||
                      _kind == AccountKind.credit) ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey('bank_$_kind'),
                      initialValue: _bank ?? '',
                      isExpanded: true,
                      itemHeight: null,
                      decoration: const InputDecoration(labelText: '银行模板'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('其他 / 自定义银行'),
                        ),
                        for (final b in bankTemplates)
                          DropdownMenuItem(value: b.id, child: Text(b.name)),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _bank = v!.isEmpty ? null : v;
                              if (_bank != null) {
                                _name.text =
                                    '${bankTemplate(_bank)!.name}${_kind == AccountKind.credit ? '信用卡' : ''}';
                              }
                            }),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _card,
                      onChanged: (text) {
                        if (text.isNotEmpty && _clearCard) {
                          setState(() => _clearCard = false);
                        }
                        if (_bank == null) return;
                        final base =
                            '${bankTemplate(_bank)!.name}${_kind == AccountKind.credit ? '信用卡' : ''}';
                        if (_name.text != base &&
                            !RegExp('^$base \\d{4}\$').hasMatch(_name.text)) {
                          return;
                        }
                        try {
                          final tail = cardTailFromInput(text);
                          _name.text = tail == null ? base : '$base $tail';
                        } on FormatException {
                          /* Keep the name until input is complete. */
                        }
                      },
                      enabled: !_busy,
                      obscureText: _obscureCard,
                      keyboardType: TextInputType.number,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: '卡号或尾号（选填）',
                        helperText: widget.account == null
                            ? '填写完整卡号或4位尾号'
                            : '留空保留已存卡号；填写新卡号或尾号可替换',
                        helperMaxLines: 3,
                        suffixIcon: IconButton(
                          tooltip: '切换卡号显示',
                          onPressed: () =>
                              setState(() => _obscureCard = !_obscureCard),
                          icon: Icon(
                            _obscureCard
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      validator: (v) {
                        try {
                          cardTailFromInput(v ?? '');
                          return null;
                        } on FormatException {
                          return '请输入4位尾号或13～19位完整卡号';
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    const Text('输入完整卡号将保存在系统安全存储；列表仅显示尾号。也可以只填写尾号。'),
                    if (widget.account?.cardLast4 != null) ...[
                      Text('已保存卡号：•••• ${widget.account!.cardLast4}'),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _clearCard,
                        title: const Text('清除已保存卡号和尾号'),
                        onChanged: _busy
                            ? null
                            : (v) => setState(() {
                                _clearCard = v!;
                                if (_clearCard) _card.clear();
                              }),
                      ),
                    ],
                    const SizedBox(height: 16),
                  ],
                  if (_kind == AccountKind.creditPayment ||
                      _kind == AccountKind.loan) ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey('platform_$_kind'),
                      initialValue: _provider ?? '',
                      isExpanded: true,
                      itemHeight: null,
                      decoration: const InputDecoration(labelText: '平台模板'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('其他 / 自定义平台'),
                        ),
                        for (final p in creditPlatforms.where(
                          (p) => p.kind == _kind,
                        ))
                          DropdownMenuItem(value: p.id, child: Text(p.name)),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _provider = v!.isEmpty ? null : v;
                              if (_provider != null) {
                                _name.text = creditPlatform(_provider)!.name;
                              }
                            }),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    controller: _name,
                    enabled: !_busy,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: '账户名称'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请输入账户名称' : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownMenu<String>(
                    key: ValueKey(
                      'currency_${_currency}_${_currencies.length}',
                    ),
                    initialSelection:
                        _currencies.any((value) => value.code == _currency)
                        ? _currency
                        : null,
                    expandedInsets: EdgeInsets.zero,
                    label: const Text('币种'),
                    dropdownMenuEntries: [
                      for (final value in _currencies)
                        DropdownMenuEntry(
                          value: value.code,
                          label:
                              '${value.code} · ${value.name}（${value.symbol}）',
                        ),
                    ],
                    enabled: !_busy && _currencies.isNotEmpty,
                    onSelected: _busy
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _currency = value);
                            }
                          },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _opening,
                    enabled: !_busy,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(
                      labelText: widget.account != null
                          ? '当前余额'
                          : _kind.isDebt
                          ? '当前欠款（填正数）'
                          : '期初余额',
                      helperText: widget.account != null
                          ? '$_currency · 欠款填负数；已有流水的账户不能修改币种。'
                          : '$_currency · 汇率在“管理→币种与汇率”维护',
                      helperMaxLines: 4,
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请输入金额，无欠款可填 0' : null,
                  ),
                  const SizedBox(height: 8),
                  if (widget.account == null)
                    Text(_kind.isDebt ? '欠款会作为负余额保存；授信额度不计入资产。' : '期初余额不计入收入。'),
                  const SizedBox(height: 16),
                ],
                if (_kind.isDebt) ...[
                  TextFormField(
                    controller: _day,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '每月还款日',
                      helperText: '填写 1～31，可留空',
                      helperMaxLines: 3,
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return null;
                      final n = int.tryParse(v.trim());
                      return n == null || n < 1 || n > 31 ? '请输入 1～31 日' : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today_outlined),
                          label: Text(
                            _date == null ? '指定到期日期（选填）' : dateKey(_date!),
                          ),
                          onPressed: _busy
                              ? null
                              : () async {
                                  final d = await showDatePicker(
                                    context: context,
                                    initialDate: _date ?? DateTime.now(),
                                    firstDate: DateTime(1900),
                                    lastDate: DateTime(2100),
                                  );
                                  if (d != null && mounted) {
                                    setState(() => _date = d);
                                  }
                                },
                        ),
                      ),
                      if (_date != null)
                        IconButton(
                          tooltip: '清除指定到期日',
                          onPressed: _busy
                              ? null
                              : () => setState(() => _date = null),
                          icon: const Icon(Icons.close),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '还款日以你的实际账单为准。短月份的 29～31 日按月末计算；指定日期优先，每次还款后需自行更新指定日期。',
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
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
          child: Text(_busy ? '保存中…' : '保存账户'),
        ),
      ],
    ),
  );
}

String accountTypeLabel(AccountKind k) => switch (k) {
  AccountKind.cash => '现金',
  AccountKind.bank => '银行卡',
  AccountKind.wechat => '微信',
  AccountKind.alipay => '支付宝',
  AccountKind.credit => '信用卡',
  AccountKind.creditPayment => '信用支付',
  AccountKind.loan => '贷款 / 现金借款',
};
