import 'money_privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../core/security/source_privacy.dart';
import '../domain/money.dart';
import '../domain/models.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/confidence/confidence_engine.dart';
import '../speech/speech_input.dart';
import '../speech/speech_model_service.dart';
import 'speech_model_page.dart';
import 'transaction_editor.dart';
import 'widgets.dart';

Future<void> showSmartInput(BuildContext context) => _showInput(context);
Future<void> showVoiceInput(BuildContext context) =>
    _showInput(context, source: TransactionSource.speech, listenOnOpen: true);
Future<void> showOcrInput(
  BuildContext context,
  String text,
  DateTime capturedAt, {
  TransactionDraft? initialDraft,
  String? draftId,
}) => _showInput(
  context,
  text: text,
  source: TransactionSource.ocr,
  capturedAt: capturedAt,
  initialDraft: initialDraft,
  draftId: draftId,
);
Future<void> _showInput(
  BuildContext context, {
  String? text,
  TransactionSource source = TransactionSource.text,
  DateTime? capturedAt,
  TransactionDraft? initialDraft,
  String? draftId,
  bool listenOnOpen = false,
}) async {
  final draft = await showModalBottomSheet<(TransactionDraft, String)>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SmartInputSheet(
      initialText: text,
      source: source,
      capturedAt: capturedAt,
      initialDraft: initialDraft,
      draftId: draftId,
      listenOnOpen: listenOnOpen,
    ),
  );
  if (draft != null && context.mounted) {
    await showTransactionEditor(context, draft: draft.$1, draftId: draft.$2);
  }
}

class SmartInputSheet extends ConsumerStatefulWidget {
  const SmartInputSheet({
    super.key,
    this.initialText,
    this.source = TransactionSource.text,
    this.capturedAt,
    this.initialDraft,
    this.draftId,
    this.listenOnOpen = false,
  });
  final String? initialText;
  final TransactionSource source;
  final DateTime? capturedAt;
  final TransactionDraft? initialDraft;
  final String? draftId;
  final bool listenOnOpen;
  @override
  ConsumerState<SmartInputSheet> createState() => _SmartInputSheetState();
}

class _SmartInputSheetState extends ConsumerState<SmartInputSheet> {
  final _text = TextEditingController();
  TransactionDraft? _draft;
  String? _draftId;
  bool _busy = false;
  bool _listening = false;
  bool _startingSpeech = false;
  bool _recognizingSpeech = false;
  bool _localSpeech = false;
  String? _error;
  late TransactionSource _source;
  bool get _speechActive => _listening || _startingSpeech || _recognizingSpeech;
  @override
  void initState() {
    super.initState();
    _text.text = widget.initialText ?? '';
    _draft = widget.initialDraft;
    _draftId = widget.draftId;
    _source = widget.source;
    if (widget.listenOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
    }
  }

