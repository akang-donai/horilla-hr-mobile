import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nira/core/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('injects bearer header and base url', () async {
    late http.Request seen;
    ApiClient.instance.configureForTest(
        baseUrl: 'https://hr.example.com', access: 'AT', refresh: 'RT');
    ApiClient.instance.httpClient = MockClient((req) async {
      seen = req;
      return http.Response('{}', 200);
    });
    await ApiClient.instance.get('/api/employee/employees/');
    expect(seen.url.toString(), 'https://hr.example.com/api/employee/employees/');
    expect(seen.headers['Authorization'], 'Bearer AT');
  });

  test('401 triggers refresh then retry once', () async {
    var calls = <String>[];
    ApiClient.instance.configureForTest(
        baseUrl: 'https://hr.example.com', access: 'OLD', refresh: 'RT');
    ApiClient.instance.httpClient = MockClient((req) async {
      calls.add('${req.url.path}:${req.headers['Authorization']}');
      if (req.url.path == '/api/auth/refresh/') {
        return http.Response(
            jsonEncode({'access': 'NEW', 'refresh': 'RT2'}), 200);
      }
      final auth = req.headers['Authorization'];
      return http.Response('{}', auth == 'Bearer NEW' ? 200 : 401);
    });
    final res = await ApiClient.instance.get('/api/leave/user-request/');
    expect(res.statusCode, 200);
    expect(calls.where((c) => c.startsWith('/api/leave')).length, 2);
  });

  test('failed refresh calls onSessionExpired', () async {
    var expired = false;
    ApiClient.instance.configureForTest(
        baseUrl: 'https://hr.example.com', access: 'OLD', refresh: 'BAD');
    ApiClient.instance.onSessionExpired = () => expired = true;
    ApiClient.instance.httpClient =
        MockClient((req) async => http.Response('{}', 401));
    final res = await ApiClient.instance.get('/api/x/');
    expect(res.statusCode, 401);
    expect(expired, isTrue);
  });


  test('concurrent 401s trigger only one refresh', () async {
    // Rotating refresh tokens are blacklisted after first use, so a second
    // concurrent refresh presents a dead token, fails, and logs the user out.
    var refreshCalls = 0;
    var expired = false;
    ApiClient.instance.configureForTest(
        baseUrl: 'https://hr.example.com', access: 'OLD', refresh: 'RT');
    ApiClient.instance.onSessionExpired = () => expired = true;
    ApiClient.instance.httpClient = MockClient((req) async {
      if (req.url.path == '/api/auth/refresh/') {
        refreshCalls++;
        if (refreshCalls > 1) {
          // What the server does to a blacklisted token.
          return http.Response('{"detail":"blacklisted"}', 401);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response(
            jsonEncode({'access': 'NEW', 'refresh': 'RT2'}), 200);
      }
      return http.Response(
          '{}', req.headers['Authorization'] == 'Bearer NEW' ? 200 : 401);
    });

    // A screen opening several endpoints at once, as the profile page does.
    final results = await Future.wait([
      ApiClient.instance.get('/api/base/companies/'),
      ApiClient.instance.get('/api/base/departments/'),
      ApiClient.instance.get('/api/base/job-positions/'),
      ApiClient.instance.get('/api/base/job-roles/'),
    ]);

    expect(refreshCalls, 1, reason: 'refresh must be single-flight');
    expect(results.every((r) => r.statusCode == 200), isTrue);
    expect(expired, isFalse, reason: 'must not log the user out');
  });

  group('uploadFilename', () {
    test('keeps web image extensions', () {
      expect(uploadFilename('/tmp/pic.jpg'), 'pic.jpg');
      expect(uploadFilename('/a/b/photo.PNG'), 'photo.PNG');
    });

    test('renames formats the server cannot decode', () {
      // Android camera default; image_picker hands back JPEG bytes.
      expect(uploadFilename('/storage/IMG_20260904.heic'), 'IMG_20260904.jpg');
      expect(uploadFilename('/storage/shot.HEIF'), 'shot.jpg');
    });

    test('handles a name with no extension', () {
      expect(uploadFilename('/tmp/scan'), 'scan.jpg');
    });
  });
}
