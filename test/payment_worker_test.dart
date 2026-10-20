import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/automation/automation_bridge.dart';
import 'package:smart_ledger/automation/payment_worker.dart';
import 'package:smart_ledger/automation/payment_capture_parser.dart';
import 'package:smart_ledger/automation/payment_capture_processor.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(AutomationBridge.channel, null),
  );
  test(
    'background entry pipeline commits before ack, safely acknowledges replay and closes then finishes',
    () async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final data = {
        'id': 'a' * 64,
        'packageName': 'com.tencent.mm',
        'kind': 'notification',
        'text': '支付成功\n商户名称 瑞幸咖啡\n交易金额 38.50元\n支付方式 微信零钱\n支付时间 2026-10-05',
        'capturedAt': DateTime(2026, 10, 5, 12, 5).millisecondsSinceEpoch,
        'ledgerId': 'personal',
        'autoSave': true,
      };
      var remaining = 2, finished = false;
      final outcomes = <String>[];
      var traceAttempts = 0;
      messenger.setMockMethodCallHandler(AutomationBridge.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'workerTrace':
            traceAttempts++;
            final metadata = call.arguments as Map;
            expect(
              metadata.keys.toSet().difference({
                'code',
                'app',
                'source',
                'id',
                'count',
              }),
              isEmpty,
            );
            expect(metadata.toString(), isNot(contains('瑞幸咖啡')));
            expect(metadata.toString(), isNot(contains('38.50')));
            throw StateError('logging unavailable');
          case 'takeConfirmation':
            return null;
          case 'take':
            return remaining > 0 ? data : null;
          case 'authorize':
            return true;
          case 'ack':
            outcomes.add(call.arguments['outcome']);
            if (call.arguments['outcome'] == 'repeated') {
              expect(call.arguments.containsKey('preview'), isFalse);
            }
            remaining--;
            expect((await repo.entries('personal')).length, 1);
            return null;
          case 'finish':
            finished = call.arguments['ok'] == true;
            return null;
        }
        throw StateError('Unexpected worker method');
      });
      await runPaymentAutomationWorker(openDatabase: () async => db);
      expect(outcomes, ['posted', 'repeated']);
      expect(finished, true);
      expect(remaining, 0);
      expect(traceAttempts, greaterThanOrEqualTo(3));
    },
  );
  test(
    'database failure keeps capture unacknowledged for retry and reports failure without exposing raw content',
    () async {
      var acknowledgements = 0, failed = false;
      messenger.setMockMethodCallHandler(AutomationBridge.channel, (
        call,
      ) async {
        if (call.method == 'ack') acknowledgements++;
        if (call.method == 'finish') failed = call.arguments['ok'] == false;
        return null;
      });
      await runPaymentAutomationWorker(
        openDatabase: () async => throw StateError('disk unavailable'),
      );
      expect(acknowledgements, 0);
      expect(failed, true);
    },
  );
  test('repeated pending capture does not reopen the floating form', () async {
    final db = AppDatabase.memory();
    final repo = LedgerRepository(db);
    await repo.initialize();
    final data = {
      'id': 'c' * 64,
      'packageName': 'com.tencent.mm',
      'kind': 'accessibility',
      'text': '支付成功\n商户名称 三津实业\n交易金额 3.00元',
      'capturedAt': DateTime(2026, 10, 20, 8, 22).millisecondsSinceEpoch,
      'ledgerId': 'personal',
      'autoSave': false,
    };
    var remaining = 2;
    final previews = <bool>[];
    messenger.setMockMethodCallHandler(AutomationBridge.channel, (call) async {
      switch (call.method) {
        case 'workerTrace':
        case 'takeConfirmation':
          return null;
        case 'take':
          return remaining-- > 0 ? data : null;
        case 'authorize':
          return true;
        case 'ack':
          previews.add((call.arguments as Map).containsKey('preview'));
          return null;
        case 'finish':
          return null;
      }
      throw StateError('Unexpected worker method');
    });

    await runPaymentAutomationWorker(openDatabase: () async => db);

    expect(previews, [true, false]);
  });
  test(
    'floating form background save commits before native success, then closes database',
    () async {
      final db = AppDatabase.memory();
      final repo = LedgerRepository(db);
      await repo.initialize();
      final account = (await repo.accounts(
        'personal',
      )).firstWhere((a) => a.kind == AccountKind.wechat);
      final category = (await repo.categories(
        'personal',
      )).firstWhere((c) => c.type == TransactionType.expense);
      await PaymentCaptureProcessor(repo).process(
        PaymentCapture(
          id: 'b' * 64,
          packageName: 'com.tencent.mm',
          kind: 'accessibility',
          text: '交易详情\n-16.00\n支付成功\n支付方式 零钱',
          capturedAt: DateTime(2026, 10, 5),
          ledgerId: 'personal',
          autoSave: false,
        ),
      );
      var resultSent = false, finished = false;
      messenger.setMockMethodCallHandler(AutomationBridge.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'takeConfirmation':
            return {
              'nonce': 'one',
              'draftId': 'auto-${'b' * 64}',
              'ledgerId': 'personal',
              'operation': 'confirm',
              'type': 'expense',
              'amount': '16',
              'date': '2026-10-05',
              'accountId': account.id,
              'categoryId': category.id,
              'merchant': '沙县小吃',
            };
          case 'authorizeConfirmation':
            expect(call.arguments['nonce'], 'one');
            return true;
          case 'confirmationResult':
            expect(call.arguments['ok'], true);
            expect(call.arguments['nonce'], 'one');
            expect(await repo.entries('personal'), hasLength(1));
            expect(await repo.pendingDrafts('personal'), isEmpty);
            resultSent = true;
            return null;
          case 'take':
            return null;
          case 'finish':
            finished = call.arguments['ok'] == true;
            return null;
        }
        throw StateError('Unexpected method');
      });
      await runPaymentAutomationWorker(openDatabase: () async => db);
      expect(resultSent, true);
      expect(finished, true);
    },
  );
}
