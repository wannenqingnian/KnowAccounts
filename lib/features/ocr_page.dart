import 'money_privacy.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../automation/capture_bridge.dart';
import '../automation/auto_bookkeeping.dart';
import '../domain/models.dart';
import '../core/security/source_privacy.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/refund_matcher.dart';
import 'transaction_editor.dart';
import 'refund_review.dart';
import '../ocr/ocr_service.dart';
import 'manage_page.dart' show showError;
import 'smart_input.dart';
import 'widgets.dart';

final ocrFilePickerProvider = Provider<FilePicker>(
  (ref) => FilePicker.platform,
);

Future<void> showOcrPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const OcrPage()));

class OcrPage extends ConsumerStatefulWidget {
  const OcrPage({super.key, this.capture});
  final CapturedScreenshot? capture;
  @override
  ConsumerState<OcrPage> createState() => _OcrPageState();
}

class _OcrPageState extends ConsumerState<OcrPage> {
  bool _ready = false, _checking = true, _busy = false, _cancelled = false;
  double? _progress;
  String _status = '检查模型…';
  String _selectedTier = 'balanced';
  String? _activeTier;
  bool _selectionInitialized = false;
  bool _captureAttempted = false, _captureProcessed = false;
  String? _captureDraftId;
  @override
  void initState() {
    super.initState();
    _refresh().then((_) {
      if (mounted && _ready && widget.capture != null) _capturedImage();
    });
  }

  @override
  void dispose() {
    final capture = widget.capture;
    if (capture != null) {
      File(capture.path).delete().catchError((_) => File(capture.path));
    }
    super.dispose();
  }

