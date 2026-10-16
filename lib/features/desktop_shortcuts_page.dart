import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../automation/notification_shortcuts.dart';
import 'widgets.dart';
import 'action_form.dart' show showError;

Future<void> showDesktopShortcutsPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const DesktopShortcutsPage()));

class DesktopShortcutsPage extends ConsumerStatefulWidget {
  const DesktopShortcutsPage({super.key});

  @override
  ConsumerState<DesktopShortcutsPage> createState() =>
      _DesktopShortcutsPageState();
}

class _DesktopShortcutsPageState extends ConsumerState<DesktopShortcutsPage> {
  Set<String>? _selected;
  bool _supported = true;
  bool _pinWidgetSupported = false;

  Future<void> _load() async {
    final result = await ref
        .read(notificationShortcutsProvider)
        .desktopStatus();
    if (!mounted) return;
    setState(() {
      _supported = result['supported'] != false;
      _pinWidgetSupported = result['pinWidgetSupported'] == true;
      _selected = ((result['actions'] as List?) ?? const ['quick', 'voice'])
          .whereType<String>()
          .where(desktopShortcutActions.containsKey)
          .toSet();
    });
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _save() async {
    try {
      await ref
          .read(notificationShortcutsProvider)
          .configureDesktop(_selected!.toList());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('应用图标长按快捷方式已更新')));
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _pin(String action) async {
    final ok = await ref
        .read(notificationShortcutsProvider)
        .pinDesktopShortcut(action);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已向桌面发送添加请求' : '当前桌面不支持固定快捷方式')),
    );
  }

  Future<void> _pinWidget() async {
    final ok = await ref.read(notificationShortcutsProvider).pinWidget();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已向桌面发送小组件添加请求' : '请长按桌面，从小组件列表添加知账')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('桌面快捷方式与小组件')),
    body: _selected == null
        ? const Center(child: CircularProgressIndicator())
        : !_supported
        ? const EmptyView(title: '当前平台不支持', description: '桌面快捷入口目前仅支持 Android。')
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
            children: [
              Text('长按应用图标', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text('最多选择 4 个常用动作；保存后，长按知账图标即可使用。'),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    for (final entry in desktopShortcutActions.entries)
                      CheckboxListTile(
                        title: Text(entry.value),
                        subtitle: Text('也可单独固定“${entry.value}”到桌面'),
                        value: _selected!.contains(entry.key),
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              if (_selected!.length >= 4) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('系统最多显示 4 个动态快捷方式'),
                                  ),
                                );
                                return;
                              }
                              _selected!.add(entry.key);
                            } else {
                              _selected!.remove(entry.key);
                            }
                          });
                        },
                        secondary: IconButton(
                          tooltip: '添加到桌面',
                          icon: const Icon(Icons.add_to_home_screen),
                          onPressed: () => _pin(entry.key),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存长按快捷方式'),
              ),
              const SizedBox(height: 22),
              Text('快捷记账小组件', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text('在桌面直接打开手动记账、语音、OCR截图和模板记账。'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _pinWidgetSupported ? _pinWidget : null,
                icon: const Icon(Icons.widgets_outlined),
                label: Text(_pinWidgetSupported ? '添加快捷小组件到桌面' : '请从桌面小组件列表添加'),
              ),
            ],
          ),
  );
}
