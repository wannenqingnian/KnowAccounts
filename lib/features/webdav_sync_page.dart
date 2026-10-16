import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../backup/backup_service.dart';
import '../backup/webdav_sync_service.dart';
import 'action_form.dart' show showError;
import 'widgets.dart';

Future<void> showWebDavSyncPage(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const WebDavSyncPage()));

class WebDavSyncPage extends ConsumerStatefulWidget {
  const WebDavSyncPage({super.key});

  @override
  ConsumerState<WebDavSyncPage> createState() => _WebDavSyncPageState();
}

class _WebDavSyncPageState extends ConsumerState<WebDavSyncPage> {
  final _endpoint = TextEditingController();
  final _username = TextEditingController();
  final _remotePath = TextEditingController();
  final _webDavPassword = TextEditingController();
  final _backupPassword = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  bool _hasWebDavPassword = false;
  bool _hasBackupPassword = false;
  DateTime? _lastSyncAt;

  WebDavSyncService get _service {
    final repository = ref.read(repositoryProvider);
    return WebDavSyncService(
      backup: BackupService(repository.db, cardVault: repository.cardVault),
    );
  }

  void _notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _username.dispose();
    _remotePath.dispose();
    _webDavPassword.dispose();
    _backupPassword.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await _service.loadSettings();
      if (!mounted) return;
      _endpoint.text = settings.endpoint;
      _username.text = settings.username;
      _remotePath.text = settings.remotePath;
      setState(() {
        _hasWebDavPassword = settings.hasWebDavPassword;
        _hasBackupPassword = settings.hasBackupPassword;
        _lastSyncAt = settings.lastSyncAt?.toLocal();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    await _service.saveSettings(
      endpoint: _endpoint.text,
      username: _username.text,
      remotePath: _remotePath.text,
      webDavPassword: _webDavPassword.text.isEmpty
          ? null
          : _webDavPassword.text,
      backupPassword: _backupPassword.text.isEmpty
          ? null
          : _backupPassword.text,
    );
    _webDavPassword.clear();
    _backupPassword.clear();
    final settings = await _service.loadSettings();
    if (mounted) {
      setState(() {
        _hasWebDavPassword = settings.hasWebDavPassword;
        _hasBackupPassword = settings.hasBackupPassword;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() => _run(() async {
    await _save();
    await _service.testConnection();
    if (mounted) _notice('WebDAV 连接和目录权限正常');
  });

  Future<void> _upload({bool force = false}) => _run(() async {
    await _save();
    try {
      final result = await _service.upload(force: force);
      await _load();
      if (mounted) {
        _notice('已上传加密备份（${_formatBytes(result.bytes)}）');
      }
    } on WebDavConflictException catch (e) {
      if (!mounted) rethrow;
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('远端备份有变化'),
          content: Text('${e.message}\n\n建议先下载恢复。只有确认本机数据更新时才覆盖远端。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('仍然覆盖'),
            ),
          ],
        ),
      );
      if (overwrite == true) {
        final result = await _service.upload(force: true);
        await _load();
        if (mounted) {
          _notice('已覆盖远端加密备份（${_formatBytes(result.bytes)}）');
        }
      }
    }
  });

  Future<void> _download() => _run(() async {
    await _save();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('下载并恢复？'),
        content: const Text(
          '远端加密备份会替换本机全部账本。下载后仍会验证密码、数据库结构和关联关系，验证失败不会修改本机数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('下载并恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await _service.downloadAndRestore();
    await ref.read(ledgerProvider).load();
    await _load();
    if (mounted) {
      _notice('已从 WebDAV 恢复（${_formatBytes(result.bytes)}）');
    }
  });

  Future<void> _clear() => _run(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除本机 WebDAV 配置？'),
        content: const Text('只清除本机地址和密码，不删除远端备份。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.clearSettings();
    _endpoint.clear();
    _username.clear();
    _remotePath.text = WebDavSyncService.defaultRemotePath;
    _webDavPassword.clear();
    _backupPassword.clear();
    setState(() {
      _hasWebDavPassword = false;
      _hasBackupPassword = false;
      _lastSyncAt = null;
    });
  });

  String _formatTime(DateTime? value) {
    if (value == null) return '尚未同步';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
  }

  static String _formatBytes(int value) => value < 1024 * 1024
      ? '${(value / 1024).toStringAsFixed(1)} KB'
      : '${(value / 1024 / 1024).toStringAsFixed(1)} MB';

  InputDecoration _decoration(String label, {String? helper}) =>
      InputDecoration(labelText: label, helperText: helper);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('WebDAV 加密同步')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '连接配置',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _endpoint,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: _decoration(
                        'WebDAV 地址',
                        helper: '例如 https://dav.example.com/dav/',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _username,
                      autocorrect: false,
                      decoration: _decoration('用户名'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _webDavPassword,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: _decoration(
                        'WebDAV 密码',
                        helper: _hasWebDavPassword ? '已安全保存，留空不修改' : null,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _remotePath,
                      autocorrect: false,
                      decoration: _decoration(
                        '远端备份文件',
                        helper: '相对于上方地址；不同共享账本请使用不同路径',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _backupPassword,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: _decoration(
                        '备份加密密码',
                        helper: _hasBackupPassword
                            ? '已安全保存，留空不修改'
                            : '至少 8 位；其他设备恢复时必须一致',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: _busy ? null : _test,
                        icon: const Icon(Icons.cloud_done_outlined),
                        label: const Text('保存并测试连接'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '加密备份',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (_busy)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '上次同步：${_formatTime(_lastSyncAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _upload,
                            icon: const Icon(Icons.cloud_upload_outlined),
                            label: const Text('上传本机备份'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _download,
                            icon: const Icon(Icons.cloud_download_outlined),
                            label: const Text('下载并恢复'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '多设备与共享账本',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '其他设备填写相同的远端路径和备份密码即可恢复。远端只保存加密数据；共享成员的读取、写入权限由 WebDAV 服务端账号或目录权限控制。当前采用整库备份，不会把两台设备同时产生的账单静默合并。',
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _busy ? null : _clear,
                      icon: const Icon(Icons.link_off),
                      label: const Text('清除本机配置'),
                    ),
                  ],
                ),
              ),
            ],
          ),
  );
}
