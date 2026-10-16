import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);

  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());

  static Future<AppDatabase> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return AppDatabase(
      NativeDatabase.createInBackground(
        File(p.join(directory.path, 'smart_ledger.sqlite')),
      ),
    );
  }

  @override
  int get schemaVersion => 16;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in schemaStatements) {
        await customStatement(sql);
      }
    },
    onUpgrade: (_, from, to) async {
      if (from < 1 || from >= to || to != schemaVersion) {
        throw StateError('No migration defined from $from to $to');
      }
      if (from == 1) {
        await customStatement(
          'ALTER TABLE accounts ADD COLUMN provider_id TEXT',
        );
        await customStatement(
          'ALTER TABLE accounts ADD COLUMN repayment_day INTEGER CHECK(repayment_day BETWEEN 1 AND 31)',
        );
        await customStatement('ALTER TABLE accounts ADD COLUMN due_date TEXT');
        await customStatement('ALTER TABLE accounts ADD COLUMN bank_id TEXT');
        await customStatement(
          'ALTER TABLE accounts ADD COLUMN card_last4 TEXT',
        );
        await customStatement(
          'ALTER TABLE accounts ADD COLUMN card_secret_id TEXT',
        );
      }
      if (from < 3) {
        for (final sql in draftSchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 4) {
        await customStatement(
          "ALTER TABLE transactions ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'",
        );
      }
      if (from < 5) {
        await customStatement(
          "ALTER TABLE transactions ADD COLUMN is_reimbursement INTEGER NOT NULL DEFAULT 0 CHECK(is_reimbursement IN (0,1))",
        );
        await customStatement(attachmentSchema);
        await customStatement(attachmentIndex);
      }
      for (final sql in planningSchemaStatements) {
        await customStatement(sql);
      }
      for (final sql in advancedSchemaStatements) {
        await customStatement(sql);
      }
      if (from < 8) {
        for (final sql in autoCorrectionSchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 9) {
        final rawColumns = (await customSelect(
          'PRAGMA table_info(raw_transactions)',
        ).get()).map((row) => row.read<String>('name')).toSet();
        if (!rawColumns.contains('source_app')) {
          await customStatement(
            "ALTER TABLE raw_transactions ADD COLUMN source_app TEXT NOT NULL DEFAULT ''",
          );
        }
        if (!rawColumns.contains('payment_method')) {
          await customStatement(
            "ALTER TABLE raw_transactions ADD COLUMN payment_method TEXT NOT NULL DEFAULT ''",
          );
        }
        if (from == 8) {
          await customStatement(
            'ALTER TABLE auto_correction_rules RENAME TO auto_correction_rules_v8',
          );
          await customStatement(
            'DROP INDEX IF EXISTS auto_correction_rules_lookup',
          );
          await customStatement(autoCorrectionSchemaStatements.first);
          await customStatement(
            '''INSERT INTO auto_correction_rules
            (id,ledger_id,merchant_pattern,normalized_pattern,match_mode,type,
             account_id,category_id,tags_json,enabled,learned,priority,use_count,
             last_used_at,created_at,updated_at)
            SELECT id,ledger_id,merchant_pattern,normalized_pattern,match_mode,type,
             account_id,category_id,tags_json,enabled,learned,priority,use_count,
             last_used_at,created_at,updated_at FROM auto_correction_rules_v8''',
          );
          await customStatement('DROP TABLE auto_correction_rules_v8');
          for (final sql in autoCorrectionSchemaStatements.skip(1)) {
            await customStatement(sql);
          }
        }
      }
      if (from < 10) {
        for (final sql in assetActivitySchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 11) {
        for (final sql in budgetSchemaStatements) {
          await customStatement(sql);
        }
        await customStatement('''INSERT OR IGNORE INTO budget_plans
          (id,ledger_id,name,category_id,amount_minor,period_kind,starts_on,
           custom_end_on,rollover_mode,alert_enabled,alert_bps,created_at,updated_at)
          SELECT 'legacy-'||ledger_id||'-'||month,ledger_id,month||' 月度预算',NULL,
           amount_minor,'custom',month||'-01',date(month||'-01','+1 month','-1 day'),
           'none',1,8000,month||'-01T00:00:00.000Z',month||'-01T00:00:00.000Z'
          FROM budgets WHERE amount_minor>0''');
      }
      if (from < 12) {
        final recurringColumns = (await customSelect(
          'PRAGMA table_info(recurring_rules)',
        ).get()).map((row) => row.read<String>('name')).toSet();
        for (final alteration in <String, String>{
          'end_at': 'ALTER TABLE recurring_rules ADD COLUMN end_at TEXT',
          'max_runs':
              'ALTER TABLE recurring_rules ADD COLUMN max_runs INTEGER CHECK(max_runs IS NULL OR max_runs>0)',
          'run_count':
              'ALTER TABLE recurring_rules ADD COLUMN run_count INTEGER NOT NULL DEFAULT 0 CHECK(run_count>=0)',
          'notify_enabled':
              'ALTER TABLE recurring_rules ADD COLUMN notify_enabled INTEGER NOT NULL DEFAULT 1 CHECK(notify_enabled IN (0,1))',
          'retry_count':
              'ALTER TABLE recurring_rules ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count>=0)',
          'last_error':
              "ALTER TABLE recurring_rules ADD COLUMN last_error TEXT NOT NULL DEFAULT ''",
        }.entries) {
          if (!recurringColumns.contains(alteration.key)) {
            await customStatement(alteration.value);
          }
        }
        final categoryColumns = (await customSelect(
          'PRAGMA table_info(categories)',
        ).get()).map((row) => row.read<String>('name')).toSet();
        if (!categoryColumns.contains('icon_key')) {
          await customStatement(
            "ALTER TABLE categories ADD COLUMN icon_key TEXT NOT NULL DEFAULT ''",
          );
        }
        for (final sql in organizationSchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 13) {
        for (final sql in familyPaymentSchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 14) {
        for (final sql in transactionIdentitySchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 15) {
        for (final sql in learningEventSchemaStatements) {
          await customStatement(sql);
        }
      }
      if (from < 16) {
        final ruleColumns = (await customSelect(
          'PRAGMA table_info(auto_correction_rules)',
        ).get()).map((row) => row.read<String>('name')).toSet();
        for (final alteration in <String, String>{
          'start_minute':
              'ALTER TABLE auto_correction_rules ADD COLUMN start_minute INTEGER CHECK(start_minute IS NULL OR start_minute BETWEEN 0 AND 1439)',
          'end_minute':
              'ALTER TABLE auto_correction_rules ADD COLUMN end_minute INTEGER CHECK(end_minute IS NULL OR end_minute BETWEEN 0 AND 1439)',
          'weekdays_mask':
              'ALTER TABLE auto_correction_rules ADD COLUMN weekdays_mask INTEGER NOT NULL DEFAULT 127 CHECK(weekdays_mask BETWEEN 1 AND 127)',
          'source_account_id':
              'ALTER TABLE auto_correction_rules ADD COLUMN source_account_id TEXT REFERENCES accounts(id)',
        }.entries) {
          if (!ruleColumns.contains(alteration.key)) {
            await customStatement(alteration.value);
          }
        }
        for (final sql in knowledgeSchemaStatements) {
          await customStatement(sql);
        }
      }
      await customStatement('''INSERT OR IGNORE INTO currencies
        (ledger_id,code,name,symbol,rate_to_cny_micros,decimals,updated_at)
        SELECT id,'CNY','人民币','¥',1000000,2,created_at FROM ledgers''');
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );
}

const draftSchemaStatements = [
  '''CREATE TABLE raw_transactions (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    source TEXT NOT NULL CHECK(source IN ('text','ocr','speech','notification','import')),
    raw_text TEXT NOT NULL CHECK(length(raw_text) BETWEEN 1 AND 4000),
    captured_at TEXT NOT NULL, source_app TEXT NOT NULL DEFAULT '',
    payment_method TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE transaction_drafts (
    id TEXT PRIMARY KEY, raw_id TEXT NOT NULL UNIQUE REFERENCES raw_transactions(id),
    status TEXT NOT NULL CHECK(status IN ('pending','posted','ignored')),
    parser_version INTEGER NOT NULL CHECK(parser_version = 1),
    parsed_json TEXT NOT NULL, transaction_id TEXT UNIQUE REFERENCES transactions(id),
    updated_at TEXT NOT NULL,
    CHECK((status = 'posted' AND transaction_id IS NOT NULL) OR
      (status != 'posted' AND transaction_id IS NULL)))''',
  'CREATE INDEX raw_transactions_ledger ON raw_transactions(ledger_id)',
];

const familyPaymentSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS family_cards (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    platform TEXT NOT NULL CHECK(platform IN ('wechat','alipay')),
    display_name TEXT NOT NULL, local_role TEXT NOT NULL
      CHECK(local_role IN ('payer','beneficiary')),
    payer_label TEXT NOT NULL DEFAULT '', beneficiary_label TEXT NOT NULL DEFAULT '',
    sender_limit_minor INTEGER NOT NULL DEFAULT 0 CHECK(sender_limit_minor>=0),
    user_limit_minor INTEGER NOT NULL DEFAULT 0 CHECK(user_limit_minor>=0),
    default_funding_account_id TEXT REFERENCES accounts(id),
    default_category_id TEXT REFERENCES categories(id),
    auto_save_enabled INTEGER NOT NULL DEFAULT 0 CHECK(auto_save_enabled IN (0,1)),
    archived_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK(local_role != 'beneficiary' OR default_funding_account_id IS NULL),
    UNIQUE(ledger_id,display_name))''',
  'CREATE INDEX IF NOT EXISTS family_cards_ledger ON family_cards(ledger_id,platform,archived_at)',
  '''CREATE TABLE IF NOT EXISTS family_payment_events (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    card_id TEXT REFERENCES family_cards(id),
    platform TEXT NOT NULL CHECK(platform IN ('wechat','alipay')),
    external_order_hash TEXT, amount_minor INTEGER NOT NULL CHECK(amount_minor>0),
    refunded_minor INTEGER NOT NULL DEFAULT 0 CHECK(refunded_minor>=0 AND refunded_minor<=amount_minor),
    merchant TEXT NOT NULL DEFAULT '', occurred_at TEXT,
    local_role TEXT CHECK(local_role IN ('payer','beneficiary')),
    funding_account_id TEXT REFERENCES accounts(id),
    funding_state TEXT NOT NULL DEFAULT 'unknown'
      CHECK(funding_state IN ('unknown','inferred','confirmed')),
    status TEXT NOT NULL DEFAULT 'needsReview'
      CHECK(status IN ('observed','needsReview','confirmed','refunded','voided')),
    transaction_id TEXT UNIQUE REFERENCES transactions(id),
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK(local_role != 'beneficiary' OR (funding_account_id IS NULL AND transaction_id IS NULL)),
    CHECK(status != 'confirmed' OR (local_role IS NOT NULL AND funding_state = 'confirmed'
      AND (local_role != 'payer' OR (funding_account_id IS NOT NULL AND transaction_id IS NOT NULL)))),
    UNIQUE(ledger_id,platform,external_order_hash))''',
  'CREATE INDEX IF NOT EXISTS family_events_ledger_time ON family_payment_events(ledger_id,occurred_at)',
  '''CREATE TABLE IF NOT EXISTS family_payment_evidence (
    id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES family_payment_events(id) ON DELETE CASCADE,
    capture_id TEXT NOT NULL UNIQUE,
    source_kind TEXT NOT NULL CHECK(source_kind IN ('notification','accessibility','ocr','bankNotice')),
    source_package TEXT NOT NULL DEFAULT '', amount_minor INTEGER,
    merchant_hint TEXT NOT NULL DEFAULT '', confidence INTEGER NOT NULL DEFAULT 0
      CHECK(confidence BETWEEN 0 AND 100), observed_at TEXT NOT NULL,
    redacted_excerpt TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX IF NOT EXISTS family_evidence_event ON family_payment_evidence(event_id,observed_at)',
];

const transactionIdentitySchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS transaction_evidence_records (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    transaction_id TEXT REFERENCES transactions(id),
    draft_id TEXT REFERENCES transaction_drafts(id),
    source_kind TEXT NOT NULL CHECK(source_kind IN
      ('notification','accessibility','ocr','speech','import','manual')),
    source_app TEXT NOT NULL DEFAULT '', capture_id TEXT,
    order_hash TEXT, semantic_fingerprint TEXT NOT NULL DEFAULT '',
    amount_minor INTEGER NOT NULL CHECK(amount_minor>0),
    normalized_merchant TEXT NOT NULL DEFAULT '', occurred_at TEXT NOT NULL,
    account_id TEXT REFERENCES accounts(id),
    direction TEXT NOT NULL CHECK(direction IN ('expense','income','refund')),
    details_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL,
    CHECK((transaction_id IS NULL) != (draft_id IS NULL)),
    UNIQUE(ledger_id,source_kind,capture_id))''',
  '''CREATE INDEX IF NOT EXISTS transaction_evidence_order
    ON transaction_evidence_records(ledger_id,order_hash,direction)''',
  '''CREATE INDEX IF NOT EXISTS transaction_evidence_candidate
    ON transaction_evidence_records
    (ledger_id,amount_minor,normalized_merchant,account_id,direction,occurred_at)''',
  '''CREATE INDEX IF NOT EXISTS transaction_evidence_fingerprint
    ON transaction_evidence_records(ledger_id,semantic_fingerprint)''',
  '''CREATE TABLE IF NOT EXISTS transaction_merges (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    target_transaction_id TEXT NOT NULL REFERENCES transactions(id),
    source_transaction_id TEXT NOT NULL REFERENCES transactions(id),
    evidence_ids_json TEXT NOT NULL DEFAULT '[]', source_deleted_at_before TEXT,
    created_at TEXT NOT NULL, undone_at TEXT,
    CHECK(target_transaction_id != source_transaction_id))''',
  '''CREATE UNIQUE INDEX IF NOT EXISTS transaction_merge_active_source
    ON transaction_merges(source_transaction_id) WHERE undone_at IS NULL''',
  '''CREATE INDEX IF NOT EXISTS transaction_merge_target
    ON transaction_merges(target_transaction_id,undone_at)''',
];

/// Privacy-preserving audit trail for the common transaction pipeline. Raw
/// payment text is deliberately kept in [raw_transactions], while this table
/// stores only source metadata, fingerprints, confidence and processing facts.
const learningEventSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS learning_events (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    transaction_id TEXT REFERENCES transactions(id),
    draft_id TEXT REFERENCES transaction_drafts(id),
    source_kind TEXT NOT NULL CHECK(source_kind IN
      ('notification','accessibility','ocr','speech','import','manual')),
    source_app TEXT NOT NULL DEFAULT '',
    outcome TEXT NOT NULL CHECK(outcome IN
      ('draft','posted','updated','duplicate','ignored')),
    fingerprint TEXT NOT NULL DEFAULT '',
    confidence_json TEXT NOT NULL DEFAULT '', details_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    CHECK(transaction_id IS NOT NULL OR draft_id IS NOT NULL OR outcome='duplicate'))''',
  '''CREATE INDEX IF NOT EXISTS learning_events_ledger_time
    ON learning_events(ledger_id,created_at DESC)''',
  '''CREATE INDEX IF NOT EXISTS learning_events_transaction
    ON learning_events(transaction_id,created_at DESC)''',
];

/// User-reviewed local knowledge. A suggestion cannot affect later bills until
/// it is accepted. Field changes deliberately store mapped values, not raw
/// payment-page text.
const knowledgeSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS learning_field_changes (
    id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES learning_events(id) ON DELETE CASCADE,
    field_name TEXT NOT NULL CHECK(field_name IN ('merchant','category','account','tags','ledger')),
    recognized_value TEXT NOT NULL DEFAULT '', final_value TEXT NOT NULL DEFAULT '',
    changed INTEGER NOT NULL CHECK(changed IN (0,1)), created_at TEXT NOT NULL)''',
  '''CREATE INDEX IF NOT EXISTS learning_field_changes_event
    ON learning_field_changes(event_id,field_name)''',
  '''CREATE TABLE IF NOT EXISTS merchant_knowledge (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    canonical_name TEXT NOT NULL, normalized_name TEXT NOT NULL,
    default_category_id TEXT REFERENCES categories(id), source_key TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    UNIQUE(ledger_id,normalized_name,source_key))''',
  '''CREATE TABLE IF NOT EXISTS merchant_aliases (
    id TEXT PRIMARY KEY, merchant_id TEXT NOT NULL REFERENCES merchant_knowledge(id) ON DELETE CASCADE,
    alias TEXT NOT NULL, normalized_alias TEXT NOT NULL, source_key TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL, UNIQUE(merchant_id,normalized_alias,source_key))''',
  '''CREATE INDEX IF NOT EXISTS merchant_aliases_lookup
    ON merchant_aliases(normalized_alias,source_key)''',
  '''CREATE TABLE IF NOT EXISTS auto_correction_suggestions (
    id TEXT PRIMARY KEY, learning_event_id TEXT REFERENCES learning_events(id),
    ledger_id TEXT NOT NULL REFERENCES ledgers(id), merchant_pattern TEXT NOT NULL,
    normalized_pattern TEXT NOT NULL, type TEXT NOT NULL CHECK(type IN ('expense','income')),
    account_id TEXT REFERENCES accounts(id), category_id TEXT REFERENCES categories(id),
    tags_json TEXT NOT NULL DEFAULT '[]', source_key TEXT NOT NULL DEFAULT '',
    payment_method_pattern TEXT NOT NULL DEFAULT '', min_amount_minor INTEGER,
    max_amount_minor INTEGER, start_minute INTEGER, end_minute INTEGER,
    weekdays_mask INTEGER NOT NULL DEFAULT 127, source_account_id TEXT REFERENCES accounts(id),
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','rejected')),
    reason TEXT NOT NULL DEFAULT '', accepted_rule_id TEXT REFERENCES auto_correction_rules(id),
    sample_count INTEGER NOT NULL DEFAULT 0, consistency_bps INTEGER NOT NULL DEFAULT 0,
    conflict_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL, decided_at TEXT,
    UNIQUE(ledger_id,normalized_pattern,type,source_key,status))''',
  '''CREATE INDEX IF NOT EXISTS auto_correction_suggestions_state
    ON auto_correction_suggestions(status,created_at DESC)''',
  '''CREATE TABLE IF NOT EXISTS learning_observations (
    id TEXT PRIMARY KEY, learning_event_id TEXT REFERENCES learning_events(id) ON DELETE CASCADE,
    normalized_merchant TEXT NOT NULL, merchant TEXT NOT NULL, type TEXT NOT NULL,
    source_key TEXT NOT NULL DEFAULT '', payment_method TEXT NOT NULL DEFAULT '',
    source_account_id TEXT, final_account_id TEXT, final_category_id TEXT,
    final_tags_json TEXT NOT NULL DEFAULT '[]', source_ledger_id TEXT NOT NULL,
    final_ledger_id TEXT NOT NULL, minute_of_day INTEGER NOT NULL,
    weekday INTEGER NOT NULL, explicit_remember INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL)''',
  '''CREATE INDEX IF NOT EXISTS learning_observations_cluster
    ON learning_observations(normalized_merchant,type,source_key,created_at DESC)''',
];

const attachmentSchema = '''CREATE TABLE attachments (
  id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id),
  name TEXT NOT NULL, image_base64 TEXT NOT NULL, created_at TEXT NOT NULL)''';

const attachmentIndex =
    'CREATE INDEX attachments_transaction ON attachments(transaction_id)';

const planningSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS transaction_templates (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL, type TEXT NOT NULL CHECK(type IN ('expense','income','transfer')),
    amount_minor INTEGER NOT NULL DEFAULT 0 CHECK(amount_minor >= 0),
    account_id TEXT REFERENCES accounts(id), target_account_id TEXT REFERENCES accounts(id),
    category_id TEXT REFERENCES categories(id), merchant TEXT NOT NULL DEFAULT '',
    note TEXT NOT NULL DEFAULT '', tags_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    UNIQUE(ledger_id, name))''',
  '''CREATE TABLE IF NOT EXISTS recurring_rules (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('incomeExpense','transfer','investment')),
    type TEXT NOT NULL CHECK(type IN ('expense','income','transfer')),
    amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
    account_id TEXT NOT NULL REFERENCES accounts(id), target_account_id TEXT REFERENCES accounts(id),
    category_id TEXT REFERENCES categories(id), merchant TEXT NOT NULL DEFAULT '',
    note TEXT NOT NULL DEFAULT '', tags_json TEXT NOT NULL DEFAULT '[]',
    frequency TEXT NOT NULL CHECK(frequency IN ('daily','weekly','monthly','yearly')),
    interval_count INTEGER NOT NULL DEFAULT 1 CHECK(interval_count BETWEEN 1 AND 999),
    next_at TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    last_run_at TEXT, end_at TEXT, max_runs INTEGER CHECK(max_runs IS NULL OR max_runs>0),
    run_count INTEGER NOT NULL DEFAULT 0 CHECK(run_count>=0),
    notify_enabled INTEGER NOT NULL DEFAULT 1 CHECK(notify_enabled IN (0,1)),
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count>=0),
    last_error TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK(type != 'transfer' OR (target_account_id IS NOT NULL AND target_account_id != account_id)),
    UNIQUE(ledger_id, name))''',
  'CREATE INDEX IF NOT EXISTS transaction_templates_ledger ON transaction_templates(ledger_id, created_at)',
  'CREATE INDEX IF NOT EXISTS recurring_rules_due ON recurring_rules(ledger_id, enabled, next_at)',
];

const organizationSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS recurring_executions (
    id TEXT PRIMARY KEY, rule_id TEXT NOT NULL REFERENCES recurring_rules(id) ON DELETE CASCADE,
    ledger_id TEXT NOT NULL REFERENCES ledgers(id), scheduled_at TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('success','skipped','failed')),
    transaction_id TEXT REFERENCES transactions(id), error_message TEXT NOT NULL DEFAULT '',
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count>=0),
    created_at TEXT NOT NULL, finished_at TEXT NOT NULL,
    UNIQUE(rule_id,scheduled_at))''',
  'CREATE INDEX IF NOT EXISTS recurring_executions_rule_time ON recurring_executions(rule_id,scheduled_at DESC)',
  '''CREATE TABLE IF NOT EXISTS tag_definitions (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 20),
    normalized_name TEXT NOT NULL, hidden_at TEXT, smart_pattern TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    UNIQUE(ledger_id,normalized_name))''',
  'CREATE INDEX IF NOT EXISTS tag_definitions_ledger ON tag_definitions(ledger_id,hidden_at,name)',
];

const advancedSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS currencies (
    ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    code TEXT NOT NULL CHECK(length(code)=3), name TEXT NOT NULL,
    symbol TEXT NOT NULL, rate_to_cny_micros INTEGER NOT NULL CHECK(rate_to_cny_micros>0),
    decimals INTEGER NOT NULL DEFAULT 2 CHECK(decimals BETWEEN 0 AND 4),
    updated_at TEXT NOT NULL, PRIMARY KEY(ledger_id,code))''',
  '''CREATE TABLE IF NOT EXISTS transaction_fx (
    transaction_id TEXT PRIMARY KEY REFERENCES transactions(id),
    source_currency TEXT NOT NULL CHECK(length(source_currency)=3),
    source_amount_minor INTEGER NOT NULL CHECK(source_amount_minor>0),
    source_rate_micros INTEGER NOT NULL CHECK(source_rate_micros>0),
    target_currency TEXT CHECK(target_currency IS NULL OR length(target_currency)=3),
    target_amount_minor INTEGER CHECK(target_amount_minor IS NULL OR target_amount_minor>0),
    target_rate_micros INTEGER CHECK(target_rate_micros IS NULL OR target_rate_micros>0),
    CHECK((target_currency IS NULL AND target_amount_minor IS NULL AND target_rate_micros IS NULL) OR
      (target_currency IS NOT NULL AND target_amount_minor IS NOT NULL AND target_rate_micros IS NOT NULL)))''',
  '''CREATE TABLE IF NOT EXISTS financial_assets (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    kind TEXT NOT NULL CHECK(kind IN ('stock','fund','fixedDeposit','mortgage','installment','lent','creditCard')),
    name TEXT NOT NULL, account_id TEXT REFERENCES accounts(id),
    currency TEXT NOT NULL CHECK(length(currency)=3),
    principal_minor INTEGER NOT NULL DEFAULT 0 CHECK(principal_minor>=0),
    current_minor INTEGER NOT NULL DEFAULT 0 CHECK(current_minor>=0),
    quantity_micros INTEGER NOT NULL DEFAULT 0 CHECK(quantity_micros>=0),
    interest_bps INTEGER NOT NULL DEFAULT 0 CHECK(interest_bps BETWEEN 0 AND 100000),
    start_date TEXT, maturity_date TEXT,
    total_periods INTEGER NOT NULL DEFAULT 0 CHECK(total_periods>=0),
    completed_periods INTEGER NOT NULL DEFAULT 0 CHECK(completed_periods>=0 AND completed_periods<=total_periods),
    billing_day INTEGER CHECK(billing_day BETWEEN 1 AND 31),
    repayment_day INTEGER CHECK(repayment_day BETWEEN 1 AND 31),
    counterparty TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
    archived_at TEXT, updated_at TEXT NOT NULL,
    UNIQUE(ledger_id,kind,name))''',
  '''CREATE TABLE IF NOT EXISTS transaction_groups (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
    UNIQUE(ledger_id,name))''',
  '''CREATE TABLE IF NOT EXISTS transaction_group_items (
    group_id TEXT NOT NULL REFERENCES transaction_groups(id),
    transaction_id TEXT NOT NULL UNIQUE REFERENCES transactions(id),
    PRIMARY KEY(group_id,transaction_id))''',
  '''CREATE TABLE IF NOT EXISTS transaction_splits (
    id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id),
    participant TEXT NOT NULL, amount_minor INTEGER NOT NULL CHECK(amount_minor>0),
    settled INTEGER NOT NULL DEFAULT 0 CHECK(settled IN (0,1)),
    note TEXT NOT NULL DEFAULT '')''',
  'CREATE INDEX IF NOT EXISTS financial_assets_ledger ON financial_assets(ledger_id,kind,archived_at)',
  'CREATE INDEX IF NOT EXISTS transaction_groups_ledger ON transaction_groups(ledger_id,created_at)',
  'CREATE INDEX IF NOT EXISTS transaction_splits_transaction ON transaction_splits(transaction_id)',
];

