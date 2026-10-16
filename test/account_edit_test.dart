import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'helpers/memory_card_vault.dart';

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
  test(
    'default account can be renamed and supplemented; postings and reports remain unchanged',
    () async {
      final a = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.bank);
      final category = (await repo.categories(
        'personal',
      )).firstWhere((c) => c.name == '早餐');
      final entry = await repo.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 2560,
          accountId: a.id,
          categoryId: category.id,
          occurredDate: DateTime(2026, 10, 5),
        ),
      );
      await repo.updateAccount(
        'personal',
        a.id,
        '招商工资卡',
        AccountKind.bank,
        100000,
        bankId: 'cmb',
        cardLast4: '1111',
        fullCardNumber: '4111111111111111',
        replaceCard: true,
      );
      final updated = (await repo.accounts(
        'personal',
      )).firstWhere((x) => x.id == a.id);
      expect(updated.id, a.id);
      expect(updated.balanceMinor, 100000);
      expect(updated.openingMinor, 102560);
      expect(updated.bankId, 'cmb');
      expect(updated.cardLast4, '1111');
      expect(await repo.fullCardNumber('personal', a.id), '4111111111111111');
      final posted = (await repo.entries('personal')).single;
      expect(posted.id, entry);
      expect(posted.amountMinor, 2560);
      expect(posted.accountName, contains('招商工资卡'));
      expect(
        (await repo.summary('personal', DateTime(2026, 10))).expenseMinor,
        2560,
      );
      await repo.delete('personal', entry);
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((x) => x.id == a.id).balanceMinor,
        102560,
      );
    },
  );
  test(
    'card is preserved when editing metadata; replacing by tail removes full number; clearing removes tail',
    () async {
      final a = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.bank);
      await repo.updateAccount(
        'personal',
        a.id,
        '卡',
        AccountKind.bank,
        0,
        bankId: 'cmb',
        cardLast4: '1111',
        fullCardNumber: '4111111111111111',
        replaceCard: true,
      );
      await repo.updateAccount(
        'personal',
        a.id,
        '更名卡',
        AccountKind.bank,
        0,
        bankId: 'cmb',
      );
      expect(await repo.fullCardNumber('personal', a.id), '4111111111111111');
      await repo.updateAccount(
        'personal',
        a.id,
        '更名卡',
        AccountKind.credit,
        -2000,
        bankId: 'cmb',
        cardLast4: '0001',
        replaceCard: true,
        repaymentDay: 31,
      );
      final edited = (await repo.accounts(
        'personal',
      )).firstWhere((x) => x.id == a.id);
      expect(edited.cardLast4, '0001');
      expect(edited.kind, AccountKind.credit);
      expect(edited.repaymentDay, 31);
      expect(await repo.fullCardNumber('personal', a.id), isNull);
      expect(vault.values, isEmpty);
      await repo.updateAccount(
        'personal',
        a.id,
        '更名卡',
        AccountKind.credit,
        -2000,
        bankId: 'cmb',
        replaceCard: true,
      );
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((x) => x.id == a.id).cardLast4,
        isNull,
      );
    },
  );
  test(
    'duplicate name, another ledger and invalid credit metadata leave the account unchanged',
    () async {
      final a = (await repo.accounts('personal')).first;
      await expectLater(
        repo.updateAccount('personal', a.id, '微信', AccountKind.cash, 1),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.updateAccount('other', a.id, '改名', AccountKind.cash, 1),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        repo.updateAccount(
          'personal',
          a.id,
          '改名',
          AccountKind.creditPayment,
          -1,
          providerId: 'jiebei',
        ),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.accounts('personal')).first.name, a.name);
      expect(vault.values, isEmpty);
    },
  );
  test(
    'SQL failure while replacing a card preserves the old secure reference and deletes new reference',
    () async {
      final a = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.bank);
      await repo.updateAccount(
        'personal',
        a.id,
        '卡',
        AccountKind.bank,
        0,
        cardLast4: '1111',
        fullCardNumber: '4111111111111111',
        replaceCard: true,
      );
      final old = (await repo.accounts(
        'personal',
      )).firstWhere((x) => x.id == a.id);
      await db.customStatement(
        "CREATE TRIGGER reject_account BEFORE UPDATE ON accounts BEGIN SELECT RAISE(ABORT,'failure'); END",
      );
      await expectLater(
        repo.updateAccount(
          'personal',
          a.id,
          '新卡',
          AccountKind.bank,
          999,
          cardLast4: '4444',
          fullCardNumber: '5555555555554444',
          replaceCard: true,
        ),
        throwsA(anything),
      );
      expect(vault.values.length, 1);
      expect(await repo.fullCardNumber('personal', a.id), '4111111111111111');
      final current = (await repo.accounts(
        'personal',
      )).firstWhere((x) => x.id == a.id);
      expect(current.cardSecretId, old.cardSecretId);
      expect(current.name, '卡');
      expect(current.balanceMinor, 0);
    },
  );
  test(
    'vault failure while replacing does not commit account changes',
    () async {
      final a = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.bank);
      vault.failWrites = true;
      await expectLater(
        repo.updateAccount(
          'personal',
          a.id,
          '新卡',
          AccountKind.bank,
          100,
          cardLast4: '1111',
          fullCardNumber: '4111111111111111',
          replaceCard: true,
        ),
        throwsStateError,
      );
      expect(
        (await repo.accounts('personal')).firstWhere((x) => x.id == a.id).name,
        '银行卡',
      );
      expect(vault.values, isEmpty);
    },
  );
}
