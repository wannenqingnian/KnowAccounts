import 'dart:convert';
import '../domain/attachment.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import '../core/database/app_database.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/tags.dart';
import '../transaction/auto_correction.dart';
import '../domain/credit_settings.dart';
import '../core/security/card_vault.dart';
import 'package:uuid/uuid.dart';

const backupTables = [
  'ledgers',
  'currencies',
  'accounts',
  'categories',
  'family_cards',
  'tag_definitions',
  'auto_correction_rules',
  'auto_correction_events',
  'transactions',
  'family_payment_events',
  'family_payment_evidence',
  'transaction_fx',
  'transaction_postings',
  'budgets',
  'budget_plans',
  'settings',
  'raw_transactions',
  'transaction_drafts',
  'transaction_evidence_records',
  'learning_events',
  'learning_field_changes',
  'learning_observations',
  'merchant_knowledge',
  'merchant_aliases',
  'auto_correction_suggestions',
  'transaction_merges',
  'attachments',
  'transaction_templates',
  'recurring_rules',
  'recurring_executions',
  'financial_assets',
  'asset_transactions',
  'asset_valuations',
  'asset_schedule_items',
  'credit_card_statements',
  'credit_card_statement_items',
  'transaction_groups',
  'transaction_group_items',
  'transaction_splits',
];
const maxBackupBytes = 50 * 1024 * 1024;

class BackupService {
  BackupService(this.db, {this.cardVault});
  final AppDatabase db;
  final CardVault? cardVault;

  Future<Uint8List> export(String password) async {
    if (password.length < 8) throw const LedgerException('备份密码至少 8 个字符');
    final snapshot = await db.transaction(() async {
      final tables = <String, Object>{};
      for (final table in backupTables) {
        tables[table] = (await db.customSelect('SELECT * FROM $table').get())
            .map((r) => r.data)
            .toList();
      }
      final cards = <String, String>{};
      for (final row
          in await db
              .customSelect(
                'SELECT card_secret_id FROM accounts WHERE card_secret_id IS NOT NULL',
              )
              .get()) {
        final id = row.read<String>('card_secret_id');
        final number = await cardVault?.read(id);
        if (number == null) throw const LedgerException('安全存储中的卡号不可读取，备份已取消');
        cards[id] = number;
      }
      return jsonEncode({
        'format': 'smart-ledger',
        'schema_version': db.schemaVersion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'tables': tables,
        'card_numbers': cards,
      });
    });
    final bytes = await compute(_encrypt, {
      'plaintext': snapshot,
      'password': password,
    });
    if (bytes.length > maxBackupBytes) {
      throw const LedgerException('备份数据超过当前 50 MB 上限');
    }
    return bytes;
  }

