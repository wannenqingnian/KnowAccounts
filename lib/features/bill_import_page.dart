import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../import/bill_import.dart';
import 'money_privacy.dart';
import 'widgets.dart';

Future<void> showBillImportPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const BillImportPage()));

class BillImportPage extends ConsumerStatefulWidget {
  const BillImportPage({super.key});

  @override
  ConsumerState<BillImportPage> createState() => _BillImportPageState();
}

class _BillImportPageState extends ConsumerState<BillImportPage> {
  BillImportSource _source = BillImportSource.alipay;
  BillTable? _table;
  BillMapping? _mapping;
  BillImportPreview? _preview;
  String _fileName = '';
  String? _accountId;
  String? _expenseCategoryId;
  String? _incomeCategoryId;
  final _selected = <int>{};
  bool _busy = false;

  void _message(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error is LedgerException ? error.message : '$error'),
      ),
    );
  }

  void _chooseDefaults() {
    final state = ref.read(ledgerProvider);
    Account? preferred;
    final kind = switch (_source) {
      BillImportSource.alipay => AccountKind.alipay,
      BillImportSource.wechat => AccountKind.wechat,
      _ => null,
    };
    if (kind != null) {
      preferred = state.accounts.where((item) => item.kind == kind).firstOrNull;
    }
    _accountId ??= preferred?.id ?? state.accounts.firstOrNull?.id;
    _expenseCategoryId ??= state.categories
        .where((item) => item.type == TransactionType.expense)
        .firstOrNull
        ?.id;
    _incomeCategoryId ??= state.categories
        .where((item) => item.type == TransactionType.income)
        .firstOrNull
        ?.id;
  }

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'txt', 'xlsx'],
        withData: true,
      );
      if (result == null) return;
      final file = result.files.single;
      if (file.size > 30 * 1024 * 1024) {
        throw const LedgerException('账单文件超过 30 MB，请拆分后导入');
      }
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final table = BillFileParser.decode(Uint8List.fromList(bytes), file.name);
      final detected = table.detectedSource;
      final mapping = BillFileParser.autoMapping(table);
      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _table = table;
        _mapping = mapping;
        if (detected != null) _source = detected;
        _preview = BillFileParser.mapRows(table, _source, mapping);
        _selected
          ..clear()
          ..addAll([
            for (var i = 0; i < _preview!.rows.length; i++)
              if (_preview!.rows[i].importable) i,
          ]);
        _accountId = null;
        _chooseDefaults();
      });
    } catch (error) {
      _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remap([BillMapping? mapping]) {
    final table = _table;
    if (table == null) return;
    try {
      final next = mapping ?? _mapping!;
      final preview = BillFileParser.mapRows(table, _source, next);
      setState(() {
        _mapping = next;
        _preview = preview;
        _selected
          ..clear()
          ..addAll([
            for (var i = 0; i < preview.rows.length; i++)
              if (preview.rows[i].importable) i,
          ]);
      });
    } catch (error) {
      _message(error);
    }
  }

  Future<void> _runImport() async {
    final state = ref.read(ledgerProvider);
    final preview = _preview;
    if (preview == null || _selected.isEmpty) {
      _message(const LedgerException('请至少选择一条可导入记录'));
      return;
    }
    if (_accountId == null ||
        _expenseCategoryId == null ||
        _incomeCategoryId == null) {
      _message(const LedgerException('请选择导入账户和默认分类'));
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await BillBatchImporter(state.repository).import(
        state.ledgerId,
        [for (final index in _selected) preview.rows[index]],
        accountId: _accountId!,
        expenseCategoryId: _expenseCategoryId!,
        incomeCategoryId: _incomeCategoryId!,
        categories: state.categories,
      );
      await state.load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入完成'),
          content: Text(
            '普通账单 ${result.imported} 条\n退款 ${result.refunds} 条\n'
            '重复跳过 ${result.duplicates} 条\n异常跳过 ${result.skipped} 条'
            '${result.unmatchedRefunds == 0 ? '' : '\n未找到原消费的退款 ${result.unmatchedRefunds} 条'}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    } catch (error) {
      _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    _chooseDefaults();
    final preview = _preview;
    final importable =
        preview?.rows.where((item) => item.importable).length ?? 0;
    final refunds =
        preview?.rows
            .where((item) => item.kind == ImportedBillKind.refund)
            .length ??
        0;
    final skipped = (preview?.rows.length ?? 0) - importable;
    return Scaffold(
      appBar: AppBar(title: const Text('批量导入账单')),
      bottomNavigationBar: preview == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _busy ? null : _runImport,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.file_download_done_outlined),
                  label: Text('导入已选 ${_selected.length} 条'),
                ),
              ),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('选择账单来源', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final source in BillImportSource.values)
                ChoiceChip(
                  label: Text(source.label),
                  selected: _source == source,
                  onSelected: _busy
                      ? null
                      : (_) {
                          setState(() {
                            _source = source;
                            _accountId = null;
                            _chooseDefaults();
                          });
                          if (_table != null) _remap();
                        },
                ),
            ],
          ),
          const SizedBox(height: 12),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fileName.isEmpty ? '选择账单文件' : _fileName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '支持支付宝、微信、云闪付导出的 CSV，以及自定义 Excel / CSV。文件只在本机解析。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(_fileName.isEmpty ? '选择文件' : '更换文件'),
                ),
              ],
            ),
          ),
          if (_table != null && _mapping != null) ...[
            const SizedBox(height: 12),
            _mappingCard(),
            const SizedBox(height: 12),
            _defaultsCard(state),
          ],
          if (preview != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '预览 · 可导入 $importable · 退款 $refunds · 跳过 $skipped',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == importable) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll([
                          for (var i = 0; i < preview.rows.length; i++)
                            if (preview.rows[i].importable) i,
                        ]);
                    }
                  }),
                  child: Text(_selected.length == importable ? '取消全选' : '全选'),
                ),
              ],
            ),
            if (preview.warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  preview.warnings.join('；'),
                  style: const TextStyle(color: Color(0xFF9A5A20)),
                ),
              ),
            SectionCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (
                    var index = 0;
                    index < preview.rows.length && index < 200;
                    index++
                  ) ...[
                    if (index > 0) const Divider(height: 1),
                    _previewTile(index, preview.rows[index]),
                  ],
                  if (preview.rows.length > 200)
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text('仅展示前 200 条，导入时仍会处理全部已选记录。'),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mappingCard() {
    final table = _table!;
    final mapping = _mapping!;
    const shown = [
      BillField.date,
      BillField.amount,
      BillField.direction,
      BillField.merchant,
      BillField.status,
      BillField.transactionType,
      BillField.account,
      BillField.orderId,
      BillField.refundAmount,
      BillField.refundDate,
      BillField.originalOrderId,
      BillField.category,
      BillField.note,
    ];
    return SectionCard(
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: _source == BillImportSource.spreadsheet,
        title: const Text('字段映射'),
        subtitle: Text('${table.sheetName} · 表头第 ${table.headerRow + 1} 行'),
        children: [
          for (final field in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DropdownButtonFormField<int?>(
                initialValue: mapping[field],
                decoration: InputDecoration(
                  labelText:
                      '${field.label}${field == BillField.date || field == BillField.amount ? ' *' : ''}',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('不导入')),
                  for (var i = 0; i < table.headers.length; i++)
                    DropdownMenuItem<int?>(
                      value: i,
                      child: Text(table.headers[i]),
                    ),
                ],
                onChanged: (value) => _remap(mapping.withColumn(field, value)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _defaultsCard(LedgerController state) {
    final expenses = state.categories
        .where((item) => item.type == TransactionType.expense)
        .toList();
    final incomes = state.categories
        .where((item) => item.type == TransactionType.income)
        .toList();
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入到', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _accountId,
            decoration: const InputDecoration(labelText: '账户', isDense: true),
            items: [
              for (final item in state.accounts)
                DropdownMenuItem(value: item.id, child: Text(item.displayName)),
            ],
            onChanged: (value) => setState(() => _accountId = value),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _expenseCategoryId,
                  decoration: const InputDecoration(
                    labelText: '默认支出分类',
                    isDense: true,
                  ),
                  items: [
                    for (final item in expenses)
                      DropdownMenuItem(value: item.id, child: Text(item.name)),
                  ],
                  onChanged: (value) =>
                      setState(() => _expenseCategoryId = value),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _incomeCategoryId,
                  decoration: const InputDecoration(
                    labelText: '默认收入分类',
                    isDense: true,
                  ),
                  items: [
                    for (final item in incomes)
                      DropdownMenuItem(value: item.id, child: Text(item.name)),
                  ],
                  onChanged: (value) =>
                      setState(() => _incomeCategoryId = value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewTile(int index, ImportedBillRow row) {
    final label = switch (row.kind) {
      ImportedBillKind.expense => '支出',
      ImportedBillKind.income => '收入',
      ImportedBillKind.refund => '退款',
      ImportedBillKind.skipped => '跳过',
    };
    final color = switch (row.kind) {
      ImportedBillKind.refund => const Color(0xFFB56533),
      ImportedBillKind.income => const Color(0xFF248B72),
      ImportedBillKind.skipped => Colors.grey,
      ImportedBillKind.expense => const Color(0xFF214F49),
    };
    return CheckboxListTile(
      dense: true,
      value: row.importable && _selected.contains(index),
      onChanged: row.importable
          ? (value) => setState(() {
              value == true ? _selected.add(index) : _selected.remove(index);
            })
          : null,
      title: Row(
        children: [
          Expanded(
            child: Text(
              row.merchant.isEmpty ? '$label账单' : row.merchant,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (row.amountMinor != null)
            Text(
              visibleMoney(context, row.amountMinor!),
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
        ],
      ),
      subtitle: Text(
        row.importable
            ? '第 ${row.rowNumber} 行 · $label · ${dateKey(row.occurredDate!)}'
            : '第 ${row.rowNumber} 行 · ${row.reason}',
      ),
      secondary: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: .1),
        child: Text(label.substring(0, 1), style: TextStyle(color: color)),
      ),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      isThreeLine: false,
      // Amount stays visible while merchant text truncates.
      titleAlignment: ListTileTitleAlignment.center,
    );
  }
}
