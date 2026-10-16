import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide DiagnosticLevel;
import 'package:flutter/services.dart' hide DiagnosticLevel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../automation/automation_bridge.dart';
import '../automation/automation_diagnostics.dart';
import 'action_form.dart';

Color _diagnosticColor(BuildContext context, DiagnosticLevel level) =>
    switch (level) {
      DiagnosticLevel.success => Colors.green.shade700,
      DiagnosticLevel.progress => Theme.of(context).colorScheme.primary,
      DiagnosticLevel.warning => Colors.orange.shade800,
      DiagnosticLevel.error => Theme.of(context).colorScheme.error,
      DiagnosticLevel.normal => Theme.of(context).colorScheme.onSurfaceVariant,
    };

IconData _diagnosticIcon(DiagnosticLevel level) => switch (level) {
  DiagnosticLevel.success => Icons.check_circle_outline,
  DiagnosticLevel.progress => Icons.sync,
  DiagnosticLevel.warning => Icons.info_outline,
  DiagnosticLevel.error => Icons.error_outline,
  DiagnosticLevel.normal => Icons.notes_outlined,
};

class _DiagnosticDetail extends StatelessWidget {
  const _DiagnosticDetail({
    required this.icon,
    required this.title,
    required this.text,
    this.color,
  });

  final IconData icon;
  final String title;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: Theme.of(context).textTheme.bodyMedium,
              children: [
                TextSpan(
                  text: '$title\n',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: text),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _DiagnosticSummary extends StatelessWidget {
  const _DiagnosticSummary({required this.events});

  final List<DiagnosticEvent> events;

  @override
  Widget build(BuildContext context) {
    int count(DiagnosticLevel level) => events
        .where((event) => event.explanation.level == level)
        .fold(0, (sum, event) => sum + event.repeats);
    final errors = count(DiagnosticLevel.error);
    final warnings = count(DiagnosticLevel.warning);
    final successes = count(DiagnosticLevel.success);
    final processing = count(DiagnosticLevel.progress);
    final color = errors > 0
        ? Theme.of(context).colorScheme.error
        : warnings > 0
        ? Colors.orange.shade800
        : Colors.green.shade700;
    final title = errors > 0
        ? '$errors 条错误需要处理'
        : warnings > 0
        ? '$warnings 条问题需要留意'
        : '近期没有需要处理的问题';
    final latestProblem = events
        .where(
          (event) =>
              event.explanation.level == DiagnosticLevel.error ||
              event.explanation.level == DiagnosticLevel.warning,
        )
        .firstOrNull;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: color.withValues(alpha: 0.08),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        leading: Icon(
          errors > 0
              ? Icons.error_outline
              : warnings > 0
              ? Icons.info_outline
              : Icons.check_circle_outline,
          color: color,
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '错误 $errors · 警告 $warnings · 成功 $successes · 处理中 $processing',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        children: [
          const Divider(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              latestProblem == null
                  ? '所有诊断记录均未发现需处理的问题。'
                  : '最近问题：${latestProblem.label}',
            ),
          ),
          if (latestProblem != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                latestProblem.explanation.action.isEmpty
                    ? latestProblem.explanation.result
                    : latestProblem.explanation.action,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _SummaryPill(
                icon: Icons.error_outline,
                label: '错误 $errors',
                color: Theme.of(context).colorScheme.error,
              ),
              _SummaryPill(
                icon: Icons.info_outline,
                label: '警告 $warnings',
                color: Colors.orange.shade800,
              ),
              _SummaryPill(
                icon: Icons.check_circle_outline,
                label: '成功 $successes',
                color: Colors.green.shade700,
              ),
              _SummaryPill(
                icon: Icons.sync,
                label: '处理中 $processing',
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    ),
  );
}

class _LogFilterMenu extends StatelessWidget {
  const _LogFilterMenu({
    super.key,
    required this.icon,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final IconData icon;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    initialValue: value,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final option in options.entries)
        CheckedPopupMenuItem<String>(
          value: option.key,
          checked: option.key == value,
          child: Text(option.value),
        ),
    ],
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              options[value]!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 19),
        ],
      ),
    ),
  );
}

class AutomationLogsPage extends ConsumerStatefulWidget {
  const AutomationLogsPage({super.key});
  @override
  ConsumerState<AutomationLogsPage> createState() => _AutomationLogsPageState();
}

