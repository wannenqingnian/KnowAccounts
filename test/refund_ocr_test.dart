import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/transaction/refund_matcher.dart';

const refundReceipt = '''金冠智充
-20.00
退款记录
已退款¥12.93
2026年10月11日 12:54:05
当前状态 已退款(¥12.93)
支付时间 2026年10月11日 12:07:39
商品 用户充值
商户全称 南阳金冠智能开关有限公司
收单机构 上海汇付支付有限公司
支付方式 零钱
交易单号 4500000483202610119870382192
商户单号 02212610114365344719916
账单服务''';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'OCR partial refund is conservatively linked to the original expense',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repository = LedgerRepository(db);
      await repository.initialize();
      final accounts = await repository.accounts('personal');
      final categories = await repository.categories('personal');
      final wechat = accounts.firstWhere(
        (item) => item.kind == AccountKind.wechat,
      );
      final category = categories.firstWhere(
        (item) => item.type == TransactionType.expense,
      );
      final originalId = await repository.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 2000,
          accountId: wechat.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 11),
          merchant: '南阳金冠智能开关有限公司',
        ),
      );

      final parsed = TransactionParser().parse(
        RawTransaction(
          text: refundReceipt,
          capturedAt: DateTime(2026, 10, 11, 13),
          source: TransactionSource.ocr,
        ),
        ledgerId: 'personal',
        accounts: accounts,
        categories: categories,
      );
      final linked = await RefundMatcher.resolve(repository, parsed);

      expect(linked.type, TransactionType.refund);
      expect(linked.amountMinor, 1293);
      expect(linked.relatedTransactionId, originalId);
      expect(linked.blocked, isFalse);
      expect(linked.note, contains('有退款'));
      expect(linked.note, contains('12.93元'));

      await repository.save(
        'personal',
        TransactionInput(
          type: linked.type,
          amountMinor: linked.amountMinor!,
          accountId: linked.accountId!,
          occurredDate: linked.occurredDate,
          merchant: linked.merchant,
          relatedTransactionId: linked.relatedTransactionId,
        ),
      );
      final entries = await repository.entries('personal');
      final original = entries.firstWhere((item) => item.id == originalId);
      final refund = entries.firstWhere(
        (item) => item.type == TransactionType.refund,
      );
      expect(original.refundedMinor, 1293);
      expect(refund.relatedTransactionId, originalId);
      expect(
        (await repository.summary('personal', DateTime(2026, 10))).expenseMinor,
        707,
      );
    },
  );

  test(
    'exact refund amount automatically matches original order with same amount',
    () async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repository = LedgerRepository(db);
      await repository.initialize();
      final accounts = await repository.accounts('personal');
      final categories = await repository.categories('personal');
      final wechat = accounts.firstWhere(
        (item) => item.kind == AccountKind.wechat,
      );
      final category = categories.firstWhere(
        (item) => item.type == TransactionType.expense,
      );
      final originalId = await repository.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 3500,
          accountId: wechat.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 10),
          merchant: '微信支付商家',
        ),
      );

      const refundText = '''微信支付
退款成功
退款金额 35.00元
退款时间 2026年10月11日 10:00:00
商户名称 微信支付商家''';

      final parsed = TransactionParser().parse(
        RawTransaction(
          text: refundText,
          capturedAt: DateTime(2026, 10, 11, 10),
          source: TransactionSource.ocr,
        ),
        ledgerId: 'personal',
        accounts: accounts,
        categories: categories,
      );
      expect(parsed.note, contains('有退款'));
      expect(parsed.note, contains('35.00元'));

      final linked = await RefundMatcher.resolve(repository, parsed);
      expect(linked.relatedTransactionId, originalId);
      expect(linked.blocked, isFalse);
      expect(linked.note, contains('有退款'));
      expect(linked.note, contains('35.00元'));
    },
  );

  test('app platform source is automatically filled into note for bills and refunds', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repository = LedgerRepository(db);
    await repository.initialize();
    final accounts = await repository.accounts('personal');
    final categories = await repository.categories('personal');

    final expenseDraft = TransactionParser().parse(
      RawTransaction(
        text: '美团外卖 支付成功 25.50元',
        capturedAt: DateTime.now(),
        sourceApp: 'com.sankuai.meituan',
      ),
      ledgerId: 'personal',
      accounts: accounts,
      categories: categories,
    );
    expect(expenseDraft.note, contains('来源: 美团'));

    final refundDraft = TransactionParser().parse(
      RawTransaction(
        text: '微信支付 退款成功 12.00元',
        capturedAt: DateTime.now(),
        sourceApp: 'com.tencent.mm',
      ),
      ledgerId: 'personal',
      accounts: accounts,
      categories: categories,
    );
    expect(refundDraft.note, contains('微信'));
    expect(refundDraft.note, contains('有退款'));
    expect(refundDraft.note, contains('12.00元'));
  });
}
