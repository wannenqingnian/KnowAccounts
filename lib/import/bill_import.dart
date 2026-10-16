import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:excel/excel.dart';
import 'package:fast_gbk/fast_gbk.dart';

import '../data/ledger_repository.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/refund_matcher.dart';
import '../transaction/transaction_identity.dart';
import '../transaction/transaction_pipeline.dart';

enum BillImportSource { alipay, wechat, unionPay, spreadsheet }

extension BillImportSourceLabel on BillImportSource {
  String get label => switch (this) {
    BillImportSource.alipay => '支付宝账单',
    BillImportSource.wechat => '微信账单',
    BillImportSource.unionPay => '云闪付账单',
    BillImportSource.spreadsheet => 'Excel / CSV',
  };

  String get key => switch (this) {
    BillImportSource.alipay => 'alipay',
    BillImportSource.wechat => 'wechat',
    BillImportSource.unionPay => 'unionpay',
    BillImportSource.spreadsheet => 'sheet',
  };
}

enum BillField {
  date,
  amount,
  direction,
  merchant,
  item,
  status,
  transactionType,
  account,
  orderId,
  merchantOrderId,
  refundAmount,
  refundDate,
  originalOrderId,
  category,
  note,
}

extension BillFieldLabel on BillField {
  String get label => switch (this) {
    BillField.date => '交易时间',
    BillField.amount => '交易金额',
    BillField.direction => '收支方向',
    BillField.merchant => '交易对方/商户',
    BillField.item => '商品说明',
    BillField.status => '交易状态',
    BillField.transactionType => '交易类型',
    BillField.account => '支付账户',
    BillField.orderId => '交易单号',
    BillField.merchantOrderId => '商户单号',
    BillField.refundAmount => '退款金额',
    BillField.refundDate => '退款时间',
    BillField.originalOrderId => '原交易单号',
    BillField.category => '分类',
    BillField.note => '备注',
  };
}

class BillTable {
  const BillTable({
    required this.headers,
    required this.rows,
    required this.headerRow,
    required this.detectedSource,
    required this.sheetName,
  });

  final List<String> headers;
  final List<List<String>> rows;
  final int headerRow;
  final BillImportSource? detectedSource;
  final String sheetName;
}

class BillMapping {
  const BillMapping(this.columns);

  final Map<BillField, int> columns;
  int? operator [](BillField field) => columns[field];

  BillMapping withColumn(BillField field, int? column) {
    final next = Map<BillField, int>.from(columns);
    if (column == null || column < 0) {
      next.remove(field);
    } else {
      next[field] = column;
    }
    return BillMapping(next);
  }
}

enum ImportedBillKind { expense, income, refund, skipped }

class ImportedBillRow {
  const ImportedBillRow({
    required this.rowNumber,
    required this.kind,
    required this.amountMinor,
    required this.occurredDate,
    required this.merchant,
    required this.source,
    this.orderId = '',
    this.relatedOrderId = '',
    this.accountText = '',
    this.categoryText = '',
    this.note = '',
    this.reason = '',
  });

  final int rowNumber;
  final ImportedBillKind kind;
  final int? amountMinor;
  final DateTime? occurredDate;
  final String merchant;
  final BillImportSource source;
  final String orderId, relatedOrderId, accountText, categoryText, note, reason;
  bool get importable =>
      kind != ImportedBillKind.skipped &&
      amountMinor != null &&
      amountMinor! > 0 &&
      occurredDate != null;
}

class BillImportPreview {
  const BillImportPreview(this.rows, this.warnings);
  final List<ImportedBillRow> rows;
  final List<String> warnings;
}

class BillImportResult {
  const BillImportResult({
    required this.imported,
    required this.refunds,
    required this.duplicates,
    required this.skipped,
    required this.unmatchedRefunds,
  });

  final int imported, refunds, duplicates, skipped, unmatchedRefunds;
}

