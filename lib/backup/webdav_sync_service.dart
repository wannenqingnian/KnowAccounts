import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/models.dart';
import 'backup_service.dart';

const _webDavPrefix = 'webdav_sync_';

/// Non-secret values are kept here as well so restoring a ledger backup never
/// silently changes the WebDAV account configured on this device.
abstract class WebDavSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceWebDavSecretStore implements WebDavSecretStore {
  const DeviceWebDavSecretStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: _webDavPrefix + key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: _webDavPrefix + key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _webDavPrefix + key);
}

class WebDavSettings {
  const WebDavSettings({
    required this.endpoint,
    required this.username,
    required this.remotePath,
    required this.hasWebDavPassword,
    required this.hasBackupPassword,
    this.lastEtag,
    this.lastSyncAt,
  });

  final String endpoint;
  final String username;
  final String remotePath;
  final bool hasWebDavPassword;
  final bool hasBackupPassword;
  final String? lastEtag;
  final DateTime? lastSyncAt;

  bool get configured =>
      endpoint.isNotEmpty &&
      username.isNotEmpty &&
      remotePath.isNotEmpty &&
      hasWebDavPassword &&
      hasBackupPassword;
}

class WebDavSyncResult {
  const WebDavSyncResult({required this.bytes, required this.etag});
  final int bytes;
  final String? etag;
}

class WebDavConflictException extends LedgerException {
  const WebDavConflictException(super.message);
}

class WebDavSyncService {
  WebDavSyncService({
    required this.backup,
    WebDavSecretStore? store,
    HttpClient Function()? clientFactory,
  }) : store = store ?? const DeviceWebDavSecretStore(),
       _clientFactory = clientFactory ?? HttpClient.new;

  final BackupService backup;
  final WebDavSecretStore store;
  final HttpClient Function() _clientFactory;

  static const defaultRemotePath = '知账/知账同步.slbackup';
  static const _timeout = Duration(seconds: 30);

  Future<WebDavSettings> loadSettings() async {
    final values = await Future.wait([
      store.read('endpoint'),
      store.read('username'),
      store.read('remote_path'),
      store.read('password'),
      store.read('backup_password'),
      store.read('etag'),
      store.read('last_sync_at'),
    ]);
    return WebDavSettings(
      endpoint: values[0] ?? '',
      username: values[1] ?? '',
      remotePath: values[2] ?? defaultRemotePath,
      hasWebDavPassword: (values[3] ?? '').isNotEmpty,
      hasBackupPassword: (values[4] ?? '').isNotEmpty,
      lastEtag: values[5],
      lastSyncAt: DateTime.tryParse(values[6] ?? ''),
    );
  }

  Future<void> saveSettings({
    required String endpoint,
    required String username,
    required String remotePath,
    String? webDavPassword,
    String? backupPassword,
  }) async {
    final normalizedEndpoint = _validateEndpoint(endpoint);
    final normalizedPath = _validateRemotePath(remotePath);
    if (username.trim().isEmpty) throw const LedgerException('请输入 WebDAV 用户名');
    if (webDavPassword != null && webDavPassword.isEmpty) {
      throw const LedgerException('WebDAV 密码不能为空');
    }
    if (backupPassword != null && backupPassword.length < 8) {
      throw const LedgerException('备份密码至少 8 个字符');
    }
    final existing = await loadSettings();
    if (!existing.hasWebDavPassword && webDavPassword == null) {
      throw const LedgerException('请输入 WebDAV 密码');
    }
    if (!existing.hasBackupPassword && backupPassword == null) {
      throw const LedgerException('请输入至少 8 位的备份密码');
    }
    final endpointChanged =
        existing.endpoint != normalizedEndpoint ||
        existing.username != username.trim() ||
        existing.remotePath != normalizedPath;
    await Future.wait([
      store.write('endpoint', normalizedEndpoint),
      store.write('username', username.trim()),
      store.write('remote_path', normalizedPath),
      if (webDavPassword != null) store.write('password', webDavPassword),
      if (backupPassword != null)
        store.write('backup_password', backupPassword),
      if (endpointChanged) store.delete('etag'),
      if (endpointChanged) store.delete('last_sync_at'),
    ]);
  }

