import '../../domain/models.dart';
import '../../ocr/ocr_recognition.dart';
import '../parser/transaction_parser.dart';
import 'confidence_calibration.dart';
import 'confidence_models.dart';

class ConfidenceContext {
  const ConfidenceContext({
    this.sourceKind = '',
    this.modelVersion = '',
    this.completed,
    this.ocrRecognition,
    this.calibrationProfile,
  });

  final String sourceKind;
  final String modelVersion;
  final bool? completed;
  final OcrRecognition? ocrRecognition;
  final ConfidenceCalibrationProfile? calibrationProfile;
}

class ConfidenceEngine {
  const ConfidenceEngine();

  static const version = 'confidence-rule-v2';
  static const highThreshold = .90;
  static const manualThreshold = .55;

  /// Shared source/evidence score used by family-card evidence merging. It is
  /// intentionally deterministic and retains the existing 0-100 storage
  /// contract while moving the policy into the unified engine.
  static int evidenceScore({
    required String sourceKind,
    required bool hasOrderHash,
    required int? amountMinor,
    required String merchant,
    required bool hasCardOrAccount,
    bool hasConflict = false,
  }) {
    if (hasConflict) return 40;
    var score = switch (sourceKind) {
      'accessibility' => 45,
      'ocr' => 40,
      'bankNotice' => 40,
      'notification' => 35,
      _ => 25,
    };
    if (hasOrderHash) score += 25;
    if (amountMinor != null && amountMinor > 0) score += 15;
    if (merchant.trim().isNotEmpty) score += 10;
    if (hasCardOrAccount) score += 5;
    return score.clamp(0, 100);
  }

  TransactionConfidence evaluate(
    TransactionDraft draft, {
    ConfidenceContext context = const ConfidenceContext(),
  }) {
    final warnings = draft.warnings.join('\n');
    bool warns(RegExp pattern) => pattern.hasMatch(warnings);
    final fields = <String, FieldConfidence>{};

    fields['amount'] = _field(
      draft.amountMinor != null && draft.amountMinor! > 0
          ? warns(RegExp(r'金额.*(?:不一致|多个|未确定|核对|修正)'))
                ? .45
                : draft.evidence.containsKey('amount')
                ? .98
                : .82
          : 0,
      draft.amountMinor != null && draft.amountMinor! > 0
          ? warns(RegExp(r'金额.*(?:不一致|多个|未确定|核对|修正)'))
                ? '金额存在冲突或经过不确定修正'
                : '已确定唯一正金额'
          : '未确定有效金额',
    );

    final repeatedTitle = _repeatedMerchant(draft, context.ocrRecognition);
    fields['merchant'] = _field(
      draft.merchant.trim().isEmpty
          ? 0
          : warns(RegExp(r'商户候选不一致|出现多个商户|商户信息异常'))
          ? .40
          : warns(RegExp(r'商户取自账单标题'))
          ? repeatedTitle
                ? .91
                : .68
          : draft.evidence.containsKey('merchant')
          ? .97
          : .82,
      draft.merchant.trim().isEmpty
          ? '未确定商户或对方'
          : repeatedTitle
          ? '账单标题中的商户重复出现'
          : '已解析商户或对方',
    );

    fields['account'] = _field(
      draft.accountId == null
          ? 0
          : warns(RegExp(r'账户.*(?:不一致|变化|归档)|多个可能账户|只识别|未确定实际扣款'))
          ? .45
          : draft.evidence.containsKey('account')
          ? .97
          : .84,
      draft.accountId == null ? '未确定账户' : '已匹配唯一账户',
    );

    final explicitTime =
        draft.evidence.containsKey('date') ||
        draft.evidence.containsKey('time');
    final futureTime = draft.occurredDate.isAfter(
      DateTime(
        draft.raw.capturedAt.year,
        draft.raw.capturedAt.month,
        draft.raw.capturedAt.day,
        draft.raw.capturedAt.hour,
        draft.raw.capturedAt.minute,
        draft.raw.capturedAt.second,
      ),
    );
    fields['time'] = _field(
      futureTime
          ? .20
          : warns(RegExp(r'日期.*(?:不一致|无效|多个|缺失|未提供|推测|修正)|未识别日期|多个时间'))
          ? .45
          : explicitTime
          ? .96
          : .72,
      futureTime
          ? '交易时间晚于采集时间'
          : explicitTime
          ? '已取得账单日期或时间证据'
          : '仅使用采集时间',
    );

    fields['completion'] = _field(
      context.completed == true
          ? .99
          : context.completed == false
          ? .05
          : draft.raw.source == TransactionSource.text ||
                draft.raw.source == TransactionSource.speech
          ? .70
          : .35,
      context.completed == true
          ? '来源明确表示交易已完成'
          : context.completed == false
          ? '来源未证明交易已完成'
          : '当前入口没有独立完成状态',
    );

    fields['category'] = _field(
      draft.categoryId == null
          ? 0
          : warns(RegExp(r'分类.*(?:未确定|不适用|变化)'))
          ? .45
          : draft.evidence.containsKey('category') ||
                draft.evidence.containsKey('auto_correction')
          ? .94
          : .82,
      draft.categoryId == null ? '未确定分类' : '已匹配分类',
    );

    fields['direction'] = _field(
      ![TransactionType.expense, TransactionType.income].contains(draft.type)
          ? .35
          : warns(RegExp(r'收支方向|核对收支|同时出现收入和支出|转账|红包'))
          ? .40
          : .94,
      [TransactionType.expense, TransactionType.income].contains(draft.type)
          ? '已确定普通收入或支出方向'
          : '复杂交易类型必须人工核对',
    );

    fields['source'] = _sourceField(draft, context);

    const weights = <String, double>{
      'amount': .21,
      'merchant': .13,
      'account': .17,
      'time': .12,
      'completion': .17,
      'category': .06,
      'direction': .08,
      'source': .06,
    };
    var overall = fields.entries.fold<double>(
      0,
      (sum, item) => sum + item.value.score * weights[item.key]!,
    );
    final reasons = <String>[];
    final acceptableTitleWarning = draft.warnings.every(
      (warning) => warning == '商户取自账单标题，请核对' && repeatedTitle,
    );
    if (draft.blocked) {
      overall = overall.clamp(0, .39).toDouble();
      reasons.add('解析器已阻止自动处理');
    }
    if (draft.warnings.isNotEmpty && !acceptableTitleWarning) {
      overall = overall.clamp(0, .84).toDouble();
      reasons.add('存在需要人工处理的字段警告');
    }
    if (![
      TransactionType.expense,
      TransactionType.income,
    ].contains(draft.type)) {
      overall = overall.clamp(0, .54).toDouble();
      reasons.add('退款、转账及其他复杂类型不自动入账');
    }
    if (draft.raw.source == TransactionSource.text ||
        draft.raw.source == TransactionSource.speech ||
        draft.raw.source == TransactionSource.import) {
      overall = overall.clamp(0, .89).toDouble();
      reasons.add('当前入口保留用户确认步骤');
    }
    final critical = [
      fields['amount']!,
      fields['merchant']!,
      fields['account']!,
      fields['time']!,
      fields['completion']!,
      fields['category']!,
      fields['direction']!,
      fields['source']!,
    ];
    final sourceKind = _calibrationSource(draft, context);
    final profile = context.calibrationProfile;
    final activeProfile =
        profile != null &&
            profile.passesSafetyGate &&
            profile.matches(
              sourceKind: sourceKind,
              modelVersion: context.modelVersion,
            )
        ? profile
        : null;
    final thresholds =
        activeProfile?.thresholds ??
        const ConfidenceThresholds(
          autoPost: highThreshold,
          criticalField: .85,
          manualField: manualThreshold,
        );
    final hasManualField = critical.any(
      (field) => field.score < thresholds.manualField,
    );
    final allHigh = critical.every(
      (field) => field.score >= thresholds.criticalField,
    );
    final decision = draft.blocked || hasManualField
        ? ConfidenceDecision.manual
        : overall >= thresholds.autoPost &&
              allHigh &&
              (draft.warnings.isEmpty || acceptableTitleWarning)
        ? ConfidenceDecision.autoPost
        : ConfidenceDecision.review;
    if (activeProfile != null) {
      reasons.add('已应用${activeProfile.version}脱敏样本校准参数');
    } else if (profile != null) {
      reasons.add('校准配置未通过安全门槛或与当前来源不匹配，已忽略');
    }
    reasons.add(switch (decision) {
      ConfidenceDecision.autoPost => '关键字段均达到高置信门槛',
      ConfidenceDecision.review => '字段可用，但未达到自动入账门槛',
      ConfidenceDecision.manual => '至少一个关键字段置信度过低',
    });
    return TransactionConfidence(
      engineVersion: version,
      source: _sourceLabel(draft, context),
      modelVersion: context.modelVersion,
      overall: overall,
      decision: decision,
      fields: Map.unmodifiable(fields),
      reasons: List.unmodifiable(reasons),
      calibrated: activeProfile != null,
      calibrationVersion: activeProfile?.version ?? '',
      thresholds: thresholds.toJson(),
    );
  }