class BillFileParser {
  static const _aliases = <BillField, List<String>>{
    BillField.date: [
      '交易时间',
      '交易创建时间',
      '付款时间',
      '支付时间',
      '入账时间',
      '订单时间',
      '记账时间',
      '日期',
    ],
    BillField.amount: ['金额(元)', '金额（元）', '交易金额', '订单金额', '收支金额', '金额', '实付金额'],
    BillField.direction: ['收/支', '收／支', '收支', '收支类型', '资金流向', '方向'],
    BillField.merchant: ['交易对方', '交易对象', '商户名称', '商家名称', '对方名称', '收款方'],
    BillField.item: ['商品名称', '商品说明', '商品', '交易说明', '用途'],
    BillField.status: ['当前状态', '交易状态', '订单状态', '状态'],
    BillField.transactionType: ['交易类型', '类型', '业务类型'],
    BillField.account: ['支付方式', '收/付款方式', '付款方式', '支付账户', '银行卡', '账户'],
    BillField.orderId: ['交易单号', '交易号', '订单号', '平台订单号', '流水号'],
    BillField.merchantOrderId: ['商户单号', '商家订单号', '商户订单号'],
    BillField.refundAmount: [
      '成功退款(元)',
      '成功退款（元）',
      '退款金额(元)',
      '退款金额（元）',
      '退款金额',
      '已退款金额',
    ],
    BillField.refundDate: ['退款时间', '退款成功时间', '退款到账时间', '退回时间'],
    BillField.originalOrderId: ['原交易单号', '原交易号', '原订单号', '关联交易号'],
    BillField.category: ['账单分类', '分类', '一级分类', '类别'],
    BillField.note: ['备注', '说明', '交易备注'],
  };

  static BillTable decode(Uint8List bytes, String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.xlsx')) return _xlsx(bytes);
    if (!lower.endsWith('.csv') && !lower.endsWith('.txt')) {
      throw const LedgerException('仅支持支付宝/微信/云闪付 CSV，以及 Excel .xlsx 文件');
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      try {
        text = gbk.decode(bytes);
      } on FormatException {
        throw const LedgerException('账单文本编码无法识别，请导出 UTF-8 或 GBK 格式');
      }
    }
    text = text.replaceFirst('\ufeff', '');
    final rows = _csv(text);
    return _table(rows, sheetName: 'CSV', rawHint: text);
  }

  static BillMapping autoMapping(BillTable table) {
    final result = <BillField, int>{};
    for (var index = 0; index < table.headers.length; index++) {
      final header = _header(table.headers[index]);
      for (final entry in _aliases.entries) {
        if (result.containsKey(entry.key)) continue;
        if (entry.value.any((alias) => _header(alias) == header)) {
          result[entry.key] = index;
        }
      }
    }
    return BillMapping(result);
  }

  static BillImportPreview mapRows(
    BillTable table,
    BillImportSource source,
    BillMapping mapping,
  ) {
    if (mapping[BillField.date] == null || mapping[BillField.amount] == null) {
      throw const LedgerException('请至少映射交易时间和交易金额');
    }
    final output = <ImportedBillRow>[];
    final warnings = <String>[];
    for (var index = 0; index < table.rows.length; index++) {
      final row = table.rows[index];
      String value(BillField field) {
        final column = mapping[field];
        return column == null || column >= row.length ? '' : row[column].trim();
      }

      final amount = _money(value(BillField.amount));
      final date = _date(value(BillField.date));
      final direction = value(BillField.direction);
      final status = value(BillField.status);
      final transactionType = value(BillField.transactionType);
      final combined = '$direction $status $transactionType';
      final merchant = value(BillField.merchant).isNotEmpty
          ? value(BillField.merchant)
          : value(BillField.item);
      final orderId = value(BillField.orderId).isNotEmpty
          ? value(BillField.orderId)
          : value(BillField.merchantOrderId);
      final originalOrder = value(BillField.originalOrderId);
      final refundAmount = _money(value(BillField.refundAmount));
      final refundDate = _date(value(BillField.refundDate));
      final rowNumber = table.headerRow + index + 2;
      final common = (
        account: value(BillField.account),
        category: value(BillField.category),
        note: value(BillField.note),
      );

      if (amount == null || date == null) {
        output.add(
          ImportedBillRow(
            rowNumber: rowNumber,
            kind: ImportedBillKind.skipped,
            amountMinor: amount,
            occurredDate: date,
            merchant: merchant,
            source: source,
            orderId: orderId,
            reason: amount == null ? '金额无法识别' : '日期无法识别',
          ),
        );
        continue;
      }
      if (RegExp(r'交易关闭|订单关闭|已关闭|失败|待付款|待支付|已取消|已撤销').hasMatch(combined)) {
        output.add(
          ImportedBillRow(
            rowNumber: rowNumber,
            kind: ImportedBillKind.skipped,
            amountMinor: amount,
            occurredDate: date,
            merchant: merchant,
            source: source,
            orderId: orderId,
            reason: '未完成或已关闭交易',
          ),
        );
        continue;
      }
      if (RegExp(r'不计收支|中性|内部转账|账户互转').hasMatch(combined)) {
        output.add(
          ImportedBillRow(
            rowNumber: rowNumber,
            kind: ImportedBillKind.skipped,
            amountMinor: amount,
            occurredDate: date,
            merchant: merchant,
            source: source,
            orderId: orderId,
            reason: '不计收支或内部转账',
          ),
        );
        continue;
      }

      final standaloneRefund =
          RegExp(r'退款|退回').hasMatch(transactionType) ||
          RegExp(r'^退款$|^退回$').hasMatch(direction);
      final refundedStatus = RegExp(
        r'退款成功|已退款|全额退款|退款处理完成|已退回',
      ).hasMatch(status);
      final income = RegExp(r'收入|收款|入账|转入|\+$').hasMatch(direction);
      if (!standaloneRefund) {
        output.add(
          ImportedBillRow(
            rowNumber: rowNumber,
            kind: income ? ImportedBillKind.income : ImportedBillKind.expense,
            amountMinor: amount,
            occurredDate: date,
            merchant: merchant,
            source: source,
            orderId: orderId,
            accountText: common.account,
            categoryText: common.category,
            note: common.note,
          ),
        );
      }
      if (standaloneRefund || refundedStatus || refundAmount != null) {
        final refund = refundAmount ?? amount;
        if (!standaloneRefund && refundDate == null) {
          warnings.add('第 $rowNumber 行含退款金额但无退款时间，暂按交易时间导入');
        }
        output.add(
          ImportedBillRow(
            rowNumber: rowNumber,
            kind: ImportedBillKind.refund,
            amountMinor: refund,
            occurredDate: standaloneRefund ? date : refundDate ?? date,
            merchant: merchant,
            source: source,
            orderId: standaloneRefund ? orderId : '$orderId-refund-$refund',
            relatedOrderId: originalOrder.isNotEmpty ? originalOrder : orderId,
            accountText: common.account,
            note: common.note,
          ),
        );
      }
    }
    if (output.where((row) => row.importable).isEmpty) {
      warnings.add('没有可导入的已完成交易，请检查列映射');
    }
    final refunds = output
        .where((row) => row.kind == ImportedBillKind.refund)
        .length;
    if (refunds > 0) warnings.add('已识别 $refunds 条退款，导入时会关联原消费');
    return BillImportPreview(output, warnings);
  }

