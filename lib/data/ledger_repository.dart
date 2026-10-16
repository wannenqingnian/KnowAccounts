import 'dart:convert';
import '../domain/attachment.dart';
import '../core/security/source_privacy.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../core/database/app_database.dart';
import '../domain/family_payment.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/pending_batch.dart';
import '../domain/tags.dart';
import '../domain/credit_settings.dart';
import '../core/security/card_vault.dart';
import '../domain/banks.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/confidence/confidence_models.dart';
import '../transaction/confidence/confidence_engine.dart';
import '../transaction/auto_correction.dart';
import '../transaction/transaction_identity.dart';
import '../transaction/transaction_pipeline.dart';

class LedgerRepository {
  LedgerRepository(this.db, {this.cardVault});
  final AppDatabase db;
  final CardVault? cardVault;
  static const _uuid = Uuid();
  static const trashRetentionOptions = <int>{0, 1, 7, 30, 90};

  Future<List<QueryRow>> _query(String sql, [List<Object> args = const []]) =>
      db
          .customSelect(
            sql,
            variables: args
                .map<Variable>(
                  (v) => v is int
                      ? Variable<int>(v)
                      : Variable<String>(v as String),
                )
                .toList(),
          )
          .get();

  Future<void> initialize({bool processRecurring = true}) async {
    await db.transaction(() async {
      final existing = await _query('SELECT id FROM ledgers LIMIT 1');
      if (existing.isEmpty) await _createLedger('个人账本', id: 'personal');
      await db.customStatement('INSERT OR IGNORE INTO settings VALUES (?, ?)', [
        'device_id',
        _uuid.v4(),
      ]);
    });
    await purgeExpiredTrash();
    if (processRecurring) await processDueRecurringRules();
  }

