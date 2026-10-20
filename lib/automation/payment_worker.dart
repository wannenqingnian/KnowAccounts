import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import '../core/database/app_database.dart';
import '../data/ledger_repository.dart';
import 'automation_bridge.dart';
import 'payment_capture_parser.dart';
import 'payment_capture_processor.dart';
import 'payment_confirmation.dart';
import '../transaction/confidence/confidence_models.dart';
import '../transaction/confidence/confidence_profile_bundle.dart';

Future<void> _trace(String code, [PaymentCapture? capture, int? count]) async {
  try {
    await AutomationBridge.channel.invokeMethod('workerTrace', {
      'code': code,
      if (capture != null) ...{
        'app': capture.packageName,
        'source': capture.kind,
        'id': capture.id,
      },
      'count': ?count,
    });
  } catch (_) {
    /* Diagnostics must not interrupt bookkeeping. */
  }
}

Future<void> runPaymentAutomationWorker({
  Future<AppDatabase> Function()? openDatabase,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase? database;
  var ok = false;
  var code = 'processing_error';
  try {
    database = await (openDatabase ?? AppDatabase.open)();
    final repository = LedgerRepository(database);
    await repository.initialize();
    await _trace('worker_ready');
    final confirmation = await AutomationBridge.channel
        .invokeMapMethod<String, dynamic>('takeConfirmation');
    if (confirmation != null &&
        await AutomationBridge.channel.invokeMethod<bool>(
              'authorizeConfirmation',
              {'nonce': confirmation['nonce']},
            ) ==
            true) {
      final result = await confirmPayment(repository, confirmation);
      await AutomationBridge.channel.invokeMethod('confirmationResult', {
        'nonce': confirmation['nonce'],
        'ok': result.ok,
        'message': result.message,
        'duplicate': result.duplicate,
      });
    }
    final processor = PaymentCaptureProcessor(
      repository,
      calibrationProfiles: await ConfidenceProfileBundle.loadBundled(),
    );
    for (var n = 0; n < 100; n++) {
      final data = await AutomationBridge.channel
          .invokeMapMethod<String, dynamic>('take');
      if (data == null) break;
      final capture = PaymentCapture.fromJson(data);
      final authorized = await AutomationBridge.channel.invokeMethod<bool>(
        'authorize',
        {'id': capture.id},
      );
      if (authorized != true) {
        await _trace('worker_revoked', capture);
        continue;
      }
      await _trace('worker_take', capture);
      final outcome = await processor.process(capture);
      final confidence = await repository.draftConfidence('auto-${capture.id}');
      if (confidence != null) {
        await _trace(
          switch (confidence.decision) {
            ConfidenceDecision.autoPost => 'confidence_high',
            ConfidenceDecision.review => 'confidence_review',
            ConfidenceDecision.manual => 'confidence_low',
          },
          capture,
          confidence.percent,
        );
      }
      final preview = outcome == 'pending'
          ? await paymentPreview(repository, capture)
          : null;
      if (preview != null) {
        if (preview['amount'] == '') await _trace('amount_missing', capture);
        if (preview['accountId'] == null || preview['accountId'] == '') {
          await _trace('account_missing', capture);
        }
        if (preview['categoryId'] == null || preview['categoryId'] == '') {
          await _trace('category_missing', capture);
        }
        if (preview['peer'] == true) await _trace('peer_review', capture);
        if (preview['warning'] != '') await _trace('warning_review', capture);
      }
      await AutomationBridge.channel.invokeMethod('ack', {
        'id': capture.id,
        'kind': capture.kind,
        'outcome': outcome,
        'preview': ?preview,
      });
    }
    ok = true;
  } catch (error) {
    code = error is MissingPluginException
        ? 'plugin_unavailable'
        : error is FormatException
        ? 'invalid_capture'
        : error is SqliteException
        ? 'database_error'
        : 'processing_error';
    // Keep native capture queued for explicit retry; never log financial text.
  } finally {
    try {
      if (database != null) await database.close();
    } catch (_) {
      ok = false;
    }
    try {
      await AutomationBridge.channel.invokeMethod('finish', {
        'ok': ok,
        'code': code,
      });
    } catch (_) {
      /* Engine already stopped. */
    }
  }
}