  static BillTable _xlsx(Uint8List bytes) {
    Excel book;
    try {
      book = Excel.decodeBytes(bytes);
    } catch (_) {
      throw const LedgerException('Excel 文件损坏或不是 .xlsx 格式');
    }
    BillTable? best;
    var bestScore = -1;
    for (final entry in book.tables.entries) {
      final rows = entry.value.rows
          .map(
            (row) => row
                .map((cell) => cell?.value?.toString().trim() ?? '')
                .toList(),
          )
          .toList();
      if (rows.isEmpty) continue;
      final table = _table(
        rows,
        sheetName: entry.key,
        rawHint: rows.take(8).join('\n'),
      );
      final score = autoMapping(table).columns.length;
      if (score > bestScore) {
        best = table;
        bestScore = score;
      }
    }
    if (best == null) throw const LedgerException('Excel 中没有可读取的工作表');
    return best;
  }

  static BillTable _table(
    List<List<String>> source, {
    required String sheetName,
    required String rawHint,
  }) {
    if (source.isEmpty) throw const LedgerException('账单文件为空');
    var header = 0, score = -1;
    for (var i = 0; i < source.length && i < 80; i++) {
      final rowScore = source[i].where((cell) {
        final normalized = _header(cell);
        return _aliases.values
            .expand((values) => values)
            .any((alias) => _header(alias) == normalized);
      }).length;
      if (rowScore > score) {
        header = i;
        score = rowScore;
      }
    }
    if (score < 2) throw const LedgerException('未找到表头，请选择 Excel/CSV 后手动检查文件格式');
    final headers = source[header];
    final rows = source
        .skip(header + 1)
        .where((row) => row.any((cell) => cell.trim().isNotEmpty))
        .map(
          (row) => [
            ...row,
            ...List.filled(
              (headers.length - row.length).clamp(0, headers.length),
              '',
            ),
          ],
        )
        .toList();
    final hint = '${source.take(header + 2).join('\n')}\n$rawHint';
    final detected = RegExp(r'支付宝|ALIPAY', caseSensitive: false).hasMatch(hint)
        ? BillImportSource.alipay
        : RegExp(r'微信支付|微信账单').hasMatch(hint)
        ? BillImportSource.wechat
        : RegExp(r'云闪付|中国银联|UNIONPAY', caseSensitive: false).hasMatch(hint)
        ? BillImportSource.unionPay
        : null;
    return BillTable(
      headers: headers,
      rows: rows,
      headerRow: header,
      detectedSource: detected,
      sheetName: sheetName,
    );
  }

