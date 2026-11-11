import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SessionTokenStore {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> delete();
}

class FlutterSecureSessionTokenStore implements SessionTokenStore {
  FlutterSecureSessionTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _secureTokenKey = 'inventory_plus_app_session_token_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _secureTokenKey);

  @override
  Future<void> write(String token) =>
      _storage.write(key: _secureTokenKey, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _secureTokenKey);
}

class AppSessionStorage {
  AppSessionStorage({
    SessionTokenStore? secureTokenStore,
    Future<SharedPreferences> Function()? preferences,
  }) : _secureTokenStore = secureTokenStore ?? FlutterSecureSessionTokenStore(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  static const String loggedInKey = 'isLoggedIn';
  static const String userIdKey = 'userId';
  static const String legacySessionTokenKey = 'sessionToken';

  final SessionTokenStore _secureTokenStore;
  final Future<SharedPreferences> Function() _preferences;

  /// Returns the token only for a previously completed login.
  ///
  /// A legacy SharedPreferences token is copied to secure storage first and
  /// removed only after the secure write succeeds. This makes migration
  /// retryable without losing the user's still-valid server session.
  Future<String?> readTokenForRestore() async {
    final prefs = await _preferences();
    final isLoggedIn = prefs.getBool(loggedInKey) ?? false;
    if (!isLoggedIn) {
      await _secureTokenStore.delete();
      await prefs.remove(legacySessionTokenKey);
      return null;
    }

    final secureToken = (await _secureTokenStore.read())?.trim();
    if (secureToken != null && secureToken.isNotEmpty) {
      await prefs.remove(legacySessionTokenKey);
      return secureToken;
    }

    final legacyToken = prefs.getString(legacySessionTokenKey)?.trim();
    if (legacyToken == null || legacyToken.isEmpty) return null;

    await _secureTokenStore.write(legacyToken);
    await prefs.remove(legacySessionTokenKey);
    return legacyToken;
  }

  Future<void> persistLogin({
    required String sessionToken,
    required String userId,
  }) async {
    final token = sessionToken.trim();
    if (token.isEmpty) throw ArgumentError('sessionToken must not be empty');

    await _secureTokenStore.write(token);
    final prefs = await _preferences();
    await prefs.setBool(loggedInKey, true);
    await prefs.setString(userIdKey, userId);
    await prefs.remove(legacySessionTokenKey);
  }

  /// Replaces the locally persisted token after the server has revoked the old
  /// token and issued a replacement (for example, password change). The legacy
  /// copy is removed only after the secure write succeeds.
  Future<void> replaceToken(String sessionToken) async {
    final token = sessionToken.trim();
    if (token.isEmpty) throw ArgumentError('sessionToken must not be empty');
    await _secureTokenStore.write(token);
    final prefs = await _preferences();
    await prefs.remove(legacySessionTokenKey);
  }

  Future<void> clear() async {
    await _secureTokenStore.delete();
    final prefs = await _preferences();
    await prefs.clear();
  }
}
