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
}