  static List<List<String>> _csv(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final sample = lines
        .where((line) => line.trim().isNotEmpty)
        .take(40)
        .join('\n');
    final delimiter = [',', '\t', ';']
        .map(
          (value) =>
              (value, RegExp(RegExp.escape(value)).allMatches(sample).length),
        )
        .reduce((left, right) => right.$2 > left.$2 ? right : left)
        .$1;
    final rows = <List<String>>[];
    var row = <String>[], field = StringBuffer(), quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '"') {
        if (quoted && i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (!quoted && char == delimiter) {
        row.add(field.toString());
        field = StringBuffer();
      } else if (!quoted && (char == '\n' || char == '\r')) {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field = StringBuffer();
        rows.add(row);
        row = <String>[];
      } else {
        field.write(char);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  static String _header(String value) => value
      .replaceAll('\ufeff', '')
      .replaceAll(RegExp(r'[\s:：/／()（）_\-]'), '')
      .toLowerCase();

  static int? _money(String value) {
    final match = RegExp(
      r'[+\-−－–—]?\s*[¥￥]?\s*(\d[\d,]*)(?:\.(\d{1,2}))?',
    ).firstMatch(value);
    if (match == null) return null;
    final whole = int.tryParse(match[1]!.replaceAll(',', ''));
    if (whole == null) return null;
    final minor =
        whole * 100 +
        int.parse(
          (match[2] ?? '').padRight(2, '0').isEmpty
              ? '0'
              : (match[2] ?? '').padRight(2, '0'),
        );
    return minor > 0 ? minor : null;
  }

  static DateTime? _date(String value) {
    final iso = DateTime.tryParse(value.trim());
    if (iso != null) return iso;
    final match = RegExp(
      r'(20\d{2})[年./-](\d{1,2})[月./-](\d{1,2})',
    ).firstMatch(value);
    if (match == null) return null;
    final year = int.parse(match[1]!),
        month = int.parse(match[2]!),
        day = int.parse(match[3]!);
    final result = DateTime(year, month, day);
    return result.year == year && result.month == month && result.day == day
        ? result
        : null;
  }
}

class BillBatchImporter {
  const BillBatchImporter(this.repository);
  final LedgerRepository repository;

  Future<BillImportResult> import(
    String ledgerId,
    Iterable<ImportedBillRow> selected, {
    required String accountId,
    required String expenseCategoryId,
    required String incomeCategoryId,
    required List<Category> categories,
  }) async {
    var imported = 0, refunds = 0, duplicates = 0, skipped = 0, unmatched = 0;
    final rows = selected.where((row) => row.importable).toList()
      ..sort((a, b) {
        if (a.kind == ImportedBillKind.refund &&
            b.kind != ImportedBillKind.refund) {
          return 1;
        }
        if (a.kind != ImportedBillKind.refund &&
            b.kind == ImportedBillKind.refund) {
          return -1;
        }
        return a.occurredDate!.compareTo(b.occurredDate!);
      });
    final importedOrders = <String, String>{};
    for (final row in rows) {
      final marker = _marker(row);
      if (await _hasMarker(ledgerId, marker)) {
        duplicates++;
        continue;
      }
      if (row.kind == ImportedBillKind.refund) {
        final original =
            importedOrders['${row.source.key}:${row.relatedOrderId}'] ??
            await _originalFor(ledgerId, row, accountId);
        if (original == null) {
          unmatched++;
          continue;
        }
        try {
          await repository.submitStructuredTransaction(
            ledgerId,
            TransactionInput(
              type: TransactionType.refund,
              amountMinor: row.amountMinor!,
              accountId: accountId,
              occurredDate: row.occurredDate!,
              merchant: row.merchant,
              note: _note(row, marker),
              relatedTransactionId: original,
            ),
            identitySeed: TransactionIdentitySeed(
              source: TransactionEvidenceSource.import,
              sourceApp: row.source.key,
              captureId: marker,
              orderId: row.orderId,
              details: {
                '入口': row.source == BillImportSource.spreadsheet
                    ? 'Excel/CSV 批量导入'
                    : '${row.source.label}批量导入',
                '导入来源': row.source.label,
                if (row.relatedOrderId.isNotEmpty) '关联原订单': '已取得原订单号证据',
              },
            ),
            applyCorrection: false,
          );
          refunds++;
        } on PossibleDuplicateTransactionException {
          duplicates++;
        } on LedgerException {
          skipped++;
        }
        continue;
      }
      final type = row.kind == ImportedBillKind.income
          ? TransactionType.income
          : TransactionType.expense;
      final matchedCategory = categories
          .where(
            (category) =>
                category.type == type &&
                row.categoryText.trim().isNotEmpty &&
                category.name.trim() == row.categoryText.trim(),
          )
          .firstOrNull;
      final categoryId =
          matchedCategory?.id ??
          (type == TransactionType.income
              ? incomeCategoryId
              : expenseCategoryId);
      try {
        final result = await repository.submitStructuredTransaction(
          ledgerId,
          TransactionInput(
            type: type,
            amountMinor: row.amountMinor!,
            accountId: accountId,
            categoryId: categoryId,
            occurredDate: row.occurredDate!,
            merchant: row.merchant,
            note: _note(row, marker),
          ),
          identitySeed: TransactionIdentitySeed(
            source: TransactionEvidenceSource.import,
            sourceApp: row.source.key,
            captureId: marker,
            orderId: row.orderId,
            details: {
              '入口': row.source == BillImportSource.spreadsheet
                  ? 'Excel/CSV 批量导入'
                  : '${row.source.label}批量导入',
              '导入来源': row.source.label,
              if (row.accountText.isNotEmpty) '原账户': row.accountText,
              if (row.categoryText.isNotEmpty) '原分类': row.categoryText,
            },
          ),
        );
        if (row.orderId.isNotEmpty) {
          importedOrders['${row.source.key}:${row.orderId}'] =
              result.transactionId;
        }
        imported++;
      } on PossibleDuplicateTransactionException {
        duplicates++;
      } on LedgerException {
        skipped++;
      }
    }
    return BillImportResult(
      imported: imported,
      refunds: refunds,
      duplicates: duplicates,
      skipped: skipped,
      unmatchedRefunds: unmatched,
    );
  }

  Future<bool> _hasMarker(String ledgerId, String marker) async {
    final rows = await repository.db
        .customSelect(
          'SELECT id FROM transactions WHERE ledger_id=? AND note LIKE ? AND deleted_at IS NULL LIMIT 1',
          variables: [
            Variable<String>(ledgerId),
            Variable<String>('%$marker%'),
          ],
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<String?> _originalFor(
    String ledgerId,
    ImportedBillRow row,
    String accountId,
  ) async {
    if (row.relatedOrderId.isNotEmpty) {
      final marker = '[#账单:${row.source.key}:${_safe(row.relatedOrderId)}:';
      final rows = await repository.db
          .customSelect(
            "SELECT id FROM transactions WHERE ledger_id=? AND type='expense' AND note LIKE ? AND deleted_at IS NULL ORDER BY created_at LIMIT 2",
            variables: [
              Variable<String>(ledgerId),
              Variable<String>('%$marker%'),
            ],
          )
          .get();
      if (rows.length == 1) return rows.single.read<String>('id');
    }
    final draft = TransactionDraft(
      raw: RawTransaction(
        text: '退款成功\n退款金额 ${money(row.amountMinor!, symbol: false)}元',
        capturedAt: row.occurredDate!,
        source: TransactionSource.import,
      ),
      ledgerId: ledgerId,
      type: TransactionType.refund,
      amountMinor: row.amountMinor,
      occurredDate: row.occurredDate!,
      accountId: accountId,
      merchant: row.merchant,
      warnings: const [],
      evidence: const {},
      blocked: true,
    );
    final matches = RefundMatcher.candidates(
      draft,
      await repository.entries(ledgerId),
    );
    return matches.length == 1 ? matches.single.id : null;
  }

  String _marker(ImportedBillRow row) =>
      '[#账单:${row.source.key}:${_safe(row.orderId.isEmpty ? '${dateKey(row.occurredDate!)}-${row.amountMinor}-${row.merchant}' : row.orderId)}:${row.kind.name}]';

  String _note(ImportedBillRow row, String marker) => [
    marker,
    if (row.accountText.isNotEmpty) '原账户：${row.accountText}',
    if (row.note.isNotEmpty) row.note,
  ].join(' · ');

  String _safe(String value) => value
      .replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '')
      .substring(
        0,
        value.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '').length.clamp(0, 80),
      );
}
