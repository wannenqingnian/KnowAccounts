import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/backup/backup_service.dart';
import 'package:smart_ledger/backup/webdav_sync_service.dart';
import 'package:smart_ledger/core/database/app_database.dart';
import 'package:smart_ledger/data/ledger_repository.dart';
import 'package:smart_ledger/domain/models.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('uploads encrypted backup and restores it on another device', () async {
    final server = await _TestWebDavServer.start();
    final sourceDb = AppDatabase.memory();
    final targetDb = AppDatabase.memory();
    try {
      final sourceRepository = LedgerRepository(sourceDb);
      final targetRepository = LedgerRepository(targetDb);
      await sourceRepository.initialize();
      await targetRepository.initialize();
      final account = (await sourceRepository.accounts('personal')).first;
      final category = (await sourceRepository.categories('personal')).first;
      await sourceRepository.save(
        'personal',
        TransactionInput(
          type: TransactionType.expense,
          amountMinor: 1234,
          accountId: account.id,
          categoryId: category.id,
          merchant: '仅本地可见商户',
          occurredDate: DateTime(2026, 10, 13, 12, 30, 45),
        ),
      );

      final sourceStore = _MemorySecretStore();
      final source = WebDavSyncService(
        backup: BackupService(sourceDb),
        store: sourceStore,
      );
      await _configure(source, server.endpoint);
      await source.testConnection();
      final uploaded = await source.upload();

      expect(uploaded.bytes, greaterThan(0));
      expect(server.bytes, isNotNull);
      expect(utf8.decode(server.bytes!).contains('仅本地可见商户'), isFalse);

      final target = WebDavSyncService(
        backup: BackupService(targetDb),
        store: _MemorySecretStore(),
      );
      await _configure(target, server.endpoint);
      final downloaded = await target.downloadAndRestore();
      expect(downloaded.bytes, uploaded.bytes);
      expect(
        (await targetRepository.entries('personal')).single.amountMinor,
        1234,
      );
    } finally {
      await sourceDb.close();
      await targetDb.close();
      await server.close();
    }
  });

  test('stops upload when another device changed the remote ETag', () async {
    final server = await _TestWebDavServer.start();
    final db = AppDatabase.memory();
    try {
      final repository = LedgerRepository(db);
      await repository.initialize();
      final service = WebDavSyncService(
        backup: BackupService(db),
        store: _MemorySecretStore(),
      );
      await _configure(service, server.endpoint);
      await service.upload();
      server.replaceFromAnotherDevice();

      await expectLater(
        service.upload(),
        throwsA(isA<WebDavConflictException>()),
      );
    } finally {
      await db.close();
      await server.close();
    }
  });

  test(
    'rejects insecure non-local endpoint and short backup password',
    () async {
      final db = AppDatabase.memory();
      try {
        final service = WebDavSyncService(
          backup: BackupService(db),
          store: _MemorySecretStore(),
        );
        await expectLater(
          service.saveSettings(
            endpoint: 'http://example.com/dav',
            username: 'user',
            remotePath: '知账/data.slbackup',
            webDavPassword: 'secret',
            backupPassword: '12345678',
          ),
          throwsA(isA<LedgerException>()),
        );
        await expectLater(
          service.saveSettings(
            endpoint: 'https://example.com/dav',
            username: 'user',
            remotePath: '知账/data.slbackup',
            webDavPassword: 'secret',
            backupPassword: 'short',
          ),
          throwsA(isA<LedgerException>()),
        );
      } finally {
        await db.close();
      }
    },
  );
}

Future<void> _configure(WebDavSyncService service, String endpoint) =>
    service.saveSettings(
      endpoint: endpoint,
      username: 'test-user',
      remotePath: '知账/device.slbackup',
      webDavPassword: 'test-password',
      backupPassword: 'backup-password-2026',
    );

class _MemorySecretStore implements WebDavSecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _TestWebDavServer {
  _TestWebDavServer(this.server) {
    server.listen(_handle);
  }

  final HttpServer server;
  List<int>? bytes;
  int revision = 0;

  String get endpoint => 'http://127.0.0.1:${server.port}/dav/';
  String get etag => '"revision-$revision"';

  static Future<_TestWebDavServer> start() async =>
      _TestWebDavServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  void replaceFromAnotherDevice() {
    bytes = utf8.encode('different encrypted payload');
    revision++;
  }

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final expected =
        'Basic ${base64Encode(utf8.encode('test-user:test-password'))}';
    if (request.headers.value(HttpHeaders.authorizationHeader) != expected) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (request.method == 'PROPFIND') {
      request.response.statusCode = 207;
    } else if (request.method == 'MKCOL') {
      request.response.statusCode = HttpStatus.created;
    } else if (request.method == 'HEAD') {
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.etagHeader, etag);
        request.response.contentLength = bytes!.length;
      }
    } else if (request.method == 'PUT') {
      final incoming = await request.fold<List<int>>(
        <int>[],
        (value, chunk) => value..addAll(chunk),
      );
      final ifNoneMatch = request.headers.value('If-None-Match');
      final ifMatch = request.headers.value('If-Match');
      if ((ifNoneMatch == '*' && bytes != null) ||
          (ifMatch != null && ifMatch != etag)) {
        request.response.statusCode = HttpStatus.preconditionFailed;
      } else {
        bytes = incoming;
        revision++;
        request.response.statusCode = HttpStatus.created;
        request.response.headers.set(HttpHeaders.etagHeader, etag);
      }
    } else if (request.method == 'GET') {
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.etagHeader, etag);
        request.response.add(bytes!);
      }
    } else {
      request.response.statusCode = HttpStatus.methodNotAllowed;
    }
    await request.response.close();
  }
}
