import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'helpers/memory_card_vault.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/domain/banks.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  late MemoryCardVault vault;
  setUp(() async {
    db = AppDatabase.memory();
    vault = MemoryCardVault();
    repo = LedgerRepository(db, cardVault: vault);
    await repo.initialize();
  });
  tearDown(() => db.close());
  Account schedule(int day, {DateTime? date}) => Account(
    id: 'a',
    name: 'a',
    kind: AccountKind.creditPayment,
    openingMinor: 0,
    balanceMinor: -10000,
    repaymentDay: day,
    dueDate: date,
  );

  test(
    'monthly dates clamp and cross years without rolling into another month',
    () {
      expect(
        schedule(31).nextRepayment(DateTime(2026, 2, 1)),
        DateTime(2026, 2, 28),
      );
      expect(
        schedule(31).nextRepayment(DateTime(2028, 2, 1)),
        DateTime(2028, 2, 29),
      );
      expect(
        schedule(28).nextRepayment(DateTime(2026, 2, 28, 23)),
        DateTime(2026, 2, 28),
      );
      expect(
        schedule(5).nextRepayment(DateTime(2026, 12, 6)),
        DateTime(2027, 1, 5),
      );
      expect(
        schedule(
          1,
          date: DateTime(2026, 1, 1),
        ).nextRepayment(DateTime(2026, 10, 5)),
        DateTime(2026, 1, 1),
      );
    },
  );
  test(
    'credit consumption increases debt, principal repayment is not another expense',
    () async {
      await repo.addAccount(
        'personal',
        '花呗',
        AccountKind.creditPayment,
        -100000,
        providerId: 'huabei',
        repaymentDay: 9,
      );
      final a = (await repo.accounts('personal')).last;
      final bank = (await repo.accounts('personal'))[1];
      final c = (await repo.categories('personal')).first;
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 3850,
          accountId: a.id,
          categoryId: c.id,
          occurredDate: DateTime(2026, 10, 5),
        ),
      );
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.transfer,
          amountMinor: 100000,
          accountId: bank.id,
          targetAccountId: a.id,
          occurredDate: DateTime(2026, 10, 6),
        ),
      );
      expect((await repo.accounts('personal')).last.balanceMinor, -3850);
      expect(
        (await repo.summary('personal', DateTime(2026, 10))).expenseMinor,
        3850,
      );
      await repo.setRepayment(
        'personal',
        a,
        day: 15,
        dueDate: DateTime(2026, 11, 10),
      );
      final updated = (await repo.accounts('personal')).last;
      expect(updated.repaymentDay, 15);
      expect(updated.dueDate, DateTime(2026, 11, 10));
      await expectLater(
        repo.setRepayment('personal', updated, day: 32),
        throwsA(isA<LedgerException>()),
      );
    },
  );
  test(
    'loan drawdown and repayment preserve income and expense totals',
    () async {
      await repo.addAccount(
        'personal',
        '借呗',
        AccountKind.loan,
        0,
        providerId: 'jiebei',
      );
      final loan = (await repo.accounts('personal')).last;
      final bank = (await repo.accounts('personal'))[1];
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.transfer,
          amountMinor: 200000,
          accountId: loan.id,
          targetAccountId: bank.id,
          occurredDate: DateTime(2026, 10, 5),
        ),
      );
      await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.transfer,
          amountMinor: 50000,
          accountId: bank.id,
          targetAccountId: loan.id,
          occurredDate: DateTime(2026, 10, 6),
        ),
      );
      expect((await repo.accounts('personal')).last.balanceMinor, -150000);
      final s = await repo.summary('personal', DateTime(2026, 10));
      expect(s.expenseMinor, 0);
      expect(s.incomeMinor, 0);
    },
  );
  test(
    'platform identification wins over its parent wallet and missing platform stays unresolved',
    () async {
      final raw = RawTransaction(
        text: '今天支付宝花呗付款38元',
        capturedAt: DateTime(2026, 10, 5),
      );
      TransactionDraft parse(RawTransaction r, List<Account> a) =>
          TransactionParser().parse(
            r,
            ledgerId: 'personal',
            accounts: a,
            categories: const [],
          );
      expect(parse(raw, await repo.accounts('personal')).accountId, isNull);
      await repo.addAccount(
        'personal',
        '我的信用消费',
        AccountKind.creditPayment,
        0,
        providerId: 'huabei',
      );
      final accounts = await repo.accounts('personal');
      expect(parse(raw, accounts).accountId, accounts.last.id);
      expect(
        parse(
          RawTransaction(
            text: '借呗借款到账3000元支付宝',
            capturedAt: DateTime(2026, 10, 5),
          ),
          accounts,
        ).blocked,
        isTrue,
      );
    },
  );
  test(
    'bank and tail resolve multiple cards without leaking complete numbers',
    () async {
      for (final tail in ['0001', '0002']) {
        await repo.addAccount(
          'personal',
          '招行 $tail',
          AccountKind.bank,
          0,
          bankId: 'cmb',
          cardLast4: tail,
        );
      }
      final a = await repo.accounts('personal');
      final d = TransactionParser().parse(
        RawTransaction(
          text: '今天招商银行尾号0002付款38元',
          capturedAt: DateTime(2026, 10, 5),
        ),
        ledgerId: 'personal',
        accounts: a,
        categories: const [],
      );
      expect(d.accountId, a.last.id);
      expect(d.amountMinor, 3800);
      expect(cardTailFromInput('4111 1111 1111 1111'), '1111');
      expect(cardTailFromInput('0001'), '0001');
      expect(() => cardTailFromInput('12345'), throwsFormatException);
    },
  );
  test(
    'full number stays in secure store, database has only reference and tail',
    () async {
      const testNumber =
          '4111111111111111'; // Public test number, never a user card.
      await repo.addAccount(
        'personal',
        '测试银行卡',
        AccountKind.bank,
        0,
        bankId: 'cmb',
        cardLast4: '1111',
        fullCardNumber: testNumber,
      );
      final a = (await repo.accounts('personal')).last;
      expect(await repo.fullCardNumber('personal', a.id), testNumber);
      expect(a.displayName.contains(testNumber), isFalse);
      final rows = await db.customSelect('SELECT * FROM accounts').get();
      expect(rows.any((r) => r.data.values.contains(testNumber)), isFalse);
    },
  );
  test(
    'encrypted backup restores cards to new device references and rejects vault failure atomically',
    () async {
      const testNumber = '4111111111111111';
      await repo.addAccount(
        'personal',
        '测试信用卡',
        AccountKind.credit,
        -10000,
        bankId: 'cmb',
        cardLast4: '1111',
        fullCardNumber: testNumber,
        repaymentDay: 9,
      );
      final old = (await repo.accounts('personal')).last;
      final bytes = await BackupService(
        db,
        cardVault: vault,
      ).export('test-password-2026');
      final target = AppDatabase.memory();
      final targetVault = MemoryCardVault();
      final targetRepo = LedgerRepository(target, cardVault: targetVault);
      await targetRepo.initialize();
      try {
        targetVault.failWrites = true;
        await expectLater(
          BackupService(
            target,
            cardVault: targetVault,
          ).restore(bytes, 'test-password-2026'),
          throwsA(isA<LedgerException>()),
        );
        expect((await targetRepo.accounts('personal')).length, 4);
        targetVault.failWrites = false;
        await BackupService(
          target,
          cardVault: targetVault,
        ).restore(bytes, 'test-password-2026');
        final restored = (await targetRepo.accounts('personal')).last;
        expect(restored.cardSecretId, isNot(old.cardSecretId));
        expect(
          await targetRepo.fullCardNumber('personal', restored.id),
          testNumber,
        );
        expect(restored.repaymentDay, 9);
        expect(restored.bankId, 'cmb');
      } finally {
        await target.close();
      }
    },
  );
  test(
    'vault or SQL failure leaves neither a new account nor an orphan card',
    () async {
      vault.failWrites = true;
      await expectLater(
        repo.addAccount(
          'personal',
          '失败的卡',
          AccountKind.bank,
          0,
          cardLast4: '1111',
          fullCardNumber: '4111111111111111',
        ),
        throwsStateError,
      );
      expect((await repo.accounts('personal')).length, 4);
      vault.failWrites = false;
      await expectLater(
        repo.addAccount(
          'missing-ledger',
          '无效账本的卡',
          AccountKind.bank,
          0,
          cardLast4: '1111',
          fullCardNumber: '4111111111111111',
        ),
        throwsA(anything),
      );
      expect(vault.values, isEmpty);
    },
  );
  test(
    'schema v1 upgrade preserves old account balance and adds nullable metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ledger-migration-',
      );
      final file = File('${directory.path}/ledger.sqlite');
      final legacy = sqlite3.open(file.path);
      for (final sql in (await File(
        'test/fixtures/schema-v1.sql',
      ).readAsString()).split(';')) {
        if (sql.trim().isNotEmpty) legacy.execute(sql);
      }
      legacy.execute(
        "INSERT INTO ledgers VALUES ('personal','旧账本','CNY','2026-10-05')",
      );
      legacy.execute(
        "INSERT INTO accounts (id,ledger_id,name,kind,opening_minor,created_at) VALUES ('legacy','personal','旧账户','bank',12345,'2026-10-05')",
      );
      legacy.execute('PRAGMA user_version=1');
      legacy.dispose();
      final upgraded = AppDatabase(NativeDatabase(file));
      try {
        final r = LedgerRepository(upgraded);
        await r.initialize();
        final a = (await r.accounts('personal')).single;
        expect(a.balanceMinor, 12345);
        expect(a.providerId, isNull);
        expect(a.cardSecretId, isNull);
        expect(
          (await upgraded.customSelect('PRAGMA user_version').get())
              .single
              .data
              .values
              .single,
          16,
        );
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'actual legacy encrypted backup restores with unchanged transaction and balance',
    () async {
      final bytes = await File(
        'test/fixtures/backup-v1-encrypted.json',
      ).readAsBytes();
      await BackupService(db).restore(bytes, 'test-password-2026');
      expect((await repo.entries('personal')).single.amountMinor, 3850);
      expect((await repo.accounts('personal')).single.balanceMinor, 96150);
      expect((await repo.accounts('personal')).single.repaymentDay, isNull);
    },
  );
}
