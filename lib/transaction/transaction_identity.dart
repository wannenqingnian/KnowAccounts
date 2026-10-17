import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../domain/models.dart';
import 'auto_correction.dart';

/// Source channels participating in ordinary-transaction identity matching.
/// Values are persisted; do not rename without a migration.
enum TransactionEvidenceSource {
  notification,
  accessibility,
  ocr,
  speech,
  import,
  manual,
}

class TransactionIdentitySeed {
  const TransactionIdentitySeed({
    required this.source,
    this.sourceApp = '',
    this.captureId = '',
    this.orderId = '',
    this.rawTextForFingerprint = '',
    this.details = const {},
  });

  final TransactionEvidenceSource source;
  final String sourceApp;
  final String captureId;
  final String orderId;

  /// Used only to extract provider/order identity; never persisted verbatim.
  final String rawTextForFingerprint;
  final Map<String, String> details;
}

class TransactionFingerprint {
  const TransactionFingerprint({
    required this.semanticHash,
    required this.orderHash,
    required this.normalizedMerchant,
    required this.provider,
  });

  final String semanticHash;
  final String? orderHash;
  final String normalizedMerchant;
  final String provider;
}

class TransactionEvidenceView {
  const TransactionEvidenceView({
    required this.id,
    required this.source,
    required this.amountMinor,
    required this.merchant,
    required this.occurredAt,
    required this.accountId,
    required this.direction,
    required this.hasOrderNumber,
    this.sourceApp = '',
  });

  final String id;
  final TransactionEvidenceSource source;
  final int amountMinor;
  final String merchant;
  final DateTime occurredAt;
  final String? accountId;
  final TransactionType direction;
  final bool hasOrderNumber;
  final String sourceApp;

  String get sourceLabel => switch (source) {
    TransactionEvidenceSource.notification => '通知',
    TransactionEvidenceSource.accessibility => '无障碍',
    TransactionEvidenceSource.ocr => 'OCR',
    TransactionEvidenceSource.speech => '语音',
    TransactionEvidenceSource.import => 'CSV/Excel 导入',
    TransactionEvidenceSource.manual => '手动补账',
  };
}

class TransactionMergeCandidate {
  const TransactionMergeCandidate({
    required this.transaction,
    required this.matchedByOrder,
    required this.differences,
    required this.evidence,
  });

  final LedgerEntry transaction;
  final bool matchedByOrder;
  final List<String> differences;
  final List<TransactionEvidenceView> evidence;

  bool get hasConflict => differences.isNotEmpty;
}

class TransactionMergeUndo {
  const TransactionMergeUndo({
    required this.id,
    required this.targetTransactionId,
    required this.sourceTransactionId,
    required this.createdAt,
  });

  final String id;
  final String targetTransactionId;
  final String sourceTransactionId;
  final DateTime createdAt;
}

class TransactionDuplicateAssessment {
  const TransactionDuplicateAssessment({
    this.candidateTransactionId,
    this.matchedByOrder = false,
    this.differences = const [],
  });

  final String? candidateTransactionId;
  final bool matchedByOrder;
  final List<String> differences;
  bool get possible => candidateTransactionId != null;

  String get message {
    if (!possible) return '';
    final basis = matchedByOrder ? '订单号与已有账单一致' : '金额、商户、日期和方向相符';
    return differences.isEmpty ? basis : '$basis；证据差异：${differences.join('；')}';
  }
}

class UnifiedTransactionIdentity {
  static final _orderPattern = RegExp(
    r'(?:交易单号|支付单号|付款单号|收款单号|转账单号|商户单号|商家订单号|订单号|交易号|流水号)\s*[:：]?\s*([A-Za-z0-9_-]{8,80})',
  );

  static String extractOrderId(String text) =>
      _orderPattern.firstMatch(text)?.group(1)?.trim() ?? '';

  static String normalizeOrderId(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), '').toUpperCase();

  static String normalizeMerchant(String value) => normalizeMerchantPattern(
    value,
  ).replaceFirst(RegExp(r'^(?:微信支付|支付宝|财付通|云闪付|中国银联)'), '');

  static String providerFor(String sourceApp, String text) {
    final app = sourceApp.toLowerCase();
    if (app.contains('alipay') || text.contains('支付宝')) return 'alipay';
    if (app.contains('tencent.mm') || app == 'wechat' || text.contains('微信')) {
      return 'wechat';
    }
    if (app.contains('unionpay') ||
        text.contains('云闪付') ||
        text.contains('中国银联')) {
      return 'unionpay';
    }
    return 'generic';
  }

  static Future<TransactionFingerprint> build({
    required int amountMinor,
    required String merchant,
    required DateTime occurredAt,
    required String? accountId,
    required TransactionType direction,
    required String sourceApp,
    required String rawText,
    String explicitOrderId = '',
  }) async {
    final provider = providerFor(sourceApp, rawText);
    final orderId = normalizeOrderId(
      explicitOrderId.isEmpty ? extractOrderId(rawText) : explicitOrderId,
    );
    final orderHash = orderId.isEmpty
        ? null
        : await _hash('order-v1|$provider|$orderId');
    final normalizedMerchant = normalizeMerchant(merchant);
    // Five-minute bucketing makes notification/accessibility/OCR observations
    // stable without turning the amount into an identity by itself.
    final minuteBucket = occurredAt.millisecondsSinceEpoch ~/ 300000;
    final semantic =
        normalizedMerchant.isEmpty ||
            amountMinor <= 0 ||
            (accountId?.trim().isEmpty ?? true)
        ? ''
        : await _hash(
            'semantic-v1|${direction.name}|$amountMinor|$normalizedMerchant|'
            '${accountId!.trim()}|$minuteBucket',
          );
    return TransactionFingerprint(
      semanticHash: semantic,
      orderHash: orderHash,
      normalizedMerchant: normalizedMerchant,
      provider: provider,
    );
  }

  static Future<String> _hash(String value) async {
    final digest = await Sha256().hash(utf8.encode(value));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