  Future<void> _addTile() async {
    try {
      final added = await ref.read(captureBridgeProvider).addTile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(added ? '截图记账磁贴已添加' : '下拉系统快捷设置，点击编辑，将“截图记账”拖入磁贴区。'),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _capturedImage() => _run('正在本地识别截图…', (service) async {
    _captureAttempted = true;
    final capture = widget.capture!;
    final state = ref.read(ledgerProvider);
    final ledger = state.ledgerId;
    final recognition = await service.recognizeDetailed(capture.path);
    final text = recognition.text;
    if (state.ledgerId != ledger) throw const LedgerException('账本已切换，请重新识别');
    var draft = TransactionParser().parse(
      RawTransaction(
        text: sanitizeSourceText(text),
        capturedAt: capture.capturedAt,
        source: TransactionSource.ocr,
      ),
      ledgerId: ledger,
      accounts: state.accounts,
      categories: state.categories,
    );
    draft = await state.repository.applyAutoCorrectionRule(
      draft,
      rules: state.autoCorrectionRules,
    );
    draft = await RefundMatcher.resolve(state.repository, draft);
    if (!recognition.hasClearBody) {
      draft = TransactionDraft(
        raw: draft.raw,
        ledgerId: draft.ledgerId,
        type: draft.type,
        occurredDate: draft.occurredDate,
        amountMinor: draft.amountMinor,
        accountId: draft.accountId,
        categoryId: draft.categoryId,
        relatedTransactionId: draft.relatedTransactionId,
        merchant: draft.merchant,
        note: draft.note,
        tags: draft.tags,
        blocked: draft.blocked,
        evidence: draft.evidence,
        warnings: [...draft.warnings, '文字识别评分不足或缺失，请核对金额、日期与账户'],
        confidence: draft.confidence,
      );
    }
    draft = draft.withConfidence(ocrConfidence(draft, recognition));
    final id = await state.repository.storeDraft(draft, id: _captureDraftId);
    _captureDraftId = id;
    await state.load();
    if (state.ledgerId != ledger) throw const LedgerException('账本已切换，请从待确认箱继续');
    if (canAutoBookkeep(draft, recognition)) {
      final entryId = await state.repository.autoConfirmDraft(
        ledger,
        id,
        TransactionInput(
          type: draft.type,
          amountMinor: draft.amountMinor!,
          accountId: draft.accountId!,
          categoryId: draft.categoryId,
          merchant: draft.merchant,
          tags: draft.tags,
          occurredDate: draft.occurredDate,
        ),
      );
      if (entryId != null) {
        await state.load();
        if (mounted) {
          setState(() {
            _busy = false;
            _captureProcessed = true;
          });
          final messenger = ScaffoldMessenger.of(context);
          final controller = messenger.showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 5),
              content: Text(
                '已自动记账：${draft.merchant} ${visibleMoney(context, draft.amountMinor!)}',
              ),
              action: SnackBarAction(
                label: '撤销',
                onPressed: () async {
                  try {
                    await state.repository.delete(ledger, entryId);
                    await state.load();
                  } catch (e) {
                    if (messenger.mounted) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('撤销失败：$e')),
                      );
                    }
                  }
                },
              ),
            ),
          );
          final timer = Timer(const Duration(seconds: 5), controller.close);
          unawaited(controller.closed.whenComplete(timer.cancel));
          Navigator.of(context).pop();
        }
        return;
      }
      draft = TransactionDraft(
        raw: draft.raw,
        ledgerId: draft.ledgerId,
        type: draft.type,
        occurredDate: draft.occurredDate,
        amountMinor: draft.amountMinor,
        accountId: draft.accountId,
        categoryId: draft.categoryId,
        relatedTransactionId: draft.relatedTransactionId,
        merchant: draft.merchant,
        note: draft.note,
        blocked: draft.blocked,
        evidence: draft.evidence,
        warnings: [...draft.warnings, '疑似已有同日、同商户、同账户、同金额账目，请核对，未自动重复记账'],
        confidence: draft.confidence,
      );
      await state.repository.storeDraft(draft, id: id);
    }
    if (mounted) {
      setState(() => _busy = false);
      if (draft.type == TransactionType.refund &&
          draft.relatedTransactionId == null) {
        await showRefundReview(context, draft: draft, draftId: id);
      } else if (draft.blocked) {
        await showOcrInput(
          context,
          draft.raw.text,
          capture.capturedAt,
          initialDraft: draft,
          draftId: id,
        );
      } else {
        await showTransactionEditor(context, draft: draft, draftId: id);
      }
      if (mounted) {
        setState(
          () => _captureProcessed = !state.pendingDrafts.any((d) => d.id == id),
        );
      }
    }
  });

  Future<void> _refresh() async {
    final installed = await ref.read(ocrServiceProvider).installedTier();
    final ready = installed != null;
    if (mounted) {
      setState(() {
        _ready = ready;
        _activeTier = installed?.id;
        if (!_selectionInitialized) {
          _selectedTier = installed?.id ?? 'balanced';
          _selectionInitialized = true;
        }
        _checking = false;
        _status = ready ? '模型已就绪，可离线识别 · ${installed.name}' : '模型尚未下载';
      });
    }
  }

  Future<void> _run(
    String status,
    Future<void> Function(OcrService) operation,
  ) async {
    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = null;
      _status = status;
    });
    try {
      await operation(ref.read(ocrServiceProvider));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
        if (mounted && _ready && widget.capture != null && !_captureAttempted) {
          await _capturedImage();
        }
      }
    }
  }

  Future<void> _download() => _run(
    '正在下载模型…',
    (service) => service.download(
      tierId: _selectedTier,
      cancelled: () => _cancelled,
      onProgress: (received, total) {
        if (mounted) setState(() => _progress = received / total);
      },
    ),
  );
  Future<void> _import() => _run('正在验证导入模型…', (service) async {
    final selection = await ref
        .read(ocrFilePickerProvider)
        .pickFiles(
          allowMultiple: true,
          type: FileType.custom,
          allowedExtensions: ['onnx'],
        );
    if (selection == null) return;
    final files = <String, File>{};
    for (final file in selection.files) {
      if (file.path == null || files.containsKey(file.name)) {
        throw const LedgerException('模型文件无法读取或重复，请重新选择');
      }
      files[file.name] = File(file.path!);
    }
    await service.importFiles(files, tierId: _selectedTier);
  });
  Future<void> _image() => _run('选择图片…', (service) async {
    final state = ref.read(ledgerProvider);
    final ledger = state.ledgerId;
    final selection = await ref
        .read(ocrFilePickerProvider)
        .pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
    if (selection == null) return;
    final file = selection.files.single;
    if (file.path == null || file.size > 20 * 1024 * 1024) {
      throw const LedgerException('请选择20MB以内的PNG/JPG/WebP图片');
    }
    final capturedAt = DateTime.now();
    if (mounted) setState(() => _status = '正在本地识别图片…');
    final text = await service.recognize(file.path!);
    if (state.ledgerId != ledger) throw const LedgerException('账本已切换，请重新识别');
    if (mounted) {
      // Recognition and the image picker never post a transaction. The edited
      // recognized text is persisted only after generating a draft.
      setState(() {
        _busy = false;
        _status = '识别完成，请核对文字';
      });
      await showOcrInput(context, text, capturedAt);
    }
  });
  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除OCR模型？'),
        content: const Text('释放模型占用空间。账本和已有草稿会保留，下次识别需要重新下载或导入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除模型'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run('正在删除模型…', (service) => service.remove());
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(ocrServiceProvider);
    final disabled = _busy || _checking;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.capture == null ? 'OCR模型与图片导入' : '截图记账'),
          automaticallyImplyLeading: !_busy,
        ),
        body: widget.capture != null && _ready
            ? ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('已收到截图'),
                        const SizedBox(height: 12),
                        Text(_status),
                        if (_busy)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: LinearProgressIndicator(),
                          ),
                        const Text('字段完整、识别清晰时自动记账；缺失、歧义或疑似重复时进入核对页。'),
                        const SizedBox(height: 12),
                        if (!_busy)
                          FilledButton(
                            onPressed: disabled || _captureProcessed
                                ? null
                                : _capturedImage,
                            child: Text(
                              _captureProcessed ? '该截图已处理' : '重新识别这张截图',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (service.supported) ...[
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '下拉快捷设置 · 截图记账',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '在支付成功页面下拉快捷设置，点击“截图记账”。每次由系统请求屏幕捕获授权，截取一张图片后停止，并自动识别。字段完整且无明显歧义时自动保存；不确定或疑似重复时打开核对表单。受保护页面可能无法截图。',
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: disabled ? null : _addTile,
                            icon: const Icon(Icons.add_box_outlined),
                            label: const Text('添加截图记账磁贴'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (widget.capture != null) ...[
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('已收到截图'),
                          Text(
                            '账本：${ref.watch(ledgerProvider).ledgers[ref.watch(ledgerProvider).ledgerId] ?? "当前账本"}',
                          ),
                          const Text('模型就绪后可识别。截图仅临时保存在设备上，离开此页面后删除。'),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: disabled || !_ready || _captureProcessed
                                ? null
                                : _capturedImage,
                            child: Text(
                              _captureProcessed
                                  ? '该截图已处理'
                                  : _captureAttempted
                                  ? '重新识别这张截图'
                                  : '识别这张截图',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '飞桨 PP-OCR 模型',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '检测和识别模型不包含在安装包中，由你主动下载。下载后离线识别，图片和文字不会上传。旧版 Tesseract 模型不兼容，需要重新下载。',
                        ),
                        const SizedBox(height: 12),
                        Text(_status, key: const ValueKey('ocr_model_status')),
                        if (_busy || _checking)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: LinearProgressIndicator(value: _progress),
                          ),
                        if (!service.supported)
                          const Text('当前版本截图识别支持Android；其他平台后续接入。'),
                        const SizedBox(height: 20),
                        DropdownButtonFormField<String>(
                          key: ValueKey('ocr_tier_$_selectedTier'),
                          initialValue: _selectedTier,
                          isExpanded: true,
                          itemHeight: null,
                          decoration: const InputDecoration(labelText: '模型档位'),
                          items: [
                            for (final t in service.tiers)
                              DropdownMenuItem(
                                value: t.id,
                                child: Text(
                                  '${t.name} · ${(t.bytes / 1024 / 1024).toStringAsFixed(1)}MB',
                                ),
                              ),
                          ],
                          onChanged: disabled
                              ? null
                              : (id) => setState(() => _selectedTier = id!),
                        ),
                        const SizedBox(height: 8),
                        Text(service.tier(_selectedTier).description),
                        if (_ready && _activeTier != _selectedTier)
                          const Text('当前仍使用已安装档位。下载或导入新档位并验证成功后才切换。'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  disabled ||
                                      (_ready && _activeTier == _selectedTier)
                                  ? null
                                  : _download,
                              icon: const Icon(Icons.download_outlined),
                              label: Text(
                                '下载模型 · ${(service.tier(_selectedTier).bytes / 1024 / 1024).toStringAsFixed(1)}MB',
                              ),
                            ),
                            OutlinedButton(
                              onPressed: disabled ? null : _import,
                              child: const Text('从文件导入模型'),
                            ),
                            if (_ready)
                              TextButton(
                                onPressed: disabled ? null : _remove,
                                child: const Text('删除模型'),
                              ),
                            if (_busy && _status.startsWith('正在下载'))
                              TextButton(
                                onPressed: () =>
                                    setState(() => _cancelled = true),
                                child: const Text('取消下载'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: disabled
                              ? null
                              : () => showLicensePage(
                                  context: context,
                                  applicationName: '知账',
                                ),
                          child: const Text('开源许可'),
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('手动下载地址与模型版本'),
                          children: [
                            const Text(
                              '按所选档位下载下面的文件，再点击“从文件导入模型”。仅接受指定版本，验证失败不会替换原模型。',
                            ),
                            for (final model
                                in service.tier(_selectedTier).models)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: SelectableText(
                                  '${model.fileName}\n${model.url}',
                                ),
                              ),
                            const Text(
                              '模型：PaddleOCR PP-OCRv6，RapidOCR 转换的 ONNX 文件；Apache-2.0 许可。',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '选择一笔账单截图',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '可识别PNG、JPG和WebP中的付款详情、订单和小票。请核对实付金额、账户和日期；多笔交易请先裁剪成单笔。',
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const ValueKey('ocr_pick_image'),
                          onPressed: disabled || !_ready || !service.supported
                              ? null
                              : _image,
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('选择截图并识别'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
