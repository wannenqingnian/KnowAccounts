import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/security/source_privacy.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
  });
  tearDown(() => db.close());

  Future<TransactionDraft> parse([String text = '昨天滴滴42元支付宝']) async =>
      TransactionParser().parse(
        RawTransaction(text: text, capturedAt: DateTime(2026, 10, 5, 12)),
        ledgerId: 'personal',
        accounts: await repo.accounts('personal'),
        categories: await repo.categories('personal'),
      );
  TransactionInput input(TransactionDraft draft, {String? account}) =>
      TransactionInput(
        type: draft.type,
        amountMinor: draft.amountMinor!,
        accountId: account ?? draft.accountId!,
        categoryId: draft.categoryId,
        merchant: draft.merchant,
        occurredDate: draft.occurredDate,
      );

  test(
    'persisted sources and snapshots mask long card identifiers and retain money',
    () async {
      for (final number in [
        '4111111111111111',
        '4111 1111 1111 1111',
        '４１１１-１１１１-１１１１-１１１１',
      ]) {
        final text = sanitizeSourceText('招商银行卡号 $number 早餐38.50元');
        expect(text, contains('尾号 1111'));
        final draft = await parse(text);
        expect(draft.amountMinor, 3850);
        await repo.storeDraft(draft);
      }
      final rows = await db
          .customSelect('SELECT raw_text FROM raw_transactions')
          .get();
      expect(
        rows.every(
          (r) => !r.read<String>('raw_text').contains('4111111111111111'),
        ),
        isTrue,
      );
      expect((await repo.pendingDrafts('personal')).length, 3);
    },
  );

  test(
    'pending source is isolated and has no accounting effect; repeated parsing updates it',
    () async {
      final draft = await parse();
      final id = await repo.storeDraft(draft);
      await repo.storeDraft(await parse('昨天滴滴43元支付宝'), id: id);
      final pending = (await repo.pendingDrafts('personal')).single;
      expect(pending.id, id);
      expect(pending.raw.text, '昨天滴滴43元支付宝');
      expect(await repo.pendingDrafts('different-ledger'), isEmpty);
      expect(await repo.entries('personal'), isEmpty);
      expect(
        (await repo.accounts('personal')).every((a) => a.balanceMinor == 0),
        isTrue,
      );
      expect(
        (await db.customSelect('SELECT * FROM raw_transactions').get()).length,
        1,
      );
    },
  );
  test(
    'confirmation is atomic and repeated confirmation returns the same entry',
    () async {
      final draft = await parse();
      final id = await repo.storeDraft(draft);
      await expectLater(
        repo.confirmDraft('personal', id, input(draft, account: 'missing')),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.pendingDrafts('personal')).length, 1);
      expect(await repo.entries('personal'), isEmpty);
      final entry = await repo.confirmDraft('personal', id, input(draft));
      expect(await repo.confirmDraft('personal', id, input(draft)), entry);
      expect(await repo.pendingDrafts('personal'), isEmpty);
      expect((await repo.entries('personal')).length, 1);
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((a) => a.id == draft.accountId).balanceMinor,
        -4200,
      );
      final link =
          (await db.customSelect('SELECT * FROM transaction_drafts').get())
              .single;
      expect(link.read<String>('transaction_id'), entry);
    },
  );
  test(
    'failed source link rolls back the newly created entry and its postings',
    () async {
      final draft = await parse();
      final id = await repo.storeDraft(draft);
      await db.customStatement(
        "CREATE TRIGGER reject_link BEFORE UPDATE ON transaction_drafts WHEN NEW.status='posted' BEGIN SELECT RAISE(ABORT,'link failure'); END",
      );
      await expectLater(
        repo.confirmDraft('personal', id, input(draft)),
        throwsA(anything),
      );
      expect(await repo.entries('personal'), isEmpty);
      expect((await repo.pendingDrafts('personal')).length, 1);
      expect(
        (await db.customSelect('SELECT * FROM transaction_postings').get()),
        isEmpty,
      );
    },
  );
  test(
    'another ledger cannot confirm or ignore; ignored sources cannot post',
    () async {
      final draft = await parse();
      final id = await repo.storeDraft(draft);
      await expectLater(
        repo.ignoreDraft('another', id),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.confirmDraft('another', id, input(draft)),
        throwsA(isA<LedgerException>()),
      );
      await repo.ignoreDraft('personal', id);
      expect(await repo.pendingDrafts('personal'), isEmpty);
      await expectLater(
        repo.confirmDraft('personal', id, input(draft)),
        throwsA(isA<LedgerException>()),
      );
      expect(await repo.entries('personal'), isEmpty);
    },
  );
  test(
    'drafts survive reopening; relative dates retain original capture date',
    () async {
      final dir = await Directory.systemTemp.createTemp('persisted-draft-');
      final file = File('${dir.path}/data.sqlite');
      var disk = AppDatabase(NativeDatabase(file));
      var r = LedgerRepository(disk);
      await r.initialize();
      await r.storeDraft(await parse());
      await disk.close();
      disk = AppDatabase(NativeDatabase(file));
      r = LedgerRepository(disk);
      try {
        final pending = (await r.pendingDrafts('personal')).single;
        final draft = TransactionParser().parse(
          pending.raw,
          ledgerId: pending.ledgerId,
          accounts: await r.accounts('personal'),
          categories: await r.categories('personal'),
        );
        expect(draft.occurredDate, DateTime(2026, 10, 4, 12));
        expect(draft.amountMinor, 4200);
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('v2 database migrates credit metadata and adds an empty inbox', () async {
    final dir = await Directory.systemTemp.createTemp('migration-v2-');
    final file = File('${dir.path}/data.sqlite');
    final old = sqlite3.open(file.path);
    for (final sql in (await File(
      'test/fixtures/schema-v2.sql',
    ).readAsString()).split(';')) {
      if (sql.trim().isNotEmpty) old.execute(sql);
    }
    old.execute(
      "INSERT INTO ledgers VALUES ('personal','旧账本','CNY','2026-10-05')",
    );
    old.execute(
      "INSERT INTO accounts (id,ledger_id,name,kind,opening_minor,created_at,provider_id,repayment_day) VALUES ('huabei','personal','花呗','creditPayment',-12345,'2026-10-05','huabei',9)",
    );
    old.execute('PRAGMA user_version=2');
    old.dispose();
    final upgraded = AppDatabase(NativeDatabase(file));
    final r = LedgerRepository(upgraded);
    try {
      await r.initialize();
      final a = (await r.accounts('personal')).single;
      expect(a.balanceMinor, -12345);
      expect(a.providerId, 'huabei');
      expect(a.repaymentDay, 9);
      expect(await r.pendingDrafts('personal'), isEmpty);
    } finally {
      await upgraded.close();
      await dir.delete(recursive: true);
    }
  });
  test('v2 encrypted backup restores balances with an empty inbox', () async {
    await BackupService(db).restore(
      await File('test/fixtures/backup-v2-encrypted.json').readAsBytes(),
      'test-password-2026',
    );
    expect((await repo.accounts('personal')).single.balanceMinor, 96150);
    expect(await repo.pendingDrafts('personal'), isEmpty);
  });
  test(
    'encrypted backup restores pending sources and posted source bindings',
    () async {
      final draft = await parse();
      final posted = await repo.storeDraft(draft);
      final entry = await repo.confirmDraft('personal', posted, input(draft));
      final pending = await repo.storeDraft(await parse('微信咖啡18元'));
      final bytes = await BackupService(db).export('test-password-2026');
      await repo.ignoreDraft('personal', pending);
      await BackupService(db).restore(bytes, 'test-password-2026');
      expect((await repo.pendingDrafts('personal')).single.id, pending);
      expect(await repo.confirmDraft('personal', posted, input(draft)), entry);
      expect((await repo.entries('personal')).length, 1);
    },
  );
}
