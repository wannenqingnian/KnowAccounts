import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/payment_apps.dart';
import 'package:smart_ledger/automation/payment_capture_parser.dart';
import 'package:smart_ledger/automation/payment_capture_processor.dart';
import 'package:smart_ledger/automation/payment_confirmation.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late LedgerRepository repo;
  late String account, expense, income, target;
  final time = DateTime(2026, 10, 5, 12, 5);
  PaymentCapture capture(
    String digit, {
    String? text,
    String packageName = 'com.tencent.mm',
  }) => PaymentCapture(
    id: digit * 64,
    packageName: packageName,
    kind: 'accessibility',
    text:
        text ??
        '交易详情\n精品沙县小吃\n-16.00\n当前状态 支付成功\n支付方式 零钱\n支付时间 2026年10月05日 12:05:15',
    capturedAt: time,
    ledgerId: 'personal',
    autoSave: false,
  );
  Map<String, Object?> command(
    String digit, {
    String type = 'expense',
    bool reimbursable = false,
  }) => {
    'draftId': 'auto-${digit * 64}',
    'ledgerId': 'personal',
    'operation': 'confirm',
    'type': type,
    'amount': '16.00',
    'date': '2026-10-05',
    'accountId': account,
    'targetAccountId': target,
    'categoryId': type == 'income' ? income : expense,
    'merchant': '精品沙县小吃',
    'note': '悬浮窗确认',
    'reimbursable': reimbursable,
  };
  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    final accounts = await repo.accounts('personal');
    account = accounts.firstWhere((a) => a.kind == AccountKind.wechat).id;
    target = accounts.firstWhere((a) => a.kind == AccountKind.alipay).id;
    final categories = await repo.categories('personal');
    expense = categories
        .firstWhere((c) => c.type == TransactionType.expense)
        .id;
    income = categories.firstWhere((c) => c.type == TransactionType.income).id;
  });
  tearDown(() => db.close());
  test(
    'popup default and old configuration migration enable review without silently posting',
    () {
      expect(const AutomationConfig().reviewPopup, true);
      expect(const AutomationConfig().screenshotFallback, false);
      expect(AutomationConfig.fromJson({'enabled': true}).reviewPopup, true);
      expect(
        AutomationConfig.fromJson(
          const AutomationConfig(
            reviewPopup: false,
            screenshotFallback: true,
          ).toJson(),
        ).reviewPopup,
        false,
      );
      expect(
        AutomationConfig.fromJson(
          const AutomationConfig(screenshotFallback: true).toJson(),
        ).screenshotFallback,
        true,
      );
    },
  );
  test(
    'editable preview uses parsed receipt fields and pending draft, then confirmation commits once',
    () async {
      final event = capture('a');
      expect(
        await PaymentCaptureProcessor(repo).process(event, now: time),
        'pending',
      );
      expect(await repo.entries('personal'), isEmpty);
      final preview = await paymentPreview(repo, event);
      expect(preview!['amount'], '16.00');
      expect(preview['accountId'], account);
      expect((preview['accounts'] as List).first, {'id': '', 'name': '请选择账户'});
      final first = await confirmPayment(repo, command('a'));
      expect(first.ok, true, reason: first.message);
      expect((await confirmPayment(repo, command('a'))).ok, true);
      expect(await repo.entries('personal'), hasLength(1));
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((a) => a.id == account).balanceMinor,
        -1600,
      );
      expect(await repo.pendingDrafts('personal'), isEmpty);
      expect(await paymentPreview(repo, event), isNull);
    },
  );
  test(
    'confirmation can create and use a searched category atomically',
    () async {
      final event = capture('b');
      await PaymentCaptureProcessor(repo).process(event, now: time);
      final data = command('b')
        ..['categoryId'] = ''
        ..['newCategoryName'] = '工作午餐';
      final result = await confirmPayment(repo, data);
      expect(result.ok, true, reason: result.message);
      final categories = await repo.categories('personal');
      final created = categories.singleWhere((c) => c.name == '工作午餐');
      expect(created.type, TransactionType.expense);
      expect((await repo.entries('personal')).single.categoryId, created.id);
    },
  );
  test(
    'automatic confirmation can mark an expense for reimbursement',
    () async {
      final event = capture('8');
      await PaymentCaptureProcessor(repo).process(event, now: time);
      final result = await confirmPayment(
        repo,
        command('8', reimbursable: true),
      );
      expect(result.ok, true, reason: result.message);
      expect((await repo.entries('personal')).single.reimbursable, true);
    },
  );
  test('overlay preview can route a pending bill to another ledger', () async {
    await repo.createLedger('工作账本');
    final targetLedger = (await repo.ledgers()).entries
        .singleWhere((entry) => entry.value == '工作账本')
        .key;
    final targetAccount = (await repo.accounts(targetLedger)).first.id;
    final targetCategory = (await repo.categories(
      targetLedger,
    )).firstWhere((value) => value.type == TransactionType.expense).id;
    final event = capture('9');
    await PaymentCaptureProcessor(repo).process(event, now: time);
    final preview = await paymentPreview(repo, event);
    expect((preview!['ledgers'] as List), hasLength(2));
    expect((preview['accountsByLedger'] as Map)[targetLedger], isNotEmpty);
    final data = command('9')
      ..['ledgerId'] = targetLedger
      ..['accountId'] = targetAccount
      ..['categoryId'] = targetCategory;
    final result = await confirmPayment(repo, data);
    expect(result.ok, isTrue, reason: result.message);
    expect(await repo.entries('personal'), isEmpty);
    expect(await repo.entries(targetLedger), hasLength(1));
    final mapping = await db
        .customSelect(
          '''SELECT f.recognized_value,f.final_value FROM learning_field_changes f
      JOIN learning_events e ON e.id=f.event_id
      WHERE e.transaction_id=? AND f.field_name='ledger' ''',
          variables: [
            Variable<String>((await repo.entries(targetLedger)).single.id),
          ],
        )
        .getSingle();
    expect(mapping.read<String>('recognized_value'), 'personal');
    expect(mapping.read<String>('final_value'), targetLedger);
  });
  test(
    'red packet is always reviewed; user selects income or peer expense explicitly',
    () async {
      final event = capture(
        'a',
        text: '红包详情\n-16.00\n红包已发出\n支付方式 零钱\n发出时间 2026年10月05日 12:05:15',
      );
      await PaymentCaptureProcessor(repo).process(event, now: time);
      final preview = await paymentPreview(repo, event);
      expect(preview!['peer'], true);
      expect(await repo.entries('personal'), isEmpty);
      final missing = command('a')..['type'] = '';
      expect((await confirmPayment(repo, missing)).ok, false);
      expect(await repo.pendingDrafts('personal'), hasLength(1));
      final result = await confirmPayment(repo, command('a', type: 'income'));
      expect(result.ok, true, reason: result.message);
      expect(
        (await repo.accounts(
          'personal',
        )).firstWhere((a) => a.id == account).balanceMinor,
        1600,
      );
      expect(
        (await repo.entries('personal')).single.type,
        TransactionType.income,
      );
    },
  );
  test('wechat chat transfer card becomes an editable peer draft', () async {
    final event = capture('c', text: '¥0.01\n你发起了一笔转账\n微信转账');
    expect(
      await PaymentCaptureProcessor(repo).process(event, now: time),
      'pending',
    );
    final preview = await paymentPreview(repo, event);
    expect(preview!['amount'], '0.01');
    expect(preview['peer'], true);
    expect(preview['merchant'], '微信转账');
    expect(await repo.entries('personal'), isEmpty);
  });
  test(
    'alipay purchase mentioning a red packet is not a wechat red packet',
    () async {
      final accounts = await repo.accounts('personal');
      final categories = await repo.categories('personal');
      final event = capture(
        'd',
        packageName: 'com.eg.android.AlipayGphone',
        text:
            '交易详情\n支付宝红包主题餐厅\n-16.00\n当前状态 支付成功\n'
            '商品 支付宝红包套餐\n优惠 支付宝红包\n支付方式 余额\n'
            '支付时间 2026年10月05日 12:05:15',
      );
      final parsed = PaymentCaptureParser().parse(
        event,
        accounts,
        categories,
        now: time,
      );
      expect(parsed.draft.merchant, '支付宝红包主题餐厅');
      expect(parsed.draft.type, TransactionType.expense);
      expect(parsed.draft.warnings.any((w) => w.contains('核对收支方向')), false);
      expect(parsed.draft.merchant, isNot('微信红包'));
    },
  );
  test('real alipay red packet keeps alipay source identity', () async {
    final event = capture(
      'e',
      packageName: 'com.eg.android.AlipayGphone',
      text:
          '支付宝红包\n红包金额 16.00元\n领取成功，已存入余额\n'
          '领取时间 2026年10月05日 12:05:15',
    );
    await PaymentCaptureProcessor(repo).process(event, now: time);
    final preview = await paymentPreview(repo, event);
    expect(preview!['peer'], true);
    expect(preview['merchant'], '支付宝红包');
  });
  test('alipay transfer advisory text remains a reviewable transfer', () async {
    final event = capture(
      'f',
      packageName: 'com.eg.android.AlipayGphone',
      text:
          '支付宝转账\n-0.01\n转账成功，对方预计即时到账\n收款方 张三\n'
          '转账时间 2026年10月05日 12:05:15\n'
          '对方未收款时资金将原路退回\n退款说明\n立减优惠',
    );
    await PaymentCaptureProcessor(repo).process(event, now: time);
    final preview = await paymentPreview(repo, event);
    expect(preview, isNotNull);
    expect(preview!['peer'], true);
    expect(preview['amount'], '0.01');
    expect(preview['merchant'], isNot('微信红包'));
  });
  test(
    'own account transfer creates balanced postings without income or expense',
    () async {
      await PaymentCaptureProcessor(repo).process(
        capture('a', text: '转账成功\n转账金额 16.00元\n转账时间 2026年10月05日\n支付方式 零钱'),
        now: time,
      );
      final result = await confirmPayment(repo, command('a', type: 'transfer'));
      expect(result.ok, true, reason: result.message);
      final accounts = await repo.accounts('personal');
      expect(accounts.firstWhere((a) => a.id == account).balanceMinor, -1600);
      expect(accounts.firstWhere((a) => a.id == target).balanceMinor, 1600);
      expect(
        (await repo.entries('personal')).single.type,
        TransactionType.transfer,
      );
    },
  );
  test(
    'invalid fields and wrong ledger cannot consume pending draft; ignore is idempotent',
    () async {
      await PaymentCaptureProcessor(repo).process(capture('a'), now: time);
      for (final change in [
        {'date': '2026-02-31'},
        {'accountId': ''},
        {'amount': '-16'},
        {'amount': '0'},
        {'ledgerId': 'missing'},
      ]) {
        expect(
          (await confirmPayment(repo, {...command('a'), ...change})).ok,
          false,
          reason: '$change',
        );
      }
      expect(await repo.entries('personal'), isEmpty);
      expect(await repo.pendingDrafts('personal'), hasLength(1));
      expect(
        (await confirmPayment(repo, {
          ...command('a'),
          'operation': 'ignore',
        })).ok,
        true,
      );
      expect(
        (await confirmPayment(repo, {
          ...command('a'),
          'operation': 'ignore',
        })).ok,
        true,
      );
      expect(await repo.pendingDrafts('personal'), isEmpty);
      expect(await repo.entries('personal'), isEmpty);
    },
  );
  test(
    'duplicate capture requires explicit override before another posting',
    () async {
      await PaymentCaptureProcessor(repo).process(capture('a'), now: time);
      await confirmPayment(repo, command('a'));
      await PaymentCaptureProcessor(repo).process(capture('b'), now: time);
      final preview = await paymentPreview(repo, capture('b'));
      expect(preview!['duplicate'], true);
      expect(preview['warning'], contains('疑似重复'));
      final duplicate = await confirmPayment(repo, command('b'));
      expect(duplicate.ok, false);
      expect(duplicate.duplicate, true);
      expect(await repo.entries('personal'), hasLength(1));
      expect(
        (await confirmPayment(repo, {
          ...command('b'),
          'allowDuplicate': true,
        })).ok,
        true,
      );
      expect(await repo.entries('personal'), hasLength(2));
    },
  );
  test(
    'revisited bill is flagged duplicate even when account is not recognized',
    () async {
      await PaymentCaptureProcessor(repo).process(capture('a'), now: time);
      await confirmPayment(repo, command('a'));
      final revisit = capture(
        'b',
        text: '交易详情\n精品沙县小吃\n-16.00\n当前状态 支付成功\n支付时间 2026年10月05日 12:05:15',
      );
      await PaymentCaptureProcessor(repo).process(revisit, now: time);
      final preview = await paymentPreview(repo, revisit);
      expect(preview!['accountId'], isNull);
      expect(preview['duplicate'], true);
    },
  );
  test(
    'completed notification prose without fixed success phrase extracts amount and merchant',
    () async {
      final accounts = await repo.accounts('personal'),
          categories = await repo.categories('personal');
      final event = PaymentCapture(
        id: 'a' * 64,
        packageName: 'com.tencent.mm',
        kind: 'notification',
        text: '你向精品沙县小吃付款16.00元',
        capturedAt: time,
        ledgerId: 'personal',
        accountId: account,
      );
      final parsed = PaymentCaptureParser().parse(
        event,
        accounts,
        categories,
        now: time,
      );
      expect(parsed.draft.amountMinor, 1600);
      expect(parsed.draft.merchant, '精品沙县小吃');
      expect(parsed.canAutoSave, true, reason: parsed.draft.warnings.join(';'));
    },
  );
}
