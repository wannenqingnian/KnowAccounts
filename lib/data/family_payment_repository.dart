import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:uuid/uuid.dart';
import '../core/database/app_database.dart';
import '../core/security/source_privacy.dart';
import '../domain/family_payment.dart';
import '../transaction/confidence/confidence_engine.dart';
import '../domain/models.dart';
import '../transaction/auto_correction.dart';
import '../transaction/parser/payment_account_resolver.dart';
import 'ledger_repository.dart';

class FamilyPaymentRepository {
  FamilyPaymentRepository(this.db);
  final AppDatabase db;
  static const _uuid = Uuid();

  static const Set<String> _allowedSourceKinds = {
    'notification',
    'accessibility',
    'ocr',
    'bankNotice',
  };

  /// Maps capture/input source kinds into the schema-supported enum values.
  /// Returns `null` (fail-closed) for unrecognized source kinds so callers
  /// never trigger a SQLite CHECK constraint rollback.
  static String? normalizeSourceKind(
    String sourceKind, {
    String sourcePackage = '',
  }) {
    final trimmed = sourceKind.trim();
    if (trimmed == 'screenshot' || trimmed == 'ocr') return 'ocr';
    if (trimmed == 'bankNotice' ||
        trimmed == 'bank_notice' ||
        trimmed == 'bank' ||
        trimmed == 'sms') {
      return 'bankNotice';
    }
    if (trimmed == 'accessibility') return 'accessibility';
    if (trimmed == 'notification') {
      final pkg = sourcePackage.trim();
      if (pkg.isNotEmpty &&
          pkg != FamilyCardPlatform.wechat.packageName &&
          pkg != FamilyCardPlatform.alipay.packageName &&
          pkg != 'com.smartledger.capture.ocr') {
        return 'bankNotice';
      }
      return 'notification';
    }
    return _allowedSourceKinds.contains(trimmed) ? trimmed : null;
  }

  /// Compatibility entry point for the family-card 0-100 column. The policy
  /// is owned by [ConfidenceEngine] so source weights cannot drift again.
  static int computeEvidenceConfidence({
    required String sourceKind,
    required bool hasOrderHash,
    required int? amountMinor,
    required String merchant,
    required bool hasCardOrAccount,
    bool hasConflict = false,
  }) {
    return ConfidenceEngine.evidenceScore(
      sourceKind: sourceKind,
      hasOrderHash: hasOrderHash,
      amountMinor: amountMinor,
      merchant: merchant,
      hasCardOrAccount: hasCardOrAccount,
      hasConflict: hasConflict,
    );
  }

  Future<List<FamilyCardAccountSummary>> cards(
    String ledgerId, {
    bool includeArchived = false,
    DateTime? month,
  }) async {
    final selected = month ?? DateTime.now();
    final start = DateTime(selected.year, selected.month).toIso8601String();
    final end = DateTime(selected.year, selected.month + 1).toIso8601String();
    final rows = await db
        .customSelect(
          '''SELECT c.*,
      COALESCE(SUM(CASE WHEN e.status IN ('observed','needsReview','confirmed','refunded')
        AND e.occurred_at>=? AND e.occurred_at<?
        THEN e.amount_minor-e.refunded_minor ELSE 0 END),0) AS used_minor,
      COALESCE(SUM(CASE WHEN e.status='needsReview'
        AND e.occurred_at>=? AND e.occurred_at<?
        THEN 1 ELSE 0 END),0) AS pending_count,
      (SELECT COALESCE(SUM(u.amount_minor-u.refunded_minor),0)
        FROM family_payment_events u
        WHERE u.ledger_id=c.ledger_id AND u.platform=c.platform AND u.card_id IS NULL
          AND u.status IN ('observed','needsReview','confirmed','refunded')
          AND u.occurred_at>=? AND u.occurred_at<?) AS unassigned_used_minor,
      (SELECT COUNT(*)
        FROM family_payment_events u
        WHERE u.ledger_id=c.ledger_id AND u.platform=c.platform AND u.card_id IS NULL
          AND u.status='needsReview'
          AND u.occurred_at>=? AND u.occurred_at<?) AS unassigned_pending_count
      FROM family_cards c LEFT JOIN family_payment_events e ON e.card_id=c.id
      WHERE c.ledger_id=? ${includeArchived ? '' : 'AND c.archived_at IS NULL'}
      GROUP BY c.id ORDER BY c.created_at,c.rowid''',
          variables: [
            Variable<String>(start),
            Variable<String>(end),
            Variable<String>(start),
            Variable<String>(end),
            Variable<String>(start),
            Variable<String>(end),
            Variable<String>(start),
            Variable<String>(end),
            Variable<String>(ledgerId),
          ],
        )
        .get();
    return rows.map((row) {
      final card = _cardFromRow(row);
      return FamilyCardAccountSummary(
        card: card,
        usedMinor: row.read('used_minor'),
        pendingCount: row.read('pending_count'),
        unassignedUsedMinor: row.read('unassigned_used_minor'),
        unassignedPendingCount: row.read('unassigned_pending_count'),
      );
    }).toList();
  }

  FamilyCardAccount _cardFromRow(QueryRow row) => FamilyCardAccount(
    id: row.read('id'),
    ledgerId: row.read('ledger_id'),
    platform: FamilyCardPlatform.values.byName(row.read('platform')),
    displayName: row.read('display_name'),
    localRole: FamilyLocalRole.values.byName(row.read('local_role')),
    payerLabel: row.read('payer_label'),
    beneficiaryLabel: row.read('beneficiary_label'),
    senderLimitMinor: row.read('sender_limit_minor'),
    userLimitMinor: row.read('user_limit_minor'),
    defaultFundingAccountId: row.readNullable('default_funding_account_id'),
    defaultCategoryId: row.readNullable('default_category_id'),
    autoSaveEnabled: row.read<int>('auto_save_enabled') == 1,
    archivedAt: row.readNullable<String>('archived_at') == null
        ? null
        : DateTime.parse(row.read<String>('archived_at')),
    createdAt: DateTime.parse(row.read('created_at')),
    updatedAt: DateTime.parse(row.read('updated_at')),
  );

