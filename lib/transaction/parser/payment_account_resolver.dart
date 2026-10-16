import '../../domain/banks.dart';
import '../../domain/credit_platforms.dart';
import '../../domain/models.dart';

class PaymentAccountResolution {
  const PaymentAccountResolution({
    this.account,
    this.reason = '',
    this.ambiguous = false,
  });

  final Account? account;
  final String reason;
  final bool ambiguous;
}

class _Candidate {
  const _Candidate(this.account, this.score, this.reason);

  final Account account;
  final int score;
  final String reason;
}

/// Maps the payment-method text exposed by a source app to one ledger account.
///
/// Strong, user-controlled identifiers win over weak scene fallbacks. A tied
/// best score deliberately returns no account so the confirmation sheet can ask
/// the user instead of silently debiting the wrong card.
class PaymentAccountResolver {
  const PaymentAccountResolver();

  PaymentAccountResolution resolve(
    String method,
    String sourceApp,
    Iterable<Account> accounts,
  ) {
    final active = accounts.where((account) => !account.archived).toList();
    final text = method.trim();
    if (text.isEmpty || active.isEmpty) return const PaymentAccountResolution();
    final normalizedText = _normalize(text);
    final tails = RegExp(
      r'(?:尾号|末四位|末4位|[*xX]{2,}|[（(])\s*(\d{4})(?!\d)',
    ).allMatches(text).map((match) => match[1]!).toSet();
    final tail = tails.length == 1 ? tails.single : null;
    final banks = bankTemplates
        .where((bank) => bank.aliases.any(text.contains))
        .toList();
    final platform = creditPlatforms
        .where((item) => item.aliases.any(text.contains))
        .toList();
    final hasSpecificCreditPlatform = platform.isNotEmpty;
    final candidates = <_Candidate>[];

    for (final account in active) {
      final accountName = _normalize(account.name);
      final displayName = _normalize(account.displayName);
      final genericAccountName =
          _isGenericPaymentAccount(accountName) ||
          _isGenericPaymentAccount(displayName);
      void offer(int score, String reason) {
        candidates.add(_Candidate(account, score, reason));
      }

      if (!genericAccountName &&
          (normalizedText == accountName || normalizedText == displayName)) {
        offer(100, '付款方式与账户名称精确匹配');
      }
      if (platform.length == 1 &&
          (account.providerId == platform.single.id ||
              platform.single.aliases.any(account.name.contains))) {
        offer(95, '付款方式匹配信用账户');
      }
      final bankMatches =
          banks.length == 1 &&
          (account.bankId == banks.single.id ||
              banks.single.aliases.any(account.name.contains));
      if (bankMatches && tail != null && account.cardLast4 == tail) {
        offer(90, '银行与卡片尾号同时匹配');
      } else if (tail != null && account.cardLast4 == tail) {
        offer(85, '卡片尾号匹配');
      } else if (bankMatches &&
          (account.kind == AccountKind.bank ||
              account.kind == AccountKind.credit)) {
        offer(70, '银行名称匹配');
      }
      if (!genericAccountName &&
          accountName.length >= 2 &&
          normalizedText.contains(accountName)) {
        offer(75, '付款方式包含账户名称');
      }
      // Generic channel words apply the same weak score to every account of
      // that kind. One account may resolve; multiple accounts deliberately
      // tie. Voice/manual input has no source package, so do not require it.
      final scene =
          (account.kind == AccountKind.wechat &&
              RegExp(r'微信|零钱|零钱通').hasMatch(text)) ||
          (!hasSpecificCreditPlatform &&
              account.kind == AccountKind.alipay &&
              RegExp(r'支付宝|余额宝|余额').hasMatch(text));
      if (scene) offer(55, '支付场景匹配');
      if (account.kind == AccountKind.cash && RegExp(r'现金').hasMatch(text)) {
        offer(55, '现金账户匹配');
      }
    }

    if (candidates.isEmpty) return const PaymentAccountResolution();
    candidates.sort((left, right) => right.score.compareTo(left.score));
    final bestScore = candidates.first.score;
    final bestByAccount = <String, _Candidate>{};
    for (final candidate in candidates.where(
      (item) => item.score == bestScore,
    )) {
      bestByAccount[candidate.account.id] = candidate;
    }
    if (bestByAccount.length != 1) {
      return const PaymentAccountResolution(ambiguous: true);
    }
    final best = bestByAccount.values.single;
    return PaymentAccountResolution(account: best.account, reason: best.reason);
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('储蓄卡', '')
      .replaceAll('借记卡', '')
      .replaceAll('信用卡', '')
      .replaceAll('银行卡', '')
      .replaceAll(RegExp(r'尾号\s*\d{4}|[*xX]{2,}\s*\d{4}'), '')
      .replaceAll(RegExp(r'[^0-9a-z\u3400-\u9fff]'), '');

  bool _isGenericPaymentAccount(String value) => const {
    '微信',
    '微信支付',
    '微信零钱',
    '零钱',
    '零钱通',
    '支付宝',
    '支付宝余额',
    '余额',
    '余额宝',
  }.contains(value);
}
