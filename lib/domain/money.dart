import 'models.dart';

int parseMoney(String text) {
  return parseMinorUnits(text, 2);
}

int parseMinorUnits(String text, int decimals) {
  if (decimals < 0 || decimals > 4) {
    throw const LedgerException('币种小数位无效');
  }
  final value = text.trim();
  final pattern = decimals == 0
      ? RegExp(r'^\d{1,12}$')
      : RegExp('^\\d{1,12}(\\.\\d{1,$decimals})?\$');
  if (!pattern.hasMatch(value)) {
    throw LedgerException('请输入有效金额，最多$decimals位小数');
  }
  final parts = value.split('.');
  final scale = _pow10(decimals);
  final minor =
      int.parse(parts[0]) * scale +
      (parts.length == 2 ? int.parse(parts[1].padRight(decimals, '0')) : 0);
  if (minor <= 0) throw const LedgerException('金额必须大于 0');
  return minor;
}

int _pow10(int value) {
  var result = 1;
  for (var i = 0; i < value; i++) {
    result *= 10;
  }
  return result;
}

String currencyMoney(
  int minor, {
  required String symbol,
  required int decimals,
  bool showSymbol = true,
}) {
  final scale = _pow10(decimals);
  final sign = minor < 0 ? '-' : '';
  final absolute = minor.abs();
  final whole = (absolute ~/ scale).toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (match) => '${match[1]},',
  );
  final fraction = decimals == 0
      ? ''
      : '.${(absolute % scale).toString().padLeft(decimals, '0')}';
  return '$sign${showSymbol ? symbol : ''}$whole$fraction';
}

String money(int minor, {bool symbol = true}) {
  return currencyMoney(minor, symbol: '¥', decimals: 2, showSymbol: symbol);
}

String dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Stable local wall-clock representation used by transaction storage.
///
/// Older databases contain date-only values. [DateTime.parse] accepts both
/// forms, so storing new entries to second precision is backwards compatible.
String dateTimeKey(DateTime date) =>
    '${dateKey(date)}T${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';

String dateTimeLabel(DateTime date) => dateTimeKey(date).replaceFirst('T', ' ');
