import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/payment_quality.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

TransactionDraft draft({
  int? amount = 3850,
  String? account = 'wechat',
  String? category = 'food',
  String merchant = '瑞幸咖啡',
}) => TransactionDraft(
  raw: RawTransaction(text: '支付成功', capturedAt: DateTime(2026, 10, 20, 9)),
  ledgerId: 'personal',
  type: TransactionType.expense,
  amountMinor: amount,
  occurredDate: DateTime(2026, 10, 20),
  accountId: account,
  categoryId: category,
  merchant: merchant,
  warnings: const [],
  evidence: const {},
);

void main() {
  test('a fully agreeing capture scores 100', () {
    final quality = PaymentQuality.evaluate(
      recognized: draft(),
      saved: draft(),
    );
    expect(quality.score, 100);
    expect(quality.amountMatch, isTrue);
    expect(quality.categoryMatch, isTrue);
    expect(quality.accountMatch, isTrue);
    expect(quality.remarkSimilarity, 1);
    expect(quality.needsReview, isFalse);
  });

  test('corrected category and account keep the amount weight', () {
    final quality = PaymentQuality.evaluate(
      recognized: draft(),
      saved: draft(account: 'cmb', category: 'shopping'),
    );
    // Amount 0.3 of the 1.0 weight remains correct.
    expect(quality.score, 40);
    expect(quality.amountMatch, isTrue);
    expect(quality.categoryMatch, isFalse);
    expect(quality.accountMatch, isFalse);
    expect(quality.needsReview, isTrue);
    expect(quality.summary, contains('分类 被修正'));
  });

  test('sparse captures normalize over the dimensions they contain', () {
    final quality = PaymentQuality.evaluate(
      recognized: draft(account: null, category: null, merchant: ''),
      saved: draft(account: 'cmb', category: 'shopping'),
    );
    expect(quality.score, 100);
    expect(quality.dimensionCount, 1);
    expect(quality.categoryMatch, isNull);
  });

  test(
    'merchant similarity lowers the note dimension without hiding amount',
    () {
      final quality = PaymentQuality.evaluate(
        recognized: draft(merchant: '瑞幸咖啡'),
        saved: draft(merchant: '瑞幸咖啡（科技园店）'),
      );
      expect(quality.score, inInclusiveRange(90, 99));
      expect(quality.remarkSimilarity, greaterThan(0.3));
      expect(quality.remarkSimilarity, lessThan(1));
    },
  );

  test('trace fields contain only numeric metrics and round-trip', () {
    final quality = PaymentQuality.evaluate(
      recognized: draft(),
      saved: draft(category: 'shopping'),
    );
    final fields = quality.toTraceFields();
    expect(
      fields.keys,
      containsAll([
        'qualityScore',
        'amountMatch',
        'categoryMatch',
        'accountMatch',
        'remarkScore',
      ]),
    );
    expect(fields.values.join(), isNot(contains('瑞幸')));
    expect(fields.values.join(), isNot(contains('shopping')));
    final parsed = PaymentQuality.tryParse(fields)!;
    expect(parsed.score, quality.score);
    expect(parsed.categoryMatch, isFalse);
    expect(PaymentQuality.tryParse({'qualityScore': '101'}), isNull);
    expect(PaymentQuality.tryParse({'qualityScore': 'abc'}), isNull);
  });
}