  Future<void> restore(Uint8List bytes, String password) async {
    if (bytes.length > maxBackupBytes) {
      throw const LedgerException('备份文件超过 50 MB');
    }
    Map<String, dynamic> payload;
    try {
      final text = await compute(_decrypt, {
        'bytes': bytes,
        'password': password,
      });
      payload = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw const LedgerException('密码错误，或备份文件已损坏');
    }
    final version = payload['schema_version'];
    if (payload['format'] != 'smart-ledger' ||
        version is! int ||
        version < 1 ||
        version > db.schemaVersion) {
      throw const LedgerException('不支持此备份版本');
    }
    final staging = AppDatabase.memory();
    final newSecrets = <String>[];
    var replaced = false;
    try {
      if (payload['schema_version'] == 1) {
        final data = payload['tables'];
        if (data is! Map || data['accounts'] is! List) {
          throw const LedgerException('备份缺少账户数据');
        }
        for (final row in data['accounts']) {
          if (row is! Map ||
              row.containsKey('provider_id') ||
              row.containsKey('repayment_day') ||
              row.containsKey('due_date')) {
            throw const LedgerException('旧版本备份账户格式错误');
          }
          row['provider_id'] = null;
          row['repayment_day'] = null;
          row['due_date'] = null;
          if (row.containsKey('bank_id') || row.containsKey('card_last4')) {
            throw const LedgerException('旧版本备份银行卡字段错误');
          }
          row['bank_id'] = null;
          row['card_last4'] = null;
          if (row.containsKey('card_secret_id')) {
            throw const LedgerException('旧版本备份卡号字段错误');
          }
          row['card_secret_id'] = null;
        }
      }
      if (payload['schema_version'] < 3) {
        final data = payload['tables'];
        if (data is! Map ||
            data.containsKey('raw_transactions') ||
            data.containsKey('transaction_drafts')) {
          throw const LedgerException('旧版本备份表格式错误');
        }
        data['raw_transactions'] = <Object>[];
        data['transaction_drafts'] = <Object>[];
      }
      if (payload['schema_version'] < 4) {
        final data = payload['tables'];
        if (data is! Map || data['transactions'] is! List) {
          throw const LedgerException('备份缺少交易');
        }
        for (final row in data['transactions']) {
          if (row is! Map) throw const LedgerException('备份交易格式错误');
          row.putIfAbsent('tags_json', () => '[]');
        }
      }
      if (payload['schema_version'] < 5) {
        final data = payload['tables'];
        if (data is! Map ||
            data['transactions'] is! List ||
            data.containsKey('attachments')) {
          throw const LedgerException('旧版本备份格式错误');
        }
        data['attachments'] = <Object>[];
        for (final row in data['transactions']) {
          if (row is! Map || row.containsKey('is_reimbursement')) {
            throw const LedgerException('旧版本报销字段格式错误');
          }
          row['is_reimbursement'] = 0;
        }
      }
      if (payload['schema_version'] < 6) {
        final data = payload['tables'];
        if (data is! Map ||
            (data.containsKey('transaction_templates') &&
                (data['transaction_templates'] is! List ||
                    (data['transaction_templates'] as List).isNotEmpty)) ||
            (data.containsKey('recurring_rules') &&
                (data['recurring_rules'] is! List ||
                    (data['recurring_rules'] as List).isNotEmpty))) {
          throw const LedgerException('旧版本计划数据格式错误');
        }
        data['transaction_templates'] = <Object>[];
        data['recurring_rules'] = <Object>[];
      }
      if (payload['schema_version'] < 7) {
        final data = payload['tables'];
        if (data is! Map || data['ledgers'] is! List) {
          throw const LedgerException('旧版本账本数据格式错误');
        }
        for (final table in const [
          'currencies',
          'transaction_fx',
          'financial_assets',
          'transaction_groups',
          'transaction_group_items',
          'transaction_splits',
        ]) {
          if (data.containsKey(table) &&
              (data[table] is! List || (data[table] as List).isNotEmpty)) {
            throw const LedgerException('旧版本扩展数据格式错误');
          }
        }
        data['currencies'] = [
          for (final ledger in data['ledgers'])
            {
              'ledger_id': ledger['id'],
              'code': 'CNY',
              'name': '人民币',
              'symbol': '¥',
              'rate_to_cny_micros': 1000000,
              'decimals': 2,
              'updated_at': ledger['created_at'],
            },
        ];
        if (data['accounts'] is! List) {
          throw const LedgerException('备份缺少账户数据');
        }
        for (final row in data['accounts']) {
          if (row is! Map ||
              (row.containsKey('currency') && row['currency'] != 'CNY')) {
            throw const LedgerException('旧版本账户币种格式错误');
          }
          row.putIfAbsent('currency', () => 'CNY');
        }
        data['transaction_fx'] = <Object>[];
        data['financial_assets'] = <Object>[];
        data['transaction_groups'] = <Object>[];
        data['transaction_group_items'] = <Object>[];
        data['transaction_splits'] = <Object>[];
      }
      if (payload['schema_version'] < 8) {
        final data = payload['tables'];
        if (data is! Map ||
            (data.containsKey('auto_correction_rules') &&
                (data['auto_correction_rules'] is! List ||
                    (data['auto_correction_rules'] as List).isNotEmpty))) {
          throw const LedgerException('旧版本自动修正数据格式错误');
        }
        data['auto_correction_rules'] = <Object>[];
      }
      if (payload['schema_version'] < 9) {
        final data = payload['tables'];
        if (data is! Map ||
            data['raw_transactions'] is! List ||
            data['auto_correction_rules'] is! List ||
            (data.containsKey('auto_correction_events') &&
                (data['auto_correction_events'] is! List ||
                    (data['auto_correction_events'] as List).isNotEmpty))) {
          throw const LedgerException('旧版本自动修正来源格式错误');
        }
        for (final row in data['raw_transactions']) {
          if (row is! Map) throw const LedgerException('旧版本采集记录格式错误');
          row['source_app'] = '';
          row['payment_method'] = '';
        }
        for (final row in data['auto_correction_rules']) {
          if (row is! Map) throw const LedgerException('旧版本自动修正规则格式错误');
          row['source_key'] = '';
          row['min_amount_minor'] = null;
          row['max_amount_minor'] = null;
          row['payment_method_pattern'] = '';
        }
        data['auto_correction_events'] = <Object>[];
      }
      if (payload['schema_version'] < 10) {
        final data = payload['tables'];
        if (data is! Map) throw const LedgerException('旧版本资产明细格式错误');
        for (final table in const [
          'asset_transactions',
          'asset_valuations',
          'asset_schedule_items',
          'credit_card_statements',
          'credit_card_statement_items',
        ]) {
          if (data.containsKey(table) &&
              (data[table] is! List || (data[table] as List).isNotEmpty)) {
            throw const LedgerException('旧版本资产明细格式错误');
          }
          data[table] = <Object>[];
        }
      }
      if (payload['schema_version'] < 11) {
        final data = payload['tables'];
        if (data is! Map || data['budgets'] is! List) {
          throw const LedgerException('旧版本预算数据格式错误');
        }
        if (data.containsKey('budget_plans') &&
            (data['budget_plans'] is! List ||
                (data['budget_plans'] as List).isNotEmpty)) {
          throw const LedgerException('旧版本预算数据格式错误');
        }
        final plans = <Object>[];
        for (final item in data['budgets']) {
          if (item is! Map ||
              item['ledger_id'] is! String ||
              item['month'] is! String ||
              item['amount_minor'] is! int) {
            throw const LedgerException('旧版本预算数据格式错误');
          }
          final month = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(item['month']);
          final amount = item['amount_minor'] as int;
          if (month == null || amount < 0) {
            throw const LedgerException('旧版本预算数据格式错误');
          }
          if (amount == 0) continue;
          final year = int.parse(month.group(1)!);
          final number = int.parse(month.group(2)!);
          if (number < 1 || number > 12) {
            throw const LedgerException('旧版本预算数据格式错误');
          }
          final key = item['month'] as String;
          final ledger = item['ledger_id'] as String;
          final created = '$key-01T00:00:00.000Z';
          plans.add({
            'id': 'legacy-$ledger-$key',
            'ledger_id': ledger,
            'name': '$key 月度预算',
            'category_id': null,
            'amount_minor': amount,
            'period_kind': 'custom',
            'starts_on': '$key-01',
            'custom_end_on': dateKey(DateTime(year, number + 1, 0)),
            'rollover_mode': 'none',
            'alert_enabled': 1,
            'alert_bps': 8000,
            'hidden_at': null,
            'archived_at': null,
            'created_at': created,
            'updated_at': created,
          });
        }
        data['budget_plans'] = plans;
      }
      if (payload['schema_version'] < 12) {
        final data = payload['tables'];
        if (data is! Map ||
            data['categories'] is! List ||
            data['recurring_rules'] is! List ||
            (data.containsKey('tag_definitions') &&
                (data['tag_definitions'] is! List ||
                    (data['tag_definitions'] as List).isNotEmpty)) ||
            (data.containsKey('recurring_executions') &&
                (data['recurring_executions'] is! List ||
                    (data['recurring_executions'] as List).isNotEmpty))) {
          throw const LedgerException('旧版本周期计划或标签数据格式错误');
        }
        for (final row in data['categories']) {
          if (row is! Map) throw const LedgerException('旧版本分类格式错误');
          row['icon_key'] = '';
        }
        for (final row in data['recurring_rules']) {
          if (row is! Map) throw const LedgerException('旧版本周期计划格式错误');
          row['end_at'] = null;
          row['max_runs'] = null;
          row['run_count'] = 0;
          row['notify_enabled'] = 1;
          row['retry_count'] = 0;
          row['last_error'] = '';
        }
        data['tag_definitions'] = <Object>[];
        data['recurring_executions'] = <Object>[];
      }
      if (payload['schema_version'] < 13) {
        final data = payload['tables'];
        if (data is! Map) throw const LedgerException('旧版本亲情卡数据格式错误');
        for (final table in const [
          'family_cards',
          'family_payment_events',
          'family_payment_evidence',
        ]) {
          if (data.containsKey(table) &&
              (data[table] is! List || (data[table] as List).isNotEmpty)) {
            throw const LedgerException('旧版本亲情卡数据格式错误');
          }
          data[table] = <Object>[];
        }
      }
      if (payload['schema_version'] < 14) {
        final data = payload['tables'];
        if (data is! Map) throw const LedgerException('旧版本账单指纹数据格式错误');
        for (final table in const [
          'transaction_evidence_records',
          'transaction_merges',
        ]) {
          if (data.containsKey(table) &&
              (data[table] is! List || (data[table] as List).isNotEmpty)) {
            throw const LedgerException('旧版本账单指纹数据格式错误');
          }
          data[table] = <Object>[];
        }
      }
      if (payload['schema_version'] < 15) {
        final data = payload['tables'];
        if (data is! Map ||
            (data.containsKey('learning_events') &&
                (data['learning_events'] is! List ||
                    (data['learning_events'] as List).isNotEmpty))) {
          throw const LedgerException('旧版本学习事件格式错误');
        }
        data['learning_events'] = <Object>[];
      }
      if (payload['schema_version'] < 16) {
        final data = payload['tables'];
        if (data is! Map) {
          throw const LedgerException('旧版本商户学习数据格式错误');
        }
        for (final table in const [
          'learning_field_changes',
          'learning_observations',
          'merchant_knowledge',
          'merchant_aliases',
          'auto_correction_suggestions',
        ]) {
          if (data.containsKey(table) &&
              (data[table] is! List || (data[table] as List).isNotEmpty)) {
            throw const LedgerException('旧版本商户学习数据格式错误');
          }
          data[table] = <Object>[];
        }
      }
      await _replace(staging, payload['tables']);
      await _validate(staging);
      final cards = payload['card_numbers'] ?? <String, dynamic>{};
      if (cards is! Map || cards.values.any((v) => v is! String)) {
        throw const LedgerException('备份卡号格式错误');
      }
      final accounts = payload['tables']['accounts'] as List;
      final withCards = accounts
          .where((r) => r['card_secret_id'] != null)
          .toList();
      if (cards.length != withCards.length ||
          withCards.any((r) => !cards.containsKey(r['card_secret_id']))) {
        throw const LedgerException('备份缺少完整卡号或存在多余卡号');
      }
      for (final row in withCards) {
        final number = cards[row['card_secret_id']] as String;
        if (!RegExp(r'^\d{13,19}$').hasMatch(number) ||
            !number.endsWith(row['card_last4'] as String)) {
          throw const LedgerException('备份中的完整卡号与尾号不一致');
        }
      }
      if (withCards.isNotEmpty && cardVault == null) {
        throw const LedgerException('此设备无法安全恢复完整卡号，恢复已取消');
      }
      // Fresh secret references keep the old database's secure records intact
      // if writing secrets or the later SQLite transaction fails.
      for (final row in withCards) {
        final number = cards[row['card_secret_id']] as String;
        final id = const Uuid().v4();
        newSecrets.add(id);
        await cardVault!.write(id, number);
        row['card_secret_id'] = id;
      }
      // Existing database is only touched after the temporary database passes validation.
      await _replace(db, payload['tables'], preserveDevice: true);
      replaced = true;
    } on LedgerException {
      rethrow;
    } catch (_) {
      throw const LedgerException('备份数据不完整，恢复已取消');
    } finally {
      if (!replaced && cardVault != null) {
        for (final id in newSecrets) {
          try {
            await cardVault!.delete(id);
          } catch (_) {
            /* Keep the original error. */
          }
        }
      }
      await staging.close();
    }
  }