  Future<String> saveCard({
    String? id,
    required String ledgerId,
    required FamilyCardPlatform platform,
    required String displayName,
    required FamilyLocalRole localRole,
    String payerLabel = '',
    String beneficiaryLabel = '',
    int senderLimitMinor = 0,
    int userLimitMinor = 0,
    String? defaultFundingAccountId,
    String? defaultCategoryId,
  }) async {
    final name = displayName.trim();
    if (name.isEmpty || name.length > 100) {
      throw const LedgerException('亲情卡账户名称需为1～100字');
    }
    if (senderLimitMinor < 0 || userLimitMinor < 0) {
      throw const LedgerException('亲情卡额度不能为负数');
    }
    if (senderLimitMinor > 999999999999 || userLimitMinor > 999999999999) {
      throw const LedgerException('亲情卡额度超出有效范围');
    }
    // A family-card account has exactly one local role. Persist only that
    // role's quota so switching roles cannot leave a second, hidden quota.
    final normalizedSenderLimit = localRole == FamilyLocalRole.payer
        ? senderLimitMinor
        : 0;
    final normalizedUserLimit = localRole == FamilyLocalRole.beneficiary
        ? userLimitMinor
        : 0;
    final normalizedFundingAccount = localRole == FamilyLocalRole.payer
        ? defaultFundingAccountId
        : null;
    return db.transaction(() async {
      final ledgerRows = await db
          .customSelect(
            'SELECT id FROM ledgers WHERE id=?',
            variables: [Variable<String>(ledgerId)],
          )
          .get();
      if (ledgerRows.isEmpty) {
        throw const LedgerException('所属账本不存在');
      }
      if (normalizedFundingAccount != null) {
        final accountRows = await db
            .customSelect(
              'SELECT id FROM accounts WHERE id=? AND ledger_id=? AND archived_at IS NULL',
              variables: [
                Variable<String>(normalizedFundingAccount),
                Variable<String>(ledgerId),
              ],
            )
            .get();
        if (accountRows.isEmpty) {
          throw const LedgerException('默认扣款账户不存在、已归档或不属于当前账本');
        }
      }
      if (defaultCategoryId != null) {
        final categoryRows = await db
            .customSelect(
              "SELECT id FROM categories WHERE id=? AND ledger_id=? AND type='expense' AND archived_at IS NULL",
              variables: [
                Variable<String>(defaultCategoryId),
                Variable<String>(ledgerId),
              ],
            )
            .get();
        if (categoryRows.isEmpty) {
          throw const LedgerException('默认支出分类不存在、已归档或不属于当前账本');
        }
      }
      final duplicate = await db
          .customSelect(
            'SELECT id FROM family_cards WHERE ledger_id=? AND display_name=? AND id!=?',
            variables: [
              Variable<String>(ledgerId),
              Variable<String>(name),
              Variable<String>(id ?? ''),
            ],
          )
          .get();
      if (duplicate.isNotEmpty) {
        throw const LedgerException('亲情卡账户名称已存在');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final cardId = id ?? _uuid.v4();
      if (id == null) {
        await db.customStatement(
          '''INSERT INTO family_cards
          (id,ledger_id,platform,display_name,local_role,payer_label,beneficiary_label,
           sender_limit_minor,user_limit_minor,default_funding_account_id,
           default_category_id,auto_save_enabled,created_at,updated_at)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?,?)''',
          [
            cardId,
            ledgerId,
            platform.name,
            name,
            localRole.name,
            payerLabel.trim(),
            beneficiaryLabel.trim(),
            normalizedSenderLimit,
            normalizedUserLimit,
            normalizedFundingAccount,
            defaultCategoryId,
            now,
            now,
          ],
        );
      } else {
        final changed = await db.customUpdate(
          '''UPDATE family_cards SET platform=?,display_name=?,local_role=?,
          payer_label=?,beneficiary_label=?,sender_limit_minor=?,user_limit_minor=?,
          default_funding_account_id=?,default_category_id=?,updated_at=?
          WHERE id=? AND ledger_id=? AND archived_at IS NULL''',
          variables: [
            Variable<String>(platform.name),
            Variable<String>(name),
            Variable<String>(localRole.name),
            Variable<String>(payerLabel.trim()),
            Variable<String>(beneficiaryLabel.trim()),
            Variable<int>(normalizedSenderLimit),
            Variable<int>(normalizedUserLimit),
            Variable<String>(normalizedFundingAccount),
            Variable<String>(defaultCategoryId),
            Variable<String>(now),
            Variable<String>(id),
            Variable<String>(ledgerId),
          ],
        );
        if (changed != 1) throw const LedgerException('亲情卡账户不存在');
      }
      return cardId;
    });
  }

  Future<void> archiveCard(String ledgerId, String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final changed = await db.customUpdate(
      'UPDATE family_cards SET archived_at=?,updated_at=? WHERE id=? AND ledger_id=? AND archived_at IS NULL',
      variables: [
        Variable<String>(now),
        Variable<String>(now),
        Variable<String>(id),
        Variable<String>(ledgerId),
      ],
    );
    if (changed != 1) throw const LedgerException('亲情卡账户不存在');
  }

  Future<List<FamilyPaymentEvent>> events(
    String ledgerId, {
    String? cardId,
    FamilyCardPlatform? platform,
    FamilyPaymentStatus? status,
    bool onlyUnassigned = false,
    DateTime? month,
  }) async {
    final clauses = <String>['ledger_id=?'];
    final vars = <Variable>[Variable<String>(ledgerId)];
    if (cardId != null) {
      clauses.add('card_id=?');
      vars.add(Variable<String>(cardId));
    }
    if (onlyUnassigned) {
      clauses.add('card_id IS NULL');
    }
    if (platform != null) {
      clauses.add('platform=?');
      vars.add(Variable<String>(platform.name));
    }
    if (status != null) {
      clauses.add('status=?');
      vars.add(Variable<String>(status.name));
    }
    if (month != null) {
      final start = DateTime(month.year, month.month).toIso8601String();
      final end = DateTime(month.year, month.month + 1).toIso8601String();
      clauses.add('occurred_at>=? AND occurred_at<?');
      vars.add(Variable<String>(start));
      vars.add(Variable<String>(end));
    }
    final eventRows = await db.customSelect(
      '''SELECT * FROM family_payment_events
          WHERE ${clauses.join(' AND ')}
          ORDER BY COALESCE(occurred_at,created_at) DESC, created_at DESC, rowid DESC''',
      variables: vars,
    ).get();
    return _hydrateEvents(eventRows);
  }

  Future<List<FamilyPaymentEvent>> unassignedEvents(
    String ledgerId, {
    DateTime? month,
    FamilyCardPlatform? platform,
  }) async {
    final all = await events(
      ledgerId,
      onlyUnassigned: true,
      month: month,
      platform: platform,
    );
    return all
        .where((event) => event.status != FamilyPaymentStatus.voided)
        .toList();
  }

  Future<FamilyPaymentEvent?> event(String ledgerId, String eventId) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM family_payment_events WHERE id=? AND ledger_id=?',
          variables: [Variable<String>(eventId), Variable<String>(ledgerId)],
        )
        .get();
    if (rows.isEmpty) return null;
    return (await _hydrateEvents(rows)).single;
  }

  Future<List<FamilyPaymentEvent>> _hydrateEvents(
    List<QueryRow> eventRows,
  ) async {
    if (eventRows.isEmpty) return const [];
    final ids = eventRows.map((r) => r.read<String>('id')).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final evidenceRows = await db
        .customSelect(
          '''SELECT * FROM family_payment_evidence
          WHERE event_id IN ($placeholders)
          ORDER BY observed_at ASC, rowid ASC''',
          variables: [for (final id in ids) Variable<String>(id)],
        )
        .get();
    final evidenceByEvent = <String, List<FamilyPaymentEvidence>>{};
    for (final row in evidenceRows) {
      final item = FamilyPaymentEvidence(
        id: row.read('id'),
        eventId: row.read('event_id'),
        captureId: row.read('capture_id'),
        sourceKind: row.read('source_kind'),
        sourcePackage: row.read('source_package'),
        amountMinor: row.readNullable('amount_minor'),
        merchantHint: row.read('merchant_hint'),
        confidence: row.read('confidence'),
        observedAt: DateTime.parse(row.read('observed_at')),
        redactedExcerpt: row.read('redacted_excerpt'),
      );
      (evidenceByEvent[item.eventId] ??= []).add(item);
    }
    return eventRows.map((row) {
      final id = row.read<String>('id');
      final roleName = row.readNullable<String>('local_role');
      final occurredText = row.readNullable<String>('occurred_at');
      return FamilyPaymentEvent(
        id: id,
        ledgerId: row.read('ledger_id'),
        cardId: row.readNullable('card_id'),
        platform: FamilyCardPlatform.values.byName(row.read('platform')),
        externalOrderHash: row.readNullable('external_order_hash'),
        amountMinor: row.read('amount_minor'),
        refundedMinor: row.read('refunded_minor'),
        merchant: row.read('merchant'),
        occurredAt: occurredText == null ? null : DateTime.parse(occurredText),
        localRole: roleName == null
            ? null
            : FamilyLocalRole.values.byName(roleName),
        fundingAccountId: row.readNullable('funding_account_id'),
        fundingState: FamilyFundingState.values.byName(
          row.read('funding_state'),
        ),
        status: FamilyPaymentStatus.values.byName(row.read('status')),
        transactionId: row.readNullable('transaction_id'),
        createdAt: DateTime.parse(row.read('created_at')),
        updatedAt: DateTime.parse(row.read('updated_at')),
        evidence: List.unmodifiable(evidenceByEvent[id] ?? const []),
      );
    }).toList();
  }

  QueryRow? _selectCardByClues(List<QueryRow> cardRows, String rawText) {
    if (cardRows.isEmpty) return null;
    if (cardRows.length == 1) return cardRows.single;
    const genericClues = {
      '我',
      '本人',
      '自己',
      '微信',
      '支付宝',
      '微信亲属卡',
      '支付宝亲情卡',
      '亲属卡',
      '亲情卡',
      '亲情号',
    };
    final textLower = rawText.toLowerCase();
    final matched = <QueryRow>[];
    for (final row in cardRows) {
      final clues =
          <String>{
                row.read<String>('display_name').trim(),
                row.read<String>('payer_label').trim(),
                row.read<String>('beneficiary_label').trim(),
              }
              .where(
                (clue) =>
                    clue.length >= 2 &&
                    !genericClues.contains(clue) &&
                    textLower.contains(clue.toLowerCase()),
              )
              .toList();
      if (clues.isNotEmpty) {
        matched.add(row);
      }
    }
    return matched.length == 1 ? matched.single : null;
  }

  Future<String?> _inferFundingAccount(
    String ledgerId,
    String sourcePackage,
    String rawText,
  ) async {
    final hasExplicitFundingClue = RegExp(
      r'银行|储蓄卡|借记卡|信用卡|尾号\s*\d{4}|\*{2,}\s*\d{4}|花呗|零钱通|余额宝',
    ).hasMatch(rawText);
    if (!hasExplicitFundingClue) return null;
    final accounts = await LedgerRepository(db).accounts(ledgerId);
    final resolved = const PaymentAccountResolver().resolve(
      rawText,
      sourcePackage,
      accounts,
    );
    if (resolved.ambiguous || resolved.account == null) return null;
    return resolved.account!.id;
  }

  static String _normalizeMerchantForMatch(String value) {
    var cleaned = value
        .trim()
        .replaceFirst(
          RegExp(r'^(?:微信支付|支付宝|财付通|云闪付|亲属卡|亲情卡|亲情号)\s*[-—:：·]?\s*'),
          '',
        )
        .trim();
    return normalizeMerchantPattern(cleaned);
  }

  static bool _merchantsCorroborate(String left, String right) {
    final a = _normalizeMerchantForMatch(left);
    final b = _normalizeMerchantForMatch(right);
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || a.contains(b) || b.contains(a);
  }

  Future<String?> observeCapture({
    required String captureId,
    required String ledgerId,
    required FamilyCardPlatform platform,
    required String sourceKind,
    required String sourcePackage,
    required int? amountMinor,
    required String merchant,
    required DateTime occurredAt,
    required String rawText,
  }) async {
    if (amountMinor == null || amountMinor <= 0 || amountMinor > 999999999999) {
      return null;
    }
    final normalizedKind = normalizeSourceKind(
      sourceKind,
      sourcePackage: sourcePackage,
    );
    if (normalizedKind == null) return null;

    return db.transaction(() async {
      final existingEvidence = await db
          .customSelect(
            'SELECT event_id FROM family_payment_evidence WHERE capture_id=?',
            variables: [Variable<String>(captureId)],
          )
          .get();
      if (existingEvidence.isNotEmpty) {
        return existingEvidence.single.read<String>('event_id');
      }

      final cardRows = await db
          .customSelect(
            '''SELECT * FROM family_cards WHERE ledger_id=? AND platform=?
        AND archived_at IS NULL ORDER BY created_at''',
            variables: [
              Variable<String>(ledgerId),
              Variable<String>(platform.name),
            ],
          )
          .get();
      final selected = _selectCardByClues(cardRows, rawText);
      final selectedCardId = selected?.read<String>('id');
      final selectedRole = selected?.read<String>('local_role');
      final defaultFundingId = selectedRole == FamilyLocalRole.beneficiary.name
          ? null
          : selected?.readNullable<String>('default_funding_account_id');
      final inferredFundingId = selectedRole == FamilyLocalRole.beneficiary.name
          ? null
          : (await _inferFundingAccount(ledgerId, sourcePackage, rawText) ??
                defaultFundingId);

      final orderHash = await _orderHash(platform, rawText);
      final occurredIso = occurredAt.toIso8601String();
      final now = DateTime.now().toUtc().toIso8601String();
      final cleanMerchant = sanitizeSourceText(merchant.trim());

      String? eventId;
      var excerpt = '';
      var hasConflict = false;

      if (orderHash != null) {
        final existingByHash = await db
            .customSelect(
              '''SELECT * FROM family_payment_events
          WHERE ledger_id=? AND platform=? AND external_order_hash=?''',
              variables: [
                Variable<String>(ledgerId),
                Variable<String>(platform.name),
                Variable<String>(orderHash),
              ],
            )
            .get();
        if (existingByHash.isNotEmpty) {
          final existing = existingByHash.single;
          eventId = existing.read<String>('id');
          final existingAmount = existing.read<int>('amount_minor');
          final existingCardId = existing.readNullable<String>('card_id');
          final existingOccurred = DateTime.tryParse(
            existing.readNullable<String>('occurred_at') ?? '',
          );
          final conflicts = <String>[];
          if (existingAmount != amountMinor) {
            conflicts.add('金额不一致（已有 $existingAmount 分，新来源 $amountMinor 分）');
          }
          if (existingCardId != null &&
              selectedCardId != null &&
              existingCardId != selectedCardId) {
            conflicts.add('亲情卡归属冲突');
          }
          if (existingOccurred != null &&
              existingOccurred.difference(occurredAt).abs() >
                  const Duration(hours: 24)) {
            conflicts.add('交易时间差异超过24小时');
          }
          if (conflicts.isNotEmpty) {
            hasConflict = true;
            excerpt = '冲突：${conflicts.join("；")}';
            final currentStatus = existing.read<String>('status');
            if (currentStatus == 'observed' || currentStatus == 'needsReview') {
              await db.customStatement(
                "UPDATE family_payment_events SET status='needsReview', updated_at=? WHERE id=?",
                [now, eventId],
              );
            }
          } else {
            await _enrichExistingEvent(
              existing: existing,
              selectedCardId: selectedCardId,
              selectedRole: selectedRole,
              inferredFundingId: inferredFundingId,
              merchant: cleanMerchant,
              orderHash: orderHash,
              now: now,
            );
          }
        } else {
          // Check if an orderless event from another source_kind of the same
          // purchase exists within 5 minutes and can be upgraded with orderHash.
          final orderlessMatch = await _findCrossSourceCandidate(
            ledgerId: ledgerId,
            platform: platform,
            amountMinor: amountMinor,
            occurredAt: occurredAt,
            normalizedKind: normalizedKind,
            merchant: cleanMerchant,
            selectedCardId: selectedCardId,
            inferredFundingId: inferredFundingId,
            requireNullOrderHash: true,
          );
          if (orderlessMatch != null) {
            eventId = orderlessMatch.read<String>('id');
            await _enrichExistingEvent(
              existing: orderlessMatch,
              selectedCardId: selectedCardId,
              selectedRole: selectedRole,
              inferredFundingId: inferredFundingId,
              merchant: cleanMerchant,
              orderHash: orderHash,
              now: now,
            );
          }
        }
      } else {
        final matched = await _findCrossSourceCandidate(
          ledgerId: ledgerId,
          platform: platform,
          amountMinor: amountMinor,
          occurredAt: occurredAt,
          normalizedKind: normalizedKind,
          merchant: cleanMerchant,
          selectedCardId: selectedCardId,
          inferredFundingId: inferredFundingId,
          requireNullOrderHash: false,
        );
        if (matched != null) {
          eventId = matched.read<String>('id');
          await _enrichExistingEvent(
            existing: matched,
            selectedCardId: selectedCardId,
            selectedRole: selectedRole,
            inferredFundingId: inferredFundingId,
            merchant: cleanMerchant,
            orderHash: null,
            now: now,
          );
        } else {
          // Never auto-merge on amount alone. If there is a nearby event with
          // the same amount, record a manual merge suggestion only.
          final nearbySameAmount = await db
              .customSelect(
                '''SELECT id, occurred_at FROM family_payment_events
            WHERE ledger_id=? AND platform=? AND amount_minor=?
              AND status IN ('observed','needsReview')
            ORDER BY created_at DESC''',
                variables: [
                  Variable<String>(ledgerId),
                  Variable<String>(platform.name),
                  Variable<int>(amountMinor),
                ],
              )
              .get();
          for (final candidate in nearbySameAmount) {
            final candidateTime = DateTime.tryParse(
              candidate.readNullable<String>('occurred_at') ?? '',
            );
            if (candidateTime != null &&
                candidateTime.difference(occurredAt).abs() <=
                    const Duration(minutes: 10)) {
              excerpt = '候选合并：${candidate.read<String>('id')}';
              break;
            }
          }
        }
      }

      final createdNewEvent = eventId == null;
      final targetEventId = eventId ?? _uuid.v4();
      if (createdNewEvent) {
        await db.customStatement(
          '''INSERT OR IGNORE INTO family_payment_events
          (id,ledger_id,card_id,platform,external_order_hash,amount_minor,merchant,
           occurred_at,local_role,funding_account_id,funding_state,status,created_at,updated_at)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,'needsReview',?,?)''',
          [
            targetEventId,
            ledgerId,
            selectedCardId,
            platform.name,
            orderHash,
            amountMinor,
            cleanMerchant,
            occurredIso,
            selectedRole,
            inferredFundingId,
            inferredFundingId == null ? 'unknown' : 'inferred',
            now,
            now,
          ],
        );
      }

      // If INSERT OR IGNORE skipped because external_order_hash was concurrently
      // inserted, resolve the actual event_id by orderHash.
      var resolvedEventId = targetEventId;
      if (createdNewEvent && orderHash != null) {
        final actual = await db
            .customSelect(
              '''SELECT id FROM family_payment_events
          WHERE ledger_id=? AND platform=? AND external_order_hash=?''',
              variables: [
                Variable<String>(ledgerId),
                Variable<String>(platform.name),
                Variable<String>(orderHash),
              ],
            )
            .get();
        if (actual.isNotEmpty) {
          resolvedEventId = actual.single.read<String>('id');
        }
      }

      final confidence = computeEvidenceConfidence(
        sourceKind: normalizedKind,
        hasOrderHash: orderHash != null,
        amountMinor: amountMinor,
        merchant: cleanMerchant,
        hasCardOrAccount: selectedCardId != null || inferredFundingId != null,
        hasConflict: hasConflict,
      );

      await db.customStatement(
        '''INSERT OR IGNORE INTO family_payment_evidence
        (id,event_id,capture_id,source_kind,source_package,amount_minor,
         merchant_hint,confidence,observed_at,redacted_excerpt)
        VALUES (?,?,?,?,?,?,?,?,?,?)''',
        [
          _uuid.v4(),
          resolvedEventId,
          captureId,
          normalizedKind,
          sourcePackage,
          amountMinor,
          cleanMerchant,
          confidence,
          occurredIso,
          excerpt,
        ],
      );

      final committed = await db
          .customSelect(
            'SELECT event_id FROM family_payment_evidence WHERE capture_id=?',
            variables: [Variable<String>(captureId)],
          )
          .get();
      final committedEventId = committed.firstOrNull?.read<String>('event_id');
      if (createdNewEvent &&
          committedEventId != null &&
          committedEventId != targetEventId) {
        await db.customStatement(
          '''DELETE FROM family_payment_events WHERE id=?
          AND NOT EXISTS (SELECT 1 FROM family_payment_evidence WHERE event_id=?)''',
          [targetEventId, targetEventId],
        );
      }
      return committedEventId ?? resolvedEventId;
    });
  }

  Future<QueryRow?> _findCrossSourceCandidate({
    required String ledgerId,
    required FamilyCardPlatform platform,
    required int amountMinor,
    required DateTime occurredAt,
    required String normalizedKind,
    required String merchant,
    required String? selectedCardId,
    required String? inferredFundingId,
    required bool requireNullOrderHash,
  }) async {
    final candidates = await db
        .customSelect(
          '''SELECT * FROM family_payment_events
      WHERE ledger_id=? AND platform=? AND amount_minor=?
        AND status IN ('observed','needsReview')
        ${requireNullOrderHash ? 'AND external_order_hash IS NULL' : ''}
      ORDER BY created_at DESC''',
          variables: [
            Variable<String>(ledgerId),
            Variable<String>(platform.name),
            Variable<int>(amountMinor),
          ],
        )
        .get();
    final matched = <QueryRow>[];
    for (final candidate in candidates) {
      final candidateId = candidate.read<String>('id');
      final candidateCardId = candidate.readNullable<String>('card_id');
      if (candidateCardId != null &&
          selectedCardId != null &&
          candidateCardId != selectedCardId) {
        continue;
      }
      final candidateOccurred = DateTime.tryParse(
        candidate.readNullable<String>('occurred_at') ?? '',
      );
      if (candidateOccurred == null ||
          candidateOccurred.difference(occurredAt).abs() >
              const Duration(minutes: 5)) {
        continue;
      }
      final existingEvidence = await db
          .customSelect(
            'SELECT source_kind, merchant_hint FROM family_payment_evidence WHERE event_id=?',
            variables: [Variable<String>(candidateId)],
          )
          .get();
      final existingKinds = existingEvidence
          .map((e) => e.read<String>('source_kind'))
          .toSet();
      // Two captures from the same source kind without an order number must
      // never be auto-merged (could be two independent purchases).
      if (existingKinds.contains(normalizedKind)) {
        continue;
      }
      final candidateMerchant = candidate.read<String>('merchant');
      final merchantMatched =
          _merchantsCorroborate(candidateMerchant, merchant) ||
          existingEvidence.any(
            (e) => _merchantsCorroborate(
              e.read<String>('merchant_hint'),
              merchant,
            ),
          );
      final candidateFunding = candidate.readNullable<String>(
        'funding_account_id',
      );
      final bankAccountMatched =
          normalizedKind == 'bankNotice' &&
          inferredFundingId != null &&
          (candidateFunding == null || candidateFunding == inferredFundingId) &&
          (merchant.isEmpty || candidateMerchant.isEmpty || merchantMatched);
      if (merchantMatched || bankAccountMatched) {
        matched.add(candidate);
      }
    }
    return matched.length == 1 ? matched.single : null;
  }

  Future<void> _enrichExistingEvent({
    required QueryRow existing,
    required String? selectedCardId,
    required String? selectedRole,
    required String? inferredFundingId,
    required String merchant,
    required String? orderHash,
    required String now,
  }) async {
    final eventId = existing.read<String>('id');
    final currentStatus = existing.read<String>('status');
    if (currentStatus == 'confirmed' ||
        currentStatus == 'refunded' ||
        currentStatus == 'voided') {
      return;
    }
    final nextCardId =
        existing.readNullable<String>('card_id') ?? selectedCardId;
    final nextRole =
        existing.readNullable<String>('local_role') ?? selectedRole;
    final currentMerchant = existing.read<String>('merchant');
    final nextMerchant = currentMerchant.isNotEmpty
        ? currentMerchant
        : merchant;
    final nextOrderHash =
        existing.readNullable<String>('external_order_hash') ?? orderHash;
    final currentFunding = existing.readNullable<String>('funding_account_id');
    final nextFunding = nextRole == FamilyLocalRole.beneficiary.name
        ? null
        : (currentFunding ?? inferredFundingId);
    final currentFundingState = existing.read<String>('funding_state');
    final nextFundingState = nextRole == FamilyLocalRole.beneficiary.name
        ? 'unknown'
        : currentFundingState == 'confirmed'
        ? 'confirmed'
        : (nextFunding != null ? 'inferred' : 'unknown');
    await db.customStatement(
      '''UPDATE family_payment_events
      SET card_id=?, local_role=?, merchant=?, external_order_hash=?,
          funding_account_id=?, funding_state=?, updated_at=?
      WHERE id=?''',
      [
        nextCardId,
        nextRole,
        nextMerchant,
        nextOrderHash,
        nextFunding,
        nextFundingState,
        now,
        eventId,
      ],
    );
  }

  /// Assigns or updates the family card bound to an unassigned or pending event.
  Future<void> assignCard({
    required String ledgerId,
    required String eventId,
    required String cardId,
  }) => db.transaction(() async {
    final cardRows = await db
        .customSelect(
          'SELECT * FROM family_cards WHERE id=? AND ledger_id=? AND archived_at IS NULL',
          variables: [Variable<String>(cardId), Variable<String>(ledgerId)],
        )
        .get();
    if (cardRows.isEmpty) {
      throw const LedgerException('亲情卡账户不存在或已归档');
    }
    final card = cardRows.single;
    final eventRows = await db
        .customSelect(
          'SELECT * FROM family_payment_events WHERE id=? AND ledger_id=?',
          variables: [Variable<String>(eventId), Variable<String>(ledgerId)],
        )
        .get();
    if (eventRows.isEmpty) {
      throw const LedgerException('亲情卡交易事件不存在');
    }
    final ev = eventRows.single;
    if (ev.read<String>('status') == 'voided') {
      throw const LedgerException('已撤销的亲情卡事件不能绑定卡片');
    }
    if (ev.read<String>('platform') != card.read<String>('platform')) {
      throw const LedgerException('亲情卡平台与交易事件平台不一致');
    }
    final cardRole = card.read<String>('local_role');
    final status = ev.read<String>('status');
    final now = DateTime.now().toUtc().toIso8601String();
    if (status == 'confirmed' || status == 'refunded') {
      if (ev.readNullable<String>('local_role') != cardRole) {
        throw const LedgerException('已确认事件不能变更为不同角色的亲情卡');
      }
      await db.customStatement(
        'UPDATE family_payment_events SET card_id=?, updated_at=? WHERE id=? AND ledger_id=?',
        [cardId, now, eventId, ledgerId],
      );
      return;
    }
    final defaultFunding = cardRole == FamilyLocalRole.beneficiary.name
        ? null
        : (ev.readNullable<String>('funding_account_id') ??
              card.readNullable<String>('default_funding_account_id'));
    final fundingState = defaultFunding == null ? 'unknown' : 'inferred';
    await db.customStatement(
      '''UPDATE family_payment_events
      SET card_id=?, local_role=?, funding_account_id=?, funding_state=?, updated_at=?
      WHERE id=? AND ledger_id=?''',
      [cardId, cardRole, defaultFunding, fundingState, now, eventId, ledgerId],
    );
    await _syncDraftsForEvent(
      eventId: eventId,
      role: cardRole,
      fundingAccountId: defaultFunding,
    );
  });

  /// Merges a duplicate pending event (`sourceEventId`) into `targetEventId`.
  Future<void> mergeEvents({
    required String ledgerId,
    required String targetEventId,
    required String sourceEventId,
  }) => db.transaction(() async {
    if (targetEventId == sourceEventId) {
      throw const LedgerException('不能将同一事件与自身合并');
    }
    final rows = await db
        .customSelect(
          'SELECT * FROM family_payment_events WHERE ledger_id=? AND id IN (?,?)',
          variables: [
            Variable<String>(ledgerId),
            Variable<String>(targetEventId),
            Variable<String>(sourceEventId),
          ],
        )
        .get();
    if (rows.length != 2) {
      throw const LedgerException('待合并的亲情卡事件不存在');
    }
    final target = rows.firstWhere(
      (r) => r.read<String>('id') == targetEventId,
    );
    final source = rows.firstWhere(
      (r) => r.read<String>('id') == sourceEventId,
    );
    if (target.read<String>('platform') != source.read<String>('platform')) {
      throw const LedgerException('不同平台的亲情卡事件不能合并');
    }
    if (target.read<String>('status') == 'voided' ||
        !const [
          'observed',
          'needsReview',
        ].contains(source.read<String>('status')) ||
        source.readNullable<String>('transaction_id') != null) {
      throw const LedgerException('仅待审核且未入账的重复事件可合并入主事件');
    }
    final sourceEvidence = await db
        .customSelect(
          'SELECT * FROM family_payment_evidence WHERE event_id=?',
          variables: [Variable<String>(sourceEventId)],
        )
        .get();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final ev in sourceEvidence) {
      final excerpt = ev.read<String>('redacted_excerpt');
      final cleanedExcerpt = excerpt.startsWith('候选合并：') ? '' : excerpt;
      await db.customStatement(
        'UPDATE family_payment_evidence SET event_id=?, redacted_excerpt=? WHERE id=?',
        [targetEventId, cleanedExcerpt, ev.read<String>('id')],
      );
      final captureId = ev.read<String>('capture_id');
      await db.customStatement(
        "UPDATE transaction_drafts SET status='ignored', updated_at=? WHERE id=? AND status='pending'",
        [now, 'auto-$captureId'],
      );
    }
    await _enrichExistingEvent(
      existing: target,
      selectedCardId: source.readNullable<String>('card_id'),
      selectedRole: source.readNullable<String>('local_role'),
      inferredFundingId: source.readNullable<String>('funding_account_id'),
      merchant: source.read<String>('merchant'),
      orderHash: source.readNullable<String>('external_order_hash'),
      now: now,
    );
    await db.customStatement(
      'DELETE FROM family_payment_events WHERE id=? AND ledger_id=?',
      [sourceEventId, ledgerId],
    );
  });

  /// Confirms a family payment event atomically:
  /// - For `payer`: validates funding account and category in `ledgerId`,
  ///   creates a single real expense transaction and posting, binds
  ///   `transaction_id`, and marks `funding_state='confirmed'` and `status='confirmed'`.
  /// - For `beneficiary`: records non-asset family-card consumption only
  ///   (`transaction_id=NULL`, `funding_account_id=NULL`, `funding_state='confirmed'`,
  ///   `status='confirmed'`), creating zero account postings.
  Future<String?> confirmFamilyEvent({
    required String ledgerId,
    required String eventId,
    FamilyLocalRole? localRole,
    String? cardId,
    String? fundingAccountId,
    String? categoryId,
    int? amountMinor,
    String? merchant,
    DateTime? occurredAt,
    String note = '',
    List<String> tags = const [],
    String? draftId,
    bool allowConflict = false,
  }) => db.transaction(() async {
    final eventRows = await db
        .customSelect(
          'SELECT * FROM family_payment_events WHERE id=? AND ledger_id=?',
          variables: [Variable<String>(eventId), Variable<String>(ledgerId)],
        )
        .get();
    if (eventRows.isEmpty) {
      throw const LedgerException('亲情卡交易事件不存在');
    }
    final ev = eventRows.single;
    final currentStatus = ev.read<String>('status');
    if (currentStatus == 'voided') {
      throw const LedgerException('已撤销的亲情卡事件不能确认');
    }
    if (currentStatus == 'confirmed' || currentStatus == 'refunded') {
      final existingRole = ev.readNullable<String>('local_role');
      if (localRole == null || existingRole == localRole.name) {
        return ev.readNullable<String>('transaction_id');
      }
      throw const LedgerException('已确认的亲情卡事件不能更改收支角色');
    }

    final evidenceRows = await db
        .customSelect(
          'SELECT * FROM family_payment_evidence WHERE event_id=? ORDER BY observed_at ASC',
          variables: [Variable<String>(eventId)],
        )
        .get();
    if (evidenceRows.isEmpty) {
      throw const LedgerException('亲情卡事件缺少来源证据，无法确认');
    }
    final hasConflict = evidenceRows.any(
      (r) => r.read<String>('redacted_excerpt').startsWith('冲突：'),
    );
    if (hasConflict && !allowConflict && amountMinor == null) {
      throw const LedgerException('该亲情卡事件存在多来源冲突，请核对后明确指定确认金额');
    }

    final resolvedCardId = cardId ?? ev.readNullable<String>('card_id');
    QueryRow? cardRow;
    if (resolvedCardId != null) {
      final cards = await db
          .customSelect(
            'SELECT * FROM family_cards WHERE id=? AND ledger_id=? AND archived_at IS NULL',
            variables: [
              Variable<String>(resolvedCardId),
              Variable<String>(ledgerId),
            ],
          )
          .get();
      if (cards.isEmpty) {
        throw const LedgerException('关联的亲情卡不存在、已归档或不属于当前账本');
      }
      cardRow = cards.single;
      if (cardRow.read<String>('platform') != ev.read<String>('platform')) {
        throw const LedgerException('亲情卡平台与交易事件平台不一致');
      }
    }

    final roleName =
        localRole?.name ??
        cardRow?.read<String>('local_role') ??
        ev.readNullable<String>('local_role');
    if (roleName == null) {
      throw const LedgerException('请先确认本机在该亲情卡交易中是发送方还是使用方');
    }
    final resolvedRole = FamilyLocalRole.values.byName(roleName);
    if (cardRow != null &&
        cardRow.read<String>('local_role') != resolvedRole.name) {
      throw const LedgerException('所选亲情卡角色与确认角色不一致');
    }

    final resolvedAmount = amountMinor ?? ev.read<int>('amount_minor');
    if (resolvedAmount <= 0 || resolvedAmount > 999999999999) {
      throw const LedgerException('亲情卡交易金额超出有效范围');
    }
    final refundedMinor = ev.read<int>('refunded_minor');
    if (refundedMinor > resolvedAmount) {
      throw const LedgerException('确认金额不能小于已退款金额');
    }
    final resolvedMerchant = sanitizeSourceText(
      (merchant ?? ev.read<String>('merchant')).trim(),
    );
    final resolvedOccurredAt =
        occurredAt ??
        DateTime.tryParse(ev.readNullable<String>('occurred_at') ?? '') ??
        DateTime.parse(ev.read<String>('created_at'));
    final now = DateTime.now().toUtc().toIso8601String();

    if (hasConflict) {
      for (final row in evidenceRows) {
        final text = row.read<String>('redacted_excerpt');
        if (text.startsWith('冲突：')) {
          await db.customStatement(
            'UPDATE family_payment_evidence SET redacted_excerpt=? WHERE id=?',
            ['已人工核对（原$text）', row.read<String>('id')],
          );
        }
      }
    }

    final nextStatus = refundedMinor >= resolvedAmount
        ? FamilyPaymentStatus.refunded.name
        : FamilyPaymentStatus.confirmed.name;

    if (resolvedRole == FamilyLocalRole.beneficiary) {
      if (fundingAccountId != null) {
        throw const LedgerException('使用方亲情卡消费不扣减本人账户，不能指定扣款账户');
      }
      await db.customStatement(
        '''UPDATE family_payment_events
        SET card_id=?, amount_minor=?, merchant=?, occurred_at=?,
            local_role='beneficiary', funding_account_id=NULL,
            funding_state='confirmed', status=?, transaction_id=NULL, updated_at=?
        WHERE id=? AND ledger_id=?''',
        [
          resolvedCardId,
          resolvedAmount,
          resolvedMerchant,
          resolvedOccurredAt.toIso8601String(),
          nextStatus,
          now,
          eventId,
          ledgerId,
        ],
      );
      await _resolveEventDrafts(
        ledgerId: ledgerId,
        eventId: eventId,
        evidenceRows: evidenceRows,
        explicitDraftId: draftId,
        transactionId: null,
        now: now,
      );
      return null;
    }

    // Payer path: requires a verified funding account in the same ledger.
    final resolvedFundingId =
        fundingAccountId ??
        ev.readNullable<String>('funding_account_id') ??
        cardRow?.readNullable<String>('default_funding_account_id');
    if (resolvedFundingId == null || resolvedFundingId.trim().isEmpty) {
      throw const LedgerException('发送方确认亲情卡消费需选择真实扣款账户');
    }
    final accountRows = await db
        .customSelect(
          'SELECT id FROM accounts WHERE id=? AND ledger_id=? AND archived_at IS NULL',
          variables: [
            Variable<String>(resolvedFundingId),
            Variable<String>(ledgerId),
          ],
        )
        .get();
    if (accountRows.isEmpty) {
      throw const LedgerException('扣款账户不存在、已归档或不属于当前账本');
    }

    var resolvedCategoryId =
        categoryId ?? cardRow?.readNullable<String>('default_category_id');
    if (resolvedCategoryId == null || resolvedCategoryId.trim().isEmpty) {
      final defaultCat = await db
          .customSelect(
            "SELECT id FROM categories WHERE ledger_id=? AND type='expense' AND archived_at IS NULL ORDER BY sort_order, rowid LIMIT 1",
            variables: [Variable<String>(ledgerId)],
          )
          .get();
      resolvedCategoryId = defaultCat.firstOrNull?.read<String>('id');
    }
    if (resolvedCategoryId == null) {
      throw const LedgerException('请选择支出分类');
    }
    final catCheck = await db
        .customSelect(
          "SELECT id FROM categories WHERE id=? AND ledger_id=? AND type='expense' AND archived_at IS NULL",
          variables: [
            Variable<String>(resolvedCategoryId),
            Variable<String>(ledgerId),
          ],
        )
        .get();
    if (catCheck.isEmpty) {
      throw const LedgerException('支出分类不存在、已归档或不属于当前账本');
    }

    final repo = LedgerRepository(db);
    final existingTxId = ev.readNullable<String>('transaction_id');
    final txId = await repo.save(
      ledgerId,
      TransactionInput(
        type: TransactionType.expense,
        amountMinor: resolvedAmount,
        accountId: resolvedFundingId,
        categoryId: resolvedCategoryId,
        occurredDate: resolvedOccurredAt,
        merchant: resolvedMerchant,
        note: note,
        tags: tags,
      ),
      id: existingTxId,
    );

    await db.customStatement(
      '''UPDATE family_payment_events
      SET card_id=?, amount_minor=?, merchant=?, occurred_at=?,
          local_role='payer', funding_account_id=?,
          funding_state='confirmed', status=?, transaction_id=?, updated_at=?
      WHERE id=? AND ledger_id=?''',
      [
        resolvedCardId,
        resolvedAmount,
        resolvedMerchant,
        resolvedOccurredAt.toIso8601String(),
        resolvedFundingId,
        nextStatus,
        txId,
        now,
        eventId,
        ledgerId,
      ],
    );
    await _resolveEventDrafts(
      ledgerId: ledgerId,
      eventId: eventId,
      evidenceRows: evidenceRows,
      explicitDraftId: draftId,
      transactionId: txId,
      now: now,
    );
    return txId;
  });

  /// Records a partial or full refund against a family payment event.
  /// If the event belongs to a confirmed payer with a bound `transaction_id`,
  /// also records a linked refund transaction to restore account balance and stats.
  Future<String?> applyRefund({
    required String ledgerId,
    required String eventId,
    required int refundMinor,
    DateTime? occurredAt,
    String note = '',
  }) => db.transaction(() async {
    if (refundMinor <= 0 || refundMinor > 999999999999) {
      throw const LedgerException('退款金额必须大于0');
    }
    final rows = await db
        .customSelect(
          'SELECT * FROM family_payment_events WHERE id=? AND ledger_id=?',
          variables: [Variable<String>(eventId), Variable<String>(ledgerId)],
        )
        .get();
    if (rows.isEmpty) {
      throw const LedgerException('亲情卡交易事件不存在');
    }
    final ev = rows.single;
    final status = ev.read<String>('status');
    if (status == 'voided') {
      throw const LedgerException('已撤销的亲情卡事件不能退款');
    }
    final amountMinor = ev.read<int>('amount_minor');
    final currentRefunded = ev.read<int>('refunded_minor');
    final nextRefunded = currentRefunded + refundMinor;
    if (nextRefunded > amountMinor) {
      throw const LedgerException('累计退款不能超过原亲情卡消费金额');
    }
    final txId = ev.readNullable<String>('transaction_id');
    final fundingId = ev.readNullable<String>('funding_account_id');
    final role = ev.readNullable<String>('local_role');
    String? refundTxId;
    if (role == FamilyLocalRole.payer.name &&
        txId != null &&
        fundingId != null) {
      final repo = LedgerRepository(db);
      refundTxId = await repo.save(
        ledgerId,
        TransactionInput(
          type: TransactionType.refund,
          amountMinor: refundMinor,
          accountId: fundingId,
          occurredDate: occurredAt ?? DateTime.now(),
          merchant: ev.read<String>('merchant'),
          note: note.trim().isEmpty ? '亲情卡退款' : note.trim(),
          relatedTransactionId: txId,
        ),
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final nextStatus = nextRefunded >= amountMinor
        ? FamilyPaymentStatus.refunded.name
        : status;
    await db.customStatement(
      'UPDATE family_payment_events SET refunded_minor=?, status=?, updated_at=? WHERE id=? AND ledger_id=?',
      [nextRefunded, nextStatus, now, eventId, ledgerId],
    );
    return refundTxId;
  });

  /// Voids a family payment event, excluding it from quota usage and soft-deleting
  /// any linked payer expense/refund transactions so account balances and bill
  /// statistics stay consistent.
  Future<void> voidEvent({
    required String ledgerId,
    required String eventId,
  }) => db.transaction(() async {
    final rows = await db
        .customSelect(
          'SELECT * FROM family_payment_events WHERE id=? AND ledger_id=?',
          variables: [Variable<String>(eventId), Variable<String>(ledgerId)],
        )
        .get();
    if (rows.isEmpty) {
      throw const LedgerException('亲情卡交易事件不存在');
    }
    final ev = rows.single;
    if (ev.read<String>('status') == 'voided') return;
    final txId = ev.readNullable<String>('transaction_id');
    if (txId != null) {
      final repo = LedgerRepository(db);
      final refunds = await db
          .customSelect(
            "SELECT id FROM transactions WHERE related_transaction_id=? AND type='refund' AND deleted_at IS NULL",
            variables: [Variable<String>(txId)],
          )
          .get();
      for (final refund in refunds) {
        await repo.delete(ledgerId, refund.read<String>('id'));
      }
      final txRows = await db
          .customSelect(
            'SELECT id FROM transactions WHERE id=? AND ledger_id=? AND deleted_at IS NULL',
            variables: [Variable<String>(txId), Variable<String>(ledgerId)],
          )
          .get();
      if (txRows.isNotEmpty) {
        await repo.delete(ledgerId, txId);
      }
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      "UPDATE family_payment_events SET status='voided', updated_at=? WHERE id=? AND ledger_id=?",
      [now, eventId, ledgerId],
    );
    final evidenceRows = await db
        .customSelect(
          'SELECT * FROM family_payment_evidence WHERE event_id=?',
          variables: [Variable<String>(eventId)],
        )
        .get();
    await _resolveEventDrafts(
      ledgerId: ledgerId,
      eventId: eventId,
      evidenceRows: evidenceRows,
      explicitDraftId: null,
      transactionId: null,
      now: now,
    );
  });

  Future<void> _syncDraftsForEvent({
    required String eventId,
    required String? role,
    required String? fundingAccountId,
  }) async {
    final evidenceRows = await db
        .customSelect(
          'SELECT capture_id FROM family_payment_evidence WHERE event_id=?',
          variables: [Variable<String>(eventId)],
        )
        .get();
    final draftIds = [
      for (final r in evidenceRows) 'auto-${r.read<String>('capture_id')}',
    ];
    if (draftIds.isEmpty) return;
    final placeholders = List.filled(draftIds.length, '?').join(',');
    final drafts = await db
        .customSelect(
          "SELECT id, parsed_json FROM transaction_drafts WHERE id IN ($placeholders) AND status='pending'",
          variables: [for (final id in draftIds) Variable<String>(id)],
        )
        .get();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final d in drafts) {
      final parsed = Map<String, Object?>.from(
        jsonDecode(d.read<String>('parsed_json')) as Map,
      );
      parsed['family_event_id'] = eventId;
      parsed['family_role'] = role;
      if (role == FamilyLocalRole.beneficiary.name) {
        parsed['account_id'] = null;
      } else if (fundingAccountId != null) {
        parsed['account_id'] = fundingAccountId;
      }
      final evMap = Map<String, Object?>.from(
        (parsed['evidence'] as Map?) ?? const {},
      );
      evMap['family_event_id'] = eventId;
      if (role != null) evMap['family_role'] = role;
      parsed['evidence'] = evMap;
      await db.customStatement(
        'UPDATE transaction_drafts SET parsed_json=?, updated_at=? WHERE id=?',
        [jsonEncode(parsed), now, d.read<String>('id')],
      );
    }
  }

  Future<void> _resolveEventDrafts({
    required String ledgerId,
    required String eventId,
    required List<QueryRow> evidenceRows,
    required String? explicitDraftId,
    required String? transactionId,
    required String now,
  }) async {
    final candidateIds = <String>{
      ?explicitDraftId,
      for (final r in evidenceRows) 'auto-${r.read<String>('capture_id')}',
    };
    final allPending = await db
        .customSelect(
          '''SELECT d.id, d.parsed_json FROM transaction_drafts d
          JOIN raw_transactions r ON r.id=d.raw_id
          WHERE r.ledger_id=? AND d.status='pending' ''',
          variables: [Variable<String>(ledgerId)],
        )
        .get();
    for (final row in allPending) {
      final id = row.read<String>('id');
      final parsed = jsonDecode(row.read<String>('parsed_json'));
      if (parsed is Map &&
          (parsed['family_event_id'] == eventId ||
              (parsed['evidence'] is Map &&
                  parsed['evidence']['family_event_id'] == eventId))) {
        candidateIds.add(id);
      }
    }
    if (candidateIds.isEmpty) return;

    var postedAssigned = false;
    if (transactionId != null) {
      final alreadyLinked = await db
          .customSelect(
            'SELECT id FROM transaction_drafts WHERE transaction_id=?',
            variables: [Variable<String>(transactionId)],
          )
          .get();
      if (alreadyLinked.isNotEmpty) {
        postedAssigned = true;
      }
    }
    final orderedIds = [
      if (explicitDraftId != null && candidateIds.contains(explicitDraftId))
        explicitDraftId,
      ...candidateIds.where((id) => id != explicitDraftId),
    ];
    for (final id in orderedIds) {
      if (transactionId != null && !postedAssigned) {
        final changed = await db.customUpdate(
          "UPDATE transaction_drafts SET status='posted', transaction_id=?, updated_at=? WHERE id=? AND status='pending'",
          variables: [
            Variable<String>(transactionId),
            Variable<String>(now),
            Variable<String>(id),
          ],
        );
        if (changed == 1) {
          postedAssigned = true;
          continue;
        }
      }
      await db.customStatement(
        "UPDATE transaction_drafts SET status='ignored', updated_at=? WHERE id=? AND status='pending'",
        [now, id],
      );
    }
  }

  Future<String?> _orderHash(FamilyCardPlatform platform, String text) async {
    final match = RegExp(
      r'(?:交易单号|支付单号|商户单号|订单号|付款单号|交易号|流水号)\s*[:：]?\s*([A-Za-z0-9_-]{8,80})',
    ).firstMatch(text);
    if (match == null) return null;
    final digest = await Sha256().hash(
      utf8.encode('${platform.name}:${match[1]}'),
    );
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
