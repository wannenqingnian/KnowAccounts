import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'data/ledger_repository.dart';
import 'data/budget_repository.dart';
import 'domain/models.dart';
import 'domain/attachment.dart';
import 'domain/appearance.dart';
import 'transaction/parser/transaction_parser.dart';
import 'transaction/transaction_identity.dart';

final repositoryProvider = Provider<LedgerRepository>(
  (ref) => throw UnimplementedError(),
);
final ledgerProvider = ChangeNotifierProvider<LedgerController>(
  (ref) => LedgerController(ref.watch(repositoryProvider)),
);

class LedgerController extends ChangeNotifier {
  LedgerController(this.repository);
  final LedgerRepository repository;
  String ledgerId = 'personal';
  Map<String, String> ledgers = {};
  List<Account> accounts = [];
  List<Account> allAccounts = [];
  List<Category> categories = [];
  List<Category> allCategories = [];
  List<LedgerEntry> entries = [];
  List<PendingDraft> pendingDrafts = [];
  List<AutoCorrectionRule> autoCorrectionRules = [];
  MonthlySummary? summary;
  List<BudgetPeriodSummary> budgets = [];
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  bool loading = true;
  bool amountPrivacy = false;
  AppearanceSettings appearance = const AppearanceSettings();
  String? error;
  int _generation = 0;
  bool _disposed = false;

  Future<void> load() async {
    if (_disposed) return;
    final generation = ++_generation;
    var selectedLedger = ledgerId;
    final selectedMonth = month;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final snapshot = await repository.db.transaction(() async {
        final nextLedgers = await repository.ledgers();
        if (!nextLedgers.containsKey(selectedLedger)) {
          selectedLedger = nextLedgers.keys.first;
        }
        return (
          nextLedgers,
          await repository.accounts(selectedLedger, includeArchived: true),
          await repository.categories(selectedLedger, includeArchived: true),
          await repository.entries(selectedLedger),
          await repository.summary(selectedLedger, selectedMonth),
          await repository.pendingDrafts(selectedLedger),
          await repository.amountPrivacy(),
          await repository.setting('appearance_v1'),
          await repository.autoCorrectionRules(
            selectedLedger,
            onlyApplicable: true,
          ),
          await BudgetRepository(repository.db).periodsForDate(
            selectedLedger,
            DateTime(selectedMonth.year, selectedMonth.month + 1, 0),
          ),
        );
      });
      if (_disposed || generation != _generation) return;
      ledgerId = selectedLedger;
      ledgers = snapshot.$1;
      allAccounts = snapshot.$2;
      allCategories = snapshot.$3;
      accounts = allAccounts.where((a) => !a.archived).toList();
      categories = allCategories.where((c) => !c.archived).toList();
      entries = snapshot.$4;
      summary = snapshot.$5;
      pendingDrafts = snapshot.$6;
      amountPrivacy = snapshot.$7;
      try {
        appearance = AppearanceSettings.decode(snapshot.$8);
      } on FormatException {
        appearance = const AppearanceSettings();
      }
      autoCorrectionRules = snapshot.$9;
      budgets = snapshot.$10;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e is LedgerException ? e.message : '数据读取失败，请重试';
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> selectLedger(String id) async {
    ledgerId = id;
    await load();
  }

  Future<void> changeMonth(int offset) async {
    month = DateTime(month.year, month.month + offset);
    await load();
  }

  Future<void> selectMonth(DateTime value) async {
    month = DateTime(value.year, value.month);
    await load();
  }

  Future<void> save(
    TransactionInput input, {
    String? id,
    String? draftId,
    List<ImageAttachment>? attachments,
    bool allowPossibleDuplicate = false,
  }) async {
    final ledger = ledgerId;
    final draftLedger = draftId == null
        ? null
        : await repository.draftLedger(draftId);
    if (draftId != null) {
      await repository.db.transaction(() async {
        final targetLedger = draftLedger ?? ledger;
        final posted = await repository.confirmDraft(
          targetLedger,
          draftId,
          input,
        );
        if (attachments != null) {
          await repository.replaceAttachments(
            targetLedger,
            posted,
            attachments,
          );
        }
      });
    } else {
      final result = await repository.submitStructuredTransaction(
        ledger,
        input,
        id: id,
        attachments: attachments,
        allowPossibleDuplicate: allowPossibleDuplicate,
        identitySeed: TransactionIdentitySeed(
          source: TransactionEvidenceSource.manual,
          sourceApp: 'smart_ledger.manual',
          captureId: id == null ? '' : 'manual-edit:$id',
          details: const {'入口': '手动表单'},
        ),
      );
      ledgerId = result.ledgerId;
    }
    if (draftLedger != null) ledgerId = draftLedger;
    await load();
  }

  Future<void> setAmountPrivacy(bool enabled) async {
    await repository.setAmountPrivacy(enabled);
    amountPrivacy = enabled;
    notifyListeners();
    await load();
  }

  Future<void> setAppearance(AppearanceSettings value) async {
    await repository.setSetting('appearance_v1', value.encode());
    appearance = value;
    notifyListeners();
  }

  Future<void> delete(String id) async {
    await repository.delete(ledgerId, id);
    await load();
  }

  Future<void> restore(String id) async {
    await repository.restore(ledgerId, id);
    await load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
