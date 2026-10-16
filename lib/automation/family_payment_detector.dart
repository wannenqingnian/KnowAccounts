import '../domain/family_payment.dart';

/// Detects only strong family-card markers after the ordinary payment parser
/// has already verified that the capture is a completed transaction.
class FamilyPaymentDetector {
  const FamilyPaymentDetector();

  FamilyPaymentDetection? detect({
    required String packageName,
    required String text,
    required bool completed,
  }) {
    if (!completed) return null;
    if (RegExp(r'支付宝小荷包').hasMatch(text)) return null;
    final roleHint = _detectRoleHint(text);
    final cardHint = _detectCardHint(text);
    if (packageName == FamilyCardPlatform.wechat.packageName) {
      final marker = RegExp(
        r'亲属卡(?:付款|支付|扣款|消费|代付|交易)?|(?:支付方式|付款方式|扣款方式)\s*[:：]?\s*亲属卡',
      ).firstMatch(text)?[0];
      return marker == null
          ? null
          : FamilyPaymentDetection(
              platform: FamilyCardPlatform.wechat,
              marker: marker,
              roleHint: roleHint,
              cardHint: cardHint,
            );
    }
    if (packageName == FamilyCardPlatform.alipay.packageName) {
      final marker = RegExp(
        r'亲情卡(?:付款|支付|扣款|消费|代付|交易)?|亲情号(?:支付|付款|代付|扣款|消费)|(?:支付方式|付款方式|交易方式)\s*[:：]?\s*(?:亲情卡|亲情号)',
      ).firstMatch(text)?[0];
      return marker == null
          ? null
          : FamilyPaymentDetection(
              platform: FamilyCardPlatform.alipay,
              marker: marker,
              roleHint: roleHint,
              cardHint: cardHint,
            );
    }
    final wechatMarker = RegExp(
      r'亲属卡(?:交易|付款|支付|扣款|消费|代付)|微信亲属卡(?:付款|支付|扣款|消费|代付)?|(?:微信|财付通).{0,20}?亲属卡(?:付款|支付|扣款|消费)?',
    ).firstMatch(text)?[0];
    if (wechatMarker != null) {
      return FamilyPaymentDetection(
        platform: FamilyCardPlatform.wechat,
        marker: wechatMarker,
        roleHint: roleHint,
        cardHint: cardHint,
      );
    }
    final alipayMarker = RegExp(
      r'支付宝亲情(?:卡|号)(?:付款|支付|扣款|消费|代付)?|亲情号(?:支付|付款|代付|扣款)',
    ).firstMatch(text)?[0];
    if (alipayMarker != null) {
      return FamilyPaymentDetection(
        platform: FamilyCardPlatform.alipay,
        marker: alipayMarker,
        roleHint: roleHint,
        cardHint: cardHint,
      );
    }
    return null;
  }

  FamilyLocalRole? _detectRoleHint(String text) {
    if (RegExp(
      r'代付扣款|亲属卡扣款通知|亲情卡扣款通知|为.{1,20}代付|对方使用亲属卡|对方使用亲情卡',
    ).hasMatch(text)) {
      return FamilyLocalRole.payer;
    }
    if (RegExp(r'由.{1,20}代付|使用.{1,20}的亲属卡|使用.{1,20}的亲情卡').hasMatch(text)) {
      return FamilyLocalRole.beneficiary;
    }
    return null;
  }

  String? _detectCardHint(String text) {
    final match = RegExp(
      r'(?:亲属卡|亲情卡|亲情号)\s*[（(]([^）)\n]{1,30})[）)]|([^\s，,。：:（(]{1,20})的(?:微信)?(?:亲属卡|亲情卡)',
    ).firstMatch(text);
    final hint = (match?[1] ?? match?[2])?.trim();
    if (hint == null ||
        hint.isEmpty ||
        const {'我', '本人', '自己', '微信', '支付宝'}.contains(hint)) {
      return null;
    }
    return hint;
  }
}
