import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/attachment.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/finance/analysis.dart';
import 'package:smart_ledger/finance/advanced_analysis.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aMxkAAAAASUVORK5CYII=',
);
ImageAttachment image([String id = '11111111-1111-4111-8111-111111111111']) =>
    ImageAttachment(id: id, name: '小票.png', data: png);
void main() {
  late AppDatabase db;
  late LedgerRepository repo;
  late String account, category;
  final date = DateTime(2026, 10, 5);
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    account = (await repo.accounts('personal')).first.id;
    category = (await repo.categories(
      'personal',
    )).firstWhere((c) => c.type == TransactionType.expense).id;
  });
  tearDown(() => db.close());
  Future<String> expense({
    bool reimbursable = true,
    List<ImageAttachment>? images,
  }) => repo.save(
    'personal',
    TransactionInput(
      type: TransactionType.expense,
      amountMinor: 10000,
      accountId: account,
      categoryId: category,
      occurredDate: date,
      reimbursable: reimbursable,
    ),
    attachments: images,
  );
  Future<String> received(
    String original,
    int amount, {
    bool reimbursement = true,
    DateTime? when,
    String? id,
  }) => repo.save(
    'personal',
    TransactionInput(
      type: TransactionType.refund,
      amountMinor: amount,
      accountId: account,
      occurredDate: when ?? date,
      relatedTransactionId: original,
      isReimbursement: reimbursement,
    ),
    id: id,
  );
  Future<LedgerEntry> original(String id) async =>
      (await repo.entries('personal')).firstWhere((e) => e.id == id);
  test(
    'partial, multiple and cross-month reimbursement affects cash, not income, with reversible status',
    () async {
      final id = await expense();
      expect((await original(id)).reimbursementStatus, '待报销');
      final a = await received(id, 4000);
      expect((await original(id)).reimbursementStatus, '部分报销');
      expect((await original(id)).reimbursementRemaining, 6000);
      expect((await repo.summary('personal', date)).incomeMinor, 0);
      expect((await repo.summary('personal', date)).expenseMinor, 6000);
      expect((await repo.accounts('personal')).first.balanceMinor, -6000);
      final b = await received(id, 6000, when: DateTime(2026, 11, 1));
      expect((await original(id)).reimbursementStatus, '已报销');
      expect((await repo.summary('personal', date)).expenseMinor, 6000);
      expect(
        (await repo.summary('personal', DateTime(2026, 11))).expenseMinor,
        -6000,
      );
      final report = PeriodAnalysis(
        await repo.entries('personal'),
        DateTime(2026),
        DateTime(2027),
      );
      expect(report.reimbursement, 10000);
      expect(report.refund, 0);
      expect(report.netExpense, 0);
      expect(report.income, 0);
      expect(
        balanceAt(
          await repo.entries('personal'),
          await repo.accounts('personal'),
          DateTime(2027),
        ),
        0,
      );
      final flow = dailyFlows(
        await repo.entries('personal'),
        DateTime(2026),
        DateTime(2027),
      );
      expect(flow['2026-11-01']!.value(2), 6000);
      await repo.delete('personal', b);
      expect((await original(id)).reimbursementStatus, '部分报销');
      await repo.delete('personal', a);
      expect((await original(id)).reimbursementStatus, '待报销');
      await repo.restore('personal', b);
      await repo.restore('personal', a);
      expect((await original(id)).reimbursementStatus, '已报销');
    },
  );
  test(
    'refund and reimbursement share a cap, edits and restores cannot bypass it',
    () async {
      final id = await expense();
      final receipt = await received(id, 4000);
      await received(id, 2000, reimbursement: false);
      expect((await original(id)).refundedMinor, 2000);
      expect((await original(id)).reimbursementRemaining, 4000);
      await expectLater(received(id, 4001), throwsA(isA<LedgerException>()));
      await received(id, 8000, id: receipt);
      expect((await original(id)).reimbursementStatus, '已报销');
      await expectLater(
        repo.delete('personal', id),
        throwsA(isA<LedgerException>()),
      );
      await repo.delete('personal', receipt);
      await received(id, 8000);
      await expectLater(
        repo.restore('personal', receipt),
        throwsA(isA<LedgerException>()),
      );
      expect((await original(id)).reimbursedMinor, 8000);
    },
  );
  test(
    'unmarked, foreign-ledger and wrong-type reimbursement cannot post',
    () async {
      final id = await expense(reimbursable: false);
      await expectLater(received(id, 1000), throwsA(isA<LedgerException>()));
      await repo.createLedger('另一个');
      final ledger = (await repo.ledgers()).keys.firstWhere(
        (k) => k != 'personal',
      );
      await expectLater(
        repo.save(
          ledger,
          TransactionInput(
            type: TransactionType.refund,
            amountMinor: 1,
            accountId: (await repo.accounts(ledger)).first.id,
            occurredDate: date,
            isReimbursement: true,
            relatedTransactionId: id,
          ),
        ),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.save(
          'personal',
          TransactionInput(
            type: TransactionType.expense,
            amountMinor: 1,
            accountId: account,
            categoryId: category,
            occurredDate: date,
            isReimbursement: true,
          ),
        ),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.entries('personal')).length, 1);
    },
  );
  test(
    'attachments survive soft delete and restore; bad attachment rolls back transaction and image changes',
    () async {
      final id = await expense(images: [image()]);
      expect((await original(id)).attachmentCount, 1);
      await repo.delete('personal', id);
      expect((await repo.attachments('personal', id)).single.data, png);
      await repo.restore('personal', id);
      final invalid = ImageAttachment(
        id: '22222222-2222-4222-8222-222222222222',
        name: '坏.png',
        data: Uint8List.fromList([1, 2, 3]),
      );
      await expectLater(
        expense(images: [invalid]),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.entries('personal')).length, 1);
      await expectLater(
        repo.replaceAttachments('personal', id, [invalid]),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.attachments('personal', id)).single.data, png);
      await received(id, 1000);
      await repo.replaceAttachments('personal', id, []);
      expect((await original(id)).attachmentCount, 0);
    },
  );
  test(
    'attachment limits and ledger ownership are enforced without removing existing images',
    () async {
      final id = await expense(images: [image()]);
      await expectLater(
        repo.replaceAttachments(
          'personal',
          id,
          List.generate(
            6,
            (i) => image('${i + 1}1111111-1111-4111-8111-111111111111'),
          ),
        ),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.replaceAttachments('personal', id, [image(), image()]),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.replaceAttachments('foreign', id, []),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.attachments('personal', id)).length, 1);
      final validJpeg = ImageAttachment(
        id: image().id,
        name: '小票.jpg',
        data: base64Decode(
          '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAADAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDk6KKKwPlj/9k=',
        ),
      );
      expect(validJpeg.validate, returnsNormally);
      final truncatedJpeg = ImageAttachment(
        id: image().id,
        name: '坏.jpg',
        data: Uint8List.fromList([255, 216, 255, 192]),
      );
      expect(truncatedJpeg.validate, throwsA(isA<LedgerException>()));
      final hugeJpeg = ImageAttachment(
        id: image().id,
        name: '大.jpg',
        data: Uint8List.fromList([
          255,
          216,
          255,
          192,
          0,
          8,
          8,
          0,
          1,
          39,
          17,
          1,
        ]),
      );
      expect(hugeJpeg.validate, throwsA(isA<LedgerException>()));
      final oversized = ImageAttachment(
        id: image().id,
        name: '大.png',
        data: Uint8List(maxAttachmentBytes + 1),
      );
      expect(oversized.validate, throwsA(isA<LedgerException>()));
      final dimensions = Uint8List.fromList(png);
      ByteData.sublistView(dimensions).setUint32(16, 10001);
      expect(
        ImageAttachment(
          id: image().id,
          name: '大.png',
          data: dimensions,
        ).validate,
        throwsA(isA<LedgerException>()),
      );
    },
  );
  test(
    'encrypted backup restores reimbursement, attachment bytes and persistent privacy; corrupt restore preserves originals',
    () async {
      final id = await expense(images: [image()]);
      await received(id, 3000);
      await repo.setAmountPrivacy(true);
      final service = BackupService(db);
      final bytes = await service.export('test-password');
      expect(utf8.decode(bytes), isNot(contains('小票.png')));
      final target = AppDatabase.memory();
      addTearDown(target.close);
      await BackupService(target).restore(bytes, 'test-password');
      final restored = LedgerRepository(target);
      expect(await restored.amountPrivacy(), true);
      expect((await restored.attachments('personal', id)).single.data, png);
      final entry = (await restored.entries(
        'personal',
      )).firstWhere((e) => e.id == id);
      expect(entry.reimbursedMinor, 3000);
      expect(entry.reimbursementStatus, '部分报销');
      final broken = Uint8List.fromList(bytes);
      broken[broken.length ~/ 2] ^= 1;
      await expectLater(
        BackupService(target).restore(broken, 'test-password'),
        throwsA(isA<LedgerException>()),
      );
      expect((await restored.attachments('personal', id)).single.data, png);
      expect((await restored.summary('personal', date)).expenseMinor, 7000);
      await db.customStatement('UPDATE attachments SET image_base64=?', [
        base64Encode([1, 2, 3]),
      ]);
      final invalidImageBackup = await service.export('test-password');
      await expectLater(
        BackupService(target).restore(invalidImageBackup, 'test-password'),
        throwsA(isA<LedgerException>()),
      );
      expect((await restored.attachments('personal', id)).single.data, png);
    },
  );
  test(
    'actual v4 database upgrade and v4 encrypted backup preserve transactions and use empty new fields',
    () async {
      final dir = await Directory.systemTemp.createTemp('ledger-v4-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/old.sqlite');
      final legacy = sql.sqlite3.open(file.path);
      for (final statement in schemaStatements.where(
        (s) => s != attachmentSchema && s != attachmentIndex,
      )) {
        legacy.execute(
          statement.replaceAll(
            '    is_reimbursement INTEGER NOT NULL DEFAULT 0 CHECK(is_reimbursement IN (0,1)),\n',
            '',
          ),
        );
      }
      legacy.execute(
        "INSERT INTO ledgers VALUES ('personal','旧账本','CNY','2026-10-05')",
      );
      legacy.execute(
        "INSERT INTO accounts (id,ledger_id,name,kind,opening_minor,created_at) VALUES ('a','personal','现金','cash',1000,'2026-10-05')",
      );
      legacy.execute(
        "INSERT INTO categories (id,ledger_id,name,type) VALUES ('c','personal','餐饮','expense')",
      );
      legacy.execute("INSERT INTO settings VALUES ('device_id','old-device')");
      legacy.execute(
        "INSERT INTO transactions (id,ledger_id,type,amount_minor,account_id,category_id,occurred_date,device_id,created_at,updated_at) VALUES ('t','personal','expense',100,'a','c','2026-10-05','old-device','2026-10-05','2026-10-05')",
      );
      legacy.execute(
        "INSERT INTO transaction_postings (id,transaction_id,account_id,delta_minor) VALUES ('p','t','a',-100)",
      );
      final payload = {
        'format': 'smart-ledger',
        'schema_version': 4,
        'tables': {
          for (final table in backupTables.where((t) => t != 'attachments'))
            table: legacy
                .select('SELECT * FROM $table')
                .map((r) => Map<String, Object?>.from(r))
                .toList(),
        },
      };
      legacy.execute('PRAGMA user_version=4');
      legacy.dispose();
      final upgraded = AppDatabase(NativeDatabase(file));
      addTearDown(upgraded.close);
      final upgradedRepo = LedgerRepository(upgraded);
      await upgradedRepo.initialize();
      expect(
        (await upgradedRepo.accounts('personal')).single.balanceMinor,
        900,
      );
      expect(
        (await upgradedRepo.entries('personal')).single.isReimbursement,
        false,
      );
      expect(await upgradedRepo.attachments('personal', 't'), isEmpty);
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
      final envelope = Uint8List.fromList(
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
      await BackupService(db).restore(envelope, 'test-password');
      expect((await repo.accounts('personal')).single.balanceMinor, 900);
      expect((await repo.entries('personal')).single.attachmentCount, 0);
    },
  );
}