  Future<void> _replace(
    AppDatabase target,
    dynamic data, {
    bool preserveDevice = false,
  }) async {
    if (data is! Map ||
        data.length != backupTables.length ||
        !backupTables.every(data.containsKey)) {
      throw const LedgerException('备份缺少数据表');
    }
    await target.transaction(() async {
      final device = preserveDevice
          ? (await target
                    .customSelect(
                      "SELECT value FROM settings WHERE key = 'device_id'",
                    )
                    .get())
                .firstOrNull
                ?.read<String>('value')
          : null;
      await target.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final table in backupTables.reversed) {
        await target.customStatement('DELETE FROM $table');
      }
      for (final table in backupTables) {
        final rows = data[table];
        if (rows is! List) throw const LedgerException('备份表格式错误');
        final columns =
            (await target.customSelect('PRAGMA table_info($table)').get())
                .map((r) => r.read<String>('name'))
                .toList();
        for (final row in rows) {
          if (row is! Map ||
              row.length != columns.length ||
              !columns.every(row.containsKey) ||
              row.values.any((v) => v != null && v is! String && v is! int)) {
            throw const LedgerException('备份字段格式错误');
          }
          await target.customStatement(
            'INSERT INTO $table (${columns.join(',')}) VALUES (${List.filled(columns.length, '?').join(',')})',
            columns.map((column) => row[column]).toList(),
          );
        }
      }
      if (device != null) {
        await target.customStatement(
          "UPDATE settings SET value = ? WHERE key = 'device_id'",
          [device],
        );
      }
      await _validate(target);
    });
  }

  Future<void> _validate(AppDatabase target) async {
    for (final row
        in await target.customSelect('SELECT * FROM accounts').get()) {
      final kind = AccountKind.values.byName(row.read<String>('kind'));
      final dateText = row.readNullable<String>('due_date');
      final date = dateText == null ? null : DateTime.tryParse(dateText);
      if (!RegExp(r'^[A-Z]{3}$').hasMatch(row.read<String>('currency')) ||
          row.read<int>('opening_minor').abs() > 999999999999 ||
          (dateText != null &&
              (date == null ||
                  date.toIso8601String().substring(0, 10) != dateText))) {
        throw const LedgerException('备份账户或还款日期无效');
      }
      validateCreditSettings(
        kind,
        row.readNullable('provider_id'),
        row.readNullable('repayment_day'),
        date,
      );
      validateBankSettings(
        kind,
        row.readNullable('bank_id'),
        row.readNullable('card_last4'),
      );
      final secretId = row.readNullable<String>('card_secret_id');
      if (secretId != null &&
          (row.readNullable<String>('card_last4') == null ||
              !RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(secretId))) {
        throw const LedgerException('备份卡号引用无效');
      }
    }
    final badCurrencies = await target.customSelect(
      '''SELECT c.code FROM currencies c LEFT JOIN ledgers l ON l.id=c.ledger_id
      WHERE l.id IS NULL OR length(c.code)!=3 OR c.code!=upper(c.code)
      OR c.rate_to_cny_micros<=0 OR c.decimals NOT BETWEEN 0 AND 4
      OR (c.code='CNY' AND (c.rate_to_cny_micros!=1000000 OR c.decimals!=2))
      OR NOT EXISTS (SELECT 1 FROM currencies base WHERE base.ledger_id=c.ledger_id AND base.code='CNY')
      LIMIT 1''',
    ).get();
    final missingAccountCurrencies = await target.customSelect(
      '''SELECT a.id FROM accounts a LEFT JOIN currencies c
      ON c.ledger_id=a.ledger_id AND c.code=a.currency
      WHERE c.code IS NULL LIMIT 1''',
    ).get();
    if (badCurrencies.isNotEmpty || missingAccountCurrencies.isNotEmpty) {
      throw const LedgerException('备份中的币种或汇率无效');
    }
    for (final row
        in await target.customSelect('SELECT * FROM raw_transactions').get()) {
      if (DateTime.tryParse(row.read<String>('captured_at')) == null ||
          row.read<String>('raw_text').trim().isEmpty) {
        throw const LedgerException('备份中的账单来源无效');
      }
    }
    for (final row
        in await target
            .customSelect('SELECT * FROM transaction_drafts')
            .get()) {
      final parsed = jsonDecode(row.read<String>('parsed_json'));
      if (parsed is! Map ||
          parsed['warnings'] is! List ||
          parsed['evidence'] is! Map ||
          parsed['blocked'] is! bool ||
          DateTime.tryParse(row.read<String>('updated_at')) == null) {
        throw const LedgerException('备份中的草稿无效');
      }
    }
    for (final row
        in await target.customSelect('SELECT * FROM attachments').get()) {
      final encoded = row.read<String>('image_base64');
      if (encoded.length > (maxAttachmentBytes + 2) ~/ 3 * 4) {
        throw const LedgerException('附件超过大小限制');
      }
      ImageAttachment(
        id: row.read('id'),
        name: row.read('name'),
        data: base64Decode(encoded),
      ).validate();
      if (DateTime.tryParse(row.read<String>('created_at')) == null) {
        throw const LedgerException('附件日期无效');
      }
    }
    if ((await target
            .customSelect(
              'SELECT transaction_id FROM attachments GROUP BY transaction_id HAVING COUNT(*) > 5',
            )
            .get())
        .isNotEmpty) {
      throw const LedgerException('附件数量超出限制');
    }
    final privacy = await target
        .customSelect("SELECT value FROM settings WHERE key='amount_privacy'")
        .get();
    if (privacy.any((r) => !['0', '1'].contains(r.read<String>('value')))) {
      throw const LedgerException('隐私设置无效');
    }
    final badDrafts = await target.customSelect(
      '''SELECT d.id FROM transaction_drafts d
      JOIN raw_transactions r ON r.id=d.raw_id JOIN transactions t ON t.id=d.transaction_id
      WHERE r.ledger_id != t.ledger_id LIMIT 1''',
    ).get();
    if (badDrafts.isNotEmpty) throw const LedgerException('备份中的草稿与账本不一致');
    final integrity = await target.customSelect('PRAGMA integrity_check').get();
    final foreignKeys = await target
        .customSelect('PRAGMA foreign_key_check')
        .get();
    if (integrity.first.data.values.first != 'ok' || foreignKeys.isNotEmpty) {
      throw const LedgerException('备份完整性检查失败');
    }
    final ledgers = await target.customSelect('SELECT id FROM ledgers').get();
    final device = await target
        .customSelect("SELECT value FROM settings WHERE key = 'device_id'")
        .get();
    if (ledgers.isEmpty ||
        device.length != 1 ||
        device.first.read<String>('value').isEmpty) {
      throw const LedgerException('备份缺少账本或设备信息');
    }
    final bad = await target.customSelect(
      '''SELECT t.id FROM transactions t
      JOIN accounts a ON a.id = t.account_id
      LEFT JOIN accounts destination ON destination.id = t.target_account_id
      LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN transactions original ON original.id = t.related_transaction_id
      WHERE a.ledger_id != t.ledger_id OR t.amount_minor > 999999999999
        OR t.currency != 'CNY' OR t.type = 'adjustment'
        OR (t.type = 'transfer' AND destination.ledger_id != t.ledger_id)
        OR (t.type IN ('expense', 'income') AND (c.id IS NULL OR c.ledger_id != t.ledger_id OR c.type != t.type))
        OR (t.is_reimbursement = 1 AND (t.type != 'refund' OR original.reimbursable != 1))
        OR (t.type = 'refund' AND (original.type != 'expense' OR original.ledger_id != t.ledger_id
          OR (t.deleted_at IS NULL AND original.deleted_at IS NOT NULL)))
        OR (SELECT COUNT(*) FROM transaction_postings p WHERE p.transaction_id = t.id) !=
          CASE WHEN t.type = 'transfer' THEN 2 ELSE 1 END
        OR NOT EXISTS (SELECT 1 FROM transaction_postings p
          LEFT JOIN transaction_fx fx ON fx.transaction_id=t.id
          WHERE p.transaction_id=t.id AND p.account_id = t.account_id
          AND p.currency = a.currency
          AND COALESCE(fx.source_currency,'CNY')=a.currency
          AND p.delta_minor = CASE WHEN t.type IN ('expense', 'transfer')
            THEN -COALESCE(fx.source_amount_minor,t.amount_minor)
            ELSE COALESCE(fx.source_amount_minor,t.amount_minor) END)
        OR (t.type = 'transfer' AND NOT EXISTS (SELECT 1 FROM transaction_postings p
          LEFT JOIN transaction_fx fx ON fx.transaction_id=t.id
          WHERE p.transaction_id = t.id AND p.account_id = t.target_account_id
          AND p.currency = destination.currency
          AND COALESCE(fx.target_currency,'CNY')=destination.currency
          AND p.delta_minor = COALESCE(fx.target_amount_minor,t.amount_minor))) LIMIT 1''',
    ).get();
    final badRefunds = await target.customSelect(
      '''SELECT original.id FROM transactions original
      JOIN transactions refund ON refund.related_transaction_id = original.id
      WHERE refund.type = 'refund' AND refund.deleted_at IS NULL
      GROUP BY original.id HAVING SUM(refund.amount_minor) > original.amount_minor LIMIT 1''',
    ).get();
    final badFx = await target.customSelect(
      '''SELECT fx.transaction_id FROM transaction_fx fx
      JOIN transactions t ON t.id=fx.transaction_id
      JOIN accounts a ON a.id=t.account_id
      LEFT JOIN accounts destination ON destination.id=t.target_account_id
      WHERE fx.source_currency!=a.currency OR fx.source_amount_minor<=0
      OR CAST((fx.source_amount_minor*fx.source_rate_micros+500000)/1000000 AS INTEGER)!=t.amount_minor
      OR (t.type='transfer' AND (fx.target_currency IS NULL
        OR fx.target_currency!=destination.currency OR fx.target_amount_minor<=0))
      OR (t.type!='transfer' AND fx.target_currency IS NOT NULL)
      OR (fx.source_currency='CNY' AND COALESCE(fx.target_currency,'CNY')='CNY')
      LIMIT 1''',
    ).get();
    final badAssets = await target.customSelect(
      '''SELECT f.id FROM financial_assets f
      LEFT JOIN currencies c ON c.ledger_id=f.ledger_id AND c.code=f.currency
      LEFT JOIN accounts a ON a.id=f.account_id
      WHERE c.code IS NULL OR (f.account_id IS NOT NULL AND a.ledger_id!=f.ledger_id)
      OR f.completed_periods>f.total_periods
      OR (f.start_date IS NOT NULL AND date(f.start_date) IS NULL)
      OR (f.maturity_date IS NOT NULL AND date(f.maturity_date) IS NULL)
      OR (f.start_date IS NOT NULL AND f.maturity_date IS NOT NULL
        AND f.maturity_date<f.start_date) LIMIT 1''',
    ).get();
    final badAssetTransactions = await target.customSelect(
      '''SELECT x.id FROM asset_transactions x
      JOIN financial_assets f ON f.id=x.asset_id
      LEFT JOIN accounts a ON a.id=x.account_id
      LEFT JOIN transactions t ON t.id=x.transaction_id
      WHERE (x.account_id IS NOT NULL AND a.ledger_id!=f.ledger_id)
      OR (x.transaction_id IS NOT NULL AND t.ledger_id!=f.ledger_id)
      OR datetime(x.occurred_at) IS NULL OR datetime(x.created_at) IS NULL
      LIMIT 1''',
    ).get();
    final badAssetValuations = await target.customSelect(
      '''SELECT v.id FROM asset_valuations v
      LEFT JOIN financial_assets f ON f.id=v.asset_id
      WHERE f.id IS NULL OR datetime(v.valued_at) IS NULL LIMIT 1''',
    ).get();
    final badAssetSchedules = await target.customSelect(
      '''SELECT s.id FROM asset_schedule_items s
      LEFT JOIN financial_assets f ON f.id=s.asset_id
      LEFT JOIN transactions t ON t.id=s.transaction_id
      WHERE f.id IS NULL OR date(s.due_at) IS NULL
      OR (s.paid_at IS NOT NULL AND datetime(s.paid_at) IS NULL)
      OR (s.status='paid' AND s.paid_at IS NULL)
      OR (s.transaction_id IS NOT NULL AND t.ledger_id!=f.ledger_id)
      LIMIT 1''',
    ).get();
    final badCardStatements = await target.customSelect(
      '''SELECT s.id FROM credit_card_statements s
      JOIN financial_assets f ON f.id=s.asset_id
      WHERE f.kind!='creditCard' OR date(s.period_start) IS NULL
      OR date(s.period_end) IS NULL OR date(s.due_at) IS NULL
      OR s.period_start>s.period_end OR s.paid_minor>s.statement_minor
      OR (s.status='paid' AND s.paid_minor<s.statement_minor)
      OR datetime(s.created_at) IS NULL OR datetime(s.updated_at) IS NULL
      LIMIT 1''',
    ).get();
    final badCardStatementItems = await target.customSelect(
      '''SELECT i.transaction_id FROM credit_card_statement_items i
      JOIN credit_card_statements s ON s.id=i.statement_id
      JOIN financial_assets f ON f.id=s.asset_id
      JOIN transactions t ON t.id=i.transaction_id
      WHERE f.ledger_id!=t.ledger_id LIMIT 1''',
    ).get();
    final badGroups = await target.customSelect(
      '''SELECT i.transaction_id FROM transaction_group_items i
      JOIN transaction_groups g ON g.id=i.group_id
      JOIN transactions t ON t.id=i.transaction_id
      WHERE g.ledger_id!=t.ledger_id LIMIT 1''',
    ).get();
    final badSplits = await target.customSelect(
      '''SELECT s.transaction_id FROM transaction_splits s
      JOIN transactions t ON t.id=s.transaction_id
      GROUP BY s.transaction_id HAVING SUM(s.amount_minor)!=MAX(t.amount_minor)
      OR MAX(t.type)='transfer' OR COUNT(*)>100 LIMIT 1''',
    ).get();
    final badCategories = await target.customSelect(
      '''SELECT c.id FROM categories c JOIN categories p ON p.id = c.parent_id
      WHERE p.parent_id IS NOT NULL OR p.ledger_id != c.ledger_id OR p.type != c.type OR (c.archived_at IS NULL AND p.archived_at IS NOT NULL) LIMIT 1''',
    ).get();
    final badAutoCorrections = await target.customSelect(
      '''SELECT r.id FROM auto_correction_rules r
      JOIN ledgers l ON l.id=r.ledger_id
      LEFT JOIN accounts a ON a.id=r.account_id
      LEFT JOIN categories c ON c.id=r.category_id
      WHERE length(r.merchant_pattern) NOT BETWEEN 1 AND 100
      OR length(r.normalized_pattern) NOT BETWEEN 1 AND 100
      OR (r.account_id IS NOT NULL AND a.ledger_id!=r.ledger_id)
      OR (r.category_id IS NOT NULL AND
        (c.ledger_id!=r.ledger_id OR c.type!=r.type))
      OR (r.account_id IS NULL AND r.category_id IS NULL AND r.tags_json='[]')
      OR (r.source_key!='' AND r.source_key NOT GLOB 'channel:*'
        AND r.source_key NOT GLOB 'app:*')
      OR r.min_amount_minor<0 OR r.max_amount_minor<0
      OR (r.min_amount_minor IS NOT NULL AND r.max_amount_minor IS NOT NULL
        AND r.min_amount_minor>r.max_amount_minor)
      OR datetime(r.created_at) IS NULL OR datetime(r.updated_at) IS NULL
      OR (r.last_used_at IS NOT NULL AND datetime(r.last_used_at) IS NULL)
      LIMIT 1''',
    ).get();
    final badBudgets = await target.customSelect(
      '''SELECT b.id FROM budget_plans b
      JOIN ledgers l ON l.id=b.ledger_id
      LEFT JOIN categories c ON c.id=b.category_id
      WHERE (b.category_id IS NOT NULL AND
        (c.ledger_id!=b.ledger_id OR c.type!='expense'))
      OR date(b.starts_on) IS NULL
      OR (b.period_kind='custom' AND
        (date(b.custom_end_on) IS NULL OR b.custom_end_on<b.starts_on))
      OR (b.period_kind!='custom' AND b.custom_end_on IS NOT NULL)
      OR datetime(b.created_at) IS NULL OR datetime(b.updated_at) IS NULL
      OR (b.hidden_at IS NOT NULL AND datetime(b.hidden_at) IS NULL)
      OR (b.archived_at IS NOT NULL AND datetime(b.archived_at) IS NULL)
      LIMIT 1''',
    ).get();
    final badRecurringExecutions = await target.customSelect(
      '''SELECT e.id FROM recurring_executions e
      JOIN recurring_rules r ON r.id=e.rule_id
      LEFT JOIN transactions t ON t.id=e.transaction_id
      WHERE e.ledger_id!=r.ledger_id
      OR datetime(e.scheduled_at) IS NULL OR datetime(e.created_at) IS NULL
      OR datetime(e.finished_at) IS NULL
      OR (e.status='success' AND
        (e.transaction_id IS NULL OR t.ledger_id!=e.ledger_id))
      OR (e.status!='success' AND e.transaction_id IS NOT NULL)
      LIMIT 1''',
    ).get();
    final badTagDefinitions = await target.customSelect(
      '''SELECT d.id FROM tag_definitions d
      JOIN ledgers l ON l.id=d.ledger_id
      WHERE length(d.name) NOT BETWEEN 1 AND 20
      OR length(d.normalized_name) NOT BETWEEN 1 AND 20
      OR datetime(d.created_at) IS NULL OR datetime(d.updated_at) IS NULL
      OR (d.hidden_at IS NOT NULL AND datetime(d.hidden_at) IS NULL)
      LIMIT 1''',
    ).get();
    final badFamilyCards = await target.customSelect(
      '''SELECT c.id FROM family_cards c
      JOIN ledgers l ON l.id=c.ledger_id
      LEFT JOIN accounts a ON a.id=c.default_funding_account_id
      LEFT JOIN categories cat ON cat.id=c.default_category_id
      WHERE length(trim(c.display_name)) NOT BETWEEN 1 AND 100
      OR c.sender_limit_minor NOT BETWEEN 0 AND 999999999999
      OR c.user_limit_minor NOT BETWEEN 0 AND 999999999999
      OR (c.local_role='beneficiary' AND c.default_funding_account_id IS NOT NULL)
      OR (c.default_funding_account_id IS NOT NULL AND (a.id IS NULL OR a.ledger_id!=c.ledger_id))
      OR (c.default_category_id IS NOT NULL AND
        (cat.id IS NULL OR cat.ledger_id!=c.ledger_id OR cat.type!='expense'))
      OR datetime(c.created_at) IS NULL OR datetime(c.updated_at) IS NULL
      OR (c.archived_at IS NOT NULL AND datetime(c.archived_at) IS NULL)
      LIMIT 1''',
    ).get();
    final badFamilyEvents = await target.customSelect(
      '''SELECT e.id FROM family_payment_events e
      JOIN ledgers l ON l.id=e.ledger_id
      LEFT JOIN family_cards c ON c.id=e.card_id
      LEFT JOIN accounts a ON a.id=e.funding_account_id
      LEFT JOIN transactions t ON t.id=e.transaction_id
      WHERE e.amount_minor NOT BETWEEN 1 AND 999999999999
      OR (e.card_id IS NOT NULL AND (c.id IS NULL OR c.ledger_id!=e.ledger_id OR c.platform!=e.platform))
      OR (e.funding_account_id IS NOT NULL AND (a.id IS NULL OR a.ledger_id!=e.ledger_id))
      OR (e.transaction_id IS NOT NULL AND (t.id IS NULL OR t.ledger_id!=e.ledger_id OR t.type!='expense'))
      OR (e.local_role='beneficiary' AND (e.funding_account_id IS NOT NULL OR e.transaction_id IS NOT NULL))
      OR (e.status='confirmed' AND (e.local_role IS NULL OR e.funding_state!='confirmed'
        OR (e.local_role='payer' AND (e.funding_account_id IS NULL OR e.transaction_id IS NULL))))
      OR (e.occurred_at IS NOT NULL AND datetime(e.occurred_at) IS NULL)
      OR datetime(e.created_at) IS NULL OR datetime(e.updated_at) IS NULL
      LIMIT 1''',
    ).get();
    final badFamilyEvidence = await target.customSelect(
      '''SELECT ev.id FROM family_payment_evidence ev
      LEFT JOIN family_payment_events e ON e.id=ev.event_id
      WHERE e.id IS NULL OR datetime(ev.observed_at) IS NULL
      OR (ev.amount_minor IS NOT NULL AND ev.amount_minor<=0)
      LIMIT 1''',
    ).get();
    final badTransactionEvidence = await target.customSelect(
      '''SELECT e.id FROM transaction_evidence_records e
      JOIN ledgers l ON l.id=e.ledger_id
      LEFT JOIN transactions t ON t.id=e.transaction_id
      LEFT JOIN transaction_drafts d ON d.id=e.draft_id
      LEFT JOIN accounts a ON a.id=e.account_id
      WHERE ((e.transaction_id IS NULL)=(e.draft_id IS NULL))
      OR (e.transaction_id IS NOT NULL AND
        (t.id IS NULL OR t.ledger_id!=e.ledger_id OR t.type!=e.direction))
      OR (e.draft_id IS NOT NULL AND d.id IS NULL)
      OR (e.account_id IS NOT NULL AND
        (a.id IS NULL OR a.ledger_id!=e.ledger_id))
      OR datetime(e.occurred_at) IS NULL OR datetime(e.created_at) IS NULL
      OR e.amount_minor<=0 LIMIT 1''',
    ).get();
    final badTransactionMerges = await target.customSelect(
      '''SELECT m.id FROM transaction_merges m
      JOIN transactions target_tx ON target_tx.id=m.target_transaction_id
      JOIN transactions source_tx ON source_tx.id=m.source_transaction_id
      WHERE target_tx.ledger_id!=m.ledger_id OR source_tx.ledger_id!=m.ledger_id
      OR target_tx.id=source_tx.id OR datetime(m.created_at) IS NULL
      OR (m.undone_at IS NOT NULL AND datetime(m.undone_at) IS NULL)
      LIMIT 1''',
    ).get();
    final badLearningEvents = await target.customSelect(
      '''SELECT e.id FROM learning_events e
      JOIN ledgers l ON l.id=e.ledger_id
      LEFT JOIN transactions t ON t.id=e.transaction_id
      LEFT JOIN transaction_drafts d ON d.id=e.draft_id
      WHERE (e.transaction_id IS NOT NULL AND
        (t.id IS NULL OR t.ledger_id!=e.ledger_id))
      OR (e.draft_id IS NOT NULL AND d.id IS NULL)
      OR (e.transaction_id IS NULL AND e.draft_id IS NULL AND e.outcome!='duplicate')
      OR datetime(e.created_at) IS NULL LIMIT 1''',
    ).get();
    if (bad.isNotEmpty ||
        badRefunds.isNotEmpty ||
        badCategories.isNotEmpty ||
        badFx.isNotEmpty ||
        badAssets.isNotEmpty ||
        badAssetTransactions.isNotEmpty ||
        badAssetValuations.isNotEmpty ||
        badAssetSchedules.isNotEmpty ||
        badCardStatements.isNotEmpty ||
        badCardStatementItems.isNotEmpty ||
        badGroups.isNotEmpty ||
        badSplits.isNotEmpty ||
        badBudgets.isNotEmpty ||
        badRecurringExecutions.isNotEmpty ||
        badTagDefinitions.isNotEmpty ||
        badAutoCorrections.isNotEmpty ||
        badFamilyCards.isNotEmpty ||
        badFamilyEvents.isNotEmpty ||
        badFamilyEvidence.isNotEmpty ||
        badTransactionEvidence.isNotEmpty ||
        badLearningEvents.isNotEmpty ||
        badTransactionMerges.isNotEmpty) {
      throw const LedgerException('备份中的交易或分类关系不一致');
    }
    for (final row
        in await target
            .customSelect(
              'SELECT merchant_pattern,normalized_pattern,tags_json FROM auto_correction_rules',
            )
            .get()) {
      if (normalizeMerchantPattern(row.read<String>('merchant_pattern')) !=
          row.read<String>('normalized_pattern')) {
        throw const LedgerException('备份中的自动修正规则无效');
      }
      decodeTags(row.read<String>('tags_json'));
    }
    for (final row
        in await target
            .customSelect('SELECT tags_json FROM transactions')
            .get()) {
      decodeTags(row.read<String>('tags_json'));
    }
    for (final row
        in await target
            .customSelect('SELECT occurred_date FROM transactions')
            .get()) {
      final value = row.read<String>('occurred_date');
      final date = DateTime.tryParse(value);
      if (date == null ||
          (dateKey(date) != value && dateTimeKey(date) != value)) {
        throw const LedgerException('备份中的日期无效');
      }
    }
  }
}

