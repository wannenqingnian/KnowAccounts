import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class CardVault {
  Future<void> write(String id, String number);
  Future<String?> read(String id);
  Future<void> delete(String id);
}

class DeviceCardVault implements CardVault {
  const DeviceCardVault();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  @override
  Future<void> write(String id, String number) =>
      _storage.write(key: 'ledger_card_$id', value: number);
  @override
  Future<String?> read(String id) => _storage.read(key: 'ledger_card_$id');
  @override
  Future<void> delete(String id) => _storage.delete(key: 'ledger_card_$id');
}
