import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:excel/excel.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/app_state.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/import/bill_import.dart';
import 'package:smart_ledger/main.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'WeChat export maps original payment and partial refund separately',
    () async {
      const csv = '''微信支付账单明细,,,,,,,,,,
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,退款金额(元),退款时间
2026-10-11 12:07:39,商户消费,南阳金冠智能开关有限公司,用户充值,支出,20.00,零钱,已退款,wx-order-1,merchant-1,12.93,2026-10-12 08:00:00
''';
      final table = BillFileParser.decode(
        Uint8List.fromList(utf8.encode(csv)),
        '微信支付账单.csv',
      );
      expect(table.detectedSource, BillImportSource.wechat);
      final preview = BillFileParser.mapRows(
        table,
        BillImportSource.wechat,
        BillFileParser.autoMapping(table),
      );
      expect(preview.rows.map((row) => row.kind), [
        ImportedBillKind.expense,
        ImportedBillKind.refund,
      ]);
      expect(preview.rows.map((row) => row.amountMinor), [2000, 1293]);
      expect(preview.rows.last.relatedOrderId, 'wx-order-1');
      expect(preview.rows.last.occurredDate, DateTime(2026, 10, 12, 8, 0, 0));

      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repository = LedgerRepository(db);
      await repository.initialize();
      final accounts = await repository.accounts('personal');
      final categories = await repository.categories('personal');
      final wechat = accounts.firstWhere(
        (item) => item.kind == AccountKind.wechat,
      );
      final expense = categories.firstWhere(
        (item) => item.type == TransactionType.expense,
      );
      final income = categories.firstWhere(
        (item) => item.type == TransactionType.income,
      );
      final importer = BillBatchImporter(repository);
      final result = await importer.import(
        'personal',
        preview.rows,
        accountId: wechat.id,
        expenseCategoryId: expense.id,
        incomeCategoryId: income.id,
        categories: categories,
      );
      expect(result.imported, 1);
      expect(result.refunds, 1);
      final entries = await repository.entries('personal');
      final original = entries.firstWhere(
        (item) => item.type == TransactionType.expense,
      );
      final refund = entries.firstWhere(
        (item) => item.type == TransactionType.refund,
      );
      expect(original.refundedMinor, 1293);
      expect(refund.relatedTransactionId, original.id);
      expect(
        (await repository.accounts(
          'personal',
        )).firstWhere((item) => item.id == wechat.id).balanceMinor,
        -707,
      );

      final repeated = await importer.import(
        'personal',
        preview.rows,
        accountId: wechat.id,
        expenseCategoryId: expense.id,
        incomeCategoryId: income.id,
        categories: categories,
      );
      expect(repeated.duplicates, 2);
      expect((await repository.entries('personal')).length, 2);
    },
  );

  test('Alipay GBK and UnionPay UTF-8 exports are detected', () {
    const alipay = '''支付宝交易记录明细查询,,,,,
交易创建时间,交易对方,收/支,金额（元）,交易状态,交易号
2026-10-10 08:00:00,早餐店,支出,8.50,交易成功,ali-1
''';
    final aliTable = BillFileParser.decode(
      Uint8List.fromList(gbk.encode(alipay)),
      'alipay.csv',
    );
    expect(aliTable.detectedSource, BillImportSource.alipay);
    expect(
      BillFileParser.mapRows(
        aliTable,
        BillImportSource.alipay,
        BillFileParser.autoMapping(aliTable),
      ).rows.single.amountMinor,
      850,
    );

    const unionPay = '''中国银联云闪付账单,,,,,
交易时间,交易类型,交易对方,资金流向,交易金额,交易状态
2026/10/09 09:30,消费,地铁,支出,2.00,成功
''';
    final unionTable = BillFileParser.decode(
      Uint8List.fromList(utf8.encode(unionPay)),
      'unionpay.csv',
    );
    expect(unionTable.detectedSource, BillImportSource.unionPay);
    expect(
      BillFileParser.mapRows(
        unionTable,
        BillImportSource.unionPay,
        BillFileParser.autoMapping(unionTable),
      ).rows.single.kind,
      ImportedBillKind.expense,
    );
  });

  test('Excel workbook uses the same editable mapping pipeline', () {
    final workbook = Excel.createExcel();
    final sheet = workbook['账单'];
    sheet.appendRow([
      TextCellValue('日期'),
      TextCellValue('金额'),
      TextCellValue('方向'),
      TextCellValue('商户'),
      TextCellValue('状态'),
    ]);
    sheet.appendRow([
      TextCellValue('2026-10-08'),
      TextCellValue('16.80'),
      TextCellValue('收入'),
      TextCellValue('测试收款'),
      TextCellValue('交易成功'),
    ]);
    final bytes = Uint8List.fromList(workbook.encode()!);
    final table = BillFileParser.decode(bytes, '账单.xlsx');
    final mapping = BillFileParser.autoMapping(table);
    final preview = BillFileParser.mapRows(
      table,
      BillImportSource.spreadsheet,
      mapping,
    );
    expect(preview.rows.single.kind, ImportedBillKind.income);
    expect(preview.rows.single.amountMinor, 1680);
  });

  testWidgets('management exposes dedicated bill import sources', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repository = LedgerRepository(db);
    await repository.initialize();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: const SmartLedgerApp(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('批量导入账单'));
    await tester.tap(find.text('批量导入账单'));
    await tester.pumpAndSettle();
    expect(find.text('支付宝账单'), findsOneWidget);
    expect(find.text('微信账单'), findsOneWidget);
    expect(find.text('云闪付账单'), findsOneWidget);
    expect(find.text('Excel / CSV'), findsOneWidget);
    expect(find.textContaining('文件只在本机解析'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
