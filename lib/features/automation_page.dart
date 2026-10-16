import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../automation/automation_bridge.dart';
import '../automation/payment_apps.dart';
import '../automation/notification_shortcuts.dart';
import '../domain/models.dart';
import 'action_form.dart';

Future<void> showAutomationPage(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const AutomationPage()),
);

class AutomationPage extends ConsumerStatefulWidget {
  const AutomationPage({super.key});
  @override
  ConsumerState<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends ConsumerState<AutomationPage>
    with WidgetsBindingObserver {
  Map<String, dynamic> _status = {};
  Map<String, dynamic> _shortcutStatus = {};
  List<String> _shortcutSelection = [];
  bool _loaded = false,
      _busy = false,
      _enabled = false,
      _enhanced = false,
      _autoSave = true,
      _reviewPopup = true,
      _screenshotFallback = false;
  String _ledger = 'personal';
  Map<String, PaymentRule> _rules = {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh(initial: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh({bool initial = false}) async {
    try {
      final value = await ref.read(automationBridgeProvider).status();
      final shortcuts = await ref.read(notificationShortcutsProvider).status();
      if (!mounted) return;
      setState(() {
        _status = value;
        _shortcutStatus = shortcuts;
        if (initial && shortcuts['actions'] is List) {
          _shortcutSelection = (shortcuts['actions'] as List)
              .whereType<String>()
              .where(shortcutActions.containsKey)
              .take(3)
              .toList();
        }
        if (initial) {
          final cfg = AutomationConfig.fromJson(
            value['config'] is Map ? value['config'] : {},
          );
          _enabled = cfg.enabled;
          _enhanced = cfg.enhanced;
          _autoSave = cfg.autoSave;
          _reviewPopup = cfg.reviewPopup;
          _screenshotFallback = cfg.screenshotFallback;
          _rules = {...cfg.rules};
          final state = ref.read(ledgerProvider);
          _ledger = state.ledgers.containsKey(cfg.ledgerId)
              ? cfg.ledgerId
              : state.ledgerId;
        }
        _loaded = true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  int _todayExpense() {
    final now = DateTime.now();
    var total = 0;
    for (final entry in ref.read(ledgerProvider).entries) {
      final date = entry.occurredDate;
      if (entry.deleted ||
          entry.excludeFromReports ||
          date.year != now.year ||
          date.month != now.month ||
          date.day != now.day) {
        continue;
      }
      if (entry.type == TransactionType.expense) total += entry.amountMinor;
      if (entry.type == TransactionType.refund) total -= entry.amountMinor;
    }
    return total < 0 ? 0 : total;
  }

  Future<void> _toggleShortcut(String action, bool selected) async {
    if (selected && _shortcutSelection.length >= 3) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('通知栏最多显示 3 个快捷按钮，请先取消一个')));
      return;
    }
    if (selected && _shortcutStatus['granted'] != true) {
      final granted = await ref
          .read(notificationShortcutsProvider)
          .requestPermission();
      if (!mounted || !granted) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('需要通知权限才能显示快捷记账入口')));
        }
        return;
      }
      _shortcutStatus = {..._shortcutStatus, 'granted': true};
    }
    setState(() {
      if (selected) {
        _shortcutSelection = [..._shortcutSelection, action];
      } else {
        _shortcutSelection = _shortcutSelection
            .where((v) => v != action)
            .toList();
      }
    });
    try {
      await ref
          .read(notificationShortcutsProvider)
          .configure(_shortcutSelection, _todayExpense(), _ledger);
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<bool> _save({bool notify = false}) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(automationBridgeProvider)
          .configure(
            AutomationConfig(
              enabled: _enabled,
              enhanced: _enhanced,
              autoSave: _autoSave,
              reviewPopup: _reviewPopup,
              screenshotFallback: _screenshotFallback,
              ledgerId: _ledger,
              rules: _rules,
            ),
          );
      await _refresh();
      if (mounted && notify) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('自动记账设置已保存')));
      }
      return true;
    } catch (e) {
      if (mounted) {
        showError(context, e);
        await _refresh(initial: true);
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _permission(bool enhanced) async {
    try {
      if (enhanced) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('无障碍自动记账增强'),
            content: const Text(
              '知账会读取你启用的支付软件页面；页面文字不足且已经下载OCR模型时，会截取当前屏幕的一帧在手机本地识别，处理后立即释放。其他页面内容不保存，不持续录屏、不点击、不支付、不读密码、不上传；可随时关闭。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('前往系统设置'),
              ),
            ],
          ),
        );
        if (yes != true) return;
        if (!await _save()) return;
        await ref.read(automationBridgeProvider).openAccessibility();
      } else {
        if (!await _save()) return;
        await ref.read(automationBridgeProvider).openNotifications();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _rule(PaymentApp app) async {
    final state = ref.read(ledgerProvider);
    final accounts = await state.repository.accounts(_ledger);
    final categories = await state.repository.categories(_ledger);
    if (!mounted) return;
    final rule = _rules[app.packageName] ?? const PaymentRule();
    await actionForm(
      context,
      title: '${app.name}记账设置',
      description:
          '只有你确认该软件固定使用此账户时才设默认付款账户；明确的付款字段优先。分类仅作为缺省支出分类。选择“待确认”更适合混用多张卡的情况。',
      fields: [
        InputSpec(
          'account',
          '默认付款账户',
          initial: rule.accountId ?? '',
          options: {
            '': '未识别时待确认',
            for (final a in accounts) a.id: a.displayName,
          },
        ),
        InputSpec(
          'category',
          '默认支出分类',
          initial: rule.categoryId ?? '',
          options: {
            '': '未识别时待确认',
            for (final c in categories.where(
              (c) => c.type == TransactionType.expense,
            ))
              c.id: c.name,
          },
        ),
      ],
      submit: (v) async {
        setState(
          () => _rules[app.packageName] = PaymentRule(
            enabled: rule.enabled,
            accountId: v['account']!.isEmpty ? null : v['account'],
            categoryId: v['category']!.isEmpty ? null : v['category'],
          ),
        );
        await _save();
      },
    );
  }

  List<String> _missingRequirements() {
    final missing = <String>[];
    if (_enabled && _status['notificationsGranted'] != true) {
      missing.add('通知读取权限');
    }
    if (_enabled && _enhanced && _status['accessibilityGranted'] != true) {
      missing.add('无障碍权限');
    }
    if (_enabled && _reviewPopup && _status['overlayGranted'] != true) {
      missing.add('悬浮窗权限');
    }
    if (_enabled &&
        _enhanced &&
        _screenshotFallback &&
        _status['ocrModelReady'] != true) {
      missing.add('OCR模型');
    }
    if (_shortcutSelection.isNotEmpty && _shortcutStatus['granted'] != true) {
      missing.add('通知显示权限');
    }
    return missing.toSet().toList();
  }

  String _errorLabel() => switch (_status['errorCode']) {
    'plugin_unavailable' => '后台组件未连接',
    'invalid_capture' => '采集格式异常',
    'database_error' => '数据库暂不可用',
    'worker_timeout' => '后台启动或处理超时',
    'worker_start_failed' => '后台引擎启动失败',
    _ => '请重试或重新进入应用',
  };
  String _diagnosis() {
    final cfg = _status['config'] is Map
        ? AutomationConfig.fromJson(_status['config'])
        : const AutomationConfig();
    if (!cfg.enabled) return '自动记账未启用';
    if (!paymentApps.any((app) => cfg.rule(app.packageName).enabled)) {
      return '未启用任何支付软件';
    }
    if (_status['error'] == true) return '后台处理失败：${_errorLabel()}，点击刷新重试';
    final sources = _status['sourceEvents'] is int
        ? _status['sourceEvents'] as int
        : 0;
    if (sources == 0) {
      return '尚未收到启用软件的通知或可读页面。检查系统权限/连接；付款软件可能不发送通知，可打开账单详情使用无障碍增强。';
    }
    final app =
        paymentApps
            .where((a) => a.packageName == _status['lastSource'])
            .firstOrNull
            ?.name ??
        '支付软件';
    final kind = _status['lastKind'] == 'accessibility' ? '无障碍页面' : '通知';
    final reason = switch (_status['lastReason']) {
      'matched' => '已匹配交易',
      'page_session_waiting' => '页面信息正在合并',
      'page_session_matched' => '跨事件页面已匹配',
      'page_session_resumed' => '已切换到最新账单页面',
      'ocr_fallback' => '节点不足，已转截图OCR',
      'ocr_event_coalesced' => 'OCR后将立即读取最新页面',
      'chat_filtered' => '聊天通知已忽略',
      'empty_content' => '未提供可读取文字',
      'too_long' => '内容超出识别范围',
      'read_failed' => '页面读取暂时失败',
      _ => '内容未匹配明确付款账单',
    };
    return '已收到 $sources 次来源事件\n最近：$app · $kind · $reason${_status['workerRunning'] == true ? '\n后台正在处理' : ''}\n匹配记录请查看下方计数及管理→待确认账单。';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('自动记账'),
          actions: [
            TextButton(
              onPressed: !_loaded || _busy || _status['supported'] != true
                  ? null
                  : () => _save(notify: true),
              child: const Text('保存设置'),
            ),
          ],
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : _status['supported'] != true
            ? const Center(child: Text('自动采集目前仅支持Android'))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_shortcutStatus['supported'] == true)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.notifications_active_outlined),
                                SizedBox(width: 10),
                                Text(
                                  '通知栏快捷记账',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '选择最多 3 项常驻通知栏；顺序按选择先后排列。功能在本机运行。',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final item in shortcutActions.entries)
                                  FilterChip(
                                    avatar: Icon(switch (item.key) {
                                      'capture' =>
                                        Icons.document_scanner_outlined,
                                      'voice' => Icons.mic_none,
                                      'today' => Icons.today_outlined,
                                      _ => Icons.add_circle_outline,
                                    }, size: 18),
                                    label: Text(item.value),
                                    selected: _shortcutSelection.contains(
                                      item.key,
                                    ),
                                    onSelected: (value) =>
                                        _toggleShortcut(item.key, value),
                                  ),
                              ],
                            ),
                            if (_shortcutSelection.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: Text('未启用；选择任一功能后显示通知。'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('启用自动记账'),
                    subtitle: const Text('开关与软件设置更改后自动保存'),
                    value: _enabled,
                    onChanged: _busy
                        ? null
                        : (v) {
                            setState(() => _enabled = v);
                            _save();
                          },
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('automation_ledger_$_ledger'),
                    initialValue: state.ledgers.containsKey(_ledger)
                        ? _ledger
                        : null,
                    decoration: const InputDecoration(labelText: '自动记账目标账本'),
                    isExpanded: true,
                    items: state.ledgers.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) {
                            if (v != null) {
                              setState(() {
                                _ledger = v;
                                _rules = {
                                  for (final app in paymentApps)
                                    app.packageName: PaymentRule(
                                      enabled:
                                          (_rules[app.packageName] ??
                                                  const PaymentRule())
                                              .enabled,
                                    ),
                                };
                              });
                              _save();
                            }
                          },
                  ),
                  SwitchListTile(
                    title: const Text('识别后弹窗记账'),
                    subtitle: const Text('未保存时可收起为悬浮球，再展开填写；开启后不直接自动保存'),
                    value: _reviewPopup,
                    onChanged: _busy
                        ? null
                        : (v) {
                            setState(() => _reviewPopup = v);
                            _save();
                          },
                  ),
                  ListTile(
                    title: const Text('悬浮窗权限'),
                    subtitle: Text(
                      _status['overlayGranted'] == true
                          ? '已授权，可显示表单与悬浮球'
                          : '未授权：识别记录仍保留在待确认账单',
                    ),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              try {
                                if (!await _save()) return;
                                await ref
                                    .read(automationBridgeProvider)
                                    .openOverlay();
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            },
                      child: const Text('系统设置'),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('完整明确的账单自动保存'),
                    subtitle: Text(
                      _reviewPopup ? '弹窗模式下须手动点击保存' : '缺字段、歧义或疑似重复进入待确认账单',
                    ),
                    value: _autoSave,
                    onChanged: _busy || _reviewPopup
                        ? null
                        : (v) {
                            setState(() => _autoSave = v);
                            _save();
                          },
                  ),
                  ListTile(
                    title: const Text('通知监听权限'),
                    subtitle: Text(
                      _status['notificationsGranted'] == true
                          ? _status['notificationConnected'] == true
                                ? '已授权 · 已连接'
                                : '已授权但未连接；请进入系统设置关闭后重新开启'
                          : '未授权',
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _permission(false),
                      child: const Text('系统设置'),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('无障碍增强模式'),
                    subtitle: const Text('读取账单页面；文字不足时使用已下载模型进行本地单帧OCR'),
                    value: _enhanced,
                    onChanged: _busy
                        ? null
                        : (v) {
                            setState(() => _enhanced = v);
                            _save();
                          },
                  ),
                  ListTile(
                    title: const Text('支付页面本地截图OCR增强'),
                    subtitle: Text(
                      _status['ocrModelReady'] == true
                          ? '模型已就绪；无障碍增强开启后自动使用，不保存、不上传截图'
                          : '请先到OCR模型管理下载一个档位',
                    ),
                    trailing: Text(
                      _status['ocrModelReady'] == true && _enhanced
                          ? '已启用'
                          : '未启用',
                    ),
                  ),
                  ListTile(
                    title: const Text('无障碍权限'),
                    subtitle: Text(
                      _status['accessibilityGranted'] == true
                          ? '已授权${_status['accessibilityConnected'] == true ? ' · 已连接' : ' · 等待系统连接'}'
                          : '未授权',
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _permission(true),
                      child: const Text('系统设置'),
                    ),
                  ),
                  if (_missingRequirements().isNotEmpty)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.warning_amber_rounded),
                        title: const Text('部分功能缺少权限'),
                        subtitle: Text(
                          '${_missingRequirements().join('、')}。对应功能暂时无法使用，请在本页完成授权。',
                        ),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '通知需软件实际发送交易消息；页面未暴露文字时会使用已下载模型做本地单帧OCR。系统强制停止、后台限制会影响捕获。若系统提示受限设置，可在知账应用信息右上角允许受限设置后授权。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  ListTile(
                    title: const Text('采集与后台状态'),
                    subtitle: Text(_diagnosis()),
                    trailing: IconButton(
                      tooltip: '刷新状态并尝试重新连接',
                      icon: const Icon(Icons.refresh),
                      onPressed: _busy
                          ? null
                          : () async {
                              try {
                                await ref
                                    .read(automationBridgeProvider)
                                    .retry();
                                await _refresh();
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            },
                    ),
                  ),
                  const Divider(),
                  const ListTile(
                    title: Text('适配软件'),
                    subtitle: Text('逐项启用；更改后自动保存；权限由系统单独授权'),
                  ),
                  for (final app in paymentApps)
                    ListTile(
                      title: Text(app.name),
                      subtitle: Text(
                        (_status['installed'] is Map &&
                                _status['installed'][app.packageName] == true)
                            ? '已安装 · 点击设置默认账户/分类'
                            : '未检测到安装 · 点击设置',
                      ),
                      onTap: _busy ? null : () => _rule(app),
                      trailing: Switch(
                        value: (_rules[app.packageName] ?? const PaymentRule())
                            .enabled,
                        onChanged: _busy
                            ? null
                            : (v) {
                                setState(() {
                                  final old =
                                      _rules[app.packageName] ??
                                      const PaymentRule();
                                  _rules[app.packageName] = PaymentRule(
                                    enabled: v,
                                    accountId: old.accountId,
                                    categoryId: old.categoryId,
                                  );
                                });
                                _save();
                              },
                      ),
                    ),
                  const Divider(),
                  ListTile(
                    title: Text(
                      '累计自动保存 ${_status['posted'] ?? 0} · 待确认 ${_status['pending'] ?? 0}',
                    ),
                    subtitle: Text(
                      '待处理 ${_status['queued'] ?? 0} · 容量/过期丢弃 ${_status['dropped'] ?? 0}',
                    ),
                  ),
                  if (_status['error'] == true)
                    ListTile(
                      title: Text('后台处理未完成：${_errorLabel()}'),
                      trailing: TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                await ref
                                    .read(automationBridgeProvider)
                                    .retry();
                                await _refresh();
                              },
                        child: const Text('重试'),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '设置变更会取消尚未处理的采集；已保存的账目和草稿保留。自动保存记录可从流水删除；不确定的记录到管理 → 待确认账单核对。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
