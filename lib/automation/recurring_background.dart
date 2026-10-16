import 'package:flutter/services.dart';

import '../core/database/app_database.dart';
import '../data/ledger_repository.dart';

class RecurringBackground {
  static const _channel = MethodChannel('smart_ledger/recurring');

  static Future<void> sync(LedgerRepository repository) async {
    final next = await repository.nextRecurringWakeAt();
    if (next == null) {
      await _channel.invokeMethod<void>('cancel');
    } else {
      await _channel.invokeMethod<void>('schedule', {
        'at': next.millisecondsSinceEpoch,
      });
    }
  }
}

@pragma('vm:entry-point')
Future<void> runRecurringBackgroundWorker() async {
  final database = await AppDatabase.open();
  try {
    final repository = LedgerRepository(database);
    await repository.initialize(processRecurring: false);
    final result = await repository.processDueRecurringRules();
    final next = await repository.nextRecurringWakeAt();
    await const MethodChannel(
      'smart_ledger/recurring',
    ).invokeMethod<void>('finish', {
      'ok': true,
      'succeeded': result.notifiableSucceeded,
      'failed': result.notifiableFailed,
      'nextAt': next?.millisecondsSinceEpoch,
    });
  } catch (_) {
    await const MethodChannel(
      'smart_ledger/recurring',
    ).invokeMethod<void>('finish', {'ok': false, 'succeeded': 0, 'failed': 1});
  } finally {
    await database.close();
  }
}
