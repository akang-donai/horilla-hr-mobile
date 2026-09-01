import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  http.Client httpClient = http.Client();
  void Function()? onSessionExpired;
  static const _timeout = Duration(seconds: 15);

  String? _baseUrl;
  String? _access;
  String? _refresh;

  Future<void> init() async {
    _baseUrl = await Session.instance.baseUrl;
    _access = await Session.instance.access;
    _refresh = await Session.instance.refresh;
  }

  void configureForTest({
    required String baseUrl,
    required String access,
    required String refresh,
  }) {
    _baseUrl = baseUrl;
    _access = access;
    _refresh = refresh;
  }

  Future<void> onLogin({
    required String baseUrl,
    required String access,
    required String refresh,
  }) async {
    _baseUrl = baseUrl;
    _access = access;
    _refresh = refresh;
    await Session.instance.saveLogin(
        baseUrl: baseUrl, access: access, refresh: refresh);
  }

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  Map<String, String> _headers({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        'Authorization': 'Bearer $_access',
      };

  Future<http.Response> get(String path) => _send('GET', path);
  Future<http.Response> post(String path, {Object? jsonBody}) =>
      _send('POST', path, jsonBody: jsonBody);
  Future<http.Response> put(String path, {Object? jsonBody}) =>
      _send('PUT', path, jsonBody: jsonBody);
  Future<http.Response> delete(String path) => _send('DELETE', path);

  Future<http.Response> _send(String method, String path,
      {Object? jsonBody, bool retried = false}) async {
    final req = http.Request(method, _uri(path));
    req.headers.addAll(_headers());
    if (jsonBody != null) req.body = jsonEncode(jsonBody);
    final res = await http.Response.fromStream(
        await httpClient.send(req).timeout(_timeout));
    if (res.statusCode == 401 &&
        !retried &&
        !path.startsWith('/api/auth/')) {
      if (await _tryRefresh()) {
        return _send(method, path, jsonBody: jsonBody, retried: true);
      }
      onSessionExpired?.call();
    }
    return res;
  }

  Future<http.StreamedResponse> multipart(
    String method,
    String path, {
    Map<String, String> fields = const {},
    Map<String, String> files = const {},
    bool retried = false,
  }) async {
    final req = http.MultipartRequest(method, _uri(path));
    req.headers['Authorization'] = 'Bearer $_access';
    req.fields.addAll(fields);
    for (final e in files.entries) {
      req.files.add(await http.MultipartFile.fromPath(e.key, e.value));
    }
    final res = await httpClient.send(req).timeout(_timeout);
    if (res.statusCode == 401 && !retried) {
      if (await _tryRefresh()) {
        return multipart(method, path,
            fields: fields, files: files, retried: true);
      }
      onSessionExpired?.call();
    }
    return res;
  }

  Future<bool> _tryRefresh() async {
    if (_refresh == null) return false;
    try {
      final res = await httpClient
          .post(
            _uri('/api/auth/refresh/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh': _refresh}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      _access = data['access'] as String?;
      final newRefresh = data['refresh'] as String?;
      if (newRefresh != null) _refresh = newRefresh;
      try {
        await Session.instance.updateTokens(
            access: _access!, refresh: newRefresh);
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> logoutServerSide() async {
    if (_refresh == null) return;
    try {
      await httpClient
          .post(
            _uri('/api/auth/logout/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh': _refresh}),
          )
          .timeout(_timeout);
    } catch (_) {}
    _access = null;
    _refresh = null;
  }
}
