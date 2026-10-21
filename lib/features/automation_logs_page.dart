import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide DiagnosticLevel;
import 'package:flutter/services.dart' hide DiagnosticLevel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../automation/automation_bridge.dart';
import '../automation/automation_diagnostics.dart';
import '../automation/payment_quality.dart';
import '../core/logging/app_logger.dart';
import 'action_form.dart';

DiagnosticLevel _appLevel(AppLogLevel level) => switch (level) {
  AppLogLevel.info => DiagnosticLevel.normal,
  AppLogLevel.success => DiagnosticLevel.success,
  AppLogLevel.warning => DiagnosticLevel.warning,
  AppLogLevel.error || AppLogLevel.fatal => DiagnosticLevel.error,
};

String _appArea(String area) => switch (area) {
  'startup' => '系统',
  'database' => '数据库',
  'transaction' => '手动记账',
  'flutter' => '界面',
  'background' => '后台任务',
  _ => '应用',
};

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

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.quality});

  final PaymentQuality quality;

  @override
  Widget build(BuildContext context) {
    final color = quality.score >= 85
        ? Colors.green.shade700
        : quality.score >= 70
        ? Colors.orange.shade800
        : Theme.of(context).colorScheme.error;
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${quality.score}',
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok
        ? Colors.green.shade700
        : Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check : Icons.close, size: 11, color: color),
          const SizedBox(width: 2),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

class _QualitySummary extends StatelessWidget {
  const _QualitySummary({
    required this.events,
    required this.onlyLow,
    required this.onToggle,
  });

