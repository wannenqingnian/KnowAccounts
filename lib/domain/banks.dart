class BankTemplate {
  const BankTemplate(this.id, this.name, this.aliases);
  final String id;
  final String name;
  final List<String> aliases;
}

const bankTemplates = [
  BankTemplate('icbc', '中国工商银行', ['中国工商银行', '工商银行', '工行']),
  BankTemplate('abc', '中国农业银行', ['中国农业银行', '农业银行', '农行']),
  BankTemplate('boc', '中国银行', ['中国银行', '中行']),
  BankTemplate('ccb', '中国建设银行', ['中国建设银行', '建设银行', '建行']),
  BankTemplate('bocom', '交通银行', ['交通银行', '交行']),
  BankTemplate('psbc', '中国邮政储蓄银行', ['邮政储蓄银行', '邮储银行', '邮储']),
  BankTemplate('cmb', '招商银行', ['招商银行', '招行']),
  BankTemplate('citic', '中信银行', ['中信银行']),
  BankTemplate('cib', '兴业银行', ['兴业银行']),
  BankTemplate('spdb', '浦发银行', ['浦发银行', '上海浦东发展银行']),
  BankTemplate('cmbc', '中国民生银行', ['中国民生银行', '民生银行']),
  BankTemplate('ceb', '中国光大银行', ['中国光大银行', '光大银行']),
  BankTemplate('pingan', '平安银行', ['平安银行']),
  BankTemplate('cgb', '广发银行', ['广发银行']),
  BankTemplate('hxb', '华夏银行', ['华夏银行']),
  BankTemplate('czbank', '浙商银行', ['浙商银行']),
  BankTemplate('bohai', '渤海银行', ['渤海银行']),
  BankTemplate('beijing', '北京银行', ['北京银行']),
  BankTemplate('shanghai', '上海银行', ['上海银行']),
  BankTemplate('ningbo', '宁波银行', ['宁波银行']),
  BankTemplate('jiangsu', '江苏银行', ['江苏银行']),
  BankTemplate('hangzhou', '杭州银行', ['杭州银行']),
];

BankTemplate? bankTemplate(String? id) =>
    bankTemplates.where((b) => b.id == id).firstOrNull;

String? cardTailFromInput(String text) {
  final digits = text.trim().replaceAll(RegExp(r'[\s-]'), '');
  if (digits.isEmpty) return null;
  if (!RegExp(r'^(\d{4}|\d{13,19})$').hasMatch(digits)) {
    throw const FormatException('请输入4位尾号或13～19位完整卡号');
  }
  return digits.substring(digits.length - 4);
}
