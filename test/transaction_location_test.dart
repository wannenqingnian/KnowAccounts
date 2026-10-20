import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:smart_ledger/features/transaction_location.dart';

class TestLocationPlatform extends GeolocatorPlatform {
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission requestedPermission = LocationPermission.whileInUse;
  int requests = 0;
  int readings = 0;
  LocationSettings? settings;

  @override
  Future<bool> isLocationServiceEnabled() async => enabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return requestedPermission;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    readings++;
    settings = locationSettings;
    return Position(
      latitude: 22.543096,
      longitude: 114.057865,
      timestamp: DateTime(2026),
      accuracy: 12.4,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }
}

void main() {
  late GeolocatorPlatform original;
  late TestLocationPlatform platform;

  setUp(() {
    original = GeolocatorPlatform.instance;
    platform = TestLocationPlatform();
    GeolocatorPlatform.instance = platform;
  });
  tearDown(() => GeolocatorPlatform.instance = original);

  test('location note round trips without losing other note lines', () {
    final note = transactionNoteWithLocation('午餐\n同事聚餐', '22.54, 114.05');
    expect(transactionLocationFromNote(note), '22.54, 114.05');
    expect(transactionNoteWithoutLocation(note), '午餐\n同事聚餐');
    expect(transactionNoteWithLocation('午餐', null), '午餐');
  });

  test('granted permission retrieves one bounded system position', () async {
    expect(await currentTransactionLocation(), '22.543096, 114.057865（精度约12米）');
    expect(platform.requests, 0);
    expect(platform.readings, 1);
    expect(platform.settings?.timeLimit, const Duration(seconds: 20));
  });

  test(
    'disabled location does not request permission or read position',
    () async {
      platform.enabled = false;
      await expectLater(
        currentTransactionLocation(),
        throwsA(isA<LocationServiceDisabledException>()),
      );
      expect(platform.requests, 0);
      expect(platform.readings, 0);
    },
  );

  test('permission can be requested once and granted', () async {
    platform.permission = LocationPermission.denied;
    await currentTransactionLocation();
    expect(platform.requests, 1);
    expect(platform.readings, 1);
  });

  test('denied permission does not read position', () async {
    platform.permission = LocationPermission.denied;
    platform.requestedPermission = LocationPermission.denied;
    await expectLater(
      currentTransactionLocation(),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect(platform.readings, 0);
  });

  test('permanent denial does not request permission again', () async {
    platform.permission = LocationPermission.deniedForever;
    await expectLater(
      currentTransactionLocation(),
      throwsA(isA<PermissionDeniedException>()),
    );
    expect(platform.requests, 0);
    expect(platform.readings, 0);
  });
}
