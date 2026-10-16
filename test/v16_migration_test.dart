import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  test('v15 database adds reviewed learning and merchant knowledge', () async {
    final directory = await Directory.systemTemp.createTemp('ledger-v16-');
    final file = File('${directory.path}/data.sqlite');
    final legacy = sql.sqlite3.open(file.path);
    for (final statement in schemaStatements) {
      if (knowledgeSchemaStatements.contains(statement)) continue;
      legacy.execute(statement);
    }
    legacy.execute('ALTER TABLE auto_correction_rules RENAME TO rules_v16');
    legacy.execute(
      '''CREATE TABLE auto_correction_rules (
      id TEXT PRIMARY KEY, ledger_id TEXT NOT NULL REFERENCES ledgers(id),
      merchant_pattern TEXT NOT NULL, normalized_pattern TEXT NOT NULL,
      match_mode TEXT NOT NULL, type TEXT NOT NULL, account_id TEXT,
      category_id TEXT, source_key TEXT NOT NULL DEFAULT '',
      min_amount_minor INTEGER, max_amount_minor INTEGER,
      payment_method_pattern TEXT NOT NULL DEFAULT '', tags_json TEXT NOT NULL DEFAULT '[]',
      enabled INTEGER NOT NULL DEFAULT 1, learned INTEGER NOT NULL DEFAULT 0,
      priority INTEGER NOT NULL DEFAULT 0, use_count INTEGER NOT NULL DEFAULT 0,
      last_used_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
    );
    legacy.execute('DROP TABLE rules_v16');
    legacy.execute('PRAGMA user_version=15');
    legacy.dispose();

    final db = AppDatabase(NativeDatabase(file));
    try {
      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      expect(
        tables.map((row) => row.read<String>('name')),
        containsAll([
          'learning_field_changes',
          'learning_observations',
          'merchant_knowledge',
          'merchant_aliases',
          'auto_correction_suggestions',
        ]),
      );
      final columns = await db
          .customSelect('PRAGMA table_info(auto_correction_rules)')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        containsAll([
          'start_minute',
          'end_minute',
          'weekdays_mask',
          'source_account_id',
        ]),
      );
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
}