  @override
  void dispose() {
    if (_listening && _localSpeech) {
      const SpeechInput().stop();
    }
    _text.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    final state = ref.read(ledgerProvider);
    var parsed = TransactionParser().parse(
      RawTransaction(
        text: sanitizeSourceText(_text.text),
        capturedAt: widget.capturedAt ?? DateTime.now(),
        source: _source,
      ),
      ledgerId: state.ledgerId,
      accounts: state.accounts,
      categories: state.categories,
    );
    setState(() {
      _busy = true;
      _error = null;
      _draft = null;
    });
    FocusScope.of(context).unfocus();
    try {
      parsed = await state.repository.applyAutoCorrectionRule(
        parsed,
        rules: state.autoCorrectionRules,
      );
      parsed = parsed.withConfidence(
        const ConfidenceEngine().evaluate(
          parsed,
          context: ConfidenceContext(
            modelVersion: _source == TransactionSource.speech
                ? 'SenseVoiceSmall/local'
                : 'manual-input-v1',
          ),
        ),
      );
      final id = await state.repository.storeDraft(parsed, id: _draftId);
      await state.load();
      if (mounted) {
        setState(() {
          _draft = parsed;
          _draftId = id;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is LedgerException ? e.message : '草稿保存失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _listen() async {
    if (_busy || _listening || _startingSpeech || _recognizingSpeech) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _startingSpeech = true;
      _recognizingSpeech = false;
      _listening = false;
      _localSpeech = false;
      _error = null;
      _draft = null;
    });
    try {
      final speechModels = ref.read(speechModelServiceProvider);
      // Do not hash the 239 MB model on the voice hot path. Installation has
      // already verified it; native loading now runs while audio is captured.
      final modelPath = await speechModels.recordingPath();
      String recognized;
      if (modelPath == null) {
        if (!mounted) return;
        setState(() => _startingSpeech = false);
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要语音模型'),
            content: const Text(
              '本地语音模型未下载。可以前往下载，也可以临时使用手机系统语音服务（是否联网取决于手机设置）。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'system'),
                child: const Text('系统语音'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'download'),
                child: const Text('下载模型'),
              ),
            ],
          ),
        );
        if (!mounted || choice == null) return;
        if (choice == 'download') {
          await showSpeechModelPage(context);
          return;
        }
        setState(() {
          _listening = true;
          _localSpeech = false;
        });
        recognized = await const SpeechInput().listenSystem();
      } else {
        if (!mounted) return;
        setState(() {
          _startingSpeech = false;
          _listening = true;
          _localSpeech = true;
        });
        recognized = await const SpeechInput().listen(modelPath);
      }
      if (!mounted) return;
      _text.text = recognized;
      _text.selection = TextSelection.collapsed(offset: recognized.length);
      _source = TransactionSource.speech;
      setState(() {
        _startingSpeech = false;
        _recognizingSpeech = false;
        _listening = false;
        _localSpeech = false;
      });
      await _parse();
    } on PlatformException catch (e) {
      if (!mounted) return;
      final message = switch (e.code) {
        'cancelled' => '已取消语音输入',
        'unavailable' => '手机未安装可用的系统语音识别服务',
        'busy' => '语音识别正在进行，请稍后',
        _ => e.message ?? '语音识别失败，请重试',
      };
      setState(() {
        _listening = false;
        _startingSpeech = false;
        _recognizingSpeech = false;
        _localSpeech = false;
        _error = message;
      });
    } on SpeechInputException catch (e) {
      if (mounted) {
        setState(() {
          _listening = false;
          _startingSpeech = false;
          _recognizingSpeech = false;
          _localSpeech = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _listening = false;
          _startingSpeech = false;
          _recognizingSpeech = false;
          _localSpeech = false;
          _error = '语音识别失败，请重试';
        });
      }
    }
  }

  Future<void> _stopListening() async {
    if (!_listening || !_localSpeech) return;
    setState(() {
      _listening = false;
      _recognizingSpeech = true;
    });
    try {
      final stopped = await const SpeechInput().stop();
      if (!stopped && mounted) {
        setState(() {
          _recognizingSpeech = false;
          _error = '录音尚未启动，请稍后重试';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _recognizingSpeech = false;
          _error = e.message ?? '无法结束录音，请重试';
        });
      }
    }
  }

  Future<void> _manual(TransactionDraft draft) async {
    final state = ref.read(ledgerProvider);
    var manual = TransactionDraft(
      raw: draft.raw,
      ledgerId: state.ledgerId,
      type: TransactionType.expense,
      occurredDate: draft.occurredDate,
      merchant: draft.merchant,
      tags: draft.tags,
      warnings: const ['自动识别存在歧义，请手动核对收支类型、金额、账户和分类'],
      evidence: const {},
    );
    manual = manual.withConfidence(
      const ConfidenceEngine().evaluate(
        manual,
        context: ConfidenceContext(
          modelVersion: _source == TransactionSource.speech
              ? 'SenseVoiceSmall/local'
              : 'manual-input-v1',
        ),
      ),
    );
    setState(() => _busy = true);
    try {
      final id = await state.repository.storeDraft(manual, id: _draftId);
      await state.load();
      if (mounted) Navigator.pop(context, (manual, id));
    } catch (e) {
      if (mounted) setState(() => _error = '草稿保存失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final draft = _draft;
    final stale = draft != null && draft.ledgerId != state.ledgerId;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .92,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.source == TransactionSource.ocr
                      ? '核对识别文字'
                      : widget.source == TransactionSource.speech
                      ? '语音记账'
                      : '一句话记账',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.source == TransactionSource.ocr
                      ? '请核对图片识别文字，可删去无关金额并补充账户。生成草稿后再确认入账；长编号仅保留尾号。'
                      : widget.source == TransactionSource.speech
                      ? '点击后立即录音，并在后台同时加载本地模型。默认会一直录音，直到你点击“完成录音”；也可在语音模型设置中开启静音自动结束或自定义最长时长。录音不保存、不上传。'
                      : '识别后自动保存到待确认，核对保存后才计入账本。卡号等长编号仅保留尾号。',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('smart_input_text'),
                  controller: _text,
                  autofocus: true,
                  enabled: !_busy && !_speechActive,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 4000,
                  decoration: InputDecoration(
                    labelText: '账单描述',
                    hintText: '昨天滴滴四十二块五，支付宝付的',
                    suffixIcon: IconButton(
                      key: const ValueKey('voice_input_button'),
                      tooltip: _recognizingSpeech
                          ? '正在识别录音'
                          : _startingSpeech
                          ? '正在启动麦克风'
                          : _listening
                          ? '完成录音'
                          : '语音输入',
                      onPressed: _busy || _startingSpeech || _recognizingSpeech
                          ? null
                          : _listening
                          ? (_localSpeech ? _stopListening : null)
                          : _listen,
                      icon: Icon(
                        _recognizingSpeech || _startingSpeech
                            ? Icons.hourglass_top
                            : _listening
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none,
                      ),
                    ),
                  ),
                  onChanged: (_) => setState(() => _draft = null),
                ),
                const SizedBox(height: 8),
                OverflowBar(
                  spacing: 10,
                  overflowSpacing: 8,
                  alignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          state.loading ||
                              _busy ||
                              _startingSpeech ||
                              _recognizingSpeech
                          ? null
                          : _listening
                          ? (_localSpeech ? _stopListening : null)
                          : _listen,
                      icon: Icon(
                        _recognizingSpeech || _startingSpeech
                            ? Icons.hourglass_top
                            : _listening
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none,
                      ),
                      label: Text(
                        _recognizingSpeech
                            ? '正在识别…'
                            : _startingSpeech
                            ? '正在启动…'
                            : _listening
                            ? '完成录音'
                            : '说一句',
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: state.loading || _busy || _speechActive
                          ? null
                          : _parse,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: Text(
                        widget.source == TransactionSource.ocr
                            ? '生成账单草稿'
                            : '识别账单',
                      ),
                    ),
                  ],
                ),
                if (_listening)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('正在录音，请说：昨天午饭三十八元，微信支付。说完点击“完成录音”。'),
                  ),
                if (_startingSpeech)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('正在启动麦克风…'),
                  ),
                if (_recognizingSpeech)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('录音已完成，正在本机识别并生成文字…'),
                  ),
                if (_busy || _startingSpeech || _recognizingSpeech)
                  const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (draft != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    '识别草稿 · ${typeLabel(draft.type)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final field in [
                    (
                      '金额',
                      draft.amountMinor == null
                          ? '未确定'
                          : visibleMoney(context, draft.amountMinor!),
                    ),
                    ('商户', draft.merchant.isEmpty ? '未确定' : draft.merchant),
                    (
                      '账户',
                      state.accounts
                              .where((a) => a.id == draft.accountId)
                              .firstOrNull
                              ?.name ??
                          '请选择',
                    ),
                    (
                      '分类',
                      state.categories
                              .where((c) => c.id == draft.categoryId)
                              .firstOrNull
                              ?.name ??
                          '请选择',
                    ),
                    ('日期', dateKey(draft.occurredDate)),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          SizedBox(width: 52, child: Text(field.$1)),
                          Expanded(child: Text(field.$2)),
                        ],
                      ),
                    ),
                  if (draft.evidence.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('查看识别依据'),
                      children: [
                        for (final e in draft.evidence.entries)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '${const {'amount': '金额', 'merchant': '商户', 'account': '账户', 'category': '分类', 'date': '日期', 'type': '类型'}[e.key]}：${e.value}',
                              ),
                            ),
                          ),
                      ],
                    ),
                  for (final warning in draft.warnings)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('• $warning'),
                    ),
                  if (widget.source == TransactionSource.ocr && draft.blocked)
                    OutlinedButton.icon(
                      onPressed: stale || state.loading || _busy
                          ? null
                          : () => _manual(draft),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('手动填写单笔收支'),
                    ),
                  if (stale) const Text('账本已切换，请重新识别'),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          draft.blocked || stale || state.loading || _busy
                          ? null
                          : () => Navigator.pop(context, (draft, _draftId!)),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('核对并记账'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
