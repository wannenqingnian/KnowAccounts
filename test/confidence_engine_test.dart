import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/automation/auto_bookkeeping.dart';
import 'package:smart_ledger/automation/payment_capture_parser.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';
import 'package:smart_ledger/ocr/ocr_recognition.dart';
import 'package:smart_ledger/transaction/confidence/confidence_engine.dart';
import 'package:smart_ledger/transaction/confidence/confidence_models.dart';
import 'package:smart_ledger/transaction/parser/transaction_parser.dart';

void main() {
  late AppDatabase db;
  late LedgerRepository repo;
  late List<Account> accounts;
  late List<Category> categories;
  final capturedAt = DateTime(2026, 10, 5, 12, 6);
  const receipt =
      '支付成功\n商户名称 瑞幸咖啡\n交易金额 38.50元\n支付方式 微信零钱\n支付时间 2026-10-05 12:05:30';

  setUp(() async {
    db = AppDatabase.memory();
    repo = LedgerRepository(db);
    await repo.initialize();
    accounts = await repo.accounts('personal');
    categories = await repo.categories('personal');
  });

  tearDown(() => db.close());

  test('same evidence produces the same versioned high-confidence report', () {
    final capture = PaymentCapture(
      id: 'a' * 64,
      packageName: 'com.tencent.mm',
      kind: 'notification',
      text: receipt,
      capturedAt: capturedAt,
      ledgerId: 'personal',
    );
    final first = PaymentCaptureParser().parse(
      capture,
      accounts,
      categories,
      now: capturedAt,
    );
    final second = PaymentCaptureParser().parse(
      capture,
      accounts,
      categories,
      now: capturedAt,
    );

    expect(first.confidence.toJson(), second.confidence.toJson());
    expect(first.confidence.engineVersion, ConfidenceEngine.version);
    expect(first.confidence.calibrated, isFalse);
    expect(first.confidence.decision, ConfidenceDecision.autoPost);
    expect(first.confidence.fields.keys, {
      'amount',
      'merchant',
      'account',
      'time',
      'completion',
      'category',
      'direction',
      'source',
    });
    expect(first.canAutoSave, isTrue);
  });

  test('confidence snapshot survives pending draft persistence', () async {
    final capture = PaymentCapture(
      id: 'b' * 64,
      packageName: 'com.tencent.mm',
      kind: 'notification',
      text: receipt,
      capturedAt: capturedAt,
      ledgerId: 'personal',
      autoSave: false,
    );
    final parsed = PaymentCaptureParser().parse(
      capture,
      accounts,
      categories,
      now: capturedAt,
    );
    await repo.storeDraft(parsed.draft);
    final stored = (await repo.pendingDrafts('personal')).single.confidence;

    expect(stored, isNotNull);
    expect(stored!.toJson(), parsed.confidence.toJson());
    expect(stored.modelVersion, 'source-profile-v1');
    expect(stored.reasons, isNotEmpty);
  });

  test('OCR engine score is quality evidence, not copied as probability', () {
    const ocrText =
        '精品沙县小吃\n交易详情\n-16.00\n精品沙县小吃\n当前状态 支付成功\n支付方式 零钱\n支付时间 2026年10月03日 12:05:15';
    TransactionDraft draft() => TransactionParser().parse(
      RawTransaction(
        text: ocrText,
        source: TransactionSource.ocr,
        capturedAt: capturedAt,
      ),
      ledgerId: 'personal',
      accounts: accounts,
      categories: categories,
    );

    OcrRecognition recognition(double score) => OcrRecognition(
      ocrText,
      engineVersion: 'ppocr-v6',
      modelVersion: 'PP-OCRv6/small',
      lines: ocrText
          .split('\n')
          .indexed
          .map((line) => OcrTextLine(line.$2, score, line.$1 * 30))
          .toList(),
    );

    final low = ocrConfidence(draft(), recognition(.70));
    final high = ocrConfidence(draft(), recognition(.99));
    expect(low.decision, ConfidenceDecision.manual);
    expect(high.decision, ConfidenceDecision.autoPost);
    expect(high.overall, isNot(.99));
    expect(high.modelVersion, 'PP-OCRv6/small');
  });

  test('speech stays review-only and missing critical fields stay manual', () {
    final completeSpeech = TransactionDraft(
      raw: RawTransaction(
        text: '午餐支出38元微信餐饮',
        source: TransactionSource.speech,
        capturedAt: capturedAt,
      ),
      ledgerId: 'personal',
      type: TransactionType.expense,
      amountMinor: 3800,
      occurredDate: capturedAt,
      accountId: accounts
          .firstWhere((item) => item.kind == AccountKind.wechat)
          .id,
      categoryId: categories
          .firstWhere(
            (item) => item.type == TransactionType.expense && item.name == '餐饮',
          )
          .id,
      merchant: '午餐',
      warnings: const [],
      evidence: const {
        'amount': '38元',
        'merchant': '午餐',
        'account': '微信',
        'category': '餐饮',
        'date': '今天',
      },
    );
    final speech = const ConfidenceEngine().evaluate(
      completeSpeech,
      context: const ConfidenceContext(modelVersion: 'SenseVoiceSmall/local'),
    );
    final missing = const ConfidenceEngine().evaluate(
      TransactionDraft(
        raw: RawTransaction(
          text: '消费',
          source: TransactionSource.text,
          capturedAt: capturedAt,
        ),
        ledgerId: 'personal',
        type: TransactionType.expense,
        occurredDate: capturedAt,
        warnings: ['金额未确定，请在确认表单中填写'],
        evidence: {},
      ),
    );

    expect(speech.decision, ConfidenceDecision.review);
    expect(speech.overall, lessThan(ConfidenceEngine.highThreshold));
    expect(missing.decision, ConfidenceDecision.manual);
    expect(missing.fields['amount']!.score, 0);
  });

  test('family-card evidence uses the same versioned policy owner', () {
    expect(
      ConfidenceEngine.evidenceScore(
        sourceKind: 'accessibility',
        hasOrderHash: true,
        amountMinor: 3850,
        merchant: '瑞幸咖啡',
        hasCardOrAccount: true,
      ),
      100,
    );
    expect(
      ConfidenceEngine.evidenceScore(
        sourceKind: 'notification',
        hasOrderHash: false,
        amountMinor: null,
        merchant: '',
        hasCardOrAccount: false,
        hasConflict: true,
      ),
      40,
    );
  });
}
