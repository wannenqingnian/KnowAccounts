import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../domain/attachment.dart';
import 'attachment_panel.dart';
import 'action_form.dart';

class AttachmentsPage extends ConsumerStatefulWidget {
  const AttachmentsPage({
    super.key,
    required this.ledger,
    required this.transactionId,
  });
  final String ledger, transactionId;
  @override
  ConsumerState<AttachmentsPage> createState() => _AttachmentsPageState();
}

class _AttachmentsPageState extends ConsumerState<AttachmentsPage> {
  List<ImageAttachment> _images = [];
  bool _loading = true, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final images = await ref
          .read(repositoryProvider)
          .attachments(widget.ledger, widget.transactionId);
      if (mounted) {
        setState(() {
          _images = images;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '附件读取失败，请重新打开');
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(repositoryProvider)
          .replaceAttachments(widget.ledger, widget.transactionId, _images);
      await ref.read(ledgerProvider).load();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('图片附件')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('可添加发票、小票或支付截图；关闭页面不保存修改。'),
          const SizedBox(height: 16),
          if (_error != null) Text(_error!),
          AttachmentPanel(
            images: _images,
            loading: _loading,
            onChanged: _loading || _saving
                ? null
                : (images) => setState(() => _images = images),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _loading || _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存附件'),
          ),
        ],
      ),
    ),
  );
}
