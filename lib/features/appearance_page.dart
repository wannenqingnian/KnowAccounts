import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../domain/appearance.dart';
import 'action_form.dart' show showError;
import 'widgets.dart';

Future<void> showAppearancePage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const AppearancePage()));

class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  static const _seeds = <int>[
    0xFF1D8C73,
    0xFF2563EB,
    0xFF7C3AED,
    0xFFD1495B,
    0xFFDB7C26,
    0xFF374151,
  ];
  static const _backgrounds = <int>[
    0xFFF7F8F2,
    0xFFF5F7FA,
    0xFFFFF8F1,
    0xFFF8F4FC,
    0xFFF2F8F7,
    0xFFFFFFFF,
  ];

  late AppearanceSettings _value;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _value = ref.read(ledgerProvider).appearance;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(ledgerProvider).setAppearance(_value);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('外观设置已应用')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    await Clipboard.setData(ClipboardData(text: _value.shareCode()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('主题分享码已复制')));
    }
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final source = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入主题'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 7,
          decoration: const InputDecoration(hintText: '粘贴 ZHI-THEME-1 分享码'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (source == null) return;
    try {
      final value = AppearanceSettings.decode(source);
      setState(() => _value = value);
      await ref.read(ledgerProvider).setAppearance(value);
    } catch (_) {
      if (mounted) showError(context, const FormatException('主题分享码无效'));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('外观与主题'),
      actions: [
        TextButton(onPressed: _saving ? null : _save, child: const Text('应用')),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '实时预览',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Icon(Icons.restaurant_outlined)),
                title: Text('午餐'),
                subtitle: Text('示例账户 · 今日 12:30:08'),
                trailing: Text('-¥28.00'),
              ),
              FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.add),
                label: const Text('示例按钮'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _title('明暗模式'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'system', label: Text('跟随系统')),
            ButtonSegment(value: 'light', label: Text('浅色')),
            ButtonSegment(value: 'dark', label: Text('深色')),
          ],
          selected: {_value.brightness},
          onSelectionChanged: (values) => setState(
            () => _value = _value.copyWith(brightness: values.single),
          ),
        ),
        const SizedBox(height: 18),
        _title('主题色'),
        _colorPicker(
          values: _seeds,
          selected: _value.seedColor,
          onSelected: (value) =>
              setState(() => _value = _value.copyWith(seedColor: value)),
        ),
        const SizedBox(height: 18),
        _title('收支颜色'),
        RadioGroup<String>(
          groupValue: _value.transactionPalette,
          onChanged: (value) => setState(
            () => _value = _value.copyWith(transactionPalette: value),
          ),
          child: const Column(
            children: [
              RadioListTile<String>(
                value: 'expenseRed',
                title: Text('支出红 · 收入绿'),
                subtitle: Text('− 支出使用红色，＋收入使用绿色'),
              ),
              RadioListTile<String>(
                value: 'expenseGreen',
                title: Text('支出绿 · 收入红'),
                subtitle: Text('− 支出使用绿色，＋收入使用红色'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _title('页面背景'),
        _colorPicker(
          values: _backgrounds,
          selected: _value.backgroundColor,
          onSelected: (value) =>
              setState(() => _value = _value.copyWith(backgroundColor: value)),
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          initialValue: _value.font,
          decoration: const InputDecoration(labelText: '字体'),
          items: const [
            DropdownMenuItem(value: 'system', child: Text('系统字体')),
            DropdownMenuItem(value: 'serif', child: Text('衬线字体')),
            DropdownMenuItem(value: 'monospace', child: Text('等宽字体')),
          ],
          onChanged: (value) =>
              setState(() => _value = _value.copyWith(font: value ?? 'system')),
        ),
        const SizedBox(height: 14),
        _title('字号 ${(100 * _value.fontScale).round()}%'),
        Slider(
          value: _value.fontScale,
          min: .8,
          max: 1.4,
          divisions: 6,
          label: '${(100 * _value.fontScale).round()}%',
          onChanged: (value) =>
              setState(() => _value = _value.copyWith(fontScale: value)),
        ),
        const SizedBox(height: 10),
        _title('图标与圆角风格'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'outlined', label: Text('线性')),
            ButtonSegment(value: 'filled', label: Text('填充')),
            ButtonSegment(value: 'sharp', label: Text('直角')),
          ],
          selected: {_value.iconStyle},
          onSelectionChanged: (values) => setState(
            () => _value = _value.copyWith(iconStyle: values.single),
          ),
        ),
        const SizedBox(height: 20),
        OverflowBar(
          spacing: 10,
          overflowSpacing: 8,
          alignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('复制分享码'),
            ),
            OutlinedButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.content_paste),
              label: const Text('导入主题'),
            ),
          ],
        ),
        TextButton(
          onPressed: () => setState(() => _value = const AppearanceSettings()),
          child: const Text('恢复默认外观'),
        ),
      ],
    ),
  );

  Widget _title(String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
  );

  Widget _colorPicker({
    required List<int> values,
    required int selected,
    required ValueChanged<int> onSelected,
  }) => Wrap(
    spacing: 12,
    runSpacing: 10,
    children: [
      for (final value in values)
        InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => onSelected(value),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Color(value),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected == value
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).colorScheme.outlineVariant,
                width: selected == value ? 3 : 1,
              ),
            ),
            child: selected == value
                ? Icon(
                    Icons.check,
                    color:
                        ThemeData.estimateBrightnessForColor(Color(value)) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                  )
                : null,
          ),
        ),
    ],
  );
}