  FieldConfidence _sourceField(
    TransactionDraft draft,
    ConfidenceContext context,
  ) {
    if (draft.raw.source == TransactionSource.ocr) {
      final recognition = context.ocrRecognition;
      if (recognition == null || recognition.bodyLines.isEmpty) {
        return _field(.35, 'OCR缺少逐行评分，不能自动入账');
      }
      if (!recognition.hasClearBody) {
        return _field(.45, 'OCR正文存在低分或无效文字行');
      }
      return _field(.94, 'OCR正文完整，原始评分仅作为文字质量证据');
    }
    return switch (context.sourceKind) {
      'accessibility' => _field(.96, '无障碍支付页面结构来源'),
      'notification' => _field(.94, '白名单支付通知来源'),
      'bankNotice' => _field(.94, '白名单银行通知来源'),
      'screenshot' => _field(.35, '快捷截图缺少逐行OCR评分'),
      _ => switch (draft.raw.source) {
        TransactionSource.speech => _field(.72, '本地语音识别结果'),
        TransactionSource.text => _field(.82, '用户主动输入'),
        TransactionSource.import => _field(.90, '结构化账单导入'),
        TransactionSource.notification => _field(.88, '通知来源未细分'),
        TransactionSource.ocr => _field(.35, 'OCR来源缺少质量信息'),
      },
    };
  }

  static FieldConfidence _field(double score, String reason) =>
      FieldConfidence(score: score.clamp(0, 1).toDouble(), reasons: [reason]);

  static bool _repeatedMerchant(
    TransactionDraft draft,
    OcrRecognition? recognition,
  ) {
    if (recognition == null || draft.merchant.trim().isEmpty) return false;
    String compact(String value) => value.replaceAll(RegExp(r'\s+'), '');
    final merchant = compact(draft.merchant);
    return recognition.bodyLines
            .where((line) => compact(line.text) == merchant)
            .length >=
        2;
  }

  static String _sourceLabel(
    TransactionDraft draft,
    ConfidenceContext context,
  ) => context.sourceKind.isEmpty
      ? draft.raw.source.name
      : '${draft.raw.source.name}/${context.sourceKind}';

  static String _calibrationSource(
    TransactionDraft draft,
    ConfidenceContext context,
  ) => context.sourceKind.isEmpty ? draft.raw.source.name : context.sourceKind;
}