/// Detailed, auditable activity behind the summary values in
/// [financial_assets]. Existing summary-only assets remain valid; their
/// current values act as an opening balance until the first activity is added.
const assetActivitySchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS asset_transactions (
    id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES financial_assets(id),
    kind TEXT NOT NULL CHECK(kind IN ('buy','sell','dividend','interest','deposit','withdraw','lend','collect','repayment','fee','adjustment')),
    occurred_at TEXT NOT NULL,
    amount_minor INTEGER NOT NULL DEFAULT 0 CHECK(amount_minor>=0),
    quantity_micros INTEGER NOT NULL DEFAULT 0 CHECK(quantity_micros>=0),
    unit_price_micros INTEGER NOT NULL DEFAULT 0 CHECK(unit_price_micros>=0),
    cost_basis_minor INTEGER NOT NULL DEFAULT 0 CHECK(cost_basis_minor>=0),
    principal_minor INTEGER NOT NULL DEFAULT 0 CHECK(principal_minor>=0),
    interest_minor INTEGER NOT NULL DEFAULT 0 CHECK(interest_minor>=0),
    fee_minor INTEGER NOT NULL DEFAULT 0 CHECK(fee_minor>=0),
    account_id TEXT REFERENCES accounts(id), transaction_id TEXT REFERENCES transactions(id),
    note TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
    CHECK(amount_minor>0 OR quantity_micros>0 OR principal_minor>0 OR interest_minor>0 OR fee_minor>0))''',
  '''CREATE TABLE IF NOT EXISTS asset_valuations (
    id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES financial_assets(id),
    valued_at TEXT NOT NULL, unit_value_micros INTEGER NOT NULL DEFAULT 0 CHECK(unit_value_micros>=0),
    total_value_minor INTEGER NOT NULL CHECK(total_value_minor>=0),
    source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','import','calculated')),
    note TEXT NOT NULL DEFAULT '', UNIQUE(asset_id,valued_at))''',
  '''CREATE TABLE IF NOT EXISTS asset_schedule_items (
    id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES financial_assets(id),
    period_no INTEGER NOT NULL CHECK(period_no>0), due_at TEXT NOT NULL,
    principal_minor INTEGER NOT NULL DEFAULT 0 CHECK(principal_minor>=0),
    interest_minor INTEGER NOT NULL DEFAULT 0 CHECK(interest_minor>=0),
    fee_minor INTEGER NOT NULL DEFAULT 0 CHECK(fee_minor>=0),
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','paid','overdue','waived')),
    paid_at TEXT, transaction_id TEXT REFERENCES transactions(id), note TEXT NOT NULL DEFAULT '',
    UNIQUE(asset_id,period_no))''',
  '''CREATE TABLE IF NOT EXISTS credit_card_statements (
    id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES financial_assets(id),
    period_start TEXT NOT NULL, period_end TEXT NOT NULL, due_at TEXT NOT NULL,
    statement_minor INTEGER NOT NULL CHECK(statement_minor>=0),
    ledger_minor INTEGER NOT NULL DEFAULT 0 CHECK(ledger_minor>=0),
    paid_minor INTEGER NOT NULL DEFAULT 0 CHECK(paid_minor>=0),
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','reconciled','paid')),
    note TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK(period_start<=period_end), UNIQUE(asset_id,period_end))''',
  '''CREATE TABLE IF NOT EXISTS credit_card_statement_items (
    statement_id TEXT NOT NULL REFERENCES credit_card_statements(id),
    transaction_id TEXT NOT NULL REFERENCES transactions(id),
    checked INTEGER NOT NULL DEFAULT 0 CHECK(checked IN (0,1)),
    PRIMARY KEY(statement_id,transaction_id))''',
  'CREATE INDEX IF NOT EXISTS asset_transactions_asset_date ON asset_transactions(asset_id,occurred_at)',
  'CREATE INDEX IF NOT EXISTS asset_valuations_asset_date ON asset_valuations(asset_id,valued_at)',
  'CREATE INDEX IF NOT EXISTS asset_schedule_asset_due ON asset_schedule_items(asset_id,status,due_at)',
  'CREATE INDEX IF NOT EXISTS credit_card_statements_asset_period ON credit_card_statements(asset_id,period_end)',
];

const budgetSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS budget_plans (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 60),
    category_id TEXT REFERENCES categories(id),
    amount_minor INTEGER NOT NULL CHECK(amount_minor>0),
    period_kind TEXT NOT NULL CHECK(period_kind IN ('monthly','quarterly','yearly','custom')),
    starts_on TEXT NOT NULL, custom_end_on TEXT,
    rollover_mode TEXT NOT NULL DEFAULT 'none' CHECK(rollover_mode IN ('none','positive','all')),
    alert_enabled INTEGER NOT NULL DEFAULT 1 CHECK(alert_enabled IN (0,1)),
    alert_bps INTEGER NOT NULL DEFAULT 8000 CHECK(alert_bps BETWEEN 1 AND 10000),
    hidden_at TEXT, archived_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK((period_kind='custom' AND custom_end_on IS NOT NULL AND custom_end_on>=starts_on)
      OR (period_kind!='custom' AND custom_end_on IS NULL)),
    UNIQUE(ledger_id,name))''',
  'CREATE INDEX IF NOT EXISTS budget_plans_ledger_state ON budget_plans(ledger_id,archived_at,hidden_at)',
  'CREATE INDEX IF NOT EXISTS budget_plans_category ON budget_plans(category_id)',
];

const autoCorrectionSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS auto_correction_rules (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    merchant_pattern TEXT NOT NULL CHECK(length(merchant_pattern) BETWEEN 1 AND 100),
    normalized_pattern TEXT NOT NULL CHECK(length(normalized_pattern) BETWEEN 1 AND 100),
    match_mode TEXT NOT NULL CHECK(match_mode IN ('exact','contains')),
    type TEXT NOT NULL CHECK(type IN ('expense','income')),
    account_id TEXT REFERENCES accounts(id), category_id TEXT REFERENCES categories(id),
    source_key TEXT NOT NULL DEFAULT '',
    min_amount_minor INTEGER CHECK(min_amount_minor IS NULL OR min_amount_minor>=0),
    max_amount_minor INTEGER CHECK(max_amount_minor IS NULL OR max_amount_minor>=0),
    payment_method_pattern TEXT NOT NULL DEFAULT '',
    start_minute INTEGER CHECK(start_minute IS NULL OR start_minute BETWEEN 0 AND 1439),
    end_minute INTEGER CHECK(end_minute IS NULL OR end_minute BETWEEN 0 AND 1439),
    weekdays_mask INTEGER NOT NULL DEFAULT 127 CHECK(weekdays_mask BETWEEN 1 AND 127),
    source_account_id TEXT REFERENCES accounts(id),
    tags_json TEXT NOT NULL DEFAULT '[]',
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    learned INTEGER NOT NULL DEFAULT 0 CHECK(learned IN (0,1)),
    priority INTEGER NOT NULL DEFAULT 0 CHECK(priority BETWEEN -1000 AND 1000),
    use_count INTEGER NOT NULL DEFAULT 0 CHECK(use_count>=0),
    last_used_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK(min_amount_minor IS NULL OR max_amount_minor IS NULL OR min_amount_minor<=max_amount_minor))''',
  'CREATE INDEX IF NOT EXISTS auto_correction_rules_lookup ON auto_correction_rules(type,enabled,priority)',
  '''CREATE TABLE IF NOT EXISTS auto_correction_events (
    id TEXT PRIMARY KEY, rule_id TEXT, event_type TEXT NOT NULL
      CHECK(event_type IN ('match','learn_created','learn_updated','batch','undo')),
    transaction_id TEXT, merchant TEXT NOT NULL DEFAULT '', amount_minor INTEGER,
    source_ledger_id TEXT NOT NULL DEFAULT '', target_ledger_id TEXT NOT NULL DEFAULT '',
    source_key TEXT NOT NULL DEFAULT '', payment_method TEXT NOT NULL DEFAULT '',
    before_json TEXT NOT NULL DEFAULT '', after_json TEXT NOT NULL DEFAULT '',
    fingerprint TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, undone_at TEXT)''',
  'CREATE INDEX IF NOT EXISTS auto_correction_events_rule_time ON auto_correction_events(rule_id,created_at DESC)',
];

const schemaStatements = [
  '''CREATE TABLE ledgers (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, currency TEXT NOT NULL DEFAULT 'CNY',
    created_at TEXT NOT NULL)''',
  '''CREATE TABLE accounts (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL, kind TEXT NOT NULL, currency TEXT NOT NULL DEFAULT 'CNY',
    opening_minor INTEGER NOT NULL DEFAULT 0, archived_at TEXT,
    created_at TEXT NOT NULL, provider_id TEXT,
    repayment_day INTEGER CHECK(repayment_day BETWEEN 1 AND 31), due_date TEXT,
    bank_id TEXT, card_last4 TEXT, card_secret_id TEXT,
    UNIQUE(ledger_id, name))''',
  '''CREATE TABLE categories (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    parent_id TEXT REFERENCES categories(id), name TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('expense', 'income')),
    sort_order INTEGER NOT NULL DEFAULT 0, archived_at TEXT,
    icon_key TEXT NOT NULL DEFAULT '')''',
  '''CREATE TABLE transactions (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    type TEXT NOT NULL CHECK(type IN ('expense','income','transfer','refund','adjustment')),
    amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
    currency TEXT NOT NULL DEFAULT 'CNY' CHECK(currency = 'CNY'),
    account_id TEXT NOT NULL REFERENCES accounts(id),
    target_account_id TEXT REFERENCES accounts(id),
    category_id TEXT REFERENCES categories(id), merchant TEXT NOT NULL DEFAULT '',
    note TEXT NOT NULL DEFAULT '', tags_json TEXT NOT NULL DEFAULT '[]', occurred_date TEXT NOT NULL,
    time_precision TEXT NOT NULL DEFAULT 'day',
    related_transaction_id TEXT REFERENCES transactions(id),
    reimbursable INTEGER NOT NULL DEFAULT 0 CHECK(reimbursable IN (0,1)),
    is_reimbursement INTEGER NOT NULL DEFAULT 0 CHECK(is_reimbursement IN (0,1)),
    exclude_from_budget INTEGER NOT NULL DEFAULT 0,
    exclude_from_reports INTEGER NOT NULL DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1, device_id TEXT NOT NULL,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT,
    CHECK(type != 'transfer' OR
      (target_account_id IS NOT NULL AND target_account_id != account_id)),
    CHECK(type != 'refund' OR related_transaction_id IS NOT NULL))''',
  '''CREATE TABLE transaction_postings (
    id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id),
    account_id TEXT NOT NULL REFERENCES accounts(id), delta_minor INTEGER NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY', UNIQUE(transaction_id, account_id))''',
  '''CREATE TABLE budgets (
    ledger_id TEXT NOT NULL REFERENCES ledgers(id), month TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK(amount_minor >= 0),
    PRIMARY KEY(ledger_id, month))''',
  '''CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)''',
  ...draftSchemaStatements,
  attachmentSchema,
  attachmentIndex,
  ...planningSchemaStatements,
  ...advancedSchemaStatements,
  ...assetActivitySchemaStatements,
  ...budgetSchemaStatements,
  ...organizationSchemaStatements,
  ...autoCorrectionSchemaStatements,
  ...familyPaymentSchemaStatements,
  ...transactionIdentitySchemaStatements,
  ...learningEventSchemaStatements,
  ...knowledgeSchemaStatements,
  '''CREATE INDEX transactions_ledger_date ON transactions(ledger_id, occurred_date, deleted_at)''',
  '''CREATE INDEX postings_account ON transaction_postings(account_id)''',
  '''CREATE INDEX transactions_related ON transactions(related_transaction_id)''',
];
