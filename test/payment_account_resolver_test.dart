import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/payment_account_resolver.dart';

void main() {
  const resolver = PaymentAccountResolver();

  test('strong account name wins over a weak payment-app scene', () {
    const accounts = [
      Account(
        id: 'daily',
        name: '日常支付宝',
        kind: AccountKind.alipay,
        openingMinor: 0,
        balanceMinor: 0,
      ),
      Account(
        id: 'spare',
        name: '备用支付宝',
        kind: AccountKind.alipay,
        openingMinor: 0,
        balanceMinor: 0,
      ),
    ];
    final result = resolver.resolve(
      '日常支付宝',
      'com.eg.android.AlipayGphone',
      accounts,
    );
    expect(result.account?.id, 'daily');
    expect(result.reason, contains('账户名称'));
  });

  test('bank plus masked tail identifies one card and ties fail open', () {
    const accounts = [
      Account(
        id: 'first',
        name: '招商卡一',
        kind: AccountKind.bank,
        openingMinor: 0,
        balanceMinor: 0,
        bankId: 'cmb',
        cardLast4: '1111',
      ),
      Account(
        id: 'second',
        name: '招商卡二',
        kind: AccountKind.bank,
        openingMinor: 0,
        balanceMinor: 0,
        bankId: 'cmb',
        cardLast4: '2222',
      ),
    ];
    final unique = resolver.resolve(
      '招商银行储蓄卡****2222',
      'com.eg.android.AlipayGphone',
      accounts,
    );
    expect(unique.account?.id, 'second');
    expect(unique.reason, contains('银行与卡片尾号'));

    final tied = resolver.resolve('银行卡尾号2222', 'com.eg.android.AlipayGphone', [
      accounts.last,
      accounts.last.copyWithForTest(id: 'third'),
    ]);
    expect(tied.account, isNull);
    expect(tied.ambiguous, isTrue);
  });

  test('generic card wording does not invent a funding account', () {
    const accounts = [
      Account(
        id: 'bank',
        name: '工资卡',
        kind: AccountKind.bank,
        openingMinor: 0,
        balanceMinor: 0,
      ),
    ];
    final result = resolver.resolve(
      '银行卡',
      'com.eg.android.AlipayGphone',
      accounts,
    );
    expect(result.account, isNull);
    expect(result.ambiguous, isFalse);
  });

  test('generic payment-app wording does not pick a namesake account', () {
    const accounts = [
      Account(
        id: 'personal',
        name: '微信',
        kind: AccountKind.wechat,
        openingMinor: 0,
        balanceMinor: 0,
      ),
      Account(
        id: 'work',
        name: '工作微信',
        kind: AccountKind.wechat,
        openingMinor: 0,
        balanceMinor: 0,
      ),
    ];
    final result = resolver.resolve('微信消费38元', 'com.tencent.mm', accounts);
    expect(result.account, isNull);
    expect(result.ambiguous, isTrue);
  });

  test('specific credit platform never falls back to its parent wallet', () {
    const accounts = [
      Account(
        id: 'wallet',
        name: '支付宝',
        kind: AccountKind.alipay,
        openingMinor: 0,
        balanceMinor: 0,
      ),
    ];
    final result = resolver.resolve(
      '支付宝花呗',
      'com.eg.android.AlipayGphone',
      accounts,
    );
    expect(result.account, isNull);
    expect(result.ambiguous, isFalse);
  });
}

extension on Account {
  Account copyWithForTest({required String id}) => Account(
    id: id,
    name: name,
    kind: kind,
    openingMinor: openingMinor,
    balanceMinor: balanceMinor,
    bankId: bankId,
    cardLast4: cardLast4,
  );
}