  final List<DiagnosticEvent> events;
  final bool onlyLow;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final qualities = events
        .map((event) => event.quality)
        .whereType<PaymentQuality>()
        .toList();
    if (qualities.isEmpty) return const SizedBox.shrink();
    final average =
        qualities.fold<int>(0, (sum, quality) => sum + quality.score) ~/
        qualities.length;
    final low = qualities.where((quality) => quality.needsReview).length;
    final color = average >= 95
        ? Colors.green.shade700
        : average >= 85
        ? Theme.of(context).colorScheme.primary
        : average >= 70
        ? Colors.orange.shade800
        : Theme.of(context).colorScheme.error;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: average / 100,
                    strokeWidth: 5,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.15),
                  ),
                  Center(
                    child: Text(
                      '$average',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '识别质量',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '最近 ${qualities.length} 次 · 平均 $average 分'
                    '${low > 0 ? ' · $low 次建议复核' : ' · 无需复核'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              key: const ValueKey('qualityFilter'),
              onPressed: onToggle,
              child: Text(onlyLow ? '查看全部' : '只看低分'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticSummary extends StatelessWidget {
  const _DiagnosticSummary({required this.events, required this.appEvents});

  final List<DiagnosticEvent> events;
  final List<AppLogEntry> appEvents;

  @override
  Widget build(BuildContext context) {
    int count(DiagnosticLevel level) =>
        events
            .where((event) => event.explanation.level == level)
            .fold(0, (sum, event) => sum + event.repeats) +
        appEvents.where((event) => _appLevel(event.level) == level).length;
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
    final latestAppProblem = appEvents
        .where(
          (event) =>
              _appLevel(event.level) == DiagnosticLevel.error ||
              _appLevel(event.level) == DiagnosticLevel.warning,
        )
        .firstOrNull;
    final appProblemIsLatest =
        latestAppProblem != null &&
        (latestProblem == null ||
            latestAppProblem.time.millisecondsSinceEpoch > latestProblem.time);
    final latestProblemLabel = appProblemIsLatest
        ? latestAppProblem.message
        : latestProblem?.label;
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
              latestProblemLabel == null
                  ? '所有诊断记录均未发现需处理的问题。'
                  : '最近问题：$latestProblemLabel',
            ),
          ),
          if (!appProblemIsLatest && latestProblem != null) ...[
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

class _PaymentRecordCard extends StatelessWidget {
  const _PaymentRecordCard({required this.record});

  final PaymentLogRecord record;

  @override
  Widget build(BuildContext context) {
    final color = _diagnosticColor(context, record.level);
    final time = DateTime.fromMillisecondsSinceEpoch(
      record.time,
    ).toLocal().toIso8601String().replaceFirst('T', ' ');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: record.quality != null
            ? _QualityBadge(quality: record.quality!)
            : Icon(_diagnosticIcon(record.level), color: color),
        title: Row(
          children: [
            Expanded(
              child: Text(
                record.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (record.outcome == PaymentLogOutcome.duplicate)
              _SummaryPill(
                icon: Icons.content_copy,
                label: '查重',
                color: Colors.orange.shade800,
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            Text(
              record.subtitle.isEmpty ? '识别信息未记录（可在上方开启敏感日志）' : record.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              record.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 3),
            Text(
              '$time · ${record.decisive.origin}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        children: [
          const Divider(height: 14),
          _DiagnosticDetail(
            icon: Icons.fact_check_outlined,
            title: '结果',
            text: record.reason,
            color: color,
          ),
          _DiagnosticDetail(
            icon: Icons.lightbulb_outline,
            title: '下一步',
            text: record.action,
            color: Colors.orange.shade800,
          ),
          if (record.quality != null)
            _DiagnosticDetail(
              icon: Icons.speed_outlined,
              title: '识别质量',
              text:
                  '${record.quality!.score} 分 · ${record.quality!.grade}\n'
                  '${record.quality!.summary}',
              color: record.quality!.needsReview
                  ? Colors.orange.shade800
                  : Colors.green.shade700,
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(
              '技术过程 · ${record.events.length} 条',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            children: [
              for (final event in record.events)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    '${DateTime.fromMillisecondsSinceEpoch(event.time).toLocal().toIso8601String().replaceFirst("T", " ")}'
                    ' · ${event.label}'
                    '${event.recognizedText.isEmpty ? "" : " · ${event.recognizedText}"}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: record.events
                        .map((event) => event.detailedText())
                        .join(),
                  ),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已复制这笔记录的技术日志')));
                }
              },
              icon: const Icon(Icons.copy, size: 17),
              label: const Text('复制技术日志'),
            ),
          ),
        ],
      ),
    );
  }
}

class AutomationLogsPage extends ConsumerStatefulWidget {
  const AutomationLogsPage({
    super.key,
    this.appLogger,
    this.liveRefresh = true,
  });
  final AppLogger? appLogger;
  final bool liveRefresh;
  @override
  ConsumerState<AutomationLogsPage> createState() => _AutomationLogsPageState();
}

class _AutomationLogsPageState extends ConsumerState<AutomationLogsPage>
    with WidgetsBindingObserver {
  AppLogger get _appLogger => widget.appLogger ?? AppLogger.instance;
  AutomationDiagnostics? _report;
  List<AppLogEntry> _appEvents = [];
  Timer? _timer;
  bool _busy = false,
      _foreground = true,
      _wechatOnly = false,
      _qualityOnly = false,
      _attentionOnly = false,
      _sortAscending = false;
  String _source = 'all', _level = 'all', _view = 'records';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    if (widget.liveRefresh) {
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_foreground && !_busy) _refresh();
      });
    }
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
      final appEvents = await _appLogger.read();
      if (mounted) {
        setState(() {
          _report = AutomationDiagnostics.fromJson(data);
          _appEvents = appEvents;
        });
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
      final bytes = Uint8List.fromList(utf8.encode(await _fullText()));
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

  Future<String> _fullText() async {
    final appText = await _appLogger.text();
    final records = PaymentLogRecord.fromEvents(
      _report?.events ?? const <DiagnosticEvent>[],
    );
    final recordText = records.isEmpty
        ? '没有可展示的自动记账记录。'
        : records.map((record) => record.exportText).join('\n\n');
    return '--- 自动记账记录（按交易聚合） ---\n'
        '$recordText\n\n'
        '${_report?.text() ?? ''}\n\n'
        '--- Flutter 应用日志 ---\n$appText';
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
      if (_qualityOnly && event.quality?.needsReview != true) return false;
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
    final appEvents = (_source == 'all' || _source == 'app') && !_wechatOnly
        ? _appEvents.where((event) {
            final level = _appLevel(event.level);
            return switch (_level) {
              'error' => level == DiagnosticLevel.error,
              'warning' => level == DiagnosticLevel.warning,
              'success' => level == DiagnosticLevel.success,
              'process' => level == DiagnosticLevel.normal,
              _ => true,
            };
          }).toList()
        : <AppLogEntry>[];
    appEvents.sort(
      (a, b) =>
          _sortAscending ? a.time.compareTo(b.time) : b.time.compareTo(a.time),
    );

    if (_sortAscending) {
      events.sort((a, b) => a.time.compareTo(b.time));
    } else {
      events.sort((a, b) => b.time.compareTo(a.time));
    }
    final records = PaymentLogRecord.fromEvents(
      report?.events ?? const <DiagnosticEvent>[],
    );
    final visibleRecords = records
        .where(
          (record) =>
              (!_attentionOnly || record.needsAttention) &&
              (!_qualityOnly || record.quality?.needsReview == true),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断中心'),
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
                  await Clipboard.setData(
                    ClipboardData(text: await _fullText()),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('日志已复制')));
                  }
                }
              } else if (value == 'clear') {
                await _action(() async {
                  await ref.read(automationBridgeProvider).clearDiagnostics();
                  await _appLogger.clear();
                });
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('复制完整日志')),
              PopupMenuItem(value: 'export', child: Text('导出日志文件')),
              PopupMenuItem(value: 'clear', child: Text('清空全部诊断日志')),
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
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        secondary: Icon(
                          report.enabled
                              ? Icons.receipt_long_outlined
                              : Icons.receipt_long,
                        ),
                        title: Text(report.enabled ? '日志记录已开启' : '日志记录已关闭'),
                        subtitle: const Text(
                          '自动记账保留48小时/400条 · 应用日志保留14天/1000条',
                        ),
                        value: report.enabled,
                        onChanged: (value) => _action(
                          () => ref
                              .read(automationBridgeProvider)
                              .setDiagnosticsEnabled(value),
                        ),
                      ),
                      const Divider(height: 1),
                      SwitchListTile.adaptive(
                        key: const ValueKey('sensitiveLogging'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        secondary: const Icon(Icons.privacy_tip_outlined),
                        title: const Text('允许日志记录敏感信息'),
                        subtitle: const Text('开启后日志会保存金额、商户和付款账户；关闭会立即脱敏已有日志'),
                        value: report.state['sensitiveLogging'] == true,
                        onChanged:
                            report.enabled ||
                                report.state['sensitiveLogging'] == true
                            ? (value) => _action(
                                () => ref
                                    .read(automationBridgeProvider)
                                    .setDiagnosticsSensitive(value),
                              )
                            : null,
                      ),
                    ],
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
                _DiagnosticSummary(
                  events: report.events,
                  appEvents: _appEvents,
                ),
                _QualitySummary(
                  events: report.events,
                  onlyLow: _qualityOnly,
                  onToggle: () => setState(() => _qualityOnly = !_qualityOnly),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      key: const ValueKey('logViewToggle'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: 'records',
                          icon: Icon(Icons.receipt_long_outlined, size: 17),
                          label: Text('自动记账记录'),
                        ),
                        ButtonSegment(
                          value: 'technical',
                          icon: Icon(Icons.code, size: 17),
                          label: Text('技术日志'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (value) =>
                          setState(() => _view = value.first),
                    ),
                  ),
                ),
                if (appEvents.isNotEmpty)
                  ExpansionTile(
                    initiallyExpanded: _source == 'app',
                    leading: const Icon(Icons.apps_outlined),
                    title: Text('应用日志 · ${appEvents.length} 条'),
                    subtitle: const Text('启动、数据库、界面与手动记账'),
                    children: [
                      for (final event in appEvents)
                        Card(
                          margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                          child: ExpansionTile(
                            leading: Icon(
                              _diagnosticIcon(_appLevel(event.level)),
                              color: _diagnosticColor(
                                context,
                                _appLevel(event.level),
                              ),
                            ),
                            title: Text(
                              event.message,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${event.time.toIso8601String().replaceFirst("T", " ")} · ${_appArea(event.area)}',
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              16,
                              2,
                              16,
                              10,
                            ),
                            children: [
                              _DiagnosticDetail(
                                icon: Icons.code,
                                title: '技术信息',
                                text: [
                                  '事件码 ${event.code}',
                                  if (event.correlationId.isNotEmpty)
                                    '关联编号 ${event.correlationId}',
                                  if (event.technical.isNotEmpty)
                                    event.technical,
                                ].join(' · '),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                if (_view == 'records') ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
                    child: Row(
                      children: [
                        FilterChip(
                          key: const ValueKey('attentionOnly'),
                          selected: _attentionOnly,
                          onSelected: (value) =>
                              setState(() => _attentionOnly = value),
                          label: Text(
                            _attentionOnly
                                ? '只看需处理 · ${visibleRecords.length}'
                                : '只看需处理',
                          ),
                          avatar: const Icon(Icons.priority_high, size: 17),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '每张卡片代表一笔采集，技术细节可展开',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visibleRecords.isEmpty
                        ? Center(
                            child: Text(
                              _attentionOnly ? '暂无需要处理的记录。' : '还没有可展示的自动记账记录。',
                            ),
                          )
                        : ListView.builder(
                            itemCount: visibleRecords.length,
                            itemBuilder: (_, index) => _PaymentRecordCard(
                              record: visibleRecords[index],
                            ),
                          ),
                  ),
                ],
                if (_view == 'technical') ...[
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
                              'app': '应用日志',
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
                            onSelected: (value) =>
                                setState(() => _level = value),
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
                              final quality = event.quality;
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
                                if (event.repeats > 1)
                                  '合并重复 ${event.repeats} 次',
                              ].join(' · ');
                              return Card(
                                margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
                                clipBehavior: Clip.antiAlias,
                                child: ExpansionTile(
                                  leading: quality != null
                                      ? _QualityBadge(quality: quality)
                                      : Icon(
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 3),
                                      Text(
                                        explanation.result,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (event.recognizedText.isNotEmpty) ...[
                                        const SizedBox(height: 3),
                                        Text(
                                          event.recognizedText,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                      if (quality != null) ...[
                                        const SizedBox(height: 5),
                                        Wrap(
                                          spacing: 5,
                                          runSpacing: 4,
                                          children: [
                                            _QualityChip(
                                              label: '${quality.score} 分',
                                              ok: !quality.needsReview,
                                            ),
                                            if (quality.amountMatch != null)
                                              _QualityChip(
                                                label: '金额',
                                                ok: quality.amountMatch!,
                                              ),
                                            if (quality.categoryMatch != null)
                                              _QualityChip(
                                                label: '分类',
                                                ok: quality.categoryMatch!,
                                              ),
                                            if (quality.accountMatch != null)
                                              _QualityChip(
                                                label: '账户',
                                                ok: quality.accountMatch!,
                                              ),
                                            if (quality.remarkSimilarity !=
                                                null)
                                              _QualityChip(
                                                label:
                                                    '备注 ${(quality.remarkSimilarity! * 100).round()}%',
                                                ok:
                                                    quality.remarkSimilarity! >=
                                                    0.8,
                                              ),
                                          ],
                                        ),
                                      ],
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
                                    if (quality != null)
                                      _DiagnosticDetail(
                                        icon: Icons.speed_outlined,
                                        title: '识别质量对照',
                                        text:
                                            '${quality.score} 分 · ${quality.grade}'
                                            '\n${quality.summary}',
                                        color: quality.needsReview
                                            ? Colors.orange.shade800
                                            : Colors.green.shade700,
                                      ),
                                    if (explanation.action.isNotEmpty)
                                      _DiagnosticDetail(
                                        icon: Icons.lightbulb_outline,
                                        title: '建议操作',
                                        text: explanation.action,
                                        color: Colors.orange.shade800,
                                      ),
                                    if (event.recognizedText.isNotEmpty)
                                      _DiagnosticDetail(
                                        icon: Icons.visibility_outlined,
                                        title:
                                            report.state['sensitiveLogging'] ==
                                                true
                                            ? '识别摘要（含敏感信息）'
                                            : '脱敏识别摘要',
                                        text: event.recognizedText,
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
              ],
            ),
    );
  }
}
