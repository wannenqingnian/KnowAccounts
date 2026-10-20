import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/core/logging/app_logger.dart';

void main() {
  test(
    'app logger persists bounded structured events and redacts secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'app_logger_test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final logger = AppLogger.forDirectory(directory, maxEntries: 2);

      await logger.info('startup', 'startup_started', '应用开始启动');
      await logger.error(
        'database',
        'database_open_failed',
        '数据库初始化失败',
        error: StateError('token=secret 6222021234567890'),
        stackTrace: StackTrace.fromString('C:\\Users\\private\\app.dart:1'),
      );
      await logger.warning('transaction', 'validation_failed', '记账校验未通过');

      final events = await logger.read();
      expect(events, hasLength(2));
      expect(events.last.code, 'validation_failed');
      final exported = await logger.text();
      expect(exported, contains('数据库初始化失败'));
      expect(exported, isNot(contains('secret')));
      expect(exported, isNot(contains('6222021234567890')));
      expect(exported, isNot(contains('C:\\Users\\private')));

      await logger.clear();
      expect(await logger.read(), isEmpty);
    },
  );
}
