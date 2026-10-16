import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/database/app_database.dart';
import '../domain/models.dart';
import '../domain/tags.dart';
import 'ledger_repository.dart';

class TagRepository {
  TagRepository(this.db);

  final AppDatabase db;
  static const _uuid = Uuid();

  Future<List<QueryRow>> _query(String sql, [List<Object> args = const []]) =>
      db
          .customSelect(
            sql,
            variables: args
                .map<Variable>(
                  (value) => value is int
                      ? Variable<int>(value)
                      : Variable<String>(value as String),
                )
                .toList(),
          )
          .get();

  String _key(String name) => name.trim().toLowerCase();

  Future<void> synchronize(String ledger) async {
    final names = <String>{};
    for (final table in const [
      'transactions',
      'transaction_templates',
      'recurring_rules',
      'auto_correction_rules',
    ]) {
      for (final row in await _query(
        'SELECT tags_json FROM $table WHERE ledger_id=?',
        [ledger],
      )) {
        names.addAll(decodeTags(row.read<String>('tags_json')));
      }
    }
    final now = DateTime.now().toUtc().toIso8601String();
    for (final name in names) {
      await db.customStatement(
        '''INSERT OR IGNORE INTO tag_definitions
        (id,ledger_id,name,normalized_name,hidden_at,smart_pattern,created_at,updated_at)
        VALUES (?,?,?,?,NULL,'',?,?)''',
        [_uuid.v4(), ledger, name, _key(name), now, now],
      );
    }
  }

  Future<List<TagDefinition>> definitions(
    String ledger, {
    bool includeHidden = false,
  }) async {
    await synchronize(ledger);
    final usage = <String, int>{};
    for (final row in await _query(
      'SELECT tags_json FROM transactions WHERE ledger_id=? AND deleted_at IS NULL',
      [ledger],
    )) {
      for (final tag in decodeTags(row.read<String>('tags_json'))) {
        usage.update(_key(tag), (value) => value + 1, ifAbsent: () => 1);
      }
    }
    return (await _query(
          '''SELECT * FROM tag_definitions WHERE ledger_id=?
      ${includeHidden ? '' : 'AND hidden_at IS NULL'}
      ORDER BY hidden_at IS NOT NULL,name''',
          [ledger],
        ))
        .map(
          (row) => TagDefinition(
            id: row.read('id'),
            name: row.read('name'),
            hidden: row.readNullable<String>('hidden_at') != null,
            smartPattern: row.read('smart_pattern'),
            usageCount: usage[row.read<String>('normalized_name')] ?? 0,
          ),
        )
        .toList();
  }

  Future<String> save(
    String ledger, {
    String? id,
    required String name,
    String smartPattern = '',
  }) async {
    final tag = normalizeTags([name]).single;
    final pattern = smartPattern.trim();
    if (pattern.length > 100) throw const LedgerException('智能标签匹配词最多100字');
    final now = DateTime.now().toUtc().toIso8601String();
    if (id == null) {
      final next = _uuid.v4();
      try {
        await db.customStatement(
          '''INSERT INTO tag_definitions
          (id,ledger_id,name,normalized_name,hidden_at,smart_pattern,created_at,updated_at)
          VALUES (?,?,?,?,NULL,?,?,?)''',
          [next, ledger, tag, _key(tag), pattern, now, now],
        );
      } catch (_) {
        throw const LedgerException('标签名称已存在');
      }
      return next;
    }
    final rows = await _query(
      'SELECT name FROM tag_definitions WHERE id=? AND ledger_id=?',
      [id, ledger],
    );
    if (rows.isEmpty) throw const LedgerException('标签不存在');
    final old = rows.single.read<String>('name');
    await db.transaction(() async {
      if (_key(old) != _key(tag)) await _replaceEverywhere(ledger, old, tag);
      try {
        await db.customStatement(
          '''UPDATE tag_definitions SET name=?,normalized_name=?,smart_pattern=?,updated_at=?
          WHERE id=? AND ledger_id=?''',
          [tag, _key(tag), pattern, now, id, ledger],
        );
      } catch (_) {
        throw const LedgerException('标签名称已存在，可使用合并功能');
      }
    });
    return id;
  }

  Future<void> merge(String ledger, String sourceId, String targetId) async {
    if (sourceId == targetId) throw const LedgerException('请选择不同标签');
    final rows = await _query(
      'SELECT id,name FROM tag_definitions WHERE ledger_id=? AND id IN (?,?)',
      [ledger, sourceId, targetId],
    );
    if (rows.length != 2) throw const LedgerException('标签不存在');
    final source = rows.firstWhere((row) => row.read<String>('id') == sourceId);
    final target = rows.firstWhere((row) => row.read<String>('id') == targetId);
    await db.transaction(() async {
      await _replaceEverywhere(
        ledger,
        source.read<String>('name'),
        target.read<String>('name'),
      );
      await db.customStatement(
        'DELETE FROM tag_definitions WHERE id=? AND ledger_id=?',
        [sourceId, ledger],
      );
    });
  }

  Future<void> setHidden(String ledger, String id, bool hidden) async {
    await db.customStatement(
      'UPDATE tag_definitions SET hidden_at=?,updated_at=? WHERE id=? AND ledger_id=?',
      [
        hidden ? DateTime.now().toUtc().toIso8601String() : null,
        DateTime.now().toUtc().toIso8601String(),
        id,
        ledger,
      ],
    );
  }

  Future<List<LedgerEntry>> entries(String ledger, String name) async {
    final all = await LedgerRepository(db).entries(ledger);
    return all.where((entry) => entry.tags.contains(name)).toList();
  }

  Future<void> _replaceEverywhere(
    String ledger,
    String source,
    String target,
  ) async {
    for (final table in const [
      'transactions',
      'transaction_templates',
      'recurring_rules',
      'auto_correction_rules',
    ]) {
      final rows = await _query(
        'SELECT id,tags_json FROM $table WHERE ledger_id=?',
        [ledger],
      );
      for (final row in rows) {
        final tags = decodeTags(row.read<String>('tags_json'));
        if (!tags.contains(source)) continue;
        final replaced = normalizeTags(
          tags.map((tag) => tag == source ? target : tag),
        );
        await db.customStatement(
          'UPDATE $table SET tags_json=? WHERE id=? AND ledger_id=?',
          [jsonEncode(replaced), row.read<String>('id'), ledger],
        );
      }
    }
  }
}
