import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/advanced_finance_repository.dart';
import '../domain/models.dart';
import '../domain/preset_currencies.dart';
import 'action_form.dart' show showError;
import 'widgets.dart';

Future<void> showCurrencyPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const CurrencyPage()));

class CurrencyPage extends ConsumerStatefulWidget {
  const CurrencyPage({super.key});

  @override
  ConsumerState<CurrencyPage> createState() => _CurrencyPageState();
}

class _CurrencyPageState extends ConsumerState<CurrencyPage> {
  List<CurrencyDefinition>? _values;

  AdvancedFinanceRepository get _repository =>
      AdvancedFinanceRepository(ref.read(repositoryProvider).db);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ledger = ref.read(ledgerProvider).ledgerId;
      final values = await _repository.currencies(ledger);
      if (mounted) setState(() => _values = values);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _edit([CurrencyDefinition? value, PresetCurrency? preset]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CurrencyEditor(value: value, preset: preset),
    );
    if (changed == true) await _load();
  }

  Future<void> _selectPreset() async {
    final selected = await Navigator.of(context).push<PresetCurrency>(
      MaterialPageRoute(builder: (_) => const PresetCurrencySelectorPage()),
    );
    if (selected != null) {
      final existing = _values?.firstWhere(
        (c) => c.code.toUpperCase() == selected.code.toUpperCase(),
        orElse: () => CurrencyDefinition(
          code: selected.code,
          name: selected.name,
          symbol: selected.symbol,
          rateToCnyMicros: (selected.rateToCny * 1000000).round(),
          decimals: selected.decimals,
        ),
      );
      await _edit(existing, selected);
    }
  }

  Future<void> _delete(CurrencyDefinition value) async {
    try {
      await _repository.deleteCurrency(
        ref.read(ledgerProvider).ledgerId,
        value.code,
      );
      await _load();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('币种与汇率'),
      actions: [
        IconButton(
          tooltip: '从预设列表选择外币',
          onPressed: _selectPreset,
          icon: const Icon(Icons.travel_explore_outlined),
        ),
        IconButton(
          tooltip: '手动添加币种',
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: _values == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('所有统计以人民币为基准。外币账户按记账时的汇率折算，后续修改汇率不改写历史账单。'),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _selectPreset,
                      icon: const Icon(Icons.list_alt_outlined, size: 18),
                      label: const Text('选择预设币种（覆盖 160+ 种全球主要货币）'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < _values!.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 62, endIndent: 12),
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: teal.withValues(alpha: .1),
                          child: Text(
                            _values![i].symbol,
                            style: const TextStyle(color: teal),
                          ),
                        ),
                        title: Text(
                          '${_values![i].code} · ${_values![i].name}',
                        ),
                        subtitle: Text(
                          _values![i].code == 'CNY'
                              ? '基准币种 · ${_values![i].decimals}位小数'
                              : '1 ${_values![i].code} = ${_rateText(_values![i].rateToCnyMicros)} CNY · ${_values![i].decimals}位小数',
                        ),
                        onTap: () => _edit(_values![i]),
                        trailing: _values![i].code == 'CNY'
                            ? const Icon(Icons.lock_outline, size: 19)
                            : IconButton(
                                tooltip: '删除币种',
                                onPressed: () => _delete(_values![i]),
                                icon: const Icon(Icons.delete_outline),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
  );
}

class PresetCurrencySelectorPage extends StatefulWidget {
  const PresetCurrencySelectorPage({super.key});

  @override
  State<PresetCurrencySelectorPage> createState() =>
      _PresetCurrencySelectorPageState();
}

class _PresetCurrencySelectorPageState
    extends State<PresetCurrencySelectorPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = presetCurrencies.where((item) {
      if (_query.trim().isEmpty) return true;
      final q = _query.trim().toLowerCase();
      return item.code.toLowerCase().contains(q) ||
          item.name.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('选择币种'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: '搜索币种代码或名称 (如 USD、日元、泰铢)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (text) => setState(() => _query = text),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final item = filtered[index];
                final cnyRate = item.cnyToRate;
                final cnyText = cnyRate > 0
                    ? (cnyRate >= 100
                        ? cnyRate.toStringAsFixed(2)
                        : (cnyRate >= 1
                            ? cnyRate.toStringAsFixed(2)
                            : cnyRate.toStringAsFixed(4)))
                    : '0';

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    title: Text(
                      '${item.code} - ${item.name}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '1 ${item.code} = ${item.rateToCny} CNY',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                          Text(
                            '1 CNY = $cnyText ${item.code}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                    trailing: const Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: Colors.grey,
                    ),
                    onTap: () => Navigator.pop(context, item),
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

String _rateText(int micros) {
  final whole = micros ~/ 1000000;
  final fraction = (micros % 1000000).toString().padLeft(6, '0');
  return '$whole.${fraction.replaceFirst(RegExp(r'0+$'), '')}'.replaceFirst(
    RegExp(r'\.$'),
    '',
  );
}

int _parseRate(String value) {
  final text = value.trim();
  if (!RegExp(r'^\d{1,6}(\.\d{1,6})?$').hasMatch(text)) {
    throw const LedgerException('汇率最多6位小数');
  }
  final parts = text.split('.');
  final result =
      int.parse(parts[0]) * 1000000 +
      (parts.length == 2 ? int.parse(parts[1].padRight(6, '0')) : 0);
  if (result <= 0) throw const LedgerException('汇率必须大于0');
  return result;
}

class _CurrencyEditor extends ConsumerStatefulWidget {
  const _CurrencyEditor({this.value, this.preset});
  final CurrencyDefinition? value;
  final PresetCurrency? preset;

  @override
  ConsumerState<_CurrencyEditor> createState() => _CurrencyEditorState();
}

class _CurrencyEditorState extends ConsumerState<_CurrencyEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _symbol;
  late final TextEditingController _rate;
  int _decimals = 2;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final value = widget.value;
    final preset = widget.preset;
    _code = TextEditingController(text: value?.code ?? preset?.code ?? '');
    _name = TextEditingController(text: value?.name ?? preset?.name ?? '');
    _symbol = TextEditingController(text: value?.symbol ?? preset?.symbol ?? '');
    _rate = TextEditingController(
      text: value != null
          ? _rateText(value.rateToCnyMicros)
          : (preset != null ? preset.rateToCny.toString() : ''),
    );
    _decimals = value?.decimals ?? preset?.decimals ?? 2;
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _symbol.dispose();
    _rate.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ledger = ref.read(ledgerProvider).ledgerId;
      await AdvancedFinanceRepository(
        ref.read(repositoryProvider).db,
      ).saveCurrency(
        ledger,
        CurrencyDefinition(
          code: _code.text.toUpperCase().trim(),
          name: _name.text.trim(),
          symbol: _symbol.text.trim(),
          rateToCnyMicros: _parseRate(_rate.text),
          decimals: _decimals,
        ),
        originalCode: widget.value?.code,
      );
      await ref.read(ledgerProvider).load();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is LedgerException ? error.message : '保存失败';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.value == null ? '添加币种' : '编辑币种'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _code,
                  enabled: !_busy && widget.value?.code != 'CNY',
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: '币种代码'),
                  validator: (value) =>
                      RegExp(r'^[A-Za-z]{3}$').hasMatch(value?.trim() ?? '')
                      ? null
                      : '请输入3位英文字母',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: '币种名称'),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入币种名称' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _symbol,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: '符号'),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入币种符号' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _rate,
                  enabled: !_busy && widget.value?.code != 'CNY',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '兑人民币汇率',
                    helperText:
                        '1 ${_code.text.trim().toUpperCase().isEmpty ? '外币' : _code.text.trim().toUpperCase()} 等于多少 CNY',
                  ),
                  validator: (value) {
                    try {
                      _parseRate(value ?? '');
                      return null;
                    } catch (error) {
                      return error.toString();
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _decimals,
                  decoration: const InputDecoration(labelText: '金额小数位'),
                  items: [
                    for (var value = 0; value <= 4; value++)
                      DropdownMenuItem(value: value, child: Text('$value 位')),
                  ],
                  onChanged: _busy || widget.value?.code == 'CNY'
                      ? null
                      : (value) => setState(() => _decimals = value!),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
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
