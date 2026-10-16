import '../transaction/parser/ocr_receipt_parser.dart';
import '../merchant/merchant_normalizer.dart';
import '../domain/banks.dart';

/// Compare independent layout passes. Missing fields can be supplemented;
/// inconsistent money is deliberately not resolved by a quality score.
String selectOcrText(List<String> input) {
  final texts = input.where((s) => s.trim().isNotEmpty).toSet().toList();
  if (texts.isEmpty) return '';
  if (texts.length == 1) return texts.single;
  final parser = OcrReceiptParser();
  final parsed = texts.map((s) => parser.parse(_normalize(s))).toList();
  var best = 0;
  for (var i = 1; i < texts.length; i++) {
    if ((parsed[i]?.quality ?? 0) > (parsed[best]?.quality ?? 0)) best = i;
  }
  final receipts = parsed.whereType<OcrReceipt>().toList();
  if (receipts.isEmpty) return texts.first;
  final base = parsed[best]!;
  final additions = <String>[];
  void field(
    String guard,
    String label,
    Set<String> values,
    String? baseValue,
  ) {
    if (values.length > 1) {
      additions.add('$guard：不一致');
    } else if (values.length == 1 && (baseValue == null || baseValue.isEmpty)) {
      additions.add('$label：${values.single}');
    }
  }

  final prices = receipts.where((r) => r.amountMinor != null).map((r) {
    final n = r.amountMinor!;
    return '${n ~/ 100}.${(n % 100).toString().padLeft(2, '0')}';
  }).toSet();
  field('金额校验', '实付金额', prices, base.amountMinor?.toString());
  field(
    '日期校验',
    '支付时间',
    receipts.map((r) => r.date).whereType<String>().toSet(),
    base.date,
  );
  String merchant(String s) {
    final known = MerchantNormalizer().find(s);
    return known.length == 1 ? known.single.name : s;
  }

  field(
    '商户校验',
    '商户名称',
    receipts
        .where((r) => r.merchant.isNotEmpty)
        .map((r) => merchant(r.merchant))
        .toSet(),
    base.merchant,
  );
  String account(String s) {
    s = s.replaceAll(RegExp(r'\s+'), '');
    for (final bank in bankTemplates) {
      if (s.contains(bank.name)) continue;
      final aliases = bank.aliases.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      final alias = aliases.where(s.contains).firstOrNull;
      if (alias != null) s = s.replaceAll(alias, bank.name);
    }
    return s;
  }

  field(
    '账户校验',
    '支付方式',
    receipts
        .where((r) => r.accountText.isNotEmpty)
        .map((r) => account(r.accountText))
        .toSet(),
    base.accountText,
  );
  if (receipts.map((r) => r.type).toSet().length > 1 ||
      receipts.any((r) => r.blocked)) {
    additions.add('交易校验：不一致');
  }
  final lines = texts[best].split('\n');
  final footer = lines.indexWhere(
    (s) => RegExp(
      r'^(?:账单服务|交易服务|商家小程序|对订单有疑惑|发起群收款|联系商家|申请电子凭证|查看往来记录)',
    ).hasMatch(s.trim()),
  );
  lines.insertAll(footer < 0 ? lines.length : footer, additions);
  return lines.join('\n');
}

String _normalize(String text) {
  text = String.fromCharCodes(
    text.runes.map((c) => c >= 0xff10 && c <= 0xff19 ? c - 0xff10 + 0x30 : c),
  );
  return text
      .replaceAll('．', '.')
      .replaceAll('，', ',')
      .replaceAll(RegExp(r'(?<=[\u3400-\u9fff])[ \t]+(?=[\u3400-\u9fff])'), '')
      .replaceAllMapped(RegExp(r'(\d)[ \t]+(?=[年月日:/.-])'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'([年月日:/.-])[ \t]+(?=\d)'), (m) => m[1]!);
}
