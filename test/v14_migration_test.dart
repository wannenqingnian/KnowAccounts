import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  test(
    'v13 database adds unified evidence and reversible merge tables',
    () async {
      final directory = await Directory.systemTemp.createTemp('ledger-v14-');
      final file = File('${directory.path}/data.sqlite');
      final legacy = sql.sqlite3.open(file.path);
      for (final statement in schemaStatements) {
        if (statement.contains('transaction_evidence_records') ||
            statement.contains('transaction_merges') ||
            statement.contains('transaction_merge_')) {
          continue;
        }
        legacy.execute(statement);
      }
      legacy.execute('PRAGMA user_version=13');
      legacy.dispose();

      final db = AppDatabase(NativeDatabase(file));
      try {
        expect(db.schemaVersion, 16);
        final tables = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get();
        expect(
          tables.map((row) => row.read<String>('name')),
          containsAll([
            'transaction_evidence_records',
            'transaction_merges',
            'learning_events',
          ]),
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