class _AutomationLogsPageState extends ConsumerState<AutomationLogsPage>
    with WidgetsBindingObserver {
  AutomationDiagnostics? _report;
  Timer? _timer;
  bool _busy = false, _foreground = true, _wechatOnly = false, _sortAscending = false;
  String _source = 'all', _level = 'all';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_foreground && !_busy) _refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !_busy) _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final data = await ref.read(automationBridgeProvider).diagnostics();
      if (mounted) {
        setState(() => _report = AutomationDiagnostics.fromJson(data));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _busy = false;
    }
    if (mounted) await _refresh();
  }

  Future<void> _export() async {
    await _refresh();
    if (_report == null) return;
    await _action(() async {
      final bytes = Uint8List.fromList(utf8.encode(_report!.text()));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出诊断日志',
        fileName: '知账-诊断日志-${DateTime.now().millisecondsSinceEpoch}.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: bytes,
      );
      if (path != null &&
          (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (path != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日志已导出')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final scopedEvents =
        report?.events
            .where(
              (e) =>
                  (!_wechatOnly ||
                      e.app == 'com.tencent.mm' ||
                      e.app.isEmpty) &&
                  (_source == 'all' || e.source == _source),
            )
            .toList() ??
        [];
    final events = scopedEvents.where((event) {
      final level = event.explanation.level;
      return switch (_level) {
        'error' => level == DiagnosticLevel.error,
        'warning' => level == DiagnosticLevel.warning,
        'success' => level == DiagnosticLevel.success,
        'process' =>
          event.isInternalNoise ||
              level == DiagnosticLevel.progress ||
              level == DiagnosticLevel.normal,
        'all' => !event.isInternalNoise,
        _ => true,
      };
    }).toList();

    if (_sortAscending) {
      events.sort((a, b) => a.time.compareTo(b.time));
    } else {
      events.sort((a, b) => b.time.compareTo(a.time));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志记录'),
        actions: [
          IconButton(
            tooltip: '刷新日志',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('logActions'),
            onSelected: (value) async {
              if (value == 'export') {
                await _export();
              } else if (value == 'copy') {
                await _refresh();
                if (_report != null) {
                  await Clipboard.setData(ClipboardData(text: _report!.text()));
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('日志已复制')));
                  }
                }
              } else if (value == 'clear') {
                await _action(
                  () => ref.read(automationBridgeProvider).clearDiagnostics(),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('复制完整日志')),
              PopupMenuItem(value: 'export', child: Text('导出日志文件')),
              PopupMenuItem(value: 'clear', child: Text('清空诊断日志')),
            ],
          ),
        ],
      ),
      body: report == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: SwitchListTile.adaptive(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    secondary: Icon(
                      report.enabled
                          ? Icons.receipt_long_outlined
                          : Icons.receipt_long,
                    ),
                    title: Text(report.enabled ? '日志记录已开启' : '日志记录已关闭'),
                    subtitle: const Text('记录全部诊断 · 保留48小时/400条'),
                    value: report.enabled,
                    onChanged: (value) => _action(
                      () => ref
                          .read(automationBridgeProvider)
                          .setDiagnosticsEnabled(value),
                    ),
                  ),
                ),
                ExpansionTile(
                  title: Text(
                    '当前状态 · ${report.version} · Android API ${report.api}',
                  ),
                  children: [
                    SizedBox(
                      height: 200,
                      child: ListView(
                        children: [
                          for (final entry in diagnosticStateLabels.entries)
                            ListTile(
                              dense: true,
                              title: Text(entry.value),
                              trailing: Text(
                                report.state[entry.key] == true ? '是' : '否',
                              ),
                            ),
                          ListTile(
                            dense: true,
                            title: const Text('待处理采集'),
                            trailing: Text('${report.queued}'),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('无障碍扫描节点'),
                            trailing: Text(
                              '${report.accessibility.rootNodeCount} 个',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('无障碍可用文本'),
                            trailing: Text(
                              '${report.accessibility.usableTextCount} 段',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('无障碍窗口应用'),
                            trailing: Text(
                              report.accessibility.windowPackage.isEmpty
                                  ? '无'
                                  : report.accessibility.windowPackage,
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('无障碍页面会话'),
                            trailing: Text(
                              report.accessibility.pageSessionId.isEmpty
                                  ? '无'
                                  : report.accessibility.pageSessionId,
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('OCR 截图状态'),
                            trailing: Text(
                              report.ocr.screenshotSucceeded ? '成功' : '未触发/未成功',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('OCR 识别行数'),
                            trailing: Text(
                              '${report.ocr.recognizedLineCount} 行',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('OCR 金额候选'),
                            trailing: Text(
                              report.ocr.amountCandidateFound ? '已找到' : '未找到',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('OCR 完成状态'),
                            trailing: Text(
                              report.ocr.successMarkerFound ? '已找到' : '未找到',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('OCR 拒绝原因'),
                            trailing: Text(
                              report.ocr.rejectionReason.isEmpty
                                  ? '无'
                                  : (diagnosticLabels[report
                                            .ocr
                                            .rejectionReason] ??
                                        report.ocr.rejectionReason),
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('通知监听状态'),
                            trailing: Text(
                              report.notification.listenerConnected
                                  ? '已连接'
                                  : '未连接',
                            ),
                          ),
                          ListTile(
                            dense: true,
                            title: const Text('通知最近连接'),
                            trailing: Text(
                              report.notification.lastConnectedAt > 0
                                  ? DateTime.fromMillisecondsSinceEpoch(
                                      report.notification.lastConnectedAt,
                                    ).toLocal().toIso8601String().replaceFirst(
                                      'T',
                                      ' ',
                                    )
                                  : '无记录',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                _DiagnosticSummary(events: report.events),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: _LogFilterMenu(
                          key: const ValueKey('sourceFilter'),
                          icon: Icons.source_outlined,
                          value: _wechatOnly ? 'wechat' : _source,
                          options: const {
                            'all': '全部来源',
                            'notification': '通知',
                            'accessibility': '无障碍',
                            'wechat': '微信及后台',
                          },
                          onSelected: (value) => setState(() {
                            _wechatOnly = value == 'wechat';
                            _source = _wechatOnly ? 'all' : value;
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _LogFilterMenu(
                          key: const ValueKey('levelFilter'),
                          icon: Icons.filter_alt_outlined,
                          value: _level,
                          options: const {
                            'all': '全部记录',
                            'error': '错误',
                            'warning': '警告',
                            'success': '成功',
                            'process': '处理中',
                          },
                          onSelected: (value) => setState(() => _level = value),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        key: const ValueKey('sortToggle'),
                        tooltip: _sortAscending
                            ? '当前：时间正序 (最旧在前)，点击切为倒序'
                            : '当前：时间倒序 (最新在前)，点击切为正序',
                        icon: Icon(
                          _sortAscending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _sortAscending = !_sortAscending),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 2, 16, 0),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app_outlined, size: 15),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '默认隐藏内部轮询；选择“处理中”可查看扫描与解析阶段',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: events.isEmpty
                      ? Center(
                          child: Text(
                            report.enabled
                                ? '当前筛选范围内暂无相关日志。'
                                : '日志记录已关闭，可通过上方开关重新开启。',
                          ),
                        )
                      : ListView.builder(
                          itemCount: events.length,
                          itemBuilder: (_, i) {
                            final event = events[i];
                            final explanation = event.explanation;
                            final time = DateTime.fromMillisecondsSinceEpoch(
                              event.time,
                            ).toLocal();
                            final color = _diagnosticColor(
                              context,
                              explanation.level,
                            );
                            final technical = [
                              '事件码 ${event.code}',
                              if (event.reference.isNotEmpty)
                                '追踪编号 ${event.reference}',
                              if (event.count > 0) '计数 ${event.count}',
                              if (event.repeats > 1) '合并重复 ${event.repeats} 次',
                            ].join(' · ');
                            return Card(
                              margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                              clipBehavior: Clip.antiAlias,
                              child: ExpansionTile(
                                leading: Icon(
                                  _diagnosticIcon(explanation.level),
                                  color: color,
                                ),
                                title: Text(
                                  event.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 3),
                                    Text(
                                      explanation.result,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      '${time.toIso8601String().replaceFirst("T", " ")} · ${event.origin}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                                childrenPadding: const EdgeInsets.fromLTRB(
                                  16,
                                  2,
                                  16,
                                  10,
                                ),
                                children: [
                                  const Divider(height: 14),
                                  _DiagnosticDetail(
                                    icon: Icons.fact_check_outlined,
                                    title: '实际结果',
                                    text: explanation.result,
                                    color: color,
                                  ),
                                  if (explanation.action.isNotEmpty)
                                    _DiagnosticDetail(
                                      icon: Icons.lightbulb_outline,
                                      title: '建议操作',
                                      text: explanation.action,
                                      color: Colors.orange.shade800,
                                    ),
                                  _DiagnosticDetail(
                                    icon: Icons.code,
                                    title: '技术信息',
                                    text: technical,
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      onPressed: () async {
                                        await Clipboard.setData(
                                          ClipboardData(
                                            text: event.detailedText(),
                                          ),
                                        );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('已复制本条日志'),
                                            ),
                                          );
                                        }
                                      },
                                      icon: const Icon(Icons.copy, size: 17),
                                      label: const Text('复制本条'),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
