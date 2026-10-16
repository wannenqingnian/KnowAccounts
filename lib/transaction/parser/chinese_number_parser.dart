/// Parses money without floating point arithmetic. A null result means the
/// expression is unsupported; the caller must ask the user to enter the amount.
class ChineseNumberParser {
  static const _digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  static const _aliases = {
    '壹': '一',
    '贰': '二',
    '叁': '三',
    '肆': '四',
    '伍': '五',
    '陆': '六',
    '柒': '七',
    '捌': '八',
    '玖': '九',
    '拾': '十',
    '佰': '百',
    '仟': '千',
    '萬': '万',
    '圆': '元',
    '圓': '元',
  };

  int? parseMinor(String input) {
    var text = input.trim().replaceAll(RegExp(r'\s'), '');
    for (final entry in _aliases.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    text = text.replaceFirst(RegExp(r'^(人民币|RMB|CNY|[¥￥])'), '');
    text = text.replaceAll('块钱', '元').replaceAll('块', '元');
    text = text.replaceAll('毛', '角').replaceAll('点', '.');
    final split = text.split('元');
    if (split.length > 2) return null;
    int? minor;
    if (split.length == 2) {
      final whole = _whole(split[0]);
      if (whole == null) {
        // A decimal must end at the currency marker, e.g. 三十八点五元.
        if (split[1].isNotEmpty) return null;
        minor = _decimal(split[0]);
      } else {
        final fraction = _fraction(split[1]);
        if (fraction == null) return null;
        minor = whole * 100 + fraction;
      }
    } else if (text.contains('角') || text.contains('分')) {
      minor = _fraction(text);
    } else {
      minor = _decimal(text);
    }
    return minor != null && minor > 0 && minor <= 999999999999 ? minor : null;
  }

  int? _decimal(String text) {
    final parts = text.split('.');
    if (parts.length > 2) return null;
    final whole = _whole(parts.first);
    if (whole == null) return null;
    if (parts.length == 1) return whole * 100;
    final fraction = _digitString(parts[1]);
    if (fraction == null || fraction.isEmpty || fraction.length > 2) {
      return null;
    }
    return whole * 100 + int.parse(fraction.padRight(2, '0'));
  }

  int? _fraction(String text) {
    if (text.isEmpty) return 0;
    final plain = _digitString(text);
    if (plain != null && plain.isNotEmpty && plain.length <= 2) {
      return int.parse(plain.padRight(2, '0'));
    }
    final m = RegExp(
      r'^([0-9零〇一二两三四五六七八九])角(?:([0-9零〇一二两三四五六七八九])分?)?$',
    ).firstMatch(text);
    if (m != null) {
      return int.parse(_digitString(m[1]!)!) * 10 +
          (m[2] == null ? 0 : int.parse(_digitString(m[2]!)!));
    }
    final cents = RegExp(r'^([0-9零〇一二两三四五六七八九])分$').firstMatch(text);
    return cents == null ? null : int.parse(_digitString(cents[1]!)!);
  }

  String? _digitString(String text) {
    final result = StringBuffer();
    for (final c in text.split('')) {
      if (RegExp(r'^[0-9]$').hasMatch(c)) {
        result.write(c);
      } else if (_digits.containsKey(c)) {
        result.write(_digits[c]);
      } else {
        return null;
      }
    }
    return result.toString();
  }

  int? _whole(String text) {
    if (text.isEmpty) return null;
    if (RegExp(r'^\d{1,10}$').hasMatch(text)) return int.parse(text);
    if (RegExp(r'[0-9]').hasMatch(text)) return null;
    if (!text.contains(RegExp(r'[十百千万亿]'))) {
      final digits = _digitString(text);
      return digits == null || digits.isEmpty ? null : int.tryParse(digits);
    }
    var total = 0;
    var section = 0;
    int? digit;
    var lastSmall = 10000;
    var lastLarge = 1000000000;
    var lastUnit = 1;
    var zeroSinceUnit = false;
    for (final c in text.split('')) {
      if (_digits.containsKey(c)) {
        final d = _digits[c]!;
        if (d == 0) {
          if (digit != null && digit != 0) return null;
          zeroSinceUnit = true;
          digit = null;
        } else {
          if (digit != null) return null;
          digit = d;
        }
        continue;
      }
      final small = {'十': 10, '百': 100, '千': 1000}[c];
      if (small != null) {
        if (small >= lastSmall ||
            (digit == null && !(small == 10 && section == 0))) {
          return null;
        }
        section += (digit ?? 1) * small;
        lastSmall = small;
        lastUnit = small;
      } else {
        final large = {'万': 10000, '亿': 100000000}[c];
        if (large == null || large >= lastLarge) return null;
        final group = section + (digit ?? 0);
        if (group == 0) return null;
        total += group * large;
        section = 0;
        lastSmall = 10000;
        lastLarge = large;
        lastUnit = large;
      }
      digit = null;
      zeroSinceUnit = false;
    }
    // Colloquial shorthand: 两百八=280; 一千二=1200; 零 makes
    // the trailing digit literal, e.g. 三千零八=3008.
    final tail = digit == null
        ? 0
        : digit * (!zeroSinceUnit && lastUnit >= 100 ? lastUnit ~/ 10 : 1);
    return total + section + tail;
  }
}
