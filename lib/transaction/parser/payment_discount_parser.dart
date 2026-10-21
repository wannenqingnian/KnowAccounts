import 'chinese_number_parser.dart';

/// A discount shown on a payment result page.
///
/// The paid amount remains the transaction amount. This value is kept only as
/// extra receipt evidence so statistics and balances cannot accidentally use
/// the pre-discount price.
class PaymentDiscount {
  const PaymentDiscount(this.minor, this.source);

  final int minor;
  final String source;
}

class PaymentDiscountParser {
  const PaymentDiscountParser._();

  static final _explicit = RegExp(
    r'(?:已优惠|共优惠|优惠金额|优惠|立减|随机立减|碰一下支付立减|支付立减)[ \t]*[:：]?[ \t]*[¥￥]?[ \t]*(\d+(?:\.\d{1,2})?)[ \t]*(?:元)?(?=[ \t]*(?:$|[，,。；;）)\]]))',
    multiLine: true,
  );

  static final _fullReduction = RegExp(
    r'满[ \t]*\d+(?:\.\d{1,2})?[ \t]*减[ \t]*[¥￥]?[ \t]*(\d+(?:\.\d{1,2})?)[ \t]*(?:元)?(?=[ \t]*(?:$|[，,。；;）)\]]))',
    multiLine: true,
  );

  static final _gross = RegExp(
    r'(?:订单金额|商品金额|原价|原金额|总价|原支付金额)[ \t]*[:：]?[ \t]*[¥￥]?[ \t]*(\d+(?:\.\d{1,2})?)[ \t]*(?:元)?',
    multiLine: true,
  );

  /// Returns an explicit coupon/减立 amount first. If the page only exposes a
  /// gross amount and the paid amount, their difference is used as a fallback.
  static PaymentDiscount? parse(String text, {int? paidMinor}) {
    for (final pattern in [_explicit, _fullReduction]) {
      for (final match in pattern.allMatches(text)) {
        final value = _minor(match[1]);
        if (value != null && value > 0) {
          return PaymentDiscount(
            value,
            identical(pattern, _explicit) ? '优惠标签' : '满减标签',
          );
        }
      }
    }
    if (paidMinor == null || paidMinor <= 0) return null;
    for (final match in _gross.allMatches(text)) {
      final gross = _minor(match[1]);
      if (gross != null && gross > paidMinor) {
        return PaymentDiscount(gross - paidMinor, '订单金额减实付');
      }
    }
    return null;
  }

  static int? _minor(String? value) {
    if (value == null) return null;
    return ChineseNumberParser().parseMinor(value.replaceAll(',', ''));
  }
}
