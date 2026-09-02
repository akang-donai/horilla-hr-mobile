import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'api_client.dart';

class ClockResult {
  final bool ok;
  final String? errorCode; // outside_geofence | face_mismatch | not_enrolled
  final String? message;
  ClockResult(this.ok, {this.errorCode, this.message});

  /// The server rejected the action because it disagrees with the client about
  /// whether the employee is currently clocked in. Carries no error_code, so it
  /// is matched on the message the attendance views return.
  bool get isStateMismatch {
    final m = message?.toLowerCase() ?? '';
    return m.contains('already clocked-in') || m.contains('already clocked-out');
  }
}

Future<Position?> _position() async {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) return null;
  try {
    return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high))
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    return await Geolocator.getLastKnownPosition();
  }
}

Future<ClockResult> clockAction({required bool checkIn, required String selfiePath}) async {
  final pos = await _position();
  final path = checkIn ? '/api/attendance/clock-in/' : '/api/attendance/clock-out/';
  final res = await ApiClient.instance.multipart('POST', path,
      fields: {
        if (pos != null) 'latitude': pos.latitude.toString(),
        if (pos != null) 'longitude': pos.longitude.toString(),
      },
      files: {'image': selfiePath});
  final body = await res.stream.bytesToString();
  if (res.statusCode == 200) return ClockResult(true);
  String? code, msg;
  try {
    final data = jsonDecode(body) as Map<String, dynamic>;
    code = data['error_code'] as String?;
    msg = (data['error'] ?? data['message'])?.toString();
  } catch (_) {}
  return ClockResult(false, errorCode: code, message: msg);
}
