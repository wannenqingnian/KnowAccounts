import 'package:smart_ledger/core/security/card_vault.dart';

class MemoryCardVault implements CardVault {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<void> write(String id, String number) async {
    if (failWrites) throw StateError('test storage failure');
    values[id] = number;
  }

  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}
