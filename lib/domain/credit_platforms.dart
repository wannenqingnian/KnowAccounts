import 'models.dart';

class CreditPlatform {
  const CreditPlatform(this.id, this.name, this.kind, this.aliases);
  final String id;
  final String name;
  final AccountKind kind;
  final List<String> aliases;
}

// Templates describe bookkeeping accounts, not API connections or approvals.
const creditPlatforms = [
  CreditPlatform('huabei', '花呗', AccountKind.creditPayment, ['花呗', '蚂蚁花呗']),
  CreditPlatform('baitiao', '京东白条', AccountKind.creditPayment, ['京东白条', '白条']),
  CreditPlatform('fenfu', '微信分付', AccountKind.creditPayment, ['微信分付', '分付']),
  CreditPlatform('douyin_monthly', '抖音月付', AccountKind.creditPayment, ['抖音月付']),
  CreditPlatform('meituan_monthly', '美团月付', AccountKind.creditPayment, [
    '美团月付',
  ]),
  CreditPlatform('zhaolian_credit', '招联信用付', AccountKind.creditPayment, [
    '招联信用付',
  ]),
  CreditPlatform('jiebei', '借呗', AccountKind.loan, ['借呗', '蚂蚁借呗']),
  CreditPlatform('jintiao', '京东金条', AccountKind.loan, ['京东金条', '金条']),
  CreditPlatform('weilidai', '微粒贷', AccountKind.loan, ['微粒贷']),
  CreditPlatform('youqianhua', '度小满有钱花', AccountKind.loan, [
    '度小满有钱花',
    '有钱花',
    '度小满',
  ]),
  CreditPlatform('haoqidai', '招联好期贷', AccountKind.loan, ['招联好期贷', '好期贷']),
  CreditPlatform('meituan_loan', '美团借钱', AccountKind.loan, ['美团借钱']),
  CreditPlatform('douyin_loan', '抖音放心借', AccountKind.loan, ['抖音放心借', '放心借']),
];

CreditPlatform? creditPlatform(String? id) =>
    creditPlatforms.where((p) => p.id == id).firstOrNull;