Future<SecretKey> _derive(String password, List<int> salt) => Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: 210000,
  bits: 256,
).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

Future<Uint8List> _encrypt(Map<String, String> input) async {
  final algorithm = AesGcm.with256bits();
  final salt = algorithm.newNonce() + algorithm.newNonce();
  final box = await algorithm.encrypt(
    utf8.encode(input['plaintext']!),
    secretKey: await _derive(input['password']!, salt),
  );
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'smart-ledger-encrypted',
        'version': 1,
        'salt': base64Encode(salt),
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
    ),
  );
}

Future<String> _decrypt(Map<String, Object> input) async {
  final envelope =
      jsonDecode(utf8.decode(input['bytes']! as Uint8List))
          as Map<String, dynamic>;
  if (envelope['format'] != 'smart-ledger-encrypted' ||
      envelope['version'] != 1) {
    throw const FormatException('Invalid backup envelope');
  }
  final salt = base64Decode(envelope['salt'] as String);
  final nonce = base64Decode(envelope['nonce'] as String);
  final mac = base64Decode(envelope['mac'] as String);
  if (salt.length != 24 || nonce.length != 12 || mac.length != 16) {
    throw const FormatException('Invalid cryptographic parameters');
  }
  final plaintext = await AesGcm.with256bits().decrypt(
    SecretBox(
      base64Decode(envelope['ciphertext'] as String),
      nonce: nonce,
      mac: Mac(mac),
    ),
    secretKey: await _derive(input['password']! as String, salt),
  );
  return utf8.decode(plaintext);
}
