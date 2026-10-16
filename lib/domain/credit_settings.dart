import 'models.dart';
import 'credit_platforms.dart';
import 'banks.dart';

void validateBankSettings(AccountKind kind, String? bankId, String? cardLast4) {
  if ((bankId != null || cardLast4 != null) &&
      kind != AccountKind.bank &&
      kind != AccountKind.credit) {
    throw const LedgerException('只有银行卡或信用卡账户支持银行和尾号');
  }
  if (bankId != null && bankTemplate(bankId) == null) {
    throw const LedgerException('未知银行模板');
  }
  if (cardLast4 != null && !RegExp(r'^\d{4}$').hasMatch(cardLast4)) {
    throw const LedgerException('银行卡尾号必须为4位数字');
  }
}

void validateCreditSettings(
  AccountKind kind,
  String? providerId,
  int? day,
  DateTime? date,
) {
  if (providerId != null && creditPlatform(providerId)?.kind != kind) {
    throw const LedgerException('信用平台与账户类型不匹配');
  }
  if (!kind.isDebt && (day != null || date != null)) {
    throw const LedgerException('只有信用或贷款账户支持还款日期');
  }
  if (day != null && (day < 1 || day > 31)) {
    throw const LedgerException('每月还款日必须在 1～31 日之间');
  }
  if (date != null && (date.year < 1900 || date.year > 2100)) {
    throw const LedgerException('到期日期超出支持范围');
  }
}