  Future<void> _createLedger(String name, {String? id}) async {
    final ledger = id ?? _uuid.v4();
    await db.customStatement('INSERT INTO ledgers VALUES (?, ?, ?, ?)', [
      ledger,
      name.trim(),
      'CNY',
      DateTime.now().toUtc().toIso8601String(),
    ]);
    await db.customStatement(
      '''INSERT INTO currencies
      (ledger_id,code,name,symbol,rate_to_cny_micros,decimals,updated_at)
      VALUES (?,?,?,?,?,?,?)''',
      [
        ledger,
        'CNY',
        '人民币',
        '¥',
        1000000,
        2,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    for (final item in [
      ('现金', AccountKind.cash),
      ('银行卡', AccountKind.bank),
      ('微信', AccountKind.wechat),
      ('支付宝', AccountKind.alipay),
    ]) {
      await addAccount(ledger, item.$1, item.$2, 0);
    }
    for (final item in [
      ('餐饮', ['早餐', '午餐', '晚餐', '咖啡', '外卖']),
      ('交通', ['公交地铁', '打车']),
      ('购物', ['日用品', '服饰']),
      ('居住', ['房租', '水电']),
      ('娱乐', <String>[]),
      ('其他', <String>[]),
    ]) {
      final parent = await addCategory(
        ledger,
        item.$1,
        TransactionType.expense,
      );
      for (final child in item.$2) {
        await addCategory(
          ledger,
          child,
          TransactionType.expense,
          parentId: parent,
        );
      }
    }
    for (final name in ['工资', '奖金', '兼职', '其他收入']) {
      await addCategory(ledger, name, TransactionType.income);
    }
  }

  Future<void> createLedger(String name) async {
    if (name.trim().isEmpty) throw const LedgerException('请输入账本名称');
    await db.transaction(() => _createLedger(name));
  }

  Future<Map<String, String>> ledgers() async => {
    for (final row in await _query(
      'SELECT id, name FROM ledgers ORDER BY created_at',
    ))
      row.read<String>('id'): row.read<String>('name'),
  };

  Future<List<AutoCorrectionRule>> autoCorrectionRules(
    String ledger, {
    bool onlyApplicable = false,
    bool allLedgers = false,
  }) async =>
      (await _query(
            '''SELECT * FROM auto_correction_rules r WHERE ${allLedgers ? '1=1' : 'ledger_id=?'}
            ${onlyApplicable ? '''AND enabled=1
            AND (account_id IS NULL OR EXISTS (SELECT 1 FROM accounts a
              WHERE a.id=r.account_id AND a.ledger_id=r.ledger_id AND a.archived_at IS NULL))
            AND (category_id IS NULL OR EXISTS (SELECT 1 FROM categories c
              WHERE c.id=r.category_id AND c.ledger_id=r.ledger_id
              AND c.type=r.type AND c.archived_at IS NULL))''' : ''}
            ORDER BY enabled DESC, priority DESC, updated_at DESC, merchant_pattern''',
            allLedgers ? const [] : [ledger],
          ))
          .map(
            (row) => AutoCorrectionRule(
              id: row.read('id'),
              ledgerId: row.read('ledger_id'),
              merchantPattern: row.read('merchant_pattern'),
              normalizedPattern: row.read('normalized_pattern'),
              matchMode: AutoCorrectionMatchMode.values.byName(
                row.read('match_mode'),
              ),
              type: TransactionType.values.byName(row.read('type')),
              accountId: row.readNullable('account_id'),
              categoryId: row.readNullable('category_id'),
              tags: decodeTags(row.read('tags_json')),
              enabled: row.read<int>('enabled') == 1,
              learned: row.read<int>('learned') == 1,
              priority: row.read('priority'),
              useCount: row.read('use_count'),
              lastUsedAt: DateTime.tryParse(
                row.readNullable<String>('last_used_at') ?? '',
              ),
              updatedAt: DateTime.parse(row.read('updated_at')),
              sourceKey: row.read<String>('source_key'),
              minAmountMinor: row.readNullable<int>('min_amount_minor'),
              maxAmountMinor: row.readNullable<int>('max_amount_minor'),
              paymentMethodPattern: row.read<String>('payment_method_pattern'),
              startMinute: row.readNullable<int>('start_minute'),
              endMinute: row.readNullable<int>('end_minute'),
              weekdaysMask: row.read<int>('weekdays_mask'),
              sourceAccountId: row.readNullable<String>('source_account_id'),
            ),
          )
          .toList();

  Future<TransactionDraft> applyAutoCorrectionRule(
    TransactionDraft draft, {
    List<AutoCorrectionRule>? rules,
  }) async {
    final merchantKey = normalizeMerchantPattern(draft.merchant);
    if (merchantKey.isNotEmpty) {
      final knowledge = await _query(
        '''SELECT k.canonical_name,k.default_category_id FROM merchant_knowledge k
        JOIN merchant_aliases a ON a.merchant_id=k.id
        WHERE k.ledger_id=? AND k.enabled=1 AND a.normalized_alias=?
        AND (k.source_key='' OR k.source_key=?) ORDER BY
        CASE WHEN k.source_key=? THEN 0 ELSE 1 END LIMIT 1''',
        [
          draft.ledgerId,
          merchantKey,
          autoCorrectionSourceKey(draft),
          autoCorrectionSourceKey(draft),
        ],
      );
      if (knowledge.isNotEmpty) {
        final row = knowledge.single;
        draft = draft.withMerchantKnowledge(
          merchant: row.read<String>('canonical_name'),
          categoryId:
              draft.categoryId ??
              row.readNullable<String>('default_category_id'),
          evidenceText: '已匹配本地商户别名与来源映射',
        );
      }
    }
    if (draft.categoryId == null && draft.merchant.trim().isNotEmpty) {
      final category = await personalizedCategoryCandidate(
        draft.ledgerId,
        draft.merchant,
        sourceKey: autoCorrectionSourceKey(draft),
      );
      if (category != null) {
        draft = draft.withBatchEdits(categoryId: category);
      }
    }
    final available =
        rules ??
        await autoCorrectionRules(
          draft.ledgerId,
          onlyApplicable: true,
          allLedgers: true,
        );
    final matched = bestAutoCorrection(available, draft);
    if (matched == null) return draft;
    String? accountId = matched.accountId;
    String? categoryId = matched.categoryId;
    if (accountId != null &&
        (await _query(
          'SELECT 1 FROM accounts WHERE id=? AND ledger_id=? AND archived_at IS NULL',
          [accountId, matched.ledgerId],
        )).isEmpty) {
      accountId = null;
    }
    if (categoryId != null &&
        (await _query(
          'SELECT 1 FROM categories WHERE id=? AND ledger_id=? AND type=? AND archived_at IS NULL',
          [categoryId, matched.ledgerId, draft.type.name],
        )).isEmpty) {
      categoryId = null;
    }
    final usable = AutoCorrectionRule(
      id: matched.id,
      ledgerId: matched.ledgerId,
      merchantPattern: matched.merchantPattern,
      normalizedPattern: matched.normalizedPattern,
      type: matched.type,
      accountId: accountId,
      categoryId: categoryId,
      matchMode: matched.matchMode,
      tags: matched.tags,
      enabled: matched.enabled,
      learned: matched.learned,
      priority: matched.priority,
      useCount: matched.useCount,
      updatedAt: matched.updatedAt,
      lastUsedAt: matched.lastUsedAt,
      sourceKey: matched.sourceKey,
      minAmountMinor: matched.minAmountMinor,
      maxAmountMinor: matched.maxAmountMinor,
      paymentMethodPattern: matched.paymentMethodPattern,
      startMinute: matched.startMinute,
      endMinute: matched.endMinute,
      weekdaysMask: matched.weekdaysMask,
      sourceAccountId: matched.sourceAccountId,
    );
    final corrected = applyAutoCorrection(draft, [usable]);
    final sourceLedger =
        draft.evidence['auto_correction_source_ledger'] ?? draft.ledgerId;
    final fingerprint = [
      matched.id,
      draft.raw.capturedAt.toUtc().toIso8601String(),
      sourceLedger,
      normalizeMerchantPattern(draft.merchant),
      draft.amountMinor ?? '',
    ].join('|');
    await db.customStatement(
      '''INSERT OR IGNORE INTO auto_correction_events
      (id,rule_id,event_type,merchant,amount_minor,source_ledger_id,target_ledger_id,
       source_key,payment_method,before_json,after_json,fingerprint,created_at)
      VALUES (?,?,'match',?,?,?,?,?,?,?,?,?,?)''',
      [
        _uuid.v4(),
        matched.id,
        draft.merchant,
        draft.amountMinor,
        sourceLedger,
        matched.ledgerId,
        autoCorrectionSourceKey(draft),
        draft.raw.paymentMethod,
        '',
        jsonEncode(corrected.toJson()),
        fingerprint,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return corrected;
  }

  Future<String> saveAutoCorrectionRule(
    String ledger, {
    String? id,
    required String merchantPattern,
    required TransactionType type,
    required String? accountId,
    required String? categoryId,
    AutoCorrectionMatchMode matchMode = AutoCorrectionMatchMode.exact,
    List<String> tags = const [],
    bool enabled = true,
    int priority = 0,
    String sourceKey = '',
    int? minAmountMinor,
    int? maxAmountMinor,
    String paymentMethodPattern = '',
    int? startMinute,
    int? endMinute,
    int weekdaysMask = 127,
    String? sourceAccountId,
  }) async {
    final merchant = merchantPattern.trim();
    final normalized = normalizeMerchantPattern(merchant);
    if (merchant.isEmpty || merchant.length > 100 || normalized.isEmpty) {
      throw const LedgerException('商户匹配词需为1～100个有效字符');
    }
    if (!const [
      TransactionType.expense,
      TransactionType.income,
    ].contains(type)) {
      throw const LedgerException('自动修正仅支持普通收入或支出');
    }
    if (priority < -1000 || priority > 1000) {
      throw const LedgerException('规则优先级需在 -1000～1000 之间');
    }
    if (minAmountMinor != null && minAmountMinor < 0 ||
        maxAmountMinor != null && maxAmountMinor < 0 ||
        minAmountMinor != null &&
            maxAmountMinor != null &&
            minAmountMinor > maxAmountMinor) {
      throw const LedgerException('金额范围无效');
    }
    if (sourceKey.isNotEmpty &&
        !RegExp(r'^(channel|app):[a-zA-Z0-9._-]+$').hasMatch(sourceKey)) {
      throw const LedgerException('支付来源条件无效');
    }
    if ((startMinute != null && (startMinute < 0 || startMinute > 1439)) ||
        (endMinute != null && (endMinute < 0 || endMinute > 1439)) ||
        weekdaysMask < 1 ||
        weekdaysMask > 127) {
      throw const LedgerException('时间段或星期条件无效');
    }
    if (accountId != null &&
        (await _query(
          'SELECT 1 FROM accounts WHERE id=? AND ledger_id=? AND archived_at IS NULL',
          [accountId, ledger],
        )).isEmpty) {
      throw const LedgerException('规则账户不存在或已归档');
    }
    if (categoryId != null &&
        (await _query(
          'SELECT 1 FROM categories WHERE id=? AND ledger_id=? AND type=? AND archived_at IS NULL',
          [categoryId, ledger, type.name],
        )).isEmpty) {
      throw const LedgerException('规则分类不存在、已归档或收支方向不符');
    }
    if (accountId == null && categoryId == null && tags.isEmpty) {
      throw const LedgerException('请至少选择账户、分类或填写标签');
    }
    final normalizedTags = normalizeTags(tags);
    final now = DateTime.now().toUtc().toIso8601String();
    final ruleId = id ?? _uuid.v4();
    try {
      if (id == null) {
        await db.customStatement(
          '''INSERT INTO auto_correction_rules
          (id,ledger_id,merchant_pattern,normalized_pattern,match_mode,type,
           account_id,category_id,source_key,min_amount_minor,max_amount_minor,
           payment_method_pattern,start_minute,end_minute,weekdays_mask,source_account_id,
           tags_json,enabled,learned,priority,use_count,
           last_used_at,created_at,updated_at)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,0,NULL,?,?)''',
          [
            ruleId,
            ledger,
            merchant,
            normalized,
            matchMode.name,
            type.name,
            accountId,
            categoryId,
            sourceKey,
            minAmountMinor,
            maxAmountMinor,
            paymentMethodPattern.trim(),
            startMinute,
            endMinute,
            weekdaysMask,
            sourceAccountId,
            jsonEncode(normalizedTags),
            enabled ? 1 : 0,
            priority,
            now,
            now,
          ],
        );
      } else {
        final existing = await _query(
          'SELECT 1 FROM auto_correction_rules WHERE id=?',
          [id],
        );
        if (existing.isEmpty) throw const LedgerException('自动修正规则不存在');
        await db.customStatement(
          '''UPDATE auto_correction_rules SET merchant_pattern=?,
          ledger_id=?,normalized_pattern=?,match_mode=?,type=?,account_id=?,category_id=?,
          source_key=?,min_amount_minor=?,max_amount_minor=?,payment_method_pattern=?,
          start_minute=?,end_minute=?,weekdays_mask=?,source_account_id=?,
          tags_json=?,enabled=?,learned=0,priority=?,updated_at=? WHERE id=?''',
          [
            merchant,
            ledger,
            normalized,
            matchMode.name,
            type.name,
            accountId,
            categoryId,
            sourceKey,
            minAmountMinor,
            maxAmountMinor,
            paymentMethodPattern.trim(),
            startMinute,
            endMinute,
            weekdaysMask,
            sourceAccountId,
            jsonEncode(normalizedTags),
            enabled ? 1 : 0,
            priority,
            now,
            id,
          ],
        );
      }
    } on LedgerException {
      rethrow;
    } catch (_) {
      throw const LedgerException('自动修正规则保存失败');
    }
    return ruleId;
  }

  Future<void> setAutoCorrectionEnabled(
    String ledger,
    String id,
    bool enabled,
  ) async {
    await db.customStatement(
      'UPDATE auto_correction_rules SET enabled=?,updated_at=? WHERE id=?',
      [enabled ? 1 : 0, DateTime.now().toUtc().toIso8601String(), id],
    );
  }

  Future<void> deleteAutoCorrectionRule(String ledger, String id) async {
    await db.customStatement('DELETE FROM auto_correction_rules WHERE id=?', [
      id,
    ]);
  }

  Future<void> _learnAutoCorrection(
    String ledger,
    TransactionInput input, {
    required String learningEventId,
    required String sourceLedgerId,
    String? sourceAccountId,
    String sourceKey = '',
    String paymentMethod = '',
    bool explicitRemember = false,
  }) async {
    if (!const [
      TransactionType.expense,
      TransactionType.income,
    ].contains(input.type)) {
      return;
    }
    final merchant = input.merchant.trim();
    final normalized = normalizeMerchantPattern(merchant);
    if (merchant.isEmpty || merchant.length > 100 || normalized.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = await _query(
      '''SELECT 1 FROM auto_correction_rules WHERE ledger_id=? AND
      normalized_pattern=? AND type=? AND enabled=1 LIMIT 1''',
      [ledger, normalized, input.type.name],
    );
    if (existing.isNotEmpty) return;
    await db.customStatement(
      '''INSERT INTO learning_observations
      (id,learning_event_id,normalized_merchant,merchant,type,source_key,payment_method,
       source_account_id,final_account_id,final_category_id,final_tags_json,
       source_ledger_id,final_ledger_id,minute_of_day,weekday,explicit_remember,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        _uuid.v4(),
        learningEventId,
        normalized,
        merchant,
        input.type.name,
        sourceKey,
        paymentMethod.trim(),
        sourceAccountId,
        input.accountId,
        input.categoryId,
        jsonEncode(normalizeTags(input.tags)),
        sourceLedgerId,
        ledger,
        input.occurredDate.hour * 60 + input.occurredDate.minute,
        input.occurredDate.weekday,
        explicitRemember ? 1 : 0,
        now,
      ],
    );
    final rejected = await _query(
      "SELECT 1 FROM auto_correction_suggestions WHERE ledger_id=? AND normalized_pattern=? AND type=? AND source_key=? AND status='rejected' LIMIT 1",
      [ledger, normalized, input.type.name, sourceKey],
    );
    if (rejected.isNotEmpty && !explicitRemember) return;
    final totals = await _query(
      '''SELECT COUNT(*) AS total FROM learning_observations WHERE
      normalized_merchant=? AND type=? AND source_key=?''',
      [normalized, input.type.name, sourceKey],
    );
    final total = totals.single.read<int>('total');
    if (!explicitRemember && total < 3) return;
    final groups = await _query(
      '''SELECT final_ledger_id,final_account_id,final_category_id,final_tags_json,
      COUNT(*) AS uses FROM learning_observations WHERE normalized_merchant=?
      AND type=? AND source_key=? GROUP BY final_ledger_id,final_account_id,
      final_category_id,final_tags_json ORDER BY uses DESC LIMIT 5''',
      [normalized, input.type.name, sourceKey],
    );
    if (groups.isEmpty) return;
    final winner = groups.first;
    final uses = winner.read<int>('uses');
    final consistency = total == 0 ? 0 : (uses * 10000 ~/ total);
    if (!explicitRemember && consistency < 8000) return;
    // This condition stays explicit. Inferring it from a stable account would
    // stop the rule from filling that account when recognition omitted it.
    const String? stableSourceAccount = null;
    final conflicts = [
      for (final group in groups.skip(1))
        {
          'ledger': group.read<String>('final_ledger_id'),
          'account': group.readNullable<String>('final_account_id'),
          'category': group.readNullable<String>('final_category_id'),
          'tags': decodeTags(group.read<String>('final_tags_json')),
          'count': group.read<int>('uses'),
        },
    ];
    // Learning is staged. Only a stable cluster (or the explicit “remember”
    // action) becomes a suggestion, and a suggestion never changes a rule.
    await db.customStatement(
      '''INSERT INTO auto_correction_suggestions
      (id,ledger_id,merchant_pattern,normalized_pattern,type,account_id,category_id,
       tags_json,source_key,payment_method_pattern,source_account_id,status,reason,
       sample_count,consistency_bps,conflict_json,created_at,learning_event_id)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,'pending',?,?,?,?,?,?)
      ON CONFLICT(ledger_id,normalized_pattern,type,source_key,status) DO UPDATE SET
       merchant_pattern=excluded.merchant_pattern,account_id=excluded.account_id,
       category_id=excluded.category_id,tags_json=excluded.tags_json,
       payment_method_pattern=excluded.payment_method_pattern,
       source_account_id=excluded.source_account_id,sample_count=excluded.sample_count,
       consistency_bps=excluded.consistency_bps,conflict_json=excluded.conflict_json,
       learning_event_id=excluded.learning_event_id,created_at=excluded.created_at''',
      [
        _uuid.v4(),
        winner.read<String>('final_ledger_id'),
        merchant,
        normalized,
        input.type.name,
        winner.readNullable<String>('final_account_id'),
        winner.readNullable<String>('final_category_id'),
        winner.read<String>('final_tags_json'),
        sourceKey,
        paymentMethod.trim(),
        stableSourceAccount,
        explicitRemember ? '用户明确选择记住本次设置' : '历史选择达到稳定性门槛',
        total,
        consistency,
        jsonEncode(conflicts),
        now,
        learningEventId,
      ],
    );
  }

  Future<List<AutoCorrectionSuggestion>> autoCorrectionSuggestions({
    RuleSuggestionStatus status = RuleSuggestionStatus.pending,
  }) async =>
      (await _query(
            '''SELECT * FROM auto_correction_suggestions WHERE status=?
    ORDER BY created_at DESC''',
            [status.name],
          ))
          .map(
            (row) => AutoCorrectionSuggestion(
              id: row.read('id'),
              ledgerId: row.read('ledger_id'),
              merchantPattern: row.read('merchant_pattern'),
              type: TransactionType.values.byName(row.read('type')),
              accountId: row.readNullable('account_id'),
              categoryId: row.readNullable('category_id'),
              tags: decodeTags(row.read('tags_json')),
              sourceKey: row.read('source_key'),
              paymentMethodPattern: row.read('payment_method_pattern'),
              status: RuleSuggestionStatus.values.byName(row.read('status')),
              reason: row.read('reason'),
              sampleCount: row.read<int>('sample_count'),
              consistencyBps: row.read<int>('consistency_bps'),
              conflicts: (jsonDecode(row.read<String>('conflict_json')) as List)
                  .map((value) => Map<String, Object?>.from(value as Map))
                  .toList(),
              createdAt: DateTime.parse(row.read('created_at')),
            ),
          )
          .toList();

  Future<String> acceptAutoCorrectionSuggestion(
    String id, {
    String? merchantPattern,
    String? accountId,
    String? categoryId,
    List<String>? tags,
  }) => db.transaction(() async {
    final rows = await _query(
      "SELECT * FROM auto_correction_suggestions WHERE id=? AND status='pending'",
      [id],
    );
    if (rows.isEmpty) throw const LedgerException('规则建议不存在或已处理');
    final row = rows.single;
    final ruleId = await saveAutoCorrectionRule(
      row.read('ledger_id'),
      merchantPattern: merchantPattern ?? row.read('merchant_pattern'),
      type: TransactionType.values.byName(row.read('type')),
      accountId: accountId ?? row.readNullable('account_id'),
      categoryId: categoryId ?? row.readNullable('category_id'),
      tags: tags ?? decodeTags(row.read('tags_json')),
      sourceKey: row.read('source_key'),
      paymentMethodPattern: row.read('payment_method_pattern'),
      minAmountMinor: row.readNullable('min_amount_minor'),
      maxAmountMinor: row.readNullable('max_amount_minor'),
      startMinute: row.readNullable('start_minute'),
      endMinute: row.readNullable('end_minute'),
      weekdaysMask: row.read<int>('weekdays_mask'),
      sourceAccountId: row.readNullable('source_account_id'),
    );
    await db.customStatement(
      "UPDATE auto_correction_suggestions SET status='accepted',accepted_rule_id=?,decided_at=? WHERE id=?",
      [ruleId, DateTime.now().toUtc().toIso8601String(), id],
    );
    return ruleId;
  });

  Future<void> rejectAutoCorrectionSuggestion(String id) => db.customStatement(
    "UPDATE auto_correction_suggestions SET status='rejected',decided_at=? WHERE id=? AND status='pending'",
    [DateTime.now().toUtc().toIso8601String(), id],
  );

  Future<List<MerchantKnowledge>> merchantKnowledge(String ledger) async {
    final rows = await _query(
      'SELECT * FROM merchant_knowledge WHERE ledger_id=? ORDER BY canonical_name',
      [ledger],
    );
    final values = <MerchantKnowledge>[];
    for (final row in rows) {
      final aliases = await _query(
        'SELECT alias FROM merchant_aliases WHERE merchant_id=? ORDER BY alias',
        [row.read<String>('id')],
      );
      values.add(
        MerchantKnowledge(
          id: row.read('id'),
          ledgerId: ledger,
          canonicalName: row.read('canonical_name'),
          aliases: aliases.map((value) => value.read<String>('alias')).toList(),
          defaultCategoryId: row.readNullable('default_category_id'),
          sourceKey: row.read('source_key'),
          enabled: row.read<int>('enabled') == 1,
        ),
      );
    }
    return values;
  }

  Future<String> saveMerchantKnowledge(
    String ledger, {
    String? id,
    required String canonicalName,
    required List<String> aliases,
    String? defaultCategoryId,
    String sourceKey = '',
    bool enabled = true,
  }) => db.transaction(() async {
    final name = canonicalName.trim();
    final normalized = normalizeMerchantPattern(name);
    if (name.isEmpty || normalized.isEmpty) {
      throw const LedgerException('商户名称不能为空');
    }
    final knowledgeId = id ?? _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      '''INSERT INTO merchant_knowledge
      (id,ledger_id,canonical_name,normalized_name,default_category_id,source_key,enabled,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET canonical_name=excluded.canonical_name,
      normalized_name=excluded.normalized_name,default_category_id=excluded.default_category_id,
      source_key=excluded.source_key,enabled=excluded.enabled,updated_at=excluded.updated_at''',
      [
        knowledgeId,
        ledger,
        name,
        normalized,
        defaultCategoryId,
        sourceKey,
        enabled ? 1 : 0,
        now,
        now,
      ],
    );
    await db.customStatement(
      'DELETE FROM merchant_aliases WHERE merchant_id=?',
      [knowledgeId],
    );
    for (final alias in {
      name,
      ...aliases.map((value) => value.trim()),
    }.where((value) => value.isNotEmpty)) {
      final normalizedAlias = normalizeMerchantPattern(alias);
      if (normalizedAlias.isEmpty) continue;
      await db.customStatement(
        '''INSERT OR IGNORE INTO merchant_aliases
        (id,merchant_id,alias,normalized_alias,source_key,created_at) VALUES (?,?,?,?,?,?)''',
        [_uuid.v4(), knowledgeId, alias, normalizedAlias, sourceKey, now],
      );
    }
    return knowledgeId;
  });

  Future<void> deleteMerchantKnowledge(String id) =>
      db.customStatement('DELETE FROM merchant_knowledge WHERE id=?', [id]);

  Future<String?> personalizedCategoryCandidate(
    String ledger,
    String merchant, {
    String sourceKey = '',
  }) async {
    final normalized = normalizeMerchantPattern(merchant);
    if (normalized.isEmpty) return null;
    final direct = await _query(
      '''SELECT k.default_category_id FROM merchant_knowledge k
      JOIN merchant_aliases a ON a.merchant_id=k.id
      WHERE k.ledger_id=? AND k.enabled=1 AND a.normalized_alias=?
      AND (k.source_key='' OR k.source_key=?) LIMIT 1''',
      [ledger, normalized, sourceKey],
    );
    if (direct.isNotEmpty) {
      return direct.single.readNullable('default_category_id');
    }
    final history = await _query(
      '''SELECT category_id,COUNT(*) AS uses FROM transactions
      WHERE ledger_id=? AND deleted_at IS NULL AND category_id IS NOT NULL
      AND lower(replace(replace(merchant,' ',''),'　',''))=?
      GROUP BY category_id ORDER BY uses DESC,MAX(occurred_date) DESC LIMIT 1''',
      [ledger, merchant.toLowerCase().replaceAll(RegExp(r'\s+'), '')],
    );
    return history.firstOrNull?.readNullable<String>('category_id');
  }

  Future<void> _addAutoCorrectionEvent({
    required String? ruleId,
    required String eventType,
    required String merchant,
    required int? amountMinor,
    required String sourceLedgerId,
    required String targetLedgerId,
    String? transactionId,
    String sourceKey = '',
    String paymentMethod = '',
    String beforeJson = '',
    String afterJson = '',
    String? fingerprint,
  }) => db.customStatement(
    '''INSERT OR IGNORE INTO auto_correction_events
    (id,rule_id,event_type,transaction_id,merchant,amount_minor,source_ledger_id,
     target_ledger_id,source_key,payment_method,before_json,after_json,fingerprint,created_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
    [
      _uuid.v4(),
      ruleId,
      eventType,
      transactionId,
      merchant,
      amountMinor,
      sourceLedgerId,
      targetLedgerId,
      sourceKey,
      paymentMethod,
      beforeJson,
      afterJson,
      fingerprint ?? _uuid.v4(),
      DateTime.now().toUtc().toIso8601String(),
    ],
  );

  Future<List<AutoCorrectionEvent>> autoCorrectionEvents({
    int limit = 200,
  }) async =>
      (await _query(
            '''SELECT * FROM auto_correction_events ORDER BY created_at DESC LIMIT ?''',
            [limit.clamp(1, 500)],
          ))
          .map(
            (row) => AutoCorrectionEvent(
              id: row.read('id'),
              ruleId: row.readNullable('rule_id'),
              eventType: row.read('event_type'),
              transactionId: row.readNullable('transaction_id'),
              merchant: row.read('merchant'),
              amountMinor: row.readNullable('amount_minor'),
              sourceLedgerId: row.read('source_ledger_id'),
              targetLedgerId: row.read('target_ledger_id'),
              sourceKey: row.read('source_key'),
              paymentMethod: row.read('payment_method'),
              createdAt: DateTime.parse(row.read('created_at')),
              undoneAt: DateTime.tryParse(
                row.readNullable<String>('undone_at') ?? '',
              ),
            ),
          )
          .toList();

  Future<void> undoLatestAutoCorrectionLearning(
    String ruleId,
  ) => db.transaction(() async {
    final events = await _query(
      '''SELECT * FROM auto_correction_events WHERE rule_id=?
      AND event_type IN ('learn_created','learn_updated') AND undone_at IS NULL
      ORDER BY created_at DESC LIMIT 1''',
      [ruleId],
    );
    if (events.isEmpty) throw const LedgerException('没有可撤销的学习记录');
    final current = await _query(
      'SELECT learned FROM auto_correction_rules WHERE id=?',
      [ruleId],
    );
    if (current.isEmpty || current.single.read<int>('learned') != 1) {
      throw const LedgerException('规则已被手动编辑，不能撤销自动学习');
    }
    final event = events.single;
    final before = event.read<String>('before_json');
    if (event.read<String>('event_type') == 'learn_created') {
      await db.customStatement('DELETE FROM auto_correction_rules WHERE id=?', [
        ruleId,
      ]);
    } else {
      final value = jsonDecode(before) as Map<String, dynamic>;
      await db.customStatement(
        '''UPDATE auto_correction_rules SET ledger_id=?,merchant_pattern=?,normalized_pattern=?,
        match_mode=?,type=?,account_id=?,category_id=?,source_key=?,min_amount_minor=?,
        max_amount_minor=?,payment_method_pattern=?,tags_json=?,enabled=?,learned=?,priority=?,
        use_count=?,last_used_at=?,created_at=?,updated_at=? WHERE id=?''',
        [
          value['ledger_id'],
          value['merchant_pattern'],
          value['normalized_pattern'],
          value['match_mode'],
          value['type'],
          value['account_id'],
          value['category_id'],
          value['source_key'],
          value['min_amount_minor'],
          value['max_amount_minor'],
          value['payment_method_pattern'],
          value['tags_json'],
          value['enabled'],
          value['learned'],
          value['priority'],
          value['use_count'],
          value['last_used_at'],
          value['created_at'],
          value['updated_at'],
          ruleId,
        ],
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      'UPDATE auto_correction_events SET undone_at=? WHERE id=?',
      [now, event.read<String>('id')],
    );
    await _addAutoCorrectionEvent(
      ruleId: ruleId,
      eventType: 'undo',
      merchant: event.read('merchant'),
      amountMinor: event.readNullable('amount_minor'),
      sourceLedgerId: event.read('source_ledger_id'),
      targetLedgerId: event.read('target_ledger_id'),
      beforeJson: event.read('after_json'),
      afterJson: before,
    );
  });

  Future<AutoCorrectionRule> _autoCorrectionRule(String id) async {
    final values = await autoCorrectionRules('', allLedgers: true);
    final rule = values.where((value) => value.id == id).firstOrNull;
    if (rule == null) throw const LedgerException('自动修正规则不存在');
    return rule;
  }

  Future<List<QueryRow>> _autoCorrectionBatchRows(
    AutoCorrectionRule rule,
  ) async {
    final rows = await _query(
      '''SELECT t.*,a.name AS account_name,r.source,r.source_app,r.payment_method,
      (SELECT COUNT(*) FROM transactions child WHERE child.related_transaction_id=t.id) AS child_count,
      (SELECT COUNT(*) FROM transaction_fx fx WHERE fx.transaction_id=t.id) AS fx_count,
      (SELECT COUNT(*) FROM transaction_group_items gi WHERE gi.transaction_id=t.id) AS group_count
      FROM transactions t JOIN accounts a ON a.id=t.account_id
      LEFT JOIN transaction_drafts d ON d.transaction_id=t.id
      LEFT JOIN raw_transactions r ON r.id=d.raw_id
      WHERE t.deleted_at IS NULL AND t.type=?''',
      [rule.type.name],
    );
    return rows.where((row) {
      final sourceName = row.readNullable<String>('source') ?? 'text';
      final draft = TransactionDraft(
        raw: RawTransaction(
          text: '历史账单',
          capturedAt: DateTime.parse(row.read<String>('occurred_date')),
          source: TransactionSource.values.byName(sourceName),
          sourceApp: row.readNullable<String>('source_app') ?? '',
          paymentMethod:
              row.readNullable<String>('payment_method') ??
              row.read<String>('account_name'),
        ),
        ledgerId: row.read<String>('ledger_id'),
        type: rule.type,
        amountMinor: row.read<int>('amount_minor'),
        occurredDate: DateTime.parse(row.read<String>('occurred_date')),
        accountId: row.read<String>('account_id'),
        categoryId: row.readNullable<String>('category_id'),
        merchant: row.read<String>('merchant'),
        tags: decodeTags(row.read<String>('tags_json')),
        warnings: const [],
        evidence: const {},
      );
      return autoCorrectionConditionsMatch(rule, draft);
    }).toList();
  }

  bool _canBatchCorrect(QueryRow row, AutoCorrectionRule rule) {
    if (row.readNullable<String>('related_transaction_id') != null ||
        row.read<int>('child_count') > 0 ||
        row.read<int>('fx_count') > 0 ||
        row.read<int>('group_count') > 0) {
      return false;
    }
    final sameLedger = row.read<String>('ledger_id') == rule.ledgerId;
    return (rule.accountId != null || sameLedger) &&
        (rule.categoryId != null || sameLedger);
  }

  Future<AutoCorrectionBatchPreview> previewAutoCorrectionBatch(
    String ruleId,
  ) async {
    final rule = await _autoCorrectionRule(ruleId);
    final rows = await _autoCorrectionBatchRows(rule);
    final eligible = rows.where((row) => _canBatchCorrect(row, rule)).length;
    return AutoCorrectionBatchPreview(
      matched: rows.length,
      eligible: eligible,
      skipped: rows.length - eligible,
    );
  }

  Future<AutoCorrectionBatchPreview> applyAutoCorrectionBatch(
    String ruleId,
  ) => db.transaction(() async {
    final rule = await _autoCorrectionRule(ruleId);
    final rows = await _autoCorrectionBatchRows(rule);
    var applied = 0;
    for (final row in rows) {
      if (!_canBatchCorrect(row, rule)) continue;
      final sourceLedger = row.read<String>('ledger_id');
      final account = rule.accountId ?? row.read<String>('account_id');
      final category =
          rule.categoryId ??
          (sourceLedger == rule.ledgerId
              ? row.readNullable<String>('category_id')
              : null);
      final transactionId = row.read<String>('id');
      final now = DateTime.now().toUtc().toIso8601String();
      final before = jsonEncode(row.data);
      await db.customStatement(
        '''UPDATE transactions SET ledger_id=?,account_id=?,category_id=?,tags_json=?,
        updated_at=?,version=version+1 WHERE id=?''',
        [
          rule.ledgerId,
          account,
          category,
          jsonEncode(rule.tags),
          now,
          transactionId,
        ],
      );
      await db.customStatement(
        'DELETE FROM transaction_postings WHERE transaction_id=?',
        [transactionId],
      );
      final delta = rule.type == TransactionType.expense
          ? -row.read<int>('amount_minor')
          : row.read<int>('amount_minor');
      await _post(transactionId, account, delta, 'CNY');
      await db.customStatement(
        '''UPDATE raw_transactions SET ledger_id=? WHERE id IN
        (SELECT raw_id FROM transaction_drafts WHERE transaction_id=?)''',
        [rule.ledgerId, transactionId],
      );
      final afterRows = await _query('SELECT * FROM transactions WHERE id=?', [
        transactionId,
      ]);
      await _addAutoCorrectionEvent(
        ruleId: rule.id,
        eventType: 'batch',
        transactionId: transactionId,
        merchant: row.read('merchant'),
        amountMinor: row.read('amount_minor'),
        sourceLedgerId: sourceLedger,
        targetLedgerId: rule.ledgerId,
        sourceKey: (row.readNullable<String>('source_app') ?? '').isNotEmpty
            ? 'app:${row.read<String>('source_app')}'
            : 'channel:${row.readNullable<String>('source') ?? 'text'}',
        paymentMethod: row.readNullable<String>('payment_method') ?? '',
        beforeJson: before,
        afterJson: jsonEncode(afterRows.single.data),
      );
      applied++;
    }
    return AutoCorrectionBatchPreview(
      matched: rows.length,
      eligible: applied,
      skipped: rows.length - applied,
    );
  });

  Future<void> addAccount(
    String ledger,
    String name,
    AccountKind kind,
    int opening, {
    String? providerId,
    int? repaymentDay,
    DateTime? dueDate,
    String? bankId,
    String? cardLast4,
    String? fullCardNumber,
    String currency = 'CNY',
  }) async {
    if (name.trim().isEmpty) throw const LedgerException('请输入账户名称');
    validateCreditSettings(kind, providerId, repaymentDay, dueDate);
    validateBankSettings(kind, bankId, cardLast4);
    if (fullCardNumber != null) {
      if (!RegExp(r'^\d{13,19}$').hasMatch(fullCardNumber) ||
          cardTailFromInput(fullCardNumber) != cardLast4) {
        throw const LedgerException('完整卡号与尾号不一致');
      }
      if (cardVault == null) throw const LedgerException('此设备未配置安全存储，完整卡号未保存');
    }
    if (opening.abs() > 999999999999) throw const LedgerException('期初余额超出有效范围');
    if ((await _query('SELECT 1 FROM currencies WHERE ledger_id=? AND code=?', [
      ledger,
      currency,
    ])).isEmpty) {
      throw const LedgerException('账户币种不存在');
    }
    final exists = await _query(
      'SELECT id FROM accounts WHERE ledger_id = ? AND name = ?',
      [ledger, name.trim()],
    );
    if (exists.isNotEmpty) throw const LedgerException('账户名称已存在');
    final secretId = fullCardNumber == null ? null : _uuid.v4();
    if (secretId != null) await cardVault!.write(secretId, fullCardNumber!);
    try {
      await db.customStatement(
        '''INSERT INTO accounts
      (id, ledger_id, name, kind, currency, opening_minor, created_at, provider_id, repayment_day, due_date, bank_id, card_last4, card_secret_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          _uuid.v4(),
          ledger,
          name.trim(),
          kind.name,
          currency,
          opening,
          DateTime.now().toUtc().toIso8601String(),
          providerId,
          repaymentDay,
          dueDate == null ? null : dateKey(dueDate),
          bankId,
          cardLast4,
          secretId,
        ],
      );
    } catch (_) {
      if (secretId != null) await cardVault!.delete(secretId);
      rethrow;
    }
  }

  /// Changing displayed balance adjusts opening balance, never rewrites postings.
  /// New secure references are written before the DB transaction; the original
  /// reference is retained if validation or the SQL update fails.
  Future<void> updateAccount(
    String ledger,
    String id,
    String name,
    AccountKind kind,
    int balance, {
    String? providerId,
    int? repaymentDay,
    DateTime? dueDate,
    String? bankId,
    String? cardLast4,
    String? fullCardNumber,
    bool replaceCard = false,
    String? currency,
  }) async {
    if (name.trim().isEmpty || name.trim().length > 100) {
      throw const LedgerException('账户名称需为1～100字');
    }
    validateCreditSettings(kind, providerId, repaymentDay, dueDate);
    validateBankSettings(kind, bankId, cardLast4);
    if (balance.abs() > 999999999999) throw const LedgerException('账户余额超出有效范围');
    if (fullCardNumber != null) {
      if (!replaceCard ||
          !RegExp(r'^\d{13,19}$').hasMatch(fullCardNumber) ||
          cardTailFromInput(fullCardNumber) != cardLast4) {
        throw const LedgerException('完整卡号与尾号不一致');
      }
      if (cardVault == null) throw const LedgerException('此设备未配置安全存储，完整卡号未保存');
    }
    String? newSecret;
    String? oldSecret;
    var committed = false;
    try {
      await db.transaction(() async {
        final rows = await _query(
          'SELECT * FROM accounts WHERE id=? AND ledger_id=? AND archived_at IS NULL',
          [id, ledger],
        );
        if (rows.isEmpty) throw const LedgerException('账户不存在');
        final duplicate = await _query(
          'SELECT id FROM accounts WHERE ledger_id=? AND name=? AND id!=?',
          [ledger, name.trim(), id],
        );
        if (duplicate.isNotEmpty) throw const LedgerException('账户名称已存在');
        final old = rows.single;
        final oldCurrency = old.read<String>('currency');
        final nextCurrency = currency ?? oldCurrency;
        if ((await _query(
          'SELECT 1 FROM currencies WHERE ledger_id=? AND code=?',
          [ledger, nextCurrency],
        )).isEmpty) {
          throw const LedgerException('账户币种不存在');
        }
        oldSecret = old.readNullable<String>('card_secret_id');
        final isBank = kind == AccountKind.bank || kind == AccountKind.credit;
        final tail = isBank
            ? (replaceCard ? cardLast4 : old.readNullable<String>('card_last4'))
            : null;
        validateBankSettings(kind, bankId, tail);
        final postingSummary = (await _query(
          '''SELECT COUNT(*) AS posting_count,
          COALESCE(SUM(p.delta_minor),0) AS posting_total FROM transaction_postings p
          JOIN transactions t ON t.id=p.transaction_id WHERE p.account_id=? AND t.deleted_at IS NULL''',
          [id],
        )).single;
        if (nextCurrency != oldCurrency &&
            postingSummary.read<int>('posting_count') != 0) {
          throw const LedgerException('已有流水的账户不能修改币种，请新建账户后转账');
        }
        final opening = balance - postingSummary.read<int>('posting_total');
        if (opening.abs() > 999999999999) {
          throw const LedgerException('调整后的期初余额超出有效范围');
        }
        if (fullCardNumber != null) {
          newSecret = _uuid.v4();
          await cardVault!.write(newSecret!, fullCardNumber);
        }
        final secret = !isBank
            ? null
            : replaceCard
            ? newSecret
            : oldSecret;
        await db.customStatement(
          '''UPDATE accounts SET name=?,kind=?,currency=?,opening_minor=?,provider_id=?,repayment_day=?,due_date=?,bank_id=?,card_last4=?,card_secret_id=?
          WHERE id=? AND ledger_id=?''',
          [
            name.trim(),
            kind.name,
            nextCurrency,
            opening,
            providerId,
            repaymentDay,
            dueDate == null ? null : dateKey(dueDate),
            bankId,
            tail,
            secret,
            id,
            ledger,
          ],
        );
      });
      committed = true;
    } finally {
      if (!committed && newSecret != null) {
        try {
          await cardVault!.delete(newSecret!);
        } catch (_) {
          /* Original DB reference remains intact. */
        }
      }
    }
    if (oldSecret != null && cardVault != null) {
      final references = await _query(
        'SELECT id FROM accounts WHERE card_secret_id=? LIMIT 1',
        [oldSecret!],
      );
      if (references.isEmpty) {
        try {
          await cardVault!.delete(oldSecret!);
        } catch (_) {
          /* Account update is committed; stale unreferenced key cleanup can be retried later. */
        }
      }
    }
  }

  Future<String> addCategory(
    String ledger,
    String name,
    TransactionType type, {
    String? parentId,
    String iconKey = '',
  }) async {
    _categoryName(name);
    if (type != TransactionType.expense && type != TransactionType.income) {
      throw const LedgerException('分类仅支持收入或支出');
    }
    if (parentId != null) {
      final parent = await _query(
        'SELECT id FROM categories WHERE id=? AND ledger_id=? AND type=? AND parent_id IS NULL AND archived_at IS NULL',
        [parentId, ledger, type.name],
      );
      if (parent.isEmpty) throw const LedgerException('请选择同类型的可用一级分类');
    }
    await _uniqueCategoryName(ledger, name.trim(), type, parentId);
    final order = (await _query(
      "SELECT COALESCE(MAX(sort_order),-1)+1 AS next FROM categories WHERE ledger_id=? AND type=? AND COALESCE(parent_id,'')=?",
      [ledger, type.name, parentId ?? ''],
    )).single.read<int>('next');
    final id = _uuid.v4();
    await db.customStatement(
      'INSERT INTO categories (id,ledger_id,parent_id,name,type,sort_order,icon_key) VALUES (?,?,?,?,?,?,?)',
      [id, ledger, parentId, name.trim(), type.name, order, iconKey.trim()],
    );
    return id;
  }

  void _categoryName(String name) {
    if (name.trim().isEmpty || name.trim().length > 40) {
      throw const LedgerException('分类名称需为1～40字');
    }
  }

  Future<void> _uniqueCategoryName(
    String ledger,
    String name,
    TransactionType type,
    String? parentId, {
    String? except,
  }) async {
    final rows = await _query(
      "SELECT id FROM categories WHERE ledger_id=? AND name=? AND type=? AND COALESCE(parent_id,'')=? AND id!=?",
      [ledger, name, type.name, parentId ?? '', except ?? ''],
    );
    if (rows.isNotEmpty) throw const LedgerException('同级分类名称已存在（含已归档分类）');
  }

  Future<void> renameCategory(String ledger, String id, String name) =>
      db.transaction(() async {
        _categoryName(name);
        final rows = await _query(
          'SELECT * FROM categories WHERE id=? AND ledger_id=?',
          [id, ledger],
        );
        if (rows.isEmpty) throw const LedgerException('分类不存在');
        final row = rows.single;
        await _uniqueCategoryName(
          ledger,
          name.trim(),
          TransactionType.values.byName(row.read<String>('type')),
          row.readNullable<String>('parent_id'),
          except: id,
        );
        await db.customStatement(
          'UPDATE categories SET name=? WHERE id=? AND ledger_id=?',
          [name.trim(), id, ledger],
        );
      });

  Future<void> setCategoryIcon(String ledger, String id, String iconKey) async {
    if (!RegExp(r'^[a-z_]{0,30}$').hasMatch(iconKey)) {
      throw const LedgerException('分类图标无效');
    }
    final changed = await db.customUpdate(
      'UPDATE categories SET icon_key=? WHERE id=? AND ledger_id=?',
      variables: [
        Variable<String>(iconKey),
        Variable<String>(id),
        Variable<String>(ledger),
      ],
    );
    if (changed != 1) throw const LedgerException('分类不存在');
  }

  /// Complete sibling lists only: stale, foreign or mixed-level orders cannot
  /// silently drop a category or change its parent/type.
  Future<void> reorderCategories(
    String ledger,
    TransactionType type,
    String? parentId,
    List<String> ids,
  ) => db.transaction(() async {
    final rows = await _query(
      "SELECT id FROM categories WHERE ledger_id=? AND type=? AND COALESCE(parent_id,'')=? AND archived_at IS NULL",
      [ledger, type.name, parentId ?? ''],
    );
    final expected = rows.map((r) => r.read<String>('id')).toSet();
    if (ids.length != expected.length ||
        ids.toSet().length != ids.length ||
        !expected.containsAll(ids)) {
      throw const LedgerException('分类列表已变化，请刷新后重新排序');
    }
    for (var i = 0; i < ids.length; i++) {
      await db.customStatement(
        'UPDATE categories SET sort_order=? WHERE id=? AND ledger_id=?',
        [i, ids[i], ledger],
      );
    }
  });

  Future<void> setCategoryArchived(
    String ledger,
    String id,
    bool archived,
  ) => db.transaction(() async {
    final rows = await _query(
      'SELECT * FROM categories WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('分类不存在');
    final row = rows.single;
    if ((row.readNullable<String>('archived_at') != null) == archived) return;
    if (archived) {
      final remaining = await _query(
        'SELECT id FROM categories WHERE ledger_id=? AND type=? AND archived_at IS NULL AND id!=? AND (parent_id IS NULL OR parent_id!=?) LIMIT 1',
        [ledger, row.read<String>('type'), id, id],
      );
      if (remaining.isEmpty) throw const LedgerException('请至少保留一个此类型的可用分类');
      await db.customStatement(
        'UPDATE categories SET archived_at=? WHERE ledger_id=? AND archived_at IS NULL AND (id=? OR parent_id=?)',
        [DateTime.now().toUtc().toIso8601String(), ledger, id, id],
      );
      await db.customStatement(
        '''UPDATE auto_correction_rules SET enabled=0,updated_at=?
        WHERE ledger_id=? AND category_id IN
        (SELECT id FROM categories WHERE ledger_id=? AND (id=? OR parent_id=?))''',
        [DateTime.now().toUtc().toIso8601String(), ledger, ledger, id, id],
      );
    } else {
      final parentId = row.readNullable<String>('parent_id');
      if (parentId != null) {
        final parents = await _query(
          'SELECT id FROM categories WHERE id=? AND ledger_id=? AND archived_at IS NULL',
          [parentId, ledger],
        );
        if (parents.isEmpty) throw const LedgerException('请先恢复上级分类');
      }
      // Restoring a parent does not resurrect separately archived children.
      await db.customStatement(
        'UPDATE categories SET archived_at=NULL WHERE id=? AND ledger_id=?',
        [id, ledger],
      );
    }
  });

  Future<void> setAccountArchived(
    String ledger,
    String id,
    bool archived,
  ) => db.transaction(() async {
    final rows = await _query(
      'SELECT archived_at FROM accounts WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('账户不存在');
    if ((rows.single.readNullable<String>('archived_at') != null) == archived) {
      return;
    }
    if (archived) {
      final remaining = await _query(
        'SELECT id FROM accounts WHERE ledger_id=? AND archived_at IS NULL AND id!=? LIMIT 1',
        [ledger, id],
      );
      if (remaining.isEmpty) throw const LedgerException('请至少保留一个可用账户');
    }
    await db.customStatement(
      'UPDATE accounts SET archived_at=? WHERE id=? AND ledger_id=?',
      [archived ? DateTime.now().toUtc().toIso8601String() : null, id, ledger],
    );
    if (archived) {
      await db.customStatement(
        '''UPDATE auto_correction_rules SET enabled=0,updated_at=?
        WHERE ledger_id=? AND account_id=?''',
        [DateTime.now().toUtc().toIso8601String(), ledger, id],
      );
    }
  });

  Future<List<Account>> accounts(
    String ledger, {
    bool includeArchived = false,
  }) async =>
      (await _query(
            '''
    SELECT a.*, c.symbol AS currency_symbol, c.decimals AS currency_decimals,
      c.rate_to_cny_micros,
      a.opening_minor + COALESCE((SELECT SUM(p.delta_minor)
      FROM transaction_postings p JOIN transactions t ON t.id = p.transaction_id
      WHERE p.account_id = a.id AND t.deleted_at IS NULL), 0) AS balance_minor
    FROM accounts a JOIN currencies c ON c.ledger_id=a.ledger_id AND c.code=a.currency
    WHERE a.ledger_id = ? ${includeArchived ? '' : 'AND a.archived_at IS NULL'} ORDER BY a.created_at, a.rowid''',
            [ledger],
          ))
          .map(
            (r) => Account(
              id: r.read('id'),
              name: r.read('name'),
              kind: AccountKind.values.byName(r.read('kind')),
              openingMinor: r.read('opening_minor'),
              balanceMinor: r.read('balance_minor'),
              currency: r.read('currency'),
              currencySymbol: r.read('currency_symbol'),
              currencyDecimals: r.read('currency_decimals'),
              rateToCnyMicros: r.read('rate_to_cny_micros'),
              providerId: r.readNullable('provider_id'),
              repaymentDay: r.readNullable('repayment_day'),
              bankId: r.readNullable('bank_id'),
              cardLast4: r.readNullable('card_last4'),
              cardSecretId: r.readNullable('card_secret_id'),
              archived: r.readNullable<String>('archived_at') != null,
              dueDate: r.readNullable<String>('due_date') == null
                  ? null
                  : DateTime.parse(r.read<String>('due_date')),
            ),
          )
          .toList();

  Future<String?> fullCardNumber(String ledger, String accountId) async {
    final rows = await _query(
      'SELECT card_secret_id FROM accounts WHERE id = ? AND ledger_id = ? AND archived_at IS NULL',
      [accountId, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('账户不存在');
    final id = rows.single.readNullable<String>('card_secret_id');
    if (id == null) return null;
    final value = await cardVault?.read(id);
    if (value == null) throw const LedgerException('安全存储中没有此卡号，请从加密备份恢复');
    return value;
  }

  Future<void> setRepayment(
    String ledger,
    Account account, {
    int? day,
    DateTime? dueDate,
  }) async {
    final rows = await _query(
      'SELECT kind, provider_id FROM accounts WHERE id = ? AND ledger_id = ? AND archived_at IS NULL',
      [account.id, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('账户不存在');
    validateCreditSettings(
      AccountKind.values.byName(rows.single.read<String>('kind')),
      rows.single.readNullable('provider_id'),
      day,
      dueDate,
    );
    await db.customStatement(
      'UPDATE accounts SET repayment_day = ?, due_date = ? WHERE id = ? AND ledger_id = ?',
      [day, dueDate == null ? null : dateKey(dueDate), account.id, ledger],
    );
  }

  Future<List<Category>> categories(
    String ledger, {
    bool includeArchived = false,
  }) async =>
      (await _query(
            "SELECT * FROM categories WHERE ledger_id = ? ${includeArchived ? '' : 'AND archived_at IS NULL'} ORDER BY sort_order, rowid",
            [ledger],
          ))
          .map(
            (r) => Category(
              id: r.read('id'),
              name: r.read('name'),
              type: TransactionType.values.byName(r.read('type')),
              parentId: r.readNullable('parent_id'),
              archived: r.readNullable<String>('archived_at') != null,
              iconKey: r.read<String>('icon_key'),
            ),
          )
          .toList();

  Future<List<TransactionTemplate>> transactionTemplates(String ledger) async =>
      (await _query(
            'SELECT * FROM transaction_templates WHERE ledger_id=? ORDER BY updated_at DESC, name',
            [ledger],
          ))
          .map(
            (r) => TransactionTemplate(
              id: r.read('id'),
              name: r.read('name'),
              type: TransactionType.values.byName(r.read('type')),
              amountMinor: r.read('amount_minor'),
              accountId: r.readNullable('account_id'),
              targetAccountId: r.readNullable('target_account_id'),
              categoryId: r.readNullable('category_id'),
              merchant: r.read('merchant'),
              note: r.read('note'),
              tags: (jsonDecode(r.read<String>('tags_json')) as List)
                  .whereType<String>()
                  .toList(),
            ),
          )
          .toList();

  Future<String> saveTransactionTemplate(
    String ledger,
    TransactionTemplate template,
  ) async {
    final name = template.name.trim();
    if (name.isEmpty || name.length > 60) {
      throw const LedgerException('模板名称需为1～60字');
    }
    if (!const [
      TransactionType.expense,
      TransactionType.income,
      TransactionType.transfer,
    ].contains(template.type)) {
      throw const LedgerException('模板收支类型无效');
    }
    if (template.amountMinor < 0 || template.amountMinor > 999999999999) {
      throw const LedgerException('模板金额超出有效范围');
    }
    final accountIds = (await accounts(ledger)).map((a) => a.id).toSet();
    if (template.accountId != null &&
        !accountIds.contains(template.accountId)) {
      throw const LedgerException('模板账户不存在或已归档');
    }
    if (template.type == TransactionType.transfer &&
        template.targetAccountId != null &&
        (!accountIds.contains(template.targetAccountId) ||
            template.targetAccountId == template.accountId)) {
      throw const LedgerException('模板转入账户无效');
    }
    if (template.categoryId != null &&
        !(await categories(
          ledger,
        )).any((c) => c.id == template.categoryId && c.type == template.type)) {
      throw const LedgerException('模板分类不存在或类型不匹配');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final id = template.id.isEmpty ? _uuid.v4() : template.id;
    await db.customStatement(
      '''INSERT INTO transaction_templates
      (id,ledger_id,name,type,amount_minor,account_id,target_account_id,category_id,merchant,note,tags_json,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name,type=excluded.type,
      amount_minor=excluded.amount_minor,account_id=excluded.account_id,
      target_account_id=excluded.target_account_id,category_id=excluded.category_id,
      merchant=excluded.merchant,note=excluded.note,tags_json=excluded.tags_json,
      updated_at=excluded.updated_at WHERE transaction_templates.ledger_id=excluded.ledger_id''',
      [
        id,
        ledger,
        name,
        template.type.name,
        template.amountMinor,
        template.accountId,
        template.type == TransactionType.transfer
            ? template.targetAccountId
            : null,
        template.type == TransactionType.transfer ? null : template.categoryId,
        template.merchant.trim(),
        template.note.trim(),
        jsonEncode(normalizeTags(template.tags)),
        now,
        now,
      ],
    );
    return id;
  }

  Future<void> deleteTransactionTemplate(String ledger, String id) async {
    await db.customStatement(
      'DELETE FROM transaction_templates WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
  }

  Future<List<RecurringRule>> recurringRules(
    String ledger, {
    RecurringKind? kind,
  }) async => (await _query(
    'SELECT * FROM recurring_rules WHERE ledger_id=? ${kind == null ? '' : 'AND kind=?'} ORDER BY enabled DESC,next_at,name',
    [ledger, if (kind != null) kind.name],
  )).map(_recurringRule).toList();

  RecurringRule _recurringRule(QueryRow r) => RecurringRule(
    id: r.read('id'),
    name: r.read('name'),
    kind: RecurringKind.values.byName(r.read('kind')),
    type: TransactionType.values.byName(r.read('type')),
    amountMinor: r.read('amount_minor'),
    accountId: r.read('account_id'),
    targetAccountId: r.readNullable('target_account_id'),
    categoryId: r.readNullable('category_id'),
    merchant: r.read('merchant'),
    note: r.read('note'),
    tags: (jsonDecode(r.read<String>('tags_json')) as List)
        .whereType<String>()
        .toList(),
    frequency: RecurrenceFrequency.values.byName(r.read('frequency')),
    interval: r.read('interval_count'),
    nextAt: DateTime.parse(r.read('next_at')),
    enabled: r.read<int>('enabled') == 1,
    lastRunAt: r.readNullable<String>('last_run_at') == null
        ? null
        : DateTime.parse(r.read<String>('last_run_at')),
    endAt: r.readNullable<String>('end_at') == null
        ? null
        : DateTime.parse(r.read<String>('end_at')),
    maxRuns: r.readNullable('max_runs'),
    runCount: r.read('run_count'),
    notifyEnabled: r.read<int>('notify_enabled') == 1,
    retryCount: r.read('retry_count'),
    lastError: r.read('last_error'),
  );

  Future<String> saveRecurringRule(String ledger, RecurringRule rule) async {
    final name = rule.name.trim();
    if (name.isEmpty || name.length > 60) {
      throw const LedgerException('周期计划名称需为1～60字');
    }
    if (rule.interval < 1 || rule.interval > 999) {
      throw const LedgerException('周期必须为1～999');
    }
    if (rule.endAt != null && rule.endAt!.isBefore(rule.nextAt)) {
      throw const LedgerException('结束时间不能早于下次执行时间');
    }
    if (rule.maxRuns != null && (rule.maxRuns! < 1 || rule.maxRuns! > 100000)) {
      throw const LedgerException('执行次数需为1～100000');
    }
    final expectedType = rule.kind == RecurringKind.incomeExpense
        ? rule.type
        : TransactionType.transfer;
    if (rule.kind == RecurringKind.incomeExpense &&
        !const [
          TransactionType.expense,
          TransactionType.income,
        ].contains(expectedType)) {
      throw const LedgerException('周期收支类型无效');
    }
    await _validate(
      ledger,
      TransactionInput(
        type: expectedType,
        amountMinor: rule.amountMinor,
        accountId: rule.accountId,
        targetAccountId: rule.targetAccountId,
        categoryId: rule.categoryId,
        occurredDate: rule.nextAt,
        merchant: rule.merchant,
        note: rule.note,
        tags: rule.tags,
      ),
    );
    final now = DateTime.now().toUtc().toIso8601String();
    final id = rule.id.isEmpty ? _uuid.v4() : rule.id;
    await db.customStatement(
      '''INSERT INTO recurring_rules
      (id,ledger_id,name,kind,type,amount_minor,account_id,target_account_id,category_id,merchant,note,tags_json,frequency,interval_count,next_at,enabled,last_run_at,end_at,max_runs,run_count,notify_enabled,retry_count,last_error,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name,kind=excluded.kind,type=excluded.type,
      amount_minor=excluded.amount_minor,account_id=excluded.account_id,
      target_account_id=excluded.target_account_id,category_id=excluded.category_id,
      merchant=excluded.merchant,note=excluded.note,tags_json=excluded.tags_json,
      frequency=excluded.frequency,interval_count=excluded.interval_count,
      next_at=excluded.next_at,enabled=excluded.enabled,end_at=excluded.end_at,
      max_runs=excluded.max_runs,notify_enabled=excluded.notify_enabled,
      updated_at=excluded.updated_at
      WHERE recurring_rules.ledger_id=excluded.ledger_id''',
      [
        id,
        ledger,
        name,
        rule.kind.name,
        expectedType.name,
        rule.amountMinor,
        rule.accountId,
        expectedType == TransactionType.transfer ? rule.targetAccountId : null,
        expectedType == TransactionType.transfer ? null : rule.categoryId,
        rule.merchant.trim(),
        rule.note.trim(),
        jsonEncode(normalizeTags(rule.tags)),
        rule.frequency.name,
        rule.interval,
        rule.nextAt.toIso8601String(),
        rule.enabled ? 1 : 0,
        rule.lastRunAt?.toIso8601String(),
        rule.endAt?.toIso8601String(),
        rule.maxRuns,
        rule.runCount,
        rule.notifyEnabled ? 1 : 0,
        rule.retryCount,
        rule.lastError,
        now,
        now,
      ],
    );
    return id;
  }

  Future<void> setRecurringRuleEnabled(
    String ledger,
    String id,
    bool enabled,
  ) async {
    await db.customStatement(
      'UPDATE recurring_rules SET enabled=?,updated_at=? WHERE id=? AND ledger_id=?',
      [enabled ? 1 : 0, DateTime.now().toUtc().toIso8601String(), id, ledger],
    );
  }

  Future<void> deleteRecurringRule(String ledger, String id) async {
    await db.customStatement(
      'DELETE FROM recurring_rules WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
  }

  DateTime _nextOccurrence(RecurringRule rule) {
    final value = rule.nextAt;
    switch (rule.frequency) {
      case RecurrenceFrequency.daily:
        return value.add(Duration(days: rule.interval));
      case RecurrenceFrequency.weekly:
        return value.add(Duration(days: 7 * rule.interval));
      case RecurrenceFrequency.monthly:
        final first = DateTime(
          value.year,
          value.month + rule.interval,
          1,
          value.hour,
          value.minute,
          value.second,
        );
        final last = DateTime(first.year, first.month + 1, 0).day;
        return DateTime(
          first.year,
          first.month,
          value.day.clamp(1, last),
          value.hour,
          value.minute,
          value.second,
        );
      case RecurrenceFrequency.yearly:
        final year = value.year + rule.interval;
        final last = DateTime(year, value.month + 1, 0).day;
        return DateTime(
          year,
          value.month,
          value.day.clamp(1, last),
          value.hour,
          value.minute,
          value.second,
        );
    }
  }

  Future<String> runRecurringRule(String ledger, String id) async {
    try {
      return await _executeRecurringRule(ledger, id);
    } catch (error) {
      await _recordRecurringFailure(ledger, id, error);
      rethrow;
    }
  }

  Future<String> _executeRecurringRule(
    String ledger,
    String id, {
    DateTime? catchUpAt,
  }) => db.transaction(() async {
    final rows = await _query(
      'SELECT * FROM recurring_rules WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('周期计划不存在');
    final rule = _recurringRule(rows.single);
    if ((rule.maxRuns != null && rule.runCount >= rule.maxRuns!) ||
        (rule.endAt != null && rule.nextAt.isAfter(rule.endAt!))) {
      await db.customStatement(
        'UPDATE recurring_rules SET enabled=0,updated_at=? WHERE id=? AND ledger_id=?',
        [DateTime.now().toUtc().toIso8601String(), id, ledger],
      );
      throw const LedgerException('周期计划已达到结束条件');
    }
    final transactionId = await save(
      ledger,
      TransactionInput(
        type: rule.type,
        amountMinor: rule.amountMinor,
        accountId: rule.accountId,
        targetAccountId: rule.targetAccountId,
        categoryId: rule.categoryId,
        occurredDate: rule.nextAt,
        merchant: rule.merchant,
        note: rule.note,
        tags: rule.tags,
      ),
    );
    var next = _nextOccurrence(rule);
    while (catchUpAt != null && !next.isAfter(catchUpAt)) {
      next = _nextOccurrence(
        RecurringRule(
          id: rule.id,
          name: rule.name,
          kind: rule.kind,
          type: rule.type,
          amountMinor: rule.amountMinor,
          accountId: rule.accountId,
          targetAccountId: rule.targetAccountId,
          categoryId: rule.categoryId,
          merchant: rule.merchant,
          note: rule.note,
          tags: rule.tags,
          frequency: rule.frequency,
          interval: rule.interval,
          nextAt: next,
        ),
      );
    }
    final count = rule.runCount + 1;
    final finished = DateTime.now().toUtc().toIso8601String();
    final ended =
        (rule.maxRuns != null && count >= rule.maxRuns!) ||
        (rule.endAt != null && next.isAfter(rule.endAt!));
    await db.customStatement(
      '''INSERT INTO recurring_executions
      (id,rule_id,ledger_id,scheduled_at,status,transaction_id,error_message,
       retry_count,created_at,finished_at) VALUES (?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(rule_id,scheduled_at) DO UPDATE SET status='success',
      transaction_id=excluded.transaction_id,error_message='',
      retry_count=recurring_executions.retry_count,finished_at=excluded.finished_at''',
      [
        _uuid.v4(),
        id,
        ledger,
        rule.nextAt.toIso8601String(),
        'success',
        transactionId,
        '',
        rule.retryCount,
        finished,
        finished,
      ],
    );
    await db.customStatement(
      '''UPDATE recurring_rules SET next_at=?,last_run_at=?,run_count=?,
      retry_count=0,last_error='',enabled=?,updated_at=?
      WHERE id=? AND ledger_id=?''',
      [
        next.toIso8601String(),
        finished,
        count,
        ended ? 0 : 1,
        finished,
        id,
        ledger,
      ],
    );
    return transactionId;
  });

  Future<void> _recordRecurringFailure(
    String ledger,
    String id,
    Object error,
  ) async {
    final rows = await _query(
      'SELECT next_at,retry_count FROM recurring_rules WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
    if (rows.isEmpty) return;
    final message = error is LedgerException ? error.message : '后台执行失败';
    final scheduled = rows.single.read<String>('next_at');
    final retry = rows.single.read<int>('retry_count') + 1;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction(() async {
      await db.customStatement(
        '''INSERT INTO recurring_executions
        (id,rule_id,ledger_id,scheduled_at,status,transaction_id,error_message,
         retry_count,created_at,finished_at) VALUES (?,?,?,?,?,NULL,?,?,?,?)
        ON CONFLICT(rule_id,scheduled_at) DO UPDATE SET status='failed',
        error_message=excluded.error_message,retry_count=excluded.retry_count,
        finished_at=excluded.finished_at''',
        [_uuid.v4(), id, ledger, scheduled, 'failed', message, retry, now, now],
      );
      await db.customStatement(
        'UPDATE recurring_rules SET retry_count=?,last_error=?,updated_at=? WHERE id=? AND ledger_id=?',
        [retry, message, now, id, ledger],
      );
    });
  }

  Future<void> skipRecurringRule(String ledger, String id) =>
      db.transaction(() async {
        final rows = await _query(
          'SELECT * FROM recurring_rules WHERE id=? AND ledger_id=?',
          [id, ledger],
        );
        if (rows.isEmpty) throw const LedgerException('周期计划不存在');
        final rule = _recurringRule(rows.single);
        final next = _nextOccurrence(rule);
        final now = DateTime.now().toUtc().toIso8601String();
        final ended = rule.endAt != null && next.isAfter(rule.endAt!);
        await db.customStatement(
          '''INSERT INTO recurring_executions
          (id,rule_id,ledger_id,scheduled_at,status,transaction_id,error_message,
           retry_count,created_at,finished_at) VALUES (?,?,?,?,?,NULL,'',0,?,?)
          ON CONFLICT(rule_id,scheduled_at) DO NOTHING''',
          [
            _uuid.v4(),
            id,
            ledger,
            rule.nextAt.toIso8601String(),
            'skipped',
            now,
            now,
          ],
        );
        await db.customStatement(
          '''UPDATE recurring_rules SET next_at=?,enabled=?,retry_count=0,
          last_error='',updated_at=? WHERE id=? AND ledger_id=?''',
          [next.toIso8601String(), ended ? 0 : 1, now, id, ledger],
        );
      });

  Future<String> retryRecurringRule(String ledger, String id) async {
    try {
      return await _executeRecurringRule(ledger, id, catchUpAt: DateTime.now());
    } catch (error) {
      await _recordRecurringFailure(ledger, id, error);
      rethrow;
    }
  }

  Future<List<RecurringExecution>> recurringExecutions(
    String ledger,
    String ruleId,
  ) async =>
      (await _query(
            '''SELECT * FROM recurring_executions WHERE ledger_id=? AND rule_id=?
    ORDER BY scheduled_at DESC LIMIT 200''',
            [ledger, ruleId],
          ))
          .map(
            (row) => RecurringExecution(
              id: row.read('id'),
              ruleId: row.read('rule_id'),
              scheduledAt: DateTime.parse(row.read('scheduled_at')),
              status: row.read('status'),
              transactionId: row.readNullable('transaction_id'),
              errorMessage: row.read('error_message'),
              retryCount: row.read('retry_count'),
              finishedAt: DateTime.parse(row.read('finished_at')),
            ),
          )
          .toList();

  Future<DateTime?> nextRecurringWakeAt({DateTime? now}) async {
    final rows = await _query('''SELECT next_at,retry_count FROM recurring_rules
      WHERE enabled=1 ORDER BY next_at LIMIT 1''');
    if (rows.isEmpty) return null;
    final current = now ?? DateTime.now();
    final due = DateTime.parse(rows.single.read<String>('next_at'));
    if (due.isAfter(current)) return due;
    final retry = (rows.single.read<int>('retry_count') - 1).clamp(0, 5);
    return current.add(Duration(minutes: 15 * (1 << retry)));
  }

  /// Generates at most one catch-up transaction for each enabled plan. A
  /// unique (rule, scheduled time) history record prevents duplicate posting.
  Future<RecurringProcessResult> processDueRecurringRules({
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    final due = await _query(
      'SELECT id,ledger_id FROM recurring_rules WHERE enabled=1 AND next_at<=? ORDER BY next_at LIMIT 100',
      [now.toIso8601String()],
    );
    var succeeded = 0, failed = 0, notifyOk = 0, notifyFailed = 0;
    for (final item in due) {
      final ledger = item.read<String>('ledger_id');
      final id = item.read<String>('id');
      try {
        final ruleRows = await _query(
          'SELECT notify_enabled,next_at FROM recurring_rules WHERE id=? AND ledger_id=? AND enabled=1',
          [id, ledger],
        );
        if (ruleRows.isEmpty) continue;
        if (DateTime.parse(
          ruleRows.single.read<String>('next_at'),
        ).isAfter(now)) {
          continue;
        }
        final notify = ruleRows.single.read<int>('notify_enabled') == 1;
        await _executeRecurringRule(ledger, id, catchUpAt: now);
        succeeded++;
        if (notify) notifyOk++;
      } catch (error) {
        await _recordRecurringFailure(ledger, id, error);
        failed++;
        final rows = await _query(
          'SELECT notify_enabled FROM recurring_rules WHERE id=? AND ledger_id=?',
          [id, ledger],
        );
        if (rows.isNotEmpty && rows.single.read<int>('notify_enabled') == 1) {
          notifyFailed++;
        }
      }
    }
    return RecurringProcessResult(
      succeeded: succeeded,
      failed: failed,
      notifiableSucceeded: notifyOk,
      notifiableFailed: notifyFailed,
    );
  }

  Future<_ResolvedMoney> _resolveMoney(
    String ledger,
    TransactionInput input, {
    List<Account>? accounts,
  }) async {
    final available = accounts ?? await this.accounts(ledger);
    final source = available
        .where((account) => account.id == input.accountId)
        .firstOrNull;
    if (source == null) throw const LedgerException('账户不存在');
    Account? target;
    if (input.type == TransactionType.transfer) {
      target = available
          .where((account) => account.id == input.targetAccountId)
          .firstOrNull;
      if (target == null || target.id == source.id) {
        throw const LedgerException('请选择不同的转入账户');
      }
    }
    final codes = {source.currency, if (target != null) target.currency};
    final rateRows = await _query(
      'SELECT code,rate_to_cny_micros FROM currencies WHERE ledger_id=?',
      [ledger],
    );
    final rates = {
      for (final row in rateRows)
        row.read<String>('code'): row.read<int>('rate_to_cny_micros'),
    };
    if (!rates.keys.toSet().containsAll(codes)) {
      throw const LedgerException('账户币种缺少有效汇率');
    }
    final sourceRate = rates[source.currency]!;
    final baseAmount = (input.amountMinor * sourceRate + 500000) ~/ 1000000;
    if (baseAmount <= 0 || baseAmount > 999999999999) {
      throw const LedgerException('按当前汇率换算后的人民币金额超出有效范围');
    }
    final targetRate = target == null ? null : rates[target.currency]!;
    final targetAmount = target == null
        ? null
        : (baseAmount * 1000000 + targetRate! ~/ 2) ~/ targetRate;
    if (targetAmount != null && targetAmount <= 0) {
      throw const LedgerException('按当前汇率换算后的转入金额小于最小单位');
    }
    return _ResolvedMoney(
      baseAmount: baseAmount,
      sourceCurrency: source.currency,
      sourceRate: sourceRate,
      targetCurrency: target?.currency,
      targetAmount: targetAmount,
      targetRate: targetRate,
    );
  }

  Future<void> _validate(
    String ledger,
    TransactionInput input, {
    String? editingId,
    _ResolvedMoney? resolvedMoney,
  }) async {
    if (input.amountMinor <= 0 || input.amountMinor > 999999999999) {
      throw const LedgerException('金额超出有效范围');
    }
    if (input.isReimbursement && input.type != TransactionType.refund) {
      throw const LedgerException('报销到账必须关联原消费');
    }
    if (input.type == TransactionType.adjustment) {
      throw const LedgerException('暂不支持余额调整');
    }
    final available = await accounts(ledger);
    if (!available.any((a) => a.id == input.accountId)) {
      throw const LedgerException('账户不存在');
    }
    if (input.type == TransactionType.transfer) {
      if (input.targetAccountId == input.accountId ||
          !available.any((a) => a.id == input.targetAccountId)) {
        throw const LedgerException('请选择不同的转入账户');
      }
    }
    if (input.type == TransactionType.expense ||
        input.type == TransactionType.income) {
      final valid = await _query(
        'SELECT id FROM categories WHERE id = ? AND ledger_id = ? AND type = ? AND archived_at IS NULL',
        [input.categoryId ?? '', ledger, input.type.name],
      );
      if (valid.isEmpty) throw const LedgerException('请选择对应的分类');
    }
    if (input.type == TransactionType.refund) {
      final baseAmount =
          resolvedMoney?.baseAmount ??
          (await _resolveMoney(ledger, input, accounts: available)).baseAmount;
      final original = await _query(
        '''SELECT amount_minor, reimbursable FROM transactions
        WHERE id = ? AND ledger_id = ? AND type = 'expense' AND deleted_at IS NULL''',
        [input.relatedTransactionId ?? '', ledger],
      );
      if (original.isEmpty) throw const LedgerException('原消费不存在或已删除');
      if (input.isReimbursement &&
          original.first.read<int>('reimbursable') != 1) {
        throw const LedgerException('原消费未标记报销');
      }
      final refunded = await _query(
        '''SELECT COALESCE(SUM(amount_minor), 0) AS total FROM transactions
        WHERE related_transaction_id = ? AND type = 'refund' AND deleted_at IS NULL AND id != ?''',
        [input.relatedTransactionId!, editingId ?? ''],
      );
      if (refunded.first.read<int>('total') + baseAmount >
          original.first.read<int>('amount_minor')) {
        throw const LedgerException('累计退款与报销到账不能超过原消费金额');
      }
    }
  }

  Future<String> save(
    String ledger,
    TransactionInput input, {
    String? id,
    List<ImageAttachment>? attachments,
    String learningSourceKey = '',
    String learningPaymentMethod = '',
    TransactionIdentitySeed? identitySeed,
    bool recordIdentity = true,
  }) async {
    return db.transaction(() async {
      final money = await _resolveMoney(ledger, input);
      await _validate(ledger, input, editingId: id, resolvedMoney: money);
      final effectiveTags = await _effectiveTags(ledger, input);
      if (id != null) {
        final current = await _query(
          'SELECT id FROM transactions WHERE id = ? AND ledger_id = ? AND deleted_at IS NULL',
          [id, ledger],
        );
        if (current.isEmpty) throw const LedgerException('交易不存在');
        await _checkNoRefunds(id);
      }
      final transactionId = id ?? _uuid.v4();
      final now = DateTime.now().toUtc().toIso8601String();
      final device = (await _query(
        "SELECT value FROM settings WHERE key = 'device_id'",
      )).first.read<String>('value');
      final category =
          input.type == TransactionType.transfer ||
              input.type == TransactionType.refund
          ? null
          : input.categoryId;
      final target = input.type == TransactionType.transfer
          ? input.targetAccountId
          : null;
      final related = input.type == TransactionType.refund
          ? input.relatedTransactionId
          : null;
      final reimbursable =
          input.type == TransactionType.expense && input.reimbursable ? 1 : 0;
      final values = [
        input.type.name,
        money.baseAmount,
        input.accountId,
        target,
        category,
        input.merchant.trim(),
        input.note.trim(),
        dateTimeKey(input.occurredDate),
        related,
        reimbursable,
        now,
        device,
        jsonEncode(effectiveTags),
        input.isReimbursement ? 1 : 0,
      ];
      if (id == null) {
        await db.customStatement(
          '''INSERT INTO transactions
          (type, amount_minor, account_id, target_account_id, category_id, merchant, note,
           occurred_date, related_transaction_id, reimbursable, updated_at, device_id, tags_json, is_reimbursement, id, ledger_id, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [...values, transactionId, ledger, now],
        );
      } else {
        await db.customStatement(
          '''UPDATE transactions SET type = ?, amount_minor = ?, account_id = ?,
          target_account_id = ?, category_id = ?, merchant = ?, note = ?, occurred_date = ?,
          related_transaction_id = ?, reimbursable = ?, updated_at = ?, device_id = ?, tags_json = ?, is_reimbursement = ?, version = version + 1
          WHERE id = ?''',
          [...values, id],
        );
        await db.customStatement(
          'DELETE FROM transaction_postings WHERE transaction_id = ?',
          [id],
        );
        await db.customStatement(
          'DELETE FROM transaction_fx WHERE transaction_id = ?',
          [id],
        );
      }
      final outgoing =
          input.type == TransactionType.expense ||
          input.type == TransactionType.transfer;
      await _post(
        transactionId,
        input.accountId,
        outgoing ? -input.amountMinor : input.amountMinor,
        money.sourceCurrency,
      );
      if (input.type == TransactionType.transfer) {
        await _post(
          transactionId,
          input.targetAccountId!,
          money.targetAmount!,
          money.targetCurrency!,
        );
      }
      if (money.sourceCurrency != 'CNY' ||
          (money.targetCurrency != null && money.targetCurrency != 'CNY')) {
        await db.customStatement(
          '''INSERT INTO transaction_fx
          (transaction_id,source_currency,source_amount_minor,source_rate_micros,
           target_currency,target_amount_minor,target_rate_micros)
          VALUES (?,?,?,?,?,?,?)''',
          [
            transactionId,
            money.sourceCurrency,
            input.amountMinor,
            money.sourceRate,
            money.targetCurrency,
            money.targetAmount,
            money.targetRate,
          ],
        );
      }
      if (input.type == TransactionType.refund && related != null) {
        await _syncFamilyEventRefundFromTransaction(related, now);
      }
      await _ensureTagDefinitions(ledger, effectiveTags);
      if (attachments != null) {
        await replaceAttachments(ledger, transactionId, attachments);
      }
      if (recordIdentity &&
          [
            TransactionType.expense,
            TransactionType.income,
            TransactionType.refund,
          ].contains(input.type)) {
        await _storeTransactionIdentity(
          ledger,
          transactionId,
          input,
          money.baseAmount,
          identitySeed ??
              TransactionIdentitySeed(
                source: TransactionEvidenceSource.manual,
                captureId: 'transaction:$transactionId',
              ),
        );
      }
      return transactionId;
    });
  }

  /// Common entry point for already-structured transactions such as the
  /// manual form and CSV/Excel rows. These entrances intentionally skip
  /// natural-language parsing, but not correction, confidence, identity,
  /// duplicate protection, learning or audit.
  Future<TransactionPipelineResult> submitStructuredTransaction(
    String ledger,
    TransactionInput input, {
    String? id,
    List<ImageAttachment>? attachments,
    required TransactionIdentitySeed identitySeed,
    bool allowPossibleDuplicate = false,
    bool applyCorrection = true,
  }) async {
    final sourceKey = identitySeed.sourceApp.trim().isEmpty
        ? 'channel:${identitySeed.source.name}'
        : 'app:${identitySeed.sourceApp.trim()}';
    final rawSource = switch (identitySeed.source) {
      TransactionEvidenceSource.ocr => TransactionSource.ocr,
      TransactionEvidenceSource.speech => TransactionSource.speech,
      TransactionEvidenceSource.notification => TransactionSource.notification,
      TransactionEvidenceSource.import => TransactionSource.import,
      TransactionEvidenceSource.accessibility => TransactionSource.notification,
      TransactionEvidenceSource.manual => TransactionSource.text,
    };
    final structuredDraft = TransactionDraft(
      raw: RawTransaction(
        text: identitySeed.source == TransactionEvidenceSource.import
            ? '结构化账单导入'
            : '结构化手动记账',
        capturedAt: DateTime.now(),
        source: rawSource,
        sourceApp: identitySeed.sourceApp,
        paymentMethod: identitySeed.details['付款方式'] ?? '',
      ),
      ledgerId: ledger,
      type: input.type,
      amountMinor: input.amountMinor,
      occurredDate: input.occurredDate,
      accountId: input.accountId,
      categoryId: input.categoryId,
      relatedTransactionId: input.relatedTransactionId,
      merchant: input.merchant,
      note: input.note,
      tags: input.tags,
      warnings: const [],
      evidence: {
        'amount': '用户或结构化文件已提供',
        'account': '用户已选择或导入时已映射',
        'date': '已提供精确交易时间',
        if (input.merchant.trim().isNotEmpty) 'merchant': '结构化字段',
        if (input.categoryId != null) 'category': '用户已选择或导入时已映射',
        'pipeline': 'structured-v1',
      },
    );
    final correctedDraft =
        applyCorrection &&
            [
              TransactionType.expense,
              TransactionType.income,
            ].contains(input.type)
        ? await applyAutoCorrectionRule(structuredDraft)
        : structuredDraft;
    // A manual form contains the user's final choices. A matching rule is
    // still evaluated and audited, but must never overwrite an explicit
    // correction the user just made. Imported fields may be normalized by a
    // rule because the batch confirmation precedes this pipeline.
    final preserveExplicit =
        identitySeed.source == TransactionEvidenceSource.manual;
    final effectiveDraft = preserveExplicit
        ? TransactionDraft(
            raw: structuredDraft.raw,
            ledgerId: ledger,
            type: input.type,
            amountMinor: input.amountMinor,
            occurredDate: input.occurredDate,
            accountId: input.accountId,
            categoryId: input.categoryId,
            relatedTransactionId: input.relatedTransactionId,
            merchant: input.merchant,
            note: input.note,
            tags: input.tags,
            warnings: structuredDraft.warnings,
            evidence: correctedDraft.evidence,
          )
        : correctedDraft;
    final actualLedger = effectiveDraft.ledgerId;
    final correctedInput = TransactionInput(
      type: input.type,
      amountMinor: input.amountMinor,
      accountId: effectiveDraft.accountId ?? input.accountId,
      targetAccountId: input.targetAccountId,
      categoryId: effectiveDraft.categoryId ?? input.categoryId,
      occurredDate: input.occurredDate,
      merchant: input.merchant,
      note: input.note,
      relatedTransactionId: input.relatedTransactionId,
      reimbursable: input.reimbursable,
      isReimbursement: input.isReimbursement,
      tags: effectiveDraft.tags,
    );
    final confidence = const ConfidenceEngine().evaluate(
      effectiveDraft,
      context: ConfidenceContext(
        sourceKind: identitySeed.source.name,
        completed: true,
      ),
    );
    final duplicate = await assessStructuredDuplicate(
      actualLedger,
      correctedInput,
      identitySeed,
      excludingTransactionId: id,
    );
    if (duplicate.possible && !allowPossibleDuplicate) {
      await _recordLearningEvent(
        ledger: actualLedger,
        source: identitySeed.source,
        sourceApp: identitySeed.sourceApp,
        outcome: 'duplicate',
        fingerprint: await _pipelineFingerprint(correctedInput, identitySeed),
        confidence: confidence,
        details: {
          'candidate_transaction_id': duplicate.candidateTransactionId ?? '',
          'matched_by_order': duplicate.matchedByOrder.toString(),
          'differences': duplicate.differences.join('；'),
          'entry_point': identitySeed.details['入口'] ?? identitySeed.source.name,
        },
      );
      throw PossibleDuplicateTransactionException(duplicate);
    }
    final transactionId = await save(
      actualLedger,
      correctedInput,
      id: id,
      attachments: attachments,
      learningSourceKey: sourceKey,
      learningPaymentMethod: identitySeed.details['付款方式'] ?? '',
      identitySeed: identitySeed,
    );
    final learningEventId = await _recordLearningEvent(
      ledger: actualLedger,
      transactionId: transactionId,
      source: identitySeed.source,
      sourceApp: identitySeed.sourceApp,
      outcome: id == null ? 'posted' : 'updated',
      fingerprint: await _pipelineFingerprint(correctedInput, identitySeed),
      confidence: confidence,
      details: {
        'entry_point': identitySeed.details['入口'] ?? identitySeed.source.name,
        'auto_correction': correctedDraft.evidence['auto_correction'] ?? '',
        'duplicate_approved': (duplicate.possible && allowPossibleDuplicate)
            .toString(),
      },
      recognized: {
        'merchant': structuredDraft.merchant,
        'category': structuredDraft.categoryId ?? '',
        'account': structuredDraft.accountId ?? '',
        'tags': normalizeTags(structuredDraft.tags).join(','),
        'ledger': ledger,
      },
      finalValues: {
        'merchant': correctedInput.merchant,
        'category': correctedInput.categoryId ?? '',
        'account': correctedInput.accountId,
        'tags': normalizeTags(correctedInput.tags).join(','),
        'ledger': actualLedger,
      },
    );
    await _learnAutoCorrection(
      actualLedger,
      correctedInput,
      learningEventId: learningEventId,
      sourceLedgerId: ledger,
      sourceAccountId: structuredDraft.accountId,
      sourceKey: sourceKey,
      paymentMethod: identitySeed.details['付款方式'] ?? '',
    );
    return TransactionPipelineResult(
      transactionId: transactionId,
      ledgerId: actualLedger,
      input: correctedInput,
      confidence: confidence,
      duplicateAssessment: duplicate,
    );
  }

  Future<String> _pipelineFingerprint(
    TransactionInput input,
    TransactionIdentitySeed seed,
  ) async {
    final result = await UnifiedTransactionIdentity.build(
      amountMinor: input.amountMinor,
      merchant: input.merchant,
      occurredAt: input.occurredDate,
      accountId: input.accountId,
      direction: input.type,
      sourceApp: seed.sourceApp,
      rawText: seed.rawTextForFingerprint,
      explicitOrderId: seed.orderId,
    );
    return result.orderHash ?? result.semanticHash;
  }

  Future<String> _recordLearningEvent({
    required String ledger,
    required TransactionEvidenceSource source,
    required String sourceApp,
    required String outcome,
    String? transactionId,
    String? draftId,
    String fingerprint = '',
    TransactionConfidence? confidence,
    Map<String, String> details = const {},
    Map<String, String> recognized = const {},
    Map<String, String> finalValues = const {},
  }) async {
    final eventId = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      '''INSERT INTO learning_events
    (id,ledger_id,transaction_id,draft_id,source_kind,source_app,outcome,
     fingerprint,confidence_json,details_json,created_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
      [
        eventId,
        ledger,
        transactionId,
        draftId,
        source.name,
        sanitizeSourceText(sourceApp),
        outcome,
        fingerprint,
        confidence == null ? '' : jsonEncode(confidence.toJson()),
        jsonEncode(
          details.map(
            (key, value) =>
                MapEntry(sanitizeSourceText(key), sanitizeSourceText(value)),
          ),
        ),
        now,
      ],
    );
    for (final field in const [
      'merchant',
      'category',
      'account',
      'tags',
      'ledger',
    ]) {
      final before = sanitizeSourceText(recognized[field] ?? '');
      final after = sanitizeSourceText(finalValues[field] ?? before);
      await db.customStatement(
        '''INSERT INTO learning_field_changes
        (id,event_id,field_name,recognized_value,final_value,changed,created_at)
        VALUES (?,?,?,?,?,?,?)''',
        [
          _uuid.v4(),
          eventId,
          field,
          before,
          after,
          before == after ? 0 : 1,
          now,
        ],
      );
    }
    return eventId;
  }

  Future<void> _storeTransactionIdentity(
    String ledger,
    String transactionId,
    TransactionInput input,
    int amountMinor,
    TransactionIdentitySeed seed,
  ) async {
    final rawText = seed.rawTextForFingerprint;
    final fingerprint = await UnifiedTransactionIdentity.build(
      amountMinor: amountMinor,
      merchant: input.merchant,
      occurredAt: input.occurredDate,
      accountId: input.accountId,
      direction: input.type,
      sourceApp: seed.sourceApp,
      rawText: rawText,
      explicitOrderId: seed.orderId,
    );
    final capture = seed.captureId.trim().isEmpty
        ? null
        : seed.captureId.trim();
    if (capture != null) {
      await db.customStatement(
        '''DELETE FROM transaction_evidence_records
        WHERE ledger_id=? AND source_kind=? AND capture_id=?''',
        [ledger, seed.source.name, capture],
      );
    }
    await db.customStatement(
      '''INSERT INTO transaction_evidence_records
      (id,ledger_id,transaction_id,draft_id,source_kind,source_app,capture_id,
       order_hash,semantic_fingerprint,amount_minor,normalized_merchant,
       occurred_at,account_id,direction,details_json,created_at)
      VALUES (?,?,?,NULL,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        _uuid.v4(),
        ledger,
        transactionId,
        seed.source.name,
        sanitizeSourceText(seed.sourceApp),
        capture,
        fingerprint.orderHash,
        fingerprint.semanticHash,
        amountMinor,
        fingerprint.normalizedMerchant,
        input.occurredDate.toIso8601String(),
        input.accountId,
        input.type.name,
        jsonEncode(
          seed.details.map(
            (key, value) =>
                MapEntry(sanitizeSourceText(key), sanitizeSourceText(value)),
          ),
        ),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  Future<void> _syncFamilyEventRefundFromTransaction(
    String parentTransactionId,
    String now,
  ) async {
    final events = await _query(
      'SELECT id, amount_minor, status FROM family_payment_events WHERE transaction_id=?',
      [parentTransactionId],
    );
    if (events.isEmpty) return;
    final ev = events.single;
    if (ev.read<String>('status') == 'voided') return;
    final refundSum = (await _query(
      "SELECT COALESCE(SUM(amount_minor),0) AS total FROM transactions WHERE related_transaction_id=? AND type='refund' AND is_reimbursement=0 AND deleted_at IS NULL",
      [parentTransactionId],
    )).single.read<int>('total');
    final amountMinor = ev.read<int>('amount_minor');
    final clamped = refundSum.clamp(0, amountMinor);
    final nextStatus = clamped >= amountMinor ? 'refunded' : 'confirmed';
    await db.customStatement(
      'UPDATE family_payment_events SET refunded_minor=?, status=?, updated_at=? WHERE id=?',
      [clamped, nextStatus, now, ev.read<String>('id')],
    );
  }

  Future<List<String>> _effectiveTags(
    String ledger,
    TransactionInput input,
  ) async {
    final tags = normalizeTags(input.tags).toList();
    final haystack = '${input.merchant} ${input.note}'.toLowerCase();
    if (haystack.trim().isEmpty || tags.length >= 10) return tags;
    final rows = await _query(
      '''SELECT name,smart_pattern FROM tag_definitions
      WHERE ledger_id=? AND hidden_at IS NULL AND smart_pattern!=''
      ORDER BY updated_at DESC''',
      [ledger],
    );
    for (final row in rows) {
      final patterns = row
          .read<String>('smart_pattern')
          .split(RegExp(r'[,，;；\n]+'))
          .map((value) => value.trim().toLowerCase())
          .where((value) => value.isNotEmpty);
      final name = row.read<String>('name');
      if (patterns.any(haystack.contains) && !tags.contains(name)) {
        tags.add(name);
        if (tags.length == 10) break;
      }
    }
    return List.unmodifiable(tags);
  }

  Future<void> _ensureTagDefinitions(String ledger, List<String> tags) async {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final name in tags) {
      await db.customStatement(
        '''INSERT OR IGNORE INTO tag_definitions
        (id,ledger_id,name,normalized_name,hidden_at,smart_pattern,created_at,updated_at)
        VALUES (?,?,?,?,NULL,'',?,?)''',
        [_uuid.v4(), ledger, name, name.toLowerCase(), now, now],
      );
    }
  }

  /// Persist the source and parse snapshot together. Re-identifying the same
  /// input sheet updates its pending source rather than creating another draft.
  Future<String> storeDraft(
    TransactionDraft draft, {
    String? id,
    String? captureId,
    TransactionEvidenceSource? evidenceSource,
    String evidenceCaptureId = '',
  }) => db.transaction(() async {
    if (captureId != null) {
      if (!RegExp(r'^auto-[a-f0-9]{64}$').hasMatch(captureId)) {
        throw const LedgerException('采集编号无效');
      }
      final existing = await _query(
        'SELECT id FROM transaction_drafts WHERE id=?',
        [captureId],
      );
      if (existing.isNotEmpty) return captureId;
    }
    if (draft.raw.text.trim().isEmpty || draft.raw.text.length > 4000) {
      throw const LedgerException('请输入 1～4000 字的账单描述');
    }
    final parsedJson = jsonEncode({
      ...draft.toJson(),
      'merchant': sanitizeSourceText(draft.merchant),
      'warnings': draft.warnings.map(sanitizeSourceText).toList(),
      'evidence': draft.evidence.map(
        (key, value) => MapEntry(key, sanitizeSourceText(value)),
      ),
    });
    final draftId = id ?? captureId ?? _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    if (id == null) {
      final rawId = _uuid.v4();
      await db.customStatement(
        '''INSERT INTO raw_transactions
        (id,ledger_id,source,raw_text,captured_at,source_app,payment_method)
        VALUES (?, ?, ?, ?, ?, ?, ?)''',
        [
          rawId,
          draft.ledgerId,
          draft.raw.source.name,
          sanitizeSourceText(draft.raw.text),
          draft.raw.capturedAt.toIso8601String(),
          sanitizeSourceText(draft.raw.sourceApp),
          sanitizeSourceText(draft.raw.paymentMethod),
        ],
      );
      await db.customStatement(
        "INSERT INTO transaction_drafts VALUES (?, ?, 'pending', 1, ?, NULL, ?)",
        [draftId, rawId, parsedJson, now],
      );
    } else {
      final rows = await _query(
        "SELECT d.raw_id FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE d.id=? AND d.status='pending'",
        [id],
      );
      if (rows.isEmpty) throw const LedgerException('草稿不存在或已处理');
      await db.customStatement(
        '''UPDATE raw_transactions SET ledger_id=?,source=?,raw_text=?,captured_at=?,
        source_app=?,payment_method=? WHERE id=?''',
        [
          draft.ledgerId,
          draft.raw.source.name,
          sanitizeSourceText(draft.raw.text),
          draft.raw.capturedAt.toIso8601String(),
          sanitizeSourceText(draft.raw.sourceApp),
          sanitizeSourceText(draft.raw.paymentMethod),
          rows.single.read<String>('raw_id'),
        ],
      );
      await db.customStatement(
        'UPDATE transaction_drafts SET parsed_json=?, updated_at=? WHERE id=?',
        [parsedJson, now, id],
      );
    }
    await _storeDraftIdentity(
      draftId,
      draft,
      source: evidenceSource ?? _sourceForRaw(draft.raw.source),
      captureId: evidenceCaptureId,
    );
    final identity = (await _query(
      '''SELECT order_hash,semantic_fingerprint
      FROM transaction_evidence_records WHERE draft_id=? LIMIT 1''',
      [draftId],
    )).firstOrNull;
    await _recordLearningEvent(
      ledger: draft.ledgerId,
      draftId: draftId,
      source: evidenceSource ?? _sourceForRaw(draft.raw.source),
      sourceApp: draft.raw.sourceApp,
      outcome: 'draft',
      fingerprint:
          identity?.readNullable<String>('order_hash') ??
          identity?.readNullable<String>('semantic_fingerprint') ??
          '',
      confidence: draft.confidence,
      details: {
        'entry_point': draft.raw.source.name,
        'blocked': draft.blocked.toString(),
        'warnings': draft.warnings.join('；'),
      },
    );
    return draftId;
  });

  TransactionEvidenceSource _sourceForRaw(TransactionSource source) =>
      switch (source) {
        TransactionSource.ocr => TransactionEvidenceSource.ocr,
        TransactionSource.speech => TransactionEvidenceSource.speech,
        TransactionSource.import => TransactionEvidenceSource.import,
        TransactionSource.notification =>
          TransactionEvidenceSource.notification,
        TransactionSource.text => TransactionEvidenceSource.manual,
      };

  Future<void> _storeDraftIdentity(
    String draftId,
    TransactionDraft draft, {
    required TransactionEvidenceSource source,
    String captureId = '',
  }) async {
    if (draft.amountMinor == null ||
        draft.amountMinor! <= 0 ||
        ![
          TransactionType.expense,
          TransactionType.income,
          TransactionType.refund,
        ].contains(draft.type)) {
      return;
    }
    final fingerprint = await UnifiedTransactionIdentity.build(
      amountMinor: draft.amountMinor!,
      merchant: draft.merchant,
      occurredAt: draft.occurredDate,
      accountId: draft.accountId,
      direction: draft.type,
      sourceApp: draft.raw.sourceApp,
      rawText: draft.raw.text,
    );
    final evidenceAccountId = await _identityAccountId(
      draft.ledgerId,
      draft.accountId,
    );
    await db.customStatement(
      'DELETE FROM transaction_evidence_records WHERE draft_id=?',
      [draftId],
    );
    await db.customStatement(
      '''INSERT INTO transaction_evidence_records
      (id,ledger_id,transaction_id,draft_id,source_kind,source_app,capture_id,
       order_hash,semantic_fingerprint,amount_minor,normalized_merchant,
       occurred_at,account_id,direction,details_json,created_at)
      VALUES (?,?,NULL,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        _uuid.v4(),
        draft.ledgerId,
        draftId,
        source.name,
        sanitizeSourceText(draft.raw.sourceApp),
        captureId.trim().isEmpty ? null : captureId.trim(),
        fingerprint.orderHash,
        fingerprint.semanticHash,
        draft.amountMinor,
        fingerprint.normalizedMerchant,
        draft.occurredDate.toIso8601String(),
        evidenceAccountId,
        draft.type.name,
        jsonEncode(
          draft.evidence.map(
            (key, value) =>
                MapEntry(sanitizeSourceText(key), sanitizeSourceText(value)),
          ),
        ),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  Future<String?> _identityAccountId(String ledgerId, String? accountId) async {
    if (accountId == null || accountId.trim().isEmpty) return null;
    final account = await db
        .customSelect(
          'SELECT id FROM accounts WHERE id=? AND ledger_id=? LIMIT 1',
          variables: [Variable(accountId), Variable(ledgerId)],
        )
        .getSingleOrNull();
    return account == null ? null : accountId;
  }

  Future<List<PendingDraft>> pendingDrafts(String ledger) async =>
      (await _query(
        "SELECT d.id AS draft_id, d.parsed_json, r.* FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE r.ledger_id=? AND d.status='pending' ORDER BY r.captured_at DESC, d.id",
        [ledger],
      )).map((r) {
        final decoded =
            jsonDecode(r.read<String>('parsed_json')) as Map<Object?, Object?>;
        final ev = decoded['evidence'];
        final familyEventId =
            (decoded['family_event_id'] as String?) ??
            (ev is Map ? ev['family_event_id'] as String? : null);
        final roleName =
            (decoded['family_role'] as String?) ??
            (ev is Map ? ev['family_role'] as String? : null);
        final confidenceJson = decoded['confidence'];
        return PendingDraft(
          id: r.read<String>('draft_id'),
          ledgerId: ledger,
          storedWarnings: (decoded['warnings'] as List? ?? [])
              .whereType<String>()
              .toList(),
          familyEventId: familyEventId,
          familyRole: roleName == null
              ? null
              : FamilyLocalRole.values
                    .where((item) => item.name == roleName)
                    .firstOrNull,
          confidence: confidenceJson is Map
              ? TransactionConfidence.fromJson(
                  confidenceJson.cast<Object?, Object?>(),
                )
              : null,
          batchAccountId: ev is Map && ev['batch_review_account'] == 'true'
              ? decoded['account_id'] as String?
              : null,
          batchCategoryId: ev is Map && ev['batch_review_category'] == 'true'
              ? decoded['category_id'] as String?
              : null,
          batchTags: ev is Map && ev['batch_review_tags'] == 'true'
              ? (decoded['tags'] as List? ?? []).whereType<String>().toList()
              : null,
          raw: RawTransaction(
            text: r.read<String>('raw_text'),
            capturedAt: DateTime.parse(r.read<String>('captured_at')),
            source: TransactionSource.values.byName(r.read<String>('source')),
            sourceApp: r.read<String>('source_app'),
            paymentMethod: r.read<String>('payment_method'),
          ),
        );
      }).toList();

  Future<List<QueryRow>> _pendingDraftBatchRows(
    String ledger,
    Iterable<String> draftIds,
  ) async {
    final ids = draftIds.toSet().toList();
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    return _query(
      '''SELECT d.id AS draft_id,d.parsed_json,r.ledger_id,r.raw_text,r.source_app
      FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id
      WHERE r.ledger_id=? AND d.status='pending' AND d.id IN ($placeholders)''',
      [ledger, ...ids],
    );
  }

  Future<PendingDraftBatchPreview> previewPendingDraftBatch(
    String ledger,
    Iterable<String> draftIds,
    PendingDraftBatchPatch patch,
  ) async {
    final ids = draftIds.toSet().toList();
    if (ids.isEmpty) throw const LedgerException('请先选择待处理账单');
    if (patch.isEmpty) throw const LedgerException('请至少选择一项批量修改内容');
    final rows = await _pendingDraftBatchRows(ledger, ids);
    final byId = {for (final row in rows) row.read<String>('draft_id'): row};
    final targetLedger = patch.targetLedgerId ?? ledger;
    final ledgerRows = await _query('SELECT name FROM ledgers WHERE id=?', [
      targetLedger,
    ]);
    if (ledgerRows.isEmpty) throw const LedgerException('目标账本不存在');
    final targetLedgerName = ledgerRows.single.read<String>('name');
    final targetAccounts = {
      for (final item in await accounts(targetLedger)) item.id: item,
    };
    final targetCategories = {
      for (final item in await categories(targetLedger)) item.id: item,
    };
    if (patch.accountId != null &&
        !targetAccounts.containsKey(patch.accountId)) {
      throw const LedgerException('所选账户不属于目标账本或已归档');
    }
    final normalizedTags = patch.tags == null
        ? null
        : normalizeTags(patch.tags!);
    final result = <PendingDraftBatchItemPreview>[];
    for (final id in ids) {
      final row = byId[id];
      if (row == null) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: '草稿 $id',
            changes: const [],
            skipReason: '草稿已被处理或不属于当前账本',
          ),
        );
        continue;
      }
      Map<String, Object?> parsed;
      try {
        parsed = (jsonDecode(row.read<String>('parsed_json')) as Map)
            .cast<String, Object?>();
      } catch (_) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: '无法读取的草稿',
            changes: const [],
            skipReason: '草稿解析快照已损坏',
          ),
        );
        continue;
      }
      final title = (parsed['merchant'] as String?)?.trim().isNotEmpty == true
          ? (parsed['merchant'] as String).trim()
          : '待核对账单';
      final familyBound =
          parsed['family_event_id'] != null || parsed['family_role'] != null;
      if (familyBound) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: title,
            changes: const [],
            skipReason: '亲情卡账单需在专用审核页处理',
          ),
        );
        continue;
      }
      final typeName = parsed['type'] as String? ?? '';
      final type = TransactionType.values
          .where((item) => item.name == typeName)
          .firstOrNull;
      if (type == null) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: title,
            changes: const [],
            skipReason: '账单收支类型无效',
          ),
        );
        continue;
      }
      final accountId = patch.accountId ?? parsed['account_id'] as String?;
      if (accountId == null || !targetAccounts.containsKey(accountId)) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: title,
            changes: const [],
            skipReason: patch.targetLedgerId == null
                ? '账户缺失、已归档或不属于当前账本'
                : '转移账本时需选择目标账本中的账户',
          ),
        );
        continue;
      }
      final categoryId = patch.categoryId ?? parsed['category_id'] as String?;
      if (categoryId != null &&
          (!targetCategories.containsKey(categoryId) ||
              targetCategories[categoryId]!.type != type)) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: title,
            changes: const [],
            skipReason: patch.targetLedgerId == null
                ? '分类已归档、不存在或与收支方向不符'
                : '转移账本时需选择目标账本中方向一致的分类',
          ),
        );
        continue;
      }
      if (patch.categoryId != null &&
          targetCategories[patch.categoryId]!.type != type) {
        result.add(
          PendingDraftBatchItemPreview(
            draftId: id,
            title: title,
            changes: const [],
            skipReason: '所选分类与该账单的收支方向不符',
          ),
        );
        continue;
      }
      final changes = <String>[];
      if (targetLedger != ledger) changes.add('账本 → $targetLedgerName');
      if (patch.accountId != null && patch.accountId != parsed['account_id']) {
        changes.add('账户 → ${targetAccounts[patch.accountId]!.name}');
      }
      if (patch.categoryId != null &&
          patch.categoryId != parsed['category_id']) {
        changes.add('分类 → ${targetCategories[patch.categoryId]!.name}');
      }
      if (normalizedTags != null) {
        changes.add(
          normalizedTags.isEmpty ? '清空标签' : '标签 → ${normalizedTags.join('、')}',
        );
      }
      result.add(
        PendingDraftBatchItemPreview(
          draftId: id,
          title: title,
          changes: List.unmodifiable(changes),
          skipReason: changes.isEmpty ? '修改后内容与原草稿相同' : null,
        ),
      );
    }
    return PendingDraftBatchPreview(List.unmodifiable(result));
  }

  Future<PendingDraftBatchPreview> applyPendingDraftBatch(
    String ledger,
    Iterable<String> draftIds,
    PendingDraftBatchPatch patch,
  ) => db.transaction(() async {
    final preview = await previewPendingDraftBatch(ledger, draftIds, patch);
    final targetLedger = patch.targetLedgerId ?? ledger;
    final normalizedTags = patch.tags == null
        ? null
        : normalizeTags(patch.tags!).toList();
    final rows = await _pendingDraftBatchRows(
      ledger,
      preview.items.where((item) => item.eligible).map((item) => item.draftId),
    );
    final eligibleIds = preview.items
        .where((item) => item.eligible)
        .map((item) => item.draftId)
        .toSet();
    if (rows.length != eligibleIds.length) {
      throw const LedgerException('部分草稿在预览后已发生变化，请刷新后重试');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    for (final row in rows) {
      final id = row.read<String>('draft_id');
      final parsed = (jsonDecode(row.read<String>('parsed_json')) as Map)
          .cast<String, Object?>();
      if (patch.accountId != null) parsed['account_id'] = patch.accountId;
      if (patch.categoryId != null) parsed['category_id'] = patch.categoryId;
      if (normalizedTags != null) parsed['tags'] = normalizedTags;
      final evidence = (parsed['evidence'] is Map
          ? (parsed['evidence'] as Map).cast<String, Object?>()
          : <String, Object?>{});
      if (patch.accountId != null) evidence['batch_review_account'] = 'true';
      if (patch.categoryId != null) {
        evidence['batch_review_category'] = 'true';
      }
      if (normalizedTags != null) evidence['batch_review_tags'] = 'true';
      parsed['evidence'] = evidence;
      await db.customStatement(
        'UPDATE transaction_drafts SET parsed_json=?,updated_at=? WHERE id=?',
        [jsonEncode(parsed), now, id],
      );
      await db.customStatement(
        '''UPDATE raw_transactions SET ledger_id=? WHERE id=(
        SELECT raw_id FROM transaction_drafts WHERE id=?)''',
        [targetLedger, id],
      );
      await db.customStatement(
        '''UPDATE transaction_evidence_records SET ledger_id=?,account_id=?
        WHERE draft_id=?''',
        [targetLedger, parsed['account_id'], id],
      );
      final amount = parsed['amount_minor'] as int?;
      final typeName = parsed['type'] as String?;
      final occurred = DateTime.tryParse(
        parsed['occurred_date'] as String? ?? '',
      );
      final type = TransactionType.values
          .where((item) => item.name == typeName)
          .firstOrNull;
      if (amount != null && amount > 0 && occurred != null && type != null) {
        final identity = await UnifiedTransactionIdentity.build(
          amountMinor: amount,
          merchant: parsed['merchant'] as String? ?? '',
          occurredAt: occurred,
          accountId: parsed['account_id'] as String?,
          direction: type,
          sourceApp: row.read<String>('source_app'),
          rawText: row.read<String>('raw_text'),
        );
        await db.customStatement(
          '''UPDATE transaction_evidence_records SET semantic_fingerprint=?,
          normalized_merchant=?,occurred_at=?,direction=? WHERE draft_id=?''',
          [
            identity.semanticHash,
            identity.normalizedMerchant,
            occurred.toIso8601String(),
            type.name,
            id,
          ],
        );
      }
      if (normalizedTags != null) {
        await _ensureTagDefinitions(targetLedger, normalizedTags);
      }
      await _recordLearningEvent(
        ledger: targetLedger,
        draftId: id,
        source: TransactionEvidenceSource.manual,
        sourceApp: 'smart_ledger.batch_review',
        outcome: 'updated',
        details: {
          'operation': 'batch_edit',
          'source_ledger': ledger,
          'target_ledger': targetLedger,
          'fields': preview.items
              .firstWhere((item) => item.draftId == id)
              .changes
              .join('；'),
        },
      );
    }
    return preview;
  });

  Future<List<PendingDuplicateGroup>> pendingDuplicateGroups(
    String ledger,
  ) async {
    final evidence = await _query(
      '''SELECT e.draft_id,e.order_hash,e.semantic_fingerprint
      FROM transaction_evidence_records e
      JOIN transaction_drafts d ON d.id=e.draft_id
      JOIN raw_transactions r ON r.id=d.raw_id
      WHERE e.ledger_id=? AND r.ledger_id=? AND d.status='pending'
      AND (e.order_hash IS NOT NULL OR e.semantic_fingerprint IS NOT NULL)''',
      [ledger, ledger],
    );
    final grouped = <String, List<QueryRow>>{};
    for (final row in evidence) {
      final order = row.readNullable<String>('order_hash');
      final semantic = row.readNullable<String>('semantic_fingerprint');
      final key = order == null ? 'semantic:$semantic' : 'order:$order';
      grouped.putIfAbsent(key, () => []).add(row);
    }
    final result = <PendingDuplicateGroup>[];
    for (final entry in grouped.entries) {
      final draftIds = entry.value
          .map((row) => row.read<String>('draft_id'))
          .toSet()
          .toList();
      final hash = entry.key.substring(entry.key.indexOf(':') + 1);
      final order = entry.key.startsWith('order:');
      final posted = await _query(
        '''SELECT COUNT(DISTINCT transaction_id) AS count
        FROM transaction_evidence_records WHERE ledger_id=?
        AND transaction_id IS NOT NULL AND ${order ? 'order_hash' : 'semantic_fingerprint'}=?''',
        [ledger, hash],
      );
      final postedCount = posted.single.read<int>('count');
      if (draftIds.length > 1 || postedCount > 0) {
        result.add(
          PendingDuplicateGroup(
            key: entry.key,
            draftIds: List.unmodifiable(draftIds),
            matchedByOrder: order,
            existingTransactionCount: postedCount,
          ),
        );
      }
    }
    result.sort((a, b) => b.draftIds.length.compareTo(a.draftIds.length));
    return List.unmodifiable(result);
  }

  Future<String?> draftLedger(String id) async => (await _query(
    '''SELECT r.ledger_id FROM transaction_drafts d
    JOIN raw_transactions r ON r.id=d.raw_id WHERE d.id=?''',
    [id],
  )).firstOrNull?.read<String>('ledger_id');

  Future<TransactionConfidence?> draftConfidence(String id) async {
    final row = (await _query(
      'SELECT parsed_json FROM transaction_drafts WHERE id=?',
      [id],
    )).firstOrNull;
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row.read<String>('parsed_json'));
      if (decoded is! Map || decoded['confidence'] is! Map) return null;
      return TransactionConfidence.fromJson(
        (decoded['confidence'] as Map).cast<Object?, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> ignoreDraft(
    String ledger,
    String id,
  ) => db.transaction(() async {
    final rows = await _query(
      "SELECT d.status,r.source,r.source_app FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE d.id=? AND r.ledger_id=?",
      [id, ledger],
    );
    if (rows.isEmpty || rows.single.read<String>('status') != 'pending') {
      throw const LedgerException('草稿不存在或已处理');
    }
    await db.customStatement(
      "UPDATE transaction_drafts SET status='ignored', updated_at=? WHERE id=?",
      [DateTime.now().toUtc().toIso8601String(), id],
    );
    final row = rows.single;
    await _recordLearningEvent(
      ledger: ledger,
      draftId: id,
      source: _sourceForRaw(
        TransactionSource.values.byName(row.read<String>('source')),
      ),
      sourceApp: row.read<String>('source_app'),
      outcome: 'ignored',
      details: const {'reason': '用户忽略待确认草稿'},
    );
  });

  Future<QueryRow?> _linkedFamilyEventForDraft(
    String ledger,
    String draftId,
    String parsedJson,
  ) async {
    String? eventId;
    try {
      final parsed = jsonDecode(parsedJson);
      if (parsed is Map) {
        eventId =
            (parsed['family_event_id'] as String?) ??
            (parsed['evidence'] is Map
                ? parsed['evidence']['family_event_id'] as String?
                : null);
      }
    } catch (_) {}
    if (eventId == null && draftId.startsWith('auto-')) {
      final captureId = draftId.substring(5);
      final evRows = await _query(
        'SELECT event_id FROM family_payment_evidence WHERE capture_id=?',
        [captureId],
      );
      eventId = evRows.firstOrNull?.read<String>('event_id');
    }
    if (eventId == null) return null;
    final rows = await _query(
      'SELECT * FROM family_payment_events WHERE id=? AND ledger_id=?',
      [eventId, ledger],
    );
    return rows.firstOrNull;
  }

  /// The entry, account postings and source link commit atomically.
  /// Repeated confirmation of a posted draft never creates a second entry.
  /// Family-card drafts enforce role & funding invariants so beneficiary
  /// consumption can never deduct a personal asset account.
  Future<String> confirmDraft(
    String ledger,
    String id,
    TransactionInput input, {
    bool rememberChoice = false,
  }) => db.transaction(() async {
    final rows = await _query(
      "SELECT d.*,r.ledger_id,r.source,r.source_app,r.payment_method,r.raw_text FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE d.id=?",
      [id],
    );
    if (rows.isEmpty) throw const LedgerException('草稿不存在');
    final row = rows.single;
    if (row.read<String>('status') == 'posted') {
      return row.read<String>('transaction_id');
    }
    if (row.read<String>('status') != 'pending') {
      throw const LedgerException('草稿已忽略');
    }
    final actualLedger = row.read<String>('ledger_id');
    final parsedJson = row.read<String>('parsed_json');
    Map<String, Object?> parsedData = const {};
    try {
      parsedData = Map<String, Object?>.from(jsonDecode(parsedJson) as Map);
    } catch (_) {}
    final familyEvent = await _linkedFamilyEventForDraft(
      actualLedger,
      id,
      parsedJson,
    );
    String? draftRole;
    try {
      final decoded = jsonDecode(parsedJson);
      if (decoded is Map) {
        draftRole =
            (decoded['family_role'] as String?) ??
            (decoded['evidence'] is Map
                ? decoded['evidence']['family_role'] as String?
                : null);
      }
    } catch (_) {}

    if (familyEvent != null || draftRole != null) {
      if (ledger != actualLedger) {
        throw const LedgerException('亲情卡账单需在原账本中确认');
      }
      final role = familyEvent?.readNullable<String>('local_role') ?? draftRole;
      if (role == null) {
        throw const LedgerException('亲情卡交易需先在亲情卡审核中确认本机是发送方还是使用方');
      }
      if (role == FamilyLocalRole.beneficiary.name) {
        throw const LedgerException('使用方亲情卡消费不扣减本人账户，请在亲情卡待审核中确认额度记录');
      }
      if (input.type != TransactionType.expense) {
        throw const LedgerException('发送方亲情卡消费仅能按支出确认');
      }
      if (familyEvent != null) {
        final existingTxId = familyEvent.readNullable<String>('transaction_id');
        if (existingTxId != null) {
          final now = DateTime.now().toUtc().toIso8601String();
          final linked = await _query(
            'SELECT id FROM transaction_drafts WHERE transaction_id=?',
            [existingTxId],
          );
          if (linked.isEmpty) {
            await db.customStatement(
              "UPDATE transaction_drafts SET status='posted', transaction_id=?, updated_at=? WHERE id=?",
              [existingTxId, now, id],
            );
          } else {
            await db.customStatement(
              "UPDATE transaction_drafts SET status='ignored', updated_at=? WHERE id=?",
              [now, id],
            );
          }
          return existingTxId;
        }
      }
    }

    final sourceApp = row.read<String>('source_app');
    final source = row.read<String>('source');
    final transactionId = await save(
      ledger,
      input,
      learningSourceKey: sourceApp.isEmpty
          ? 'channel:$source'
          : 'app:$sourceApp',
      learningPaymentMethod: row.read<String>('payment_method'),
      recordIdentity: false,
    );
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      "UPDATE transaction_drafts SET status='posted', transaction_id=?, updated_at=? WHERE id=?",
      [transactionId, now, id],
    );
    await db.customStatement(
      '''UPDATE transaction_evidence_records
      SET transaction_id=?, ledger_id=?, draft_id=NULL WHERE draft_id=?''',
      [transactionId, ledger, id],
    );
    final linkedEvidence = await _query(
      'SELECT id FROM transaction_evidence_records WHERE transaction_id=? LIMIT 1',
      [transactionId],
    );
    if (linkedEvidence.isEmpty &&
        [
          TransactionType.expense,
          TransactionType.income,
        ].contains(input.type)) {
      await _storeTransactionIdentity(
        ledger,
        transactionId,
        input,
        (await _resolveMoney(ledger, input)).baseAmount,
        TransactionIdentitySeed(
          source: _sourceForRaw(TransactionSource.values.byName(source)),
          sourceApp: sourceApp,
          captureId: id,
          rawTextForFingerprint: row.read<String>('raw_text'),
        ),
      );
    }
    if (familyEvent != null) {
      final eventId = familyEvent.read<String>('id');
      final money = await _resolveMoney(ledger, input);
      await db.customStatement(
        '''UPDATE family_payment_events
        SET amount_minor=?, merchant=?, occurred_at=?, local_role='payer',
            funding_account_id=?, funding_state='confirmed', status='confirmed',
            transaction_id=?, updated_at=?
        WHERE id=? AND ledger_id=?''',
        [
          money.baseAmount,
          input.merchant.trim(),
          input.occurredDate.toIso8601String(),
          input.accountId,
          transactionId,
          now,
          eventId,
          ledger,
        ],
      );
      final siblingEvidence = await _query(
        'SELECT capture_id FROM family_payment_evidence WHERE event_id=?',
        [eventId],
      );
      for (final ev in siblingEvidence) {
        final siblingDraftId = 'auto-${ev.read<String>('capture_id')}';
        if (siblingDraftId != id) {
          await db.customStatement(
            "UPDATE transaction_drafts SET status='ignored', updated_at=? WHERE id=? AND status='pending'",
            [now, siblingDraftId],
          );
        }
      }
    }
    final postedIdentity = (await _query(
      '''SELECT order_hash,semantic_fingerprint
      FROM transaction_evidence_records WHERE transaction_id=? LIMIT 1''',
      [transactionId],
    )).firstOrNull;
    final learningEventId = await _recordLearningEvent(
      ledger: ledger,
      transactionId: transactionId,
      draftId: id,
      source: _sourceForRaw(TransactionSource.values.byName(source)),
      sourceApp: sourceApp,
      outcome: 'posted',
      fingerprint:
          postedIdentity?.readNullable<String>('order_hash') ??
          postedIdentity?.readNullable<String>('semantic_fingerprint') ??
          '',
      confidence: await draftConfidence(id),
      details: {
        'entry_point': source,
        'learning_source': sourceApp.isEmpty
            ? 'channel:$source'
            : 'app:$sourceApp',
      },
      recognized: {
        'merchant': parsedData['merchant']?.toString() ?? '',
        'category': parsedData['category_id']?.toString() ?? '',
        'account': parsedData['account_id']?.toString() ?? '',
        'tags': (parsedData['tags'] is List)
            ? (parsedData['tags'] as List).join(',')
            : '',
        'ledger': actualLedger,
      },
      finalValues: {
        'merchant': input.merchant,
        'category': input.categoryId ?? '',
        'account': input.accountId,
        'tags': normalizeTags(input.tags).join(','),
        'ledger': ledger,
      },
    );
    await _learnAutoCorrection(
      ledger,
      input,
      learningEventId: learningEventId,
      sourceLedgerId: actualLedger,
      sourceAccountId: parsedData['account_id']?.toString(),
      sourceKey: sourceApp.isEmpty ? 'channel:$source' : 'app:$sourceApp',
      paymentMethod: row.read<String>('payment_method'),
      explicitRemember: rememberChoice,
    );
    return transactionId;
  });

  /// Atomically suppress possible duplicates before automatically posting.
  /// A same-day/account/type/amount/merchant match stays pending for review;
  /// this is deliberately conservative and does not merge two real purchases.
  Future<String?> autoConfirmDraft(
    String ledger,
    String id,
    TransactionInput input,
  ) => db.transaction(() async {
    if (![
      TransactionType.expense,
      TransactionType.income,
    ].contains(input.type)) {
      throw const LedgerException('仅普通收支可自动记账');
    }
    final rows = await _query(
      "SELECT d.status,d.transaction_id,d.parsed_json,r.source,r.ledger_id FROM transaction_drafts d JOIN raw_transactions r ON r.id=d.raw_id WHERE d.id=?",
      [id],
    );
    if (rows.isEmpty) throw const LedgerException('草稿不存在');
    final row = rows.single;
    if (!['ocr', 'notification'].contains(row.read<String>('source'))) {
      throw const LedgerException('此来源不支持自动记账');
    }
    if (row.read<String>('status') == 'posted') {
      return row.read<String>('transaction_id');
    }
    if (row.read<String>('status') != 'pending') {
      throw const LedgerException('草稿已忽略');
    }
    final actualLedger = row.read<String>('ledger_id');
    final parsedJson = row.read<String>('parsed_json');
    final familyEvent = await _linkedFamilyEventForDraft(
      actualLedger,
      id,
      parsedJson,
    );
    if (familyEvent != null) {
      return null;
    }
    final money = await _resolveMoney(actualLedger, input);
    await _validate(actualLedger, input, resolvedMoney: money);
    if ((await assessDraftDuplicate(actualLedger, id, input)).possible) {
      return null;
    }
    return confirmDraft(actualLedger, id, input);
  });

  Future<void> _post(
    String transactionId,
    String accountId,
    int delta,
    String currency,
  ) => db.customStatement(
    'INSERT INTO transaction_postings (id, transaction_id, account_id, delta_minor, currency) VALUES (?, ?, ?, ?, ?)',
    [_uuid.v4(), transactionId, accountId, delta, currency],
  );

  Future<void> _checkNoRefunds(String id) async {
    final linked = await _query(
      "SELECT id FROM transactions WHERE related_transaction_id = ? AND type = 'refund' AND deleted_at IS NULL",
      [id],
    );
    if (linked.isNotEmpty) {
      throw const LedgerException('请先删除关联退款或报销到账，再修改或删除原消费');
    }
  }

  Future<void> delete(String ledger, String id) async {
    await db.transaction(() async {
      await _checkNoRefunds(id);
      final existing = await _query(
        'SELECT type, related_transaction_id FROM transactions WHERE id=? AND ledger_id=? AND deleted_at IS NULL',
        [id, ledger],
      );
      final now = DateTime.now().toUtc().toIso8601String();
      await db.customStatement(
        '''UPDATE transactions SET deleted_at = ?, updated_at = ?, version = version + 1
        WHERE id = ? AND ledger_id = ? AND deleted_at IS NULL''',
        [now, now, id, ledger],
      );
      if (existing.isNotEmpty) {
        final tx = existing.single;
        if (tx.read<String>('type') == 'refund' &&
            tx.readNullable<String>('related_transaction_id') != null) {
          await _syncFamilyEventRefundFromTransaction(
            tx.read<String>('related_transaction_id'),
            now,
          );
        } else {
          await db.customStatement(
            "UPDATE family_payment_events SET status='voided', updated_at=? WHERE transaction_id=? AND ledger_id=?",
            [now, id, ledger],
          );
        }
      }
    });
  }

  Future<void> restore(String ledger, String id) async {
    await db.transaction(() async {
      final rows = await _query(
        '''SELECT t.*,fx.source_currency AS fx_source_currency,
        fx.source_amount_minor AS fx_source_amount_minor,
        fx.source_rate_micros AS fx_source_rate_micros,
        fx.target_currency AS fx_target_currency,
        fx.target_amount_minor AS fx_target_amount_minor,
        fx.target_rate_micros AS fx_target_rate_micros
        FROM transactions t LEFT JOIN transaction_fx fx ON fx.transaction_id=t.id
        WHERE t.id = ? AND t.ledger_id = ? AND t.deleted_at IS NOT NULL''',
        [id, ledger],
      );
      if (rows.isEmpty) throw const LedgerException('已删除交易不存在');
      final r = rows.first;
      final input = TransactionInput(
        type: TransactionType.values.byName(r.read('type')),
        amountMinor:
            r.readNullable<int>('fx_source_amount_minor') ??
            r.read<int>('amount_minor'),
        accountId: r.read('account_id'),
        targetAccountId: r.readNullable('target_account_id'),
        categoryId: r.readNullable('category_id'),
        occurredDate: DateTime.parse(r.read('occurred_date')),
        relatedTransactionId: r.readNullable('related_transaction_id'),
        isReimbursement: r.read<int>('is_reimbursement') == 1,
      );
      await _validate(
        ledger,
        input,
        editingId: id,
        resolvedMoney: _ResolvedMoney(
          baseAmount: r.read<int>('amount_minor'),
          sourceCurrency: r.readNullable<String>('fx_source_currency') ?? 'CNY',
          sourceRate: r.readNullable<int>('fx_source_rate_micros') ?? 1000000,
          targetCurrency: r.readNullable('fx_target_currency'),
          targetAmount: r.readNullable('fx_target_amount_minor'),
          targetRate: r.readNullable('fx_target_rate_micros'),
        ),
      );
      final now = DateTime.now().toUtc().toIso8601String();
      await db.customStatement(
        'UPDATE transactions SET deleted_at = NULL, updated_at = ?, version = version + 1 WHERE id = ?',
        [now, id],
      );
      if (r.read<String>('type') == 'refund' &&
          r.readNullable<String>('related_transaction_id') != null) {
        await _syncFamilyEventRefundFromTransaction(
          r.read<String>('related_transaction_id'),
          now,
        );
      } else {
        await db.customStatement(
          '''UPDATE family_payment_events
          SET status = CASE WHEN refunded_minor >= amount_minor THEN 'refunded' ELSE 'confirmed' END,
              updated_at = ?
          WHERE transaction_id = ? AND ledger_id = ?''',
          [now, id, ledger],
        );
      }
    });
  }

  Future<int> trashRetentionDays() async {
    final value = int.tryParse(
      (await _query(
            "SELECT value FROM settings WHERE key='trash_retention_days'",
          )).firstOrNull?.read<String>('value') ??
          '0',
    );
    return value != null && trashRetentionOptions.contains(value) ? value : 0;
  }

  Future<void> setTrashRetentionDays(int days) async {
    if (!trashRetentionOptions.contains(days)) {
      throw const LedgerException('不支持的回收站保留期限');
    }
    await db.customStatement(
      "INSERT INTO settings VALUES ('trash_retention_days', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      ['$days'],
    );
    await purgeExpiredTrash();
  }

  Future<void> _permanentlyDeleteUnlocked(String ledger, String id) async {
    final rows = await _query(
      'SELECT id FROM transactions WHERE id=? AND ledger_id=? AND deleted_at IS NOT NULL',
      [id, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('回收站中不存在该账目');
    final linked = await _query(
      'SELECT id FROM transactions WHERE related_transaction_id=?',
      [id],
    );
    if (linked.isNotEmpty) {
      throw const LedgerException('请先彻底删除关联的退款或报销到账记录');
    }
    final drafts = await _query(
      'SELECT raw_id FROM transaction_drafts WHERE transaction_id=?',
      [id],
    );
    await db.customStatement(
      "UPDATE family_payment_events SET transaction_id=NULL, status='voided', updated_at=? WHERE transaction_id=?",
      [DateTime.now().toUtc().toIso8601String(), id],
    );
    await db.customStatement('DELETE FROM attachments WHERE transaction_id=?', [
      id,
    ]);
    await db.customStatement(
      'DELETE FROM transaction_splits WHERE transaction_id=?',
      [id],
    );
    await db.customStatement(
      'DELETE FROM transaction_group_items WHERE transaction_id=?',
      [id],
    );
    await db.customStatement(
      '''DELETE FROM transaction_merges
      WHERE target_transaction_id=? OR source_transaction_id=?''',
      [id, id],
    );
    await db.customStatement(
      'DELETE FROM transaction_evidence_records WHERE transaction_id=?',
      [id],
    );
    await db.customStatement(
      'DELETE FROM transaction_postings WHERE transaction_id=?',
      [id],
    );
    await db.customStatement(
      'DELETE FROM transaction_fx WHERE transaction_id=?',
      [id],
    );
    await db.customStatement(
      'DELETE FROM transaction_drafts WHERE transaction_id=?',
      [id],
    );
    for (final row in drafts) {
      await db.customStatement(
        'DELETE FROM raw_transactions WHERE id=? AND NOT EXISTS (SELECT 1 FROM transaction_drafts WHERE raw_id=?)',
        [row.read<String>('raw_id'), row.read<String>('raw_id')],
      );
    }
    await db.customStatement(
      'DELETE FROM transactions WHERE id=? AND ledger_id=? AND deleted_at IS NOT NULL',
      [id, ledger],
    );
  }

  Future<void> permanentlyDelete(String ledger, String id) =>
      db.transaction(() => _permanentlyDeleteUnlocked(ledger, id));

  Future<int> permanentlyDeleteMany(String ledger, Iterable<String> ids) =>
      db.transaction(() async {
        final targets = ids.toSet();
        if (targets.isEmpty) return 0;
        final rows = (await _query(
          '''SELECT id FROM transactions
      WHERE ledger_id=? AND deleted_at IS NOT NULL
      ORDER BY (related_transaction_id IS NULL), deleted_at''',
          [ledger],
        )).where((row) => targets.contains(row.read<String>('id'))).toList();
        if (rows.length != targets.length) {
          throw const LedgerException('部分所选账目已不在回收站，请刷新后重试');
        }
        for (final row in rows) {
          await _permanentlyDeleteUnlocked(ledger, row.read<String>('id'));
        }
        return rows.length;
      });

  Future<int> emptyTrash(String ledger) => db.transaction(() async {
    final rows = await _query(
      '''SELECT id FROM transactions WHERE ledger_id=? AND deleted_at IS NOT NULL
      ORDER BY (related_transaction_id IS NULL), deleted_at''',
      [ledger],
    );
    var removed = 0;
    for (final row in rows) {
      await _permanentlyDeleteUnlocked(ledger, row.read<String>('id'));
      removed++;
    }
    return removed;
  });

  Future<int> purgeExpiredTrash({DateTime? now}) async {
    final days = await trashRetentionDays();
    if (days == 0) return 0;
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(
      Duration(days: days),
    );
    return db.transaction(() async {
      final rows = await _query(
        '''SELECT id, ledger_id FROM transactions
        WHERE deleted_at IS NOT NULL AND deleted_at <= ?
        ORDER BY (related_transaction_id IS NULL), deleted_at''',
        [cutoff.toIso8601String()],
      );
      var removed = 0;
      for (final row in rows) {
        try {
          await _permanentlyDeleteUnlocked(
            row.read<String>('ledger_id'),
            row.read<String>('id'),
          );
          removed++;
        } on LedgerException {
          // Keep a parent until every linked refund/reimbursement is also due.
        }
      }
      return removed;
    });
  }

  Future<List<LedgerEntry>> entries(
    String ledger, {
    String search = '',
    bool deleted = false,
  }) async {
    final rows = await _query(
      '''SELECT t.*, a.name || CASE WHEN a.card_last4 IS NULL OR substr(a.name, -5) = ' ' || a.card_last4 THEN '' ELSE ' · 尾号 ' || a.card_last4 END AS account_name,
      fx.source_currency AS fx_source_currency,
      fx.source_amount_minor AS fx_source_amount_minor,
      fx.source_rate_micros AS fx_source_rate_micros,
      fx.target_currency AS fx_target_currency,
      fx.target_amount_minor AS fx_target_amount_minor,
      cur.symbol AS source_currency_symbol,
      cur.decimals AS source_currency_decimals,
      COALESCE(c.name, oc.name) AS category_name,
      (SELECT COALESCE(SUM(amount_minor),0) FROM transactions r WHERE r.related_transaction_id=t.id AND r.type='refund' AND r.is_reimbursement=1 AND r.deleted_at IS NULL) AS reimbursed_minor,
      (SELECT COALESCE(SUM(amount_minor),0) FROM transactions r WHERE r.related_transaction_id=t.id AND r.type='refund' AND r.is_reimbursement=0 AND r.deleted_at IS NULL) AS refunded_minor,
      (SELECT COUNT(*) FROM attachments att WHERE att.transaction_id=t.id) AS attachment_count FROM transactions t JOIN accounts a ON a.id = t.account_id
      JOIN currencies cur ON cur.ledger_id=t.ledger_id AND cur.code=a.currency
      LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN transaction_fx fx ON fx.transaction_id=t.id
      LEFT JOIN transactions original ON original.id = t.related_transaction_id
      LEFT JOIN categories oc ON oc.id = original.category_id
      WHERE t.ledger_id = ? AND t.deleted_at IS ${deleted ? 'NOT NULL' : 'NULL'}
      AND (instr(lower(t.merchant), lower(?)) > 0 OR instr(lower(t.note), lower(?)) > 0)
      ORDER BY t.occurred_date DESC, t.created_at DESC''',
      [ledger, search, search],
    );
    return rows
        .map(
          (r) => LedgerEntry(
            id: r.read('id'),
            type: TransactionType.values.byName(r.read('type')),
            amountMinor: r.read('amount_minor'),
            accountId: r.read('account_id'),
            accountName: r.read('account_name'),
            targetAccountId: r.readNullable('target_account_id'),
            categoryId: r.readNullable('category_id'),
            categoryName: r.readNullable('category_name'),
            occurredDate: DateTime.parse(r.read('occurred_date')),
            createdAt: DateTime.parse(r.read('created_at')),
            version: r.read('version'),
            merchant: r.read('merchant'),
            note: r.read('note'),
            relatedTransactionId: r.readNullable('related_transaction_id'),
            reimbursable: r.read<int>('reimbursable') == 1,
            isReimbursement: r.read<int>('is_reimbursement') == 1,
            reimbursedMinor: r.read<int>('reimbursed_minor'),
            refundedMinor: r.read<int>('refunded_minor'),
            attachmentCount: r.read<int>('attachment_count'),
            deleted: r.readNullable<String>('deleted_at') != null,
            deletedAt: r.readNullable<String>('deleted_at') == null
                ? null
                : DateTime.parse(r.read<String>('deleted_at')),
            excludeFromReports: r.read<int>('exclude_from_reports') == 1,
            tags: decodeTags(r.read<String>('tags_json')),
            currency: r.readNullable<String>('fx_source_currency') ?? 'CNY',
            originalAmountMinor: r.readNullable('fx_source_amount_minor'),
            exchangeRateMicros:
                r.readNullable<int>('fx_source_rate_micros') ?? 1000000,
            targetCurrency: r.readNullable('fx_target_currency'),
            targetAmountMinor: r.readNullable('fx_target_amount_minor'),
            currencySymbol: r.read('source_currency_symbol'),
            currencyDecimals: r.read('source_currency_decimals'),
          ),
        )
        .toList();
  }

  Future<List<TransactionEvidenceView>> transactionEvidence(
    String ledger,
    String transactionId,
  ) async =>
      (await _query(
            '''SELECT * FROM transaction_evidence_records
    WHERE ledger_id=? AND transaction_id=? ORDER BY created_at,id''',
            [ledger, transactionId],
          ))
          .map(
            (row) => TransactionEvidenceView(
              id: row.read<String>('id'),
              source: TransactionEvidenceSource.values.byName(
                row.read<String>('source_kind'),
              ),
              amountMinor: row.read<int>('amount_minor'),
              merchant: row.read<String>('normalized_merchant'),
              occurredAt: DateTime.parse(row.read<String>('occurred_at')),
              accountId: row.readNullable<String>('account_id'),
              direction: TransactionType.values.byName(
                row.read<String>('direction'),
              ),
              hasOrderNumber: row.readNullable<String>('order_hash') != null,
              sourceApp: row.read<String>('source_app'),
            ),
          )
          .toList();

  Future<void> _ensureIdentityForEntry(String ledger, LedgerEntry entry) async {
    final existing = await _query(
      'SELECT id FROM transaction_evidence_records WHERE ledger_id=? AND transaction_id=? LIMIT 1',
      [ledger, entry.id],
    );
    if (existing.isNotEmpty ||
        ![
          TransactionType.expense,
          TransactionType.income,
        ].contains(entry.type)) {
      return;
    }
    await _storeTransactionIdentity(
      ledger,
      entry.id,
      TransactionInput(
        type: entry.type,
        amountMinor: entry.amountMinor,
        accountId: entry.accountId,
        categoryId: entry.categoryId,
        occurredDate: entry.occurredDate,
        merchant: entry.merchant,
        note: entry.note,
        tags: entry.tags,
      ),
      entry.amountMinor,
      TransactionIdentitySeed(
        source: TransactionEvidenceSource.manual,
        captureId: 'legacy:${entry.id}',
        rawTextForFingerprint: entry.note,
        details: const {'来源': '旧账单兼容指纹'},
      ),
    );
  }

  Future<TransactionDuplicateAssessment> assessDraftDuplicate(
    String ledger,
    String draftId,
    TransactionInput input,
  ) async {
    if (![
      TransactionType.expense,
      TransactionType.income,
    ].contains(input.type)) {
      return const TransactionDuplicateAssessment();
    }
    final all = await entries(ledger);
    final orderRows = await _query(
      '''SELECT DISTINCT order_hash FROM transaction_evidence_records
      WHERE ledger_id=? AND draft_id=? AND order_hash IS NOT NULL''',
      [ledger, draftId],
    );
    final orders = orderRows
        .map((row) => row.read<String>('order_hash'))
        .toSet();
    LedgerEntry? candidate;
    var matchedByOrder = false;
    if (orders.isNotEmpty) {
      final placeholders = List.filled(orders.length, '?').join(',');
      final rows = await _query(
        '''SELECT DISTINCT e.transaction_id FROM transaction_evidence_records e
        JOIN transactions t ON t.id=e.transaction_id
        WHERE e.ledger_id=? AND e.order_hash IN ($placeholders)
          AND e.transaction_id IS NOT NULL AND t.deleted_at IS NULL
          AND t.type IN ('expense','income') ORDER BY t.created_at LIMIT 2''',
        [ledger, ...orders],
      );
      if (rows.isNotEmpty) {
        final id = rows.first.read<String>('transaction_id');
        candidate = all.where((item) => item.id == id).firstOrNull;
        matchedByOrder = candidate != null;
      }
    }
    final normalized = UnifiedTransactionIdentity.normalizeMerchant(
      input.merchant,
    );
    if (candidate == null && normalized.isNotEmpty) {
      candidate = all
          .where(
            (item) =>
                item.type == input.type &&
                item.amountMinor == input.amountMinor &&
                item.accountId == input.accountId &&
                dateKey(item.occurredDate) == dateKey(input.occurredDate) &&
                UnifiedTransactionIdentity.normalizeMerchant(item.merchant) ==
                    normalized,
          )
          .firstOrNull;
    }
    if (candidate == null) return const TransactionDuplicateAssessment();
    final differences = <String>[];
    if (candidate.amountMinor != input.amountMinor) differences.add('金额不同');
    if (UnifiedTransactionIdentity.normalizeMerchant(candidate.merchant) !=
        normalized) {
      differences.add('商户不同');
    }
    final minutes = candidate.occurredDate
        .difference(input.occurredDate)
        .abs()
        .inMinutes;
    if (minutes > 10) differences.add('时间相差 $minutes 分钟');
    if (candidate.accountId != input.accountId) differences.add('账户不同');
    if (candidate.type != input.type) differences.add('收支方向不同');
    return TransactionDuplicateAssessment(
      candidateTransactionId: candidate.id,
      matchedByOrder: matchedByOrder,
      differences: List.unmodifiable(differences),
    );
  }

  /// Duplicate assessment for structured entrances before they create a
  /// draft or transaction. Order identity is preferred; without it, all
  /// semantic fields must agree. Amount alone is never sufficient.
  Future<TransactionDuplicateAssessment> assessStructuredDuplicate(
    String ledger,
    TransactionInput input,
    TransactionIdentitySeed seed, {
    String? excludingTransactionId,
  }) async {
    if (![
      TransactionType.expense,
      TransactionType.income,
    ].contains(input.type)) {
      return const TransactionDuplicateAssessment();
    }
    final fingerprint = await UnifiedTransactionIdentity.build(
      amountMinor: input.amountMinor,
      merchant: input.merchant,
      occurredAt: input.occurredDate,
      accountId: input.accountId,
      direction: input.type,
      sourceApp: seed.sourceApp,
      rawText: seed.rawTextForFingerprint,
      explicitOrderId: seed.orderId,
    );
    final all = (await entries(
      ledger,
    )).where((item) => item.id != excludingTransactionId).toList();
    LedgerEntry? candidate;
    var matchedByOrder = false;
    if (fingerprint.orderHash != null) {
      final rows = await _query(
        '''SELECT DISTINCT e.transaction_id FROM transaction_evidence_records e
        JOIN transactions t ON t.id=e.transaction_id
        WHERE e.ledger_id=? AND e.order_hash=?
          AND e.transaction_id IS NOT NULL AND t.deleted_at IS NULL
          AND t.type IN ('expense','income')
          ${excludingTransactionId == null ? '' : 'AND e.transaction_id!=?'}
        ORDER BY t.created_at LIMIT 1''',
        [ledger, fingerprint.orderHash!, ?excludingTransactionId],
      );
      if (rows.isNotEmpty) {
        final candidateId = rows.single.read<String>('transaction_id');
        candidate = all.where((item) => item.id == candidateId).firstOrNull;
        matchedByOrder = candidate != null;
      }
    }
    final normalized = fingerprint.normalizedMerchant;
    if (candidate == null && normalized.isNotEmpty) {
      candidate = all
          .where(
            (item) =>
                item.type == input.type &&
                item.amountMinor == input.amountMinor &&
                item.accountId == input.accountId &&
                dateKey(item.occurredDate) == dateKey(input.occurredDate) &&
                UnifiedTransactionIdentity.normalizeMerchant(item.merchant) ==
                    normalized,
          )
          .firstOrNull;
    }
    if (candidate == null) return const TransactionDuplicateAssessment();
    final differences = <String>[];
    if (candidate.amountMinor != input.amountMinor) differences.add('金额不同');
    if (UnifiedTransactionIdentity.normalizeMerchant(candidate.merchant) !=
        normalized) {
      differences.add('商户不同');
    }
    final minutes = candidate.occurredDate
        .difference(input.occurredDate)
        .abs()
        .inMinutes;
    if (minutes > 10) differences.add('时间相差 $minutes 分钟');
    if (candidate.accountId != input.accountId) differences.add('账户不同');
    if (candidate.type != input.type) differences.add('收支方向不同');
    return TransactionDuplicateAssessment(
      candidateTransactionId: candidate.id,
      matchedByOrder: matchedByOrder,
      differences: List.unmodifiable(differences),
    );
  }

  /// Finds merge candidates without ever treating an amount as sufficient.
  /// Order evidence wins. Without it, all of amount, normalized merchant,
  /// same-day time window, account and direction must agree.
  Future<List<TransactionMergeCandidate>> transactionMergeCandidates(
    String ledger,
    String transactionId,
  ) async {
    final all = await entries(ledger);
    final target = all.where((item) => item.id == transactionId).firstOrNull;
    if (target == null) throw const LedgerException('账单不存在或已删除');
    if (![
      TransactionType.expense,
      TransactionType.income,
    ].contains(target.type)) {
      return const [];
    }
    await _ensureIdentityForEntry(ledger, target);
    final targetOrderRows = await _query(
      '''SELECT DISTINCT order_hash FROM transaction_evidence_records
      WHERE ledger_id=? AND transaction_id=? AND order_hash IS NOT NULL''',
      [ledger, transactionId],
    );
    final targetOrders = targetOrderRows
        .map((row) => row.read<String>('order_hash'))
        .toSet();
    final orderCandidateIds = <String>{};
    if (targetOrders.isNotEmpty) {
      final placeholders = List.filled(targetOrders.length, '?').join(',');
      final rows = await _query(
        '''SELECT DISTINCT e.transaction_id FROM transaction_evidence_records e
        JOIN transactions t ON t.id=e.transaction_id
        WHERE e.ledger_id=? AND e.order_hash IN ($placeholders)
          AND e.transaction_id IS NOT NULL AND e.transaction_id!=?
          AND t.deleted_at IS NULL AND t.type IN ('expense','income')''',
        [ledger, ...targetOrders, transactionId],
      );
      orderCandidateIds.addAll(
        rows.map((row) => row.read<String>('transaction_id')),
      );
    }
    final normalizedTarget = UnifiedTransactionIdentity.normalizeMerchant(
      target.merchant,
    );
    final candidateIds = <String>{...orderCandidateIds};
    if (normalizedTarget.isNotEmpty) {
      for (final item in all) {
        if (item.id == target.id ||
            ![
              TransactionType.expense,
              TransactionType.income,
            ].contains(item.type)) {
          continue;
        }
        final sameFallback =
            item.type == target.type &&
            item.amountMinor == target.amountMinor &&
            item.accountId == target.accountId &&
            UnifiedTransactionIdentity.normalizeMerchant(item.merchant) ==
                normalizedTarget &&
            dateKey(item.occurredDate) == dateKey(target.occurredDate);
        if (sameFallback) candidateIds.add(item.id);
      }
    }
    final result = <TransactionMergeCandidate>[];
    for (final candidateId in candidateIds) {
      final candidate = all.where((item) => item.id == candidateId).firstOrNull;
      if (candidate == null) continue;
      await _ensureIdentityForEntry(ledger, candidate);
      final candidateOrderRows = await _query(
        '''SELECT DISTINCT order_hash FROM transaction_evidence_records
        WHERE ledger_id=? AND transaction_id=? AND order_hash IS NOT NULL''',
        [ledger, candidate.id],
      );
      final candidateOrders = candidateOrderRows
          .map((row) => row.read<String>('order_hash'))
          .toSet();
      final matchedByOrder = targetOrders
          .intersection(candidateOrders)
          .isNotEmpty;
      final differences = <String>[];
      if (target.amountMinor != candidate.amountMinor) {
        differences.add(
          '金额不同：${target.amountMinor} 分 / ${candidate.amountMinor} 分',
        );
      }
      if (normalizedTarget !=
          UnifiedTransactionIdentity.normalizeMerchant(candidate.merchant)) {
        differences.add('商户不同：${target.merchant} / ${candidate.merchant}');
      }
      final minutes = target.occurredDate
          .difference(candidate.occurredDate)
          .abs()
          .inMinutes;
      if (minutes > 10) differences.add('时间相差 $minutes 分钟');
      if (target.accountId != candidate.accountId) {
        differences.add(
          '账户不同：${target.accountName} / ${candidate.accountName}',
        );
      }
      if (target.type != candidate.type) {
        differences.add('方向不同：${target.type.name} / ${candidate.type.name}');
      }
      if (targetOrders.isNotEmpty &&
          candidateOrders.isNotEmpty &&
          !matchedByOrder) {
        differences.add('订单号证据不一致');
      }
      result.add(
        TransactionMergeCandidate(
          transaction: candidate,
          matchedByOrder: matchedByOrder,
          differences: List.unmodifiable(differences),
          evidence: await transactionEvidence(ledger, candidate.id),
        ),
      );
    }
    result.sort((left, right) {
      if (left.matchedByOrder != right.matchedByOrder) {
        return left.matchedByOrder ? -1 : 1;
      }
      return target.occurredDate
          .difference(left.transaction.occurredDate)
          .abs()
          .compareTo(
            target.occurredDate
                .difference(right.transaction.occurredDate)
                .abs(),
          );
    });
    return result;
  }

  Future<String> mergeTransactions(
    String ledger, {
    required String targetTransactionId,
    required String sourceTransactionId,
    bool acceptConflicts = false,
  }) => db.transaction(() async {
    if (targetTransactionId == sourceTransactionId) {
      throw const LedgerException('不能将账单与自身合并');
    }
    final candidates = await transactionMergeCandidates(
      ledger,
      targetTransactionId,
    );
    final candidate = candidates
        .where((item) => item.transaction.id == sourceTransactionId)
        .firstOrNull;
    if (candidate == null) throw const LedgerException('所选账单不再是可合并候选');
    if (candidate.hasConflict && !acceptConflicts) {
      throw const LedgerException('两笔账单的来源证据存在差异，请明确确认后再合并');
    }
    final familyLinks = await _query(
      '''SELECT id FROM family_payment_events
      WHERE ledger_id=? AND transaction_id IN (?,?) LIMIT 1''',
      [ledger, targetTransactionId, sourceTransactionId],
    );
    if (familyLinks.isNotEmpty) {
      throw const LedgerException('亲情卡账单请在亲情卡审核中合并证据');
    }
    await _checkNoRefunds(sourceTransactionId);
    final sourceRows = await _query(
      '''SELECT deleted_at FROM transactions
      WHERE ledger_id=? AND id=? AND deleted_at IS NULL''',
      [ledger, sourceTransactionId],
    );
    if (sourceRows.isEmpty) throw const LedgerException('待合并账单不存在');
    final active = await _query(
      'SELECT id FROM transaction_merges WHERE source_transaction_id=? AND undone_at IS NULL',
      [sourceTransactionId],
    );
    if (active.isNotEmpty) throw const LedgerException('该账单已经合并');
    final evidenceRows = await _query(
      'SELECT id FROM transaction_evidence_records WHERE ledger_id=? AND transaction_id=?',
      [ledger, sourceTransactionId],
    );
    final evidenceIds = evidenceRows
        .map((row) => row.read<String>('id'))
        .toList();
    final now = DateTime.now().toUtc().toIso8601String();
    final mergeId = _uuid.v4();
    await db.customStatement(
      '''INSERT INTO transaction_merges
      (id,ledger_id,target_transaction_id,source_transaction_id,
       evidence_ids_json,source_deleted_at_before,created_at,undone_at)
      VALUES (?,?,?,?,?,?,?,NULL)''',
      [
        mergeId,
        ledger,
        targetTransactionId,
        sourceTransactionId,
        jsonEncode(evidenceIds),
        sourceRows.single.readNullable<String>('deleted_at'),
        now,
      ],
    );
    await db.customStatement(
      'UPDATE transaction_evidence_records SET transaction_id=? WHERE ledger_id=? AND transaction_id=?',
      [targetTransactionId, ledger, sourceTransactionId],
    );
    await db.customStatement(
      '''UPDATE transactions SET deleted_at=?,updated_at=?,version=version+1
      WHERE ledger_id=? AND id=?''',
      [now, now, ledger, sourceTransactionId],
    );
    return mergeId;
  });

  Future<TransactionMergeUndo?> latestActiveMerge(
    String ledger,
    String targetTransactionId,
  ) async {
    final row = (await _query(
      '''SELECT * FROM transaction_merges WHERE ledger_id=?
      AND target_transaction_id=? AND undone_at IS NULL
      ORDER BY created_at DESC LIMIT 1''',
      [ledger, targetTransactionId],
    )).firstOrNull;
    return row == null
        ? null
        : TransactionMergeUndo(
            id: row.read<String>('id'),
            targetTransactionId: row.read<String>('target_transaction_id'),
            sourceTransactionId: row.read<String>('source_transaction_id'),
            createdAt: DateTime.parse(row.read<String>('created_at')),
          );
  }

  Future<void> undoTransactionMerge(String ledger, String mergeId) =>
      db.transaction(() async {
        final rows = await _query(
          '''SELECT * FROM transaction_merges
          WHERE id=? AND ledger_id=? AND undone_at IS NULL''',
          [mergeId, ledger],
        );
        if (rows.isEmpty) throw const LedgerException('可撤销的合并记录不存在');
        final row = rows.single;
        final evidence =
            (jsonDecode(row.read<String>('evidence_ids_json')) as List)
                .whereType<String>()
                .toList();
        if (evidence.isNotEmpty) {
          final placeholders = List.filled(evidence.length, '?').join(',');
          await db.customStatement(
            '''UPDATE transaction_evidence_records SET transaction_id=?
            WHERE ledger_id=? AND id IN ($placeholders)''',
            [row.read<String>('source_transaction_id'), ledger, ...evidence],
          );
        }
        final now = DateTime.now().toUtc().toIso8601String();
        await db.customStatement(
          '''UPDATE transactions SET deleted_at=?,updated_at=?,version=version+1
          WHERE ledger_id=? AND id=?''',
          [
            row.readNullable<String>('source_deleted_at_before'),
            now,
            ledger,
            row.read<String>('source_transaction_id'),
          ],
        );
        await db.customStatement(
          'UPDATE transaction_merges SET undone_at=? WHERE id=?',
          [now, mergeId],
        );
      });

  Future<bool> amountPrivacy() async =>
      (await _query(
        "SELECT value FROM settings WHERE key='amount_privacy'",
      )).firstOrNull?.read<String>('value') ==
      '1';
  Future<void> setAmountPrivacy(bool enabled) => db.customStatement(
    "INSERT INTO settings VALUES ('amount_privacy', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    [enabled ? '1' : '0'],
  );

  Future<String?> setting(String key) async => (await _query(
    'SELECT value FROM settings WHERE key=?',
    [key],
  )).firstOrNull?.read<String>('value');

  Future<void> setSetting(String key, String value) => db.customStatement(
    'INSERT INTO settings (key,value) VALUES (?,?) '
    'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );

  Future<List<ImageAttachment>> attachments(
    String ledger,
    String transactionId,
  ) async =>
      (await _query(
            'SELECT a.* FROM attachments a JOIN transactions t ON t.id=a.transaction_id WHERE t.ledger_id=? AND t.id=? ORDER BY a.created_at, a.id',
            [ledger, transactionId],
          ))
          .map(
            (r) => ImageAttachment(
              id: r.read('id'),
              name: r.read('name'),
              data: base64Decode(r.read<String>('image_base64')),
            ),
          )
          .toList();

  Future<void> replaceAttachments(
    String ledger,
    String transactionId,
    List<ImageAttachment> images,
  ) => db.transaction(() async {
    if ((await _query(
      'SELECT id FROM transactions WHERE id=? AND ledger_id=? AND deleted_at IS NULL',
      [transactionId, ledger],
    )).isEmpty) {
      throw const LedgerException('交易不存在');
    }
    if (images.length > maxAttachments ||
        images.map((a) => a.id).toSet().length != images.length) {
      throw const LedgerException('每笔最多5张图片，附件不能重复');
    }
    for (final image in images) {
      image.validate();
    }
    await db.customStatement('DELETE FROM attachments WHERE transaction_id=?', [
      transactionId,
    ]);
    for (final image in images) {
      await db
          .customStatement('INSERT INTO attachments VALUES (?, ?, ?, ?, ?)', [
            image.id,
            transactionId,
            image.name,
            base64Encode(image.data),
            DateTime.now().toUtc().toIso8601String(),
          ]);
    }
  });

  Future<void> setBudget(String ledger, DateTime month, int amount) async {
    if (amount < 0) throw const LedgerException('预算不能小于 0');
    final key = dateKey(month).substring(0, 7);
    final id = 'legacy-$ledger-$key';
    await db.transaction(() async {
      await db.customStatement(
        'INSERT INTO budgets VALUES (?, ?, ?) ON CONFLICT(ledger_id, month) DO UPDATE SET amount_minor = excluded.amount_minor',
        [ledger, key, amount],
      );
      if (amount == 0) {
        await db.customStatement(
          'DELETE FROM budget_plans WHERE id=? AND ledger_id=?',
          [id, ledger],
        );
        return;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final start = DateTime(month.year, month.month);
      final end = DateTime(month.year, month.month + 1, 0);
      await db.customStatement(
        '''INSERT INTO budget_plans
        (id,ledger_id,name,category_id,amount_minor,period_kind,starts_on,
         custom_end_on,rollover_mode,alert_enabled,alert_bps,hidden_at,
         archived_at,created_at,updated_at)
        VALUES (?,?,?,NULL,?,'custom',?,?,'none',1,8000,NULL,NULL,?,?)
        ON CONFLICT(id) DO UPDATE SET amount_minor=excluded.amount_minor,
        starts_on=excluded.starts_on,custom_end_on=excluded.custom_end_on,
        updated_at=excluded.updated_at''',
        [
          id,
          ledger,
          '$key 月度预算',
          amount,
          dateKey(start),
          dateKey(end),
          now,
          now,
        ],
      );
    });
  }

  Future<MonthlySummary> summary(String ledger, DateTime month) async {
    final key = dateKey(month).substring(0, 7);
    final rows = await _query(
      '''SELECT t.type, t.amount_minor, COALESCE(c.name, oc.name, '未分类') AS category
      FROM transactions t LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN transactions original ON original.id = t.related_transaction_id
      LEFT JOIN categories oc ON oc.id = original.category_id
      WHERE t.ledger_id = ? AND substr(t.occurred_date, 1, 7) = ?
      AND t.deleted_at IS NULL AND t.exclude_from_reports = 0''',
      [ledger, key],
    );
    var expense = 0;
    var income = 0;
    final groups = <String, int>{};
    for (final r in rows) {
      final type = r.read<String>('type');
      final amount = r.read<int>('amount_minor');
      if (type == 'income') income += amount;
      if (type == 'expense' || type == 'refund') {
        final net = type == 'refund' ? -amount : amount;
        expense += net;
        final category = r.read<String>('category');
        groups[category] = (groups[category] ?? 0) + net;
      }
    }
    final budgets = await _query(
      'SELECT amount_minor FROM budgets WHERE ledger_id = ? AND month = ?',
      [ledger, key],
    );
    return MonthlySummary(
      expenseMinor: expense,
      incomeMinor: income,
      budgetMinor: budgets.isEmpty ? 0 : budgets.first.read('amount_minor'),
      categoryExpenses: groups,
    );
  }
}

class _ResolvedMoney {
  const _ResolvedMoney({
    required this.baseAmount,
    required this.sourceCurrency,
    required this.sourceRate,
    this.targetCurrency,
    this.targetAmount,
    this.targetRate,
  });

  final int baseAmount;
  final String sourceCurrency;
  final int sourceRate;
  final String? targetCurrency;
  final int? targetAmount;
  final int? targetRate;
}
