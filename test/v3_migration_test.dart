import 'dart:io';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/backup/backup_service.dart';

void main() {
  test(
    'v3 migration and encrypted v3 restore retain balances, transactions and pending OCR',
    () async {
      final dir = await Directory.systemTemp.createTemp('ledger-v3-');
      final file = File('${dir.path}/data.sqlite');
      final legacy = sql.sqlite3.open(file.path);
      for (final statement in schemaStatements.where(
        (s) => s != attachmentSchema && s != attachmentIndex,
      )) {
        legacy.execute(
          statement
              .replaceAll("tags_json TEXT NOT NULL DEFAULT '[]', ", '')
              .replaceAll(
                "    is_reimbursement INTEGER NOT NULL DEFAULT 0 CHECK(is_reimbursement IN (0,1)),\n",
                "",
              ),
        );
      }
      legacy.execute(
        "INSERT INTO ledgers VALUES ('personal','旧账本','CNY','2026-10-04')",
      );
      legacy.execute(
        "INSERT INTO accounts (id,ledger_id,name,kind,opening_minor,created_at) VALUES ('a','personal','现金','cash',1000,'2026-10-04')",
      );
      legacy.execute(
        "INSERT INTO categories (id,ledger_id,name,type) VALUES ('c','personal','交通','expense')",
      );
      legacy.execute("INSERT INTO settings VALUES ('device_id','old-device')");
      legacy.execute(
        "INSERT INTO transactions (id,ledger_id,type,amount_minor,account_id,category_id,occurred_date,device_id,created_at,updated_at) VALUES ('t','personal','expense',100,'a','c','2026-10-04','old-device','2026-10-04','2026-10-04')",
      );
      legacy.execute(
        "INSERT INTO transaction_postings (id,transaction_id,account_id,delta_minor) VALUES ('p','t','a',-100)",
      );
      legacy.execute(
        "INSERT INTO raw_transactions (id,ledger_id,source,raw_text,captured_at) VALUES ('r','personal','ocr','支付成功 ¥3.50','2026-10-04T12:00:00.000')",
      );
      legacy.execute(
        "INSERT INTO transaction_drafts VALUES ('d','r','pending',1,'{\"warnings\":[],\"evidence\":{},\"blocked\":false}',NULL,'2026-10-04')",
      );
      final payload = {
        'format': 'smart-ledger',
        'schema_version': 3,
        'tables': {
          for (final table in backupTables.where((t) => t != "attachments"))
            table: legacy
                .select('SELECT * FROM $table')
                .map((r) => Map<String, Object?>.from(r))
                .toList(),
        },
      };
      legacy.execute('PRAGMA user_version=3');
      legacy.dispose();
      final db = AppDatabase(NativeDatabase(file));
      final restored = AppDatabase.memory();
      try {
        final repo = LedgerRepository(db);
        await repo.initialize();
        expect((await repo.accounts('personal')).single.balanceMinor, 900);
        expect((await repo.entries('personal')).single.tags, isEmpty);
        expect((await repo.pendingDrafts('personal')).single.id, 'd');
        // Build an actual old envelope, with no tags_json column in its rows.
        final algorithm = AesGcm.with256bits();
        final salt = List<int>.generate(24, (i) => i);
        final key =
            await Pbkdf2(
              macAlgorithm: Hmac.sha256(),
              iterations: 210000,
              bits: 256,
            ).deriveKey(
              secretKey: SecretKey(utf8.encode('test-password')),
              nonce: salt,
            );
        final box = await algorithm.encrypt(
          utf8.encode(jsonEncode(payload)),
          secretKey: key,
        );
        final envelope = utf8.encode(
          jsonEncode({
            'format': 'smart-ledger-encrypted',
            'version': 1,
            'salt': base64Encode(salt),
            'nonce': base64Encode(box.nonce),
            'ciphertext': base64Encode(box.cipherText),
            'mac': base64Encode(box.mac.bytes),
          }),
        );
        await LedgerRepository(restored).initialize();
        await BackupService(restored).restore(envelope, 'test-password');
        final r = LedgerRepository(restored);
        expect((await r.accounts('personal')).single.balanceMinor, 900);
        expect((await r.entries('personal')).single.tags, isEmpty);
        expect((await r.pendingDrafts('personal')).single.id, 'd');
      } finally {
        await db.close();
        await restored.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