  Future<void> clearSettings() async {
    await Future.wait([
      for (final key in const [
        'endpoint',
        'username',
        'remote_path',
        'password',
        'backup_password',
        'etag',
        'last_sync_at',
      ])
        store.delete(key),
    ]);
  }

  Future<void> testConnection() async {
    final config = await _credentials();
    final client = _clientFactory();
    try {
      final request = await _open(client, 'PROPFIND', config.baseUri);
      _authorize(request, config);
      request.headers.set('Depth', '0');
      final response = await request.close().timeout(_timeout);
      await _ensureStatus(response, const {200, 207}, 'WebDAV 连接测试失败');
    } finally {
      client.close(force: true);
    }
  }

  Future<WebDavSyncResult> upload({bool force = false}) async {
    final config = await _credentials();
    final bytes = await backup.export(config.backupPassword);
    final client = _clientFactory();
    try {
      await _ensureCollections(client, config);
      final remote = await _head(client, config);
      final remembered = await store.read('etag');
      if (!force && remote.exists) {
        if (remembered == null ||
            (remote.etag != null && remote.etag != remembered)) {
          throw const WebDavConflictException(
            '远端备份已存在或已被其他设备更新。请先下载恢复，或确认后覆盖远端。',
          );
        }
      }
      final request = await _open(client, 'PUT', config.fileUri);
      _authorize(request, config);
      request.headers.contentType = ContentType.binary;
      request.headers.contentLength = bytes.length;
      if (remote.exists) {
        final condition = remote.etag ?? remembered;
        if (!force && condition != null) {
          request.headers.set('If-Match', condition);
        }
      } else {
        request.headers.set('If-None-Match', '*');
      }
      request.add(bytes);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode == HttpStatus.preconditionFailed ||
          response.statusCode == HttpStatus.conflict) {
        await response.drain<void>();
        throw const WebDavConflictException('上传期间远端备份发生变化，已停止覆盖');
      }
      await _ensureStatus(response, const {200, 201, 204}, '上传 WebDAV 备份失败');
      final after = await _head(client, config);
      await _remember(after.etag);
      return WebDavSyncResult(bytes: bytes.length, etag: after.etag);
    } finally {
      client.close(force: true);
    }
  }

  Future<WebDavSyncResult> downloadAndRestore() async {
    final config = await _credentials();
    final client = _clientFactory();
    try {
      final remote = await _head(client, config);
      if (!remote.exists) throw const LedgerException('远端尚无知账备份');
      final request = await _open(client, 'GET', config.fileUri);
      _authorize(request, config);
      if (remote.etag != null) request.headers.set('If-Match', remote.etag!);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode == HttpStatus.preconditionFailed) {
        await response.drain<void>();
        throw const WebDavConflictException('下载期间远端备份发生变化，请重试');
      }
      if (response.statusCode != HttpStatus.ok) {
        await _throwResponse(response, '下载 WebDAV 备份失败');
      }
      final declared = response.contentLength;
      if (declared > maxBackupBytes) {
        await response.drain<void>();
        throw const LedgerException('远端备份文件超过 50 MB');
      }
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response.timeout(_timeout)) {
        total += chunk.length;
        if (total > maxBackupBytes) {
          throw const LedgerException('远端备份文件超过 50 MB');
        }
        builder.add(chunk);
      }
      await backup.restore(builder.takeBytes(), config.backupPassword);
      await _remember(remote.etag);
      return WebDavSyncResult(bytes: total, etag: remote.etag);
    } finally {
      client.close(force: true);
    }
  }

  Future<_Credentials> _credentials() async {
    final values = await Future.wait([
      store.read('endpoint'),
      store.read('username'),
      store.read('remote_path'),
      store.read('password'),
      store.read('backup_password'),
    ]);
    if (values.any((value) => value == null || value.isEmpty)) {
      throw const LedgerException('请先保存完整的 WebDAV 配置');
    }
    final endpoint = Uri.parse(_validateEndpoint(values[0]!));
    return _Credentials(
      baseUri: endpoint,
      fileUri: _resolve(endpoint, _validateRemotePath(values[2]!)),
      remotePath: values[2]!,
      username: values[1]!,
      password: values[3]!,
      backupPassword: values[4]!,
    );
  }

  Future<void> _ensureCollections(
    HttpClient client,
    _Credentials config,
  ) async {
    final parts = config.remotePath.split('/');
    if (parts.length < 2) return;
    var current = config.baseUri;
    for (final part in parts.take(parts.length - 1)) {
      current = _resolve(current, '$part/');
      final request = await _open(client, 'MKCOL', current);
      _authorize(request, config);
      final response = await request.close().timeout(_timeout);
      // 405 is the standard response when the collection already exists.
      await _ensureStatus(response, const {
        200,
        201,
        204,
        405,
      }, '无法创建 WebDAV 备份目录');
    }
  }

  Future<_RemoteState> _head(HttpClient client, _Credentials config) async {
    final request = await _open(client, 'HEAD', config.fileUri);
    _authorize(request, config);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return const _RemoteState(false, null);
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.noContent) {
      await _throwResponse(response, '读取远端备份状态失败');
    }
    final etag = response.headers.value(HttpHeaders.etagHeader);
    await response.drain<void>();
    return _RemoteState(true, etag);
  }

  Future<HttpClientRequest> _open(HttpClient client, String method, Uri uri) =>
      client.openUrl(method, uri).timeout(_timeout);

  void _authorize(HttpClientRequest request, _Credentials config) {
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'SmartLedger-WebDAV/1');
  }

  Future<void> _remember(String? etag) async {
    if (etag == null) {
      await store.delete('etag');
    } else {
      await store.write('etag', etag);
    }
    await store.write('last_sync_at', DateTime.now().toUtc().toIso8601String());
  }

  static String _validateEndpoint(String value) {
    final text = value.trim();
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const LedgerException('请输入完整的 WebDAV 地址');
    }
    final local =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
      throw const LedgerException('WebDAV 地址必须使用 HTTPS');
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw const LedgerException('WebDAV 地址不能包含账号、查询参数或片段');
    }
    return uri
        .replace(path: uri.path.endsWith('/') ? uri.path : '${uri.path}/')
        .toString();
  }

  static String _validateRemotePath(String value) {
    final text = value.trim().replaceAll('\\', '/');
    final parts = text.split('/');
    if (text.startsWith('/') ||
        text.endsWith('/') ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const LedgerException('远端文件路径格式不正确');
    }
    if (!text.toLowerCase().endsWith('.slbackup')) {
      throw const LedgerException('远端文件名必须以 .slbackup 结尾');
    }
    if (text.length > 240) throw const LedgerException('远端文件路径过长');
    return text;
  }

  static Uri _resolve(Uri base, String relative) {
    final encoded = relative
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return base.resolve('$encoded${relative.endsWith('/') ? '/' : ''}');
  }

  Future<void> _ensureStatus(
    HttpClientResponse response,
    Set<int> accepted,
    String context,
  ) async {
    if (!accepted.contains(response.statusCode)) {
      await _throwResponse(response, context);
    }
    await response.drain<void>();
  }

  Future<Never> _throwResponse(
    HttpClientResponse response,
    String context,
  ) async {
    final code = response.statusCode;
    var detail = '';
    try {
      final bytes = <int>[];
      await for (final chunk in response.timeout(_timeout)) {
        if (bytes.length < 1024) {
          bytes.addAll(chunk.take(1024 - bytes.length));
        }
      }
      detail = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    } catch (_) {
      // Preserve the status code as the primary diagnostic.
    }
    if (code == HttpStatus.unauthorized || code == HttpStatus.forbidden) {
      throw const LedgerException('WebDAV 用户名、密码或目录权限不正确');
    }
    if ([301, 302, 307, 308].contains(code)) {
      throw const LedgerException('WebDAV 地址发生重定向，请填写重定向后的 HTTPS 地址');
    }
    throw LedgerException(
      '$context（HTTP $code）${detail.isEmpty ? '' : '：$detail'}',
    );
  }
}

class _Credentials {
  const _Credentials({
    required this.baseUri,
    required this.fileUri,
    required this.remotePath,
    required this.username,
    required this.password,
    required this.backupPassword,
  });
  final Uri baseUri;
  final Uri fileUri;
  final String remotePath;
  final String username;
  final String password;
  final String backupPassword;
}

class _RemoteState {
  const _RemoteState(this.exists, this.etag);
  final bool exists;
  final String? etag;
}
