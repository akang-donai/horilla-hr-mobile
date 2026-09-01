import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Session {
  Session._();
  static final Session instance = Session._();
  final _secure = const FlutterSecureStorage();

  Future<void> saveLogin({
    required String baseUrl,
    required String access,
    required String refresh,
  }) async {
    await _secure.write(key: 'access', value: access);
    await _secure.write(key: 'refresh', value: refresh);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('typed_url', baseUrl);
  }

  Future<String?> get access => _secure.read(key: 'access');
  Future<String?> get refresh => _secure.read(key: 'refresh');
  Future<String?> get baseUrl async =>
      (await SharedPreferences.getInstance()).getString('typed_url');

  Future<void> updateTokens({required String access, String? refresh}) async {
    await _secure.write(key: 'access', value: access);
    if (refresh != null) await _secure.write(key: 'refresh', value: refresh);
  }

  Future<void> clear() async {
    await _secure.deleteAll();
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      await prefs.remove(k);
    }
  }
}
