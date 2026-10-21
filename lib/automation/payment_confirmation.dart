import 'dart:convert';
import 'package:drift/drift.dart' show Variable;
import '../data/family_payment_repository.dart';
import '../data/ledger_repository.dart';
import '../domain/family_payment.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tags.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/refund_matcher.dart';
import 'payment_capture_parser.dart';
import 'payment_apps.dart';

String _compactMerchant(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

Future<bool> hasPossibleDuplicate(
  LedgerRepository repo, {
  required String ledgerId,
  required TransactionType type,
  required int amountMinor,
  required DateTime occurredDate,
  required String merchant,
  String? accountId,
}) async {
  final compactMerchant = _compactMerchant(merchant);
  if (amountMinor <= 0 || compactMerchant.isEmpty) return false;
  final account = accountId?.trim() ?? '';
  final rows = await repo.db
      .customSelect(
        'SELECT merchant FROM transactions WHERE ledger_id=? AND type=? AND amount_minor=? AND substr(occurred_date,1,10)=? AND deleted_at IS NULL${account.isEmpty ? '' : ' AND account_id=?'}',
        variables: [
          Variable<String>(ledgerId),
          Variable<String>(type.name),
          Variable<int>(amountMinor),
          Variable<String>(dateKey(occurredDate)),
          if (account.isNotEmpty) Variable<String>(account),
        ],
      )
      .get();
  return rows.any(
    (row) => _compactMerchant(row.read<String>('merchant')) == compactMerchant,
  );
}

/// Display only parsed fields; notification/page raw text stays in SQLite.
Future<Map<String, Object?>?> paymentPreview(
  LedgerRepository repo,
  PaymentCapture capture,
) async {
  final draftId = 'auto-${capture.id}';
  final targetLedger = await repo.draftLedger(draftId) ?? capture.ledgerId;
  final item = (await repo.pendingDrafts(
    targetLedger,
  )).where((d) => d.id == draftId).firstOrNull;
  if (item == null) return null;
  final accounts = await repo.accounts(targetLedger),
      categories = await repo.categories(targetLedger);
  final ledgers = await repo.ledgers();
  final accountsByLedger = <String, Object?>{};
  final categoriesByLedger = <String, Object?>{};
  for (final ledgerId in ledgers.keys) {
    accountsByLedger[ledgerId] = [
      {'id': '', 'name': '请选择账户'},
      for (final account in await repo.accounts(ledgerId))
        {'id': account.id, 'name': account.displayName},
    ];
    categoriesByLedger[ledgerId] = [
      for (final category in await repo.categories(ledgerId))
        {
          'id': category.id,
          'name': category.name,
          'type': category.type.name,
          if (category.parentId != null) 'parentId': category.parentId,
          'iconKey': category.iconKey,
        },
    ];
  }
  var parsed = TransactionParser().parse(
    item.raw,
    ledgerId: targetLedger,
    accounts: accounts,
    categories: categories,
  );
  parsed = await repo.applyAutoCorrectionRule(parsed);
  parsed = await RefundMatcher.resolve(repo, parsed);
  final warnings = {...item.storedWarnings, ...parsed.warnings};
  final duplicateAssessment = parsed.amountMinor == null
      ? null
      : await repo.assessDraftDuplicate(
          targetLedger,
          draftId,
          TransactionInput(
            type: parsed.type,
            amountMinor: parsed.amountMinor!,
            accountId: parsed.accountId ?? '',
            categoryId: parsed.categoryId,
            occurredDate: parsed.occurredDate,
            merchant: parsed.merchant,
          ),
        );
  final duplicate =
      warnings.any((warning) => warning.contains('疑似重复')) ||
      (duplicateAssessment?.possible ?? false);
  if (duplicate) {
    warnings.add(
      duplicateAssessment?.possible == true
          ? '疑似重复：${duplicateAssessment!.message}。请确认是合并证据还是仍要添加'
          : '疑似重复：已有相符账目，请确认是否仍要添加',
    );
  }
  return {
    'draftId': item.id,
    'ledgerId': targetLedger,
    'sourceLedgerId': item.ledgerId,
    'ledgers': [
      for (final entry in ledgers.entries)
        {'id': entry.key, 'name': entry.value},
    ],
    'accountsByLedger': accountsByLedger,
    'categoriesByLedger': categoriesByLedger,
    'appName': paymentCaptureSourceName(capture.packageName),
    'type': parsed.type.name,
    'amount': parsed.amountMinor == null
        ? ''
        : '${parsed.amountMinor! ~/ 100}.${(parsed.amountMinor! % 100).toString().padLeft(2, '0')}',
    'discountMinor': parsed.evidence['discount_minor'] ?? '',
    'merchant': parsed.merchant,
    'note': parsed.note,
    'date': dateTimeLabel(parsed.occurredDate),
    'accountId': item.familyRole == FamilyLocalRole.beneficiary
        ? null
        : parsed.accountId,
    'categoryId': parsed.categoryId,
    'relatedTransactionId': parsed.relatedTransactionId,
    if (item.familyEventId != null) 'familyEventId': item.familyEventId,
    if (item.familyRole != null) 'familyRole': item.familyRole!.name,
    'tags': parsed.tags.join(' '),
    'peer': warnings.any((w) => w.contains('核对收支方向')),
    'duplicate': duplicate,
    if (duplicateAssessment?.possible == true)
      'duplicateEvidence': duplicateAssessment!.message,
    'warning': warnings.take(5).join('\n'),
    if (item.confidence != null) 'confidence': item.confidence!.percent,
    if (item.confidence != null)
      'confidenceDecision': item.confidence!.decision.name,
    if (item.confidence != null)
      'confidenceReasons': item.confidence!.reasons.join('；'),
    'accounts': [
      {'id': '', 'name': '请选择账户'},
      for (final a in accounts) {'id': a.id, 'name': a.displayName},
    ],
    'categories': [
      for (final c in categories)
        {
          'id': c.id,
          'name': c.name,
          'type': c.type.name,
          if (c.parentId != null) 'parentId': c.parentId,
          'iconKey': c.iconKey,
        },
    ],
  };
}

class ConfirmationResult {
  const ConfirmationResult(
    this.ok, {
    this.message = '',
    this.duplicate = false,
  });
  final bool ok, duplicate;
  final String message;
}

/// Every action is user-confirmed. Source linking and postings commit atomically.
Future<ConfirmationResult> confirmPayment(
  LedgerRepository repo,
  Map data,
) async {
  try {
    final ledger = data['ledgerId'], id = data['draftId'];
    if (ledger is! String ||
        id is! String ||
        !RegExp(r'^auto-[a-f0-9]{64}$').hasMatch(id)) {
      throw const LedgerException('账单编号无效');
    }
    return await repo.db.transaction(() async {
      final rows = await repo.db
          .customSelect(
            'SELECT d.status,d.parsed_json,r.ledger_id FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE d.id=?',
            variables: [Variable<String>(id)],
          )
          .get();
      if (rows.isEmpty) throw const LedgerException('待确认账单不存在');
      if (rows.single.read<String>('status') != 'pending') {
        return const ConfirmationResult(true);
      }
      if (data['operation'] == 'ignore') {
        await repo.ignoreDraft(rows.single.read<String>('ledger_id'), id);
        return const ConfirmationResult(true);
      }
      if (data['operation'] != 'confirm') throw const LedgerException('操作无效');
      final familyEventId = data['familyEventId'] is String
          ? (data['familyEventId'] as String).trim()
          : '';
      final familyRole = FamilyLocalRole.values
          .where((r) => r.name == data['familyRole'])
          .firstOrNull;
      final sourceLedger = rows.single.read<String>('ledger_id');
      if (familyEventId.isNotEmpty && ledger != sourceLedger) {
        throw const LedgerException('亲情卡账单需在原账本中确认');
      }
      if (familyEventId.isNotEmpty &&
          familyRole == FamilyLocalRole.beneficiary) {
        final amount = parseMoney(
          data['amount'] is String ? data['amount'] : '',
        );
        final merchant = data['merchant'] is String
            ? (data['merchant'] as String).trim()
            : '';
        await FamilyPaymentRepository(repo.db).confirmFamilyEvent(
          ledgerId: ledger,
          eventId: familyEventId,
          localRole: FamilyLocalRole.beneficiary,
          amountMinor: amount,
          merchant: merchant,
          draftId: id,
        );
        return const ConfirmationResult(true);
      }
      final type = TransactionType.values
          .where((t) => t.name == data['type'])
          .firstOrNull;
      if (![
        TransactionType.expense,
        TransactionType.income,
        TransactionType.transfer,
        TransactionType.refund,
      ].contains(type)) {
        throw const LedgerException('请选择收支方向');
      }
      final dateText = data['date'] is String
          ? (data['date'] as String).trim()
          : '';
      final normalizedDate = dateText.replaceFirst(' ', 'T');
      final date = DateTime.tryParse(normalizedDate);
      if (date == null ||
          (dateKey(date) != dateText && dateTimeKey(date) != normalizedDate)) {
        throw const LedgerException('请输入有效日期时间YYYY-MM-DD HH:MM:SS');
      }
      final amount = parseMoney(data['amount'] is String ? data['amount'] : '');
      var storedDiscount = '';
      try {
        final decoded = jsonDecode(rows.single.read<String>('parsed_json'));
        final evidence = decoded is Map ? decoded['evidence'] : null;
        if (evidence is Map && evidence['discount_minor'] != null) {
          storedDiscount = '${evidence['discount_minor']}';
        }
      } catch (_) {
        // A corrupt legacy draft should still be confirmable; discount is extra.
      }
      final submittedDiscount = data['discountMinor'] is String
          ? (data['discountMinor'] as String).trim()
          : '';
      final discountMinor = type == TransactionType.expense
          ? int.tryParse(
              submittedDiscount.isNotEmpty ? submittedDiscount : storedDiscount,
            )
          : null;
      final account = data['accountId'] is String
          ? data['accountId'] as String
          : '';
      final merchant = data['merchant'] is String
          ? (data['merchant'] as String).trim()
          : '';
      final note = data['note'] is String ? data['note'] as String : '';
      final tags = parseTagInput(data['tags'] is String ? data['tags'] : '');
      if (merchant.length > 100 || note.length > 1000) {
        throw const LedgerException('商户或备注过长');
      }
      if (data['allowDuplicate'] != true) {
        final assessment = await repo.assessDraftDuplicate(
          ledger,
          id,
          TransactionInput(
            type: type!,
            amountMinor: amount,
            discountMinor: discountMinor,
            occurredDate: date,
            merchant: merchant,
            accountId: account,
          ),
        );
        if (assessment.possible) {
          return ConfirmationResult(
            false,
            message: '疑似重复：${assessment.message}。请核对已有流水；确为另一笔时勾选后再保存',
            duplicate: true,
          );
        }
      }
      var categoryId = data['categoryId'] is String
          ? (data['categoryId'] as String).trim()
          : '';
      final newCategoryName = data['newCategoryName'] is String
          ? (data['newCategoryName'] as String).trim()
          : '';
      if (type != TransactionType.transfer &&
          type != TransactionType.refund &&
          categoryId.isEmpty &&
          newCategoryName.isNotEmpty) {
        categoryId = await repo.addCategory(ledger, newCategoryName, type!);
      }
      await repo.confirmDraft(
        ledger,
        id,
        TransactionInput(
          type: type!,
          amountMinor: amount,
          discountMinor: discountMinor,
          accountId: account,
          occurredDate: date,
          categoryId: categoryId.isEmpty ? null : categoryId,
          targetAccountId: data['targetAccountId'] is String
              ? data['targetAccountId']
              : null,
          merchant: merchant,
          note: note,
          tags: tags,
          relatedTransactionId:
              type == TransactionType.refund &&
                  data['relatedTransactionId'] is String
              ? data['relatedTransactionId'] as String
              : null,
          reimbursable:
              type == TransactionType.expense && data['reimbursable'] == true,
        ),
        rememberChoice: data['rememberChoice'] == true,
      );
      return const ConfirmationResult(true);
    });
  } catch (error) {
    return ConfirmationResult(
      false,
      message: error is LedgerException ? error.message : '保存失败，请核对字段后重试',
    );
  }
}
