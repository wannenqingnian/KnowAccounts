import 'package:geolocator/geolocator.dart';

const transactionLocationPrefix = '📍记账地点：';

String? transactionLocationFromNote(String note) {
  for (final line in note.split('\n')) {
    if (line.startsWith(transactionLocationPrefix)) {
      return line.substring(transactionLocationPrefix.length);
    }
  }
  return null;
}

String transactionNoteWithoutLocation(String note) => note
    .split('\n')
    .where((line) => !line.startsWith(transactionLocationPrefix))
    .join('\n')
    .trim();

String transactionNoteWithLocation(String note, String? location) => [
  if (note.trim().isNotEmpty) note.trim(),
  if (location != null) '$transactionLocationPrefix$location',
].join('\n');

Future<String> currentTransactionLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationServiceDisabledException();
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission != LocationPermission.whileInUse &&
      permission != LocationPermission.always) {
    throw const PermissionDeniedException('未授予定位权限');
  }
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 20),
    ),
  );
  return '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}（精度约${position.accuracy.round()}米）';
}
