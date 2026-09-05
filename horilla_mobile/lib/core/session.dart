import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Session {
  Session._();
  static final Session instance = Session._();
  // resetOnError: an Android Keystore key can become undecryptable -- the
  // signing key changed, or a backup restored a store written under a key that
  // no longer exists. The default throws on read, and these reads happen in
  // main() before runApp, so the app froze on the launch icon. Discard the
  // unreadable store and treat the user as signed out instead.
  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
  );

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

  Future<String?> get access => _read('access');
  Future<String?> get refresh => _read('refresh');

  /// A failed read means "no session", never a crash: these are awaited during
  /// startup, where an exception would stop the app before it renders.
  Future<String?> _read(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }
  Future<String?> get baseUrl async =>
      (await SharedPreferences.getInstance()).getString('typed_url');

  Future<void> updateTokens({required String access, String? refresh}) async {
    await _secure.write(key: 'access', value: access);
    if (refresh != null) await _secure.write(key: 'refresh', value: refresh);
  }

  static const _sessionKeys = <String>[];

  Future<void> clear() async {
    await _secure.delete(key: 'access');
    await _secure.delete(key: 'refresh');
    final prefs = await SharedPreferences.getInstance();
    for (final k in _sessionKeys) {
      await prefs.remove(k);
    }
  }
}
