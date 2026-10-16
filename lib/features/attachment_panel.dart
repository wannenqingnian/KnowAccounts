import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../domain/attachment.dart';
import '../domain/models.dart';
import 'action_form.dart';

Future<void> viewAttachment(BuildContext context, ImageAttachment image) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(image.name),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: InteractiveViewer(
            minScale: .5,
            maxScale: 5,
            child: Center(
              child: Image.memory(
                image.data,
                cacheWidth: 1600,
                errorBuilder: (_, _, _) => const Text('图片无法显示'),
              ),
            ),
          ),
        ),
      ),
    );

class AttachmentPanel extends StatefulWidget {
  const AttachmentPanel({
    super.key,
    required this.images,
    this.onChanged,
    this.loading = false,
  });
  final List<ImageAttachment> images;
  final ValueChanged<List<ImageAttachment>>? onChanged;
  final bool loading;
  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  bool _picking = false;
  List<ImageAttachment> get images => widget.images;
  ValueChanged<List<ImageAttachment>>? get onChanged => widget.onChanged;
  bool get loading => widget.loading || _picking;
  Future<void> _pick(BuildContext context) async {
    if (_picking ||
        widget.loading ||
        images.length >= maxAttachments ||
        onChanged == null) {
      return;
    }
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
        withData: false,
      );
      if (result == null) return;
      final file = result.files.single;
      if (file.size > maxAttachmentBytes || file.path == null) {
        throw const LedgerException('每张图片不能超过4 MB');
      }
      final source = File(file.path!);
      if (await source.length() > maxAttachmentBytes) {
        throw const LedgerException('每张图片不能超过4 MB');
      }
      final data = await source.readAsBytes();
      final image = ImageAttachment(
        id: const Uuid().v4(),
        name: file.name.length > 120 ? file.name.substring(0, 120) : file.name,
        data: data,
      );
      image.validate();
      // Inspect encoded dimensions before allocating a decoded image.
      final buffer = await ui.ImmutableBuffer.fromUint8List(data);
      ui.ImageDescriptor? descriptor;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width > 10000 ||
            descriptor.height > 10000 ||
            descriptor.width * descriptor.height > 24000000) {
          throw const LedgerException('图片尺寸过大');
        }
      } finally {
        descriptor?.dispose();
        buffer.dispose();
      }
      if (context.mounted) onChanged?.call([...images, image]);
    } catch (e) {
      if (context.mounted) {
        showError(
          context,
          e is LedgerException
              ? e
              : const LedgerException('图片无法读取，请选择PNG或JPEG图片'),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(child: Text('图片附件')),
          if (onChanged != null)
            TextButton.icon(
              onPressed: loading || images.length >= maxAttachments
                  ? null
                  : () => _pick(context),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text('添加图片 ${images.length}/5'),
            ),
        ],
      ),
      if (loading) const LinearProgressIndicator(),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final image in images)
            SizedBox(
              width: 90,
              height: 105,
              child: Column(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => viewAttachment(context, image),
                      child: Image.memory(
                        image.data,
                        width: 90,
                        fit: BoxFit.cover,
                        cacheWidth: 180,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                  if (onChanged != null)
                    SizedBox(
                      height: 30,
                      child: TextButton(
                        onPressed: loading
                            ? null
                            : () => onChanged!(
                                [...images]
                                  ..removeWhere((a) => a.id == image.id),
                              ),
                        child: const Text('移除'),
                      ),
                    )
                  else
                    Text(
                      image.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
        ],
      ),
      if (onChanged != null)
        const Text(
          '每笔最多5张，每张不超过4 MB；保存账目后生效。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
    ],
  );
}
