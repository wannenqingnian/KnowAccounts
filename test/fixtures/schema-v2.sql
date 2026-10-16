CREATE TABLE ledgers (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, currency TEXT NOT NULL DEFAULT 'CNY',
    created_at TEXT NOT NULL)
;
CREATE TABLE accounts (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    name TEXT NOT NULL, kind TEXT NOT NULL, currency TEXT NOT NULL DEFAULT 'CNY',
    opening_minor INTEGER NOT NULL DEFAULT 0, archived_at TEXT,
    created_at TEXT NOT NULL, provider_id TEXT,
    repayment_day INTEGER CHECK(repayment_day BETWEEN 1 AND 31), due_date TEXT,
    bank_id TEXT, card_last4 TEXT, card_secret_id TEXT,
    UNIQUE(ledger_id, name))
;
CREATE TABLE categories (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    parent_id TEXT REFERENCES categories(id), name TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('expense', 'income')),
    sort_order INTEGER NOT NULL DEFAULT 0, archived_at TEXT)
;
CREATE TABLE transactions (
    id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
    type TEXT NOT NULL CHECK(type IN ('expense','income','transfer','refund','adjustment')),
    amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
    currency TEXT NOT NULL DEFAULT 'CNY' CHECK(currency = 'CNY'),
    account_id TEXT NOT NULL REFERENCES accounts(id),
    target_account_id TEXT REFERENCES accounts(id),
    category_id TEXT REFERENCES categories(id), merchant TEXT NOT NULL DEFAULT '',
    note TEXT NOT NULL DEFAULT '', occurred_date TEXT NOT NULL,
    time_precision TEXT NOT NULL DEFAULT 'day',
    related_transaction_id TEXT REFERENCES transactions(id),
    reimbursable INTEGER NOT NULL DEFAULT 0 CHECK(reimbursable IN (0,1)),
    exclude_from_budget INTEGER NOT NULL DEFAULT 0,
    exclude_from_reports INTEGER NOT NULL DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1, device_id TEXT NOT NULL,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT,
    CHECK(type != 'transfer' OR
      (target_account_id IS NOT NULL AND target_account_id != account_id)),
    CHECK(type != 'refund' OR related_transaction_id IS NOT NULL))
;
CREATE TABLE transaction_postings (
    id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id),
    account_id TEXT NOT NULL REFERENCES accounts(id), delta_minor INTEGER NOT NULL,
    currency TEXT NOT NULL DEFAULT 'CNY', UNIQUE(transaction_id, account_id))
;
CREATE TABLE budgets (
    ledger_id TEXT NOT NULL REFERENCES ledgers(id), month TEXT NOT NULL,
    amount_minor INTEGER NOT NULL CHECK(amount_minor >= 0),
    PRIMARY KEY(ledger_id, month))
;
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)
;
CREATE INDEX transactions_ledger_date ON transactions(ledger_id, occurred_date, deleted_at)
;
CREATE INDEX postings_account ON transaction_postings(account_id)
;
CREATE INDEX transactions_related ON transactions(related_transaction_id);
