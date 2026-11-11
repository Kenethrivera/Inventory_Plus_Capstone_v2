import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/login/session_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSessionTokenStore implements SessionTokenStore {
  String? token;
  bool failWrites = false;
  int deleteCalls = 0;

  @override
  Future<void> delete() async {
    deleteCalls += 1;
    token = null;
  }

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String value) async {
    if (failWrites) throw StateError('controlled secure-storage failure');
    token = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSessionTokenStore secureStore;
  late AppSessionStorage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    secureStore = _FakeSessionTokenStore();
    storage = AppSessionStorage(secureTokenStore: secureStore);
  });

  test('persists opaque token only in secure storage', () async {
    await storage.persistLogin(
      sessionToken: 'opaque-session-token',
      userId: 'staff-1',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(secureStore.token, 'opaque-session-token');
    expect(prefs.getBool(AppSessionStorage.loggedInKey), isTrue);
    expect(prefs.getString(AppSessionStorage.userIdKey), 'staff-1');
    expect(prefs.containsKey(AppSessionStorage.legacySessionTokenKey), isFalse);
  });

  test('migrates a legacy token then removes its plaintext copy', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSessionStorage.loggedInKey: true,
      AppSessionStorage.legacySessionTokenKey: 'legacy-token',
    });

    expect(await storage.readTokenForRestore(), 'legacy-token');
    final prefs = await SharedPreferences.getInstance();
    expect(secureStore.token, 'legacy-token');
    expect(prefs.containsKey(AppSessionStorage.legacySessionTokenKey), isFalse);
  });

  test('does not delete legacy token when secure migration fails', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSessionStorage.loggedInKey: true,
      AppSessionStorage.legacySessionTokenKey: 'retryable-legacy-token',
    });
    secureStore.failWrites = true;

    await expectLater(
      storage.readTokenForRestore(),
      throwsA(isA<StateError>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AppSessionStorage.legacySessionTokenKey),
      'retryable-legacy-token',
    );
  });

  test('prefers secure token and removes a stale legacy copy', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSessionStorage.loggedInKey: true,
      AppSessionStorage.legacySessionTokenKey: 'stale-token',
    });
    secureStore.token = 'current-token';

    expect(await storage.readTokenForRestore(), 'current-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(AppSessionStorage.legacySessionTokenKey), isFalse);
  });

  test('replaces password-change token without a legacy copy', () async {
    secureStore.token = 'old-token';
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSessionStorage.loggedInKey: true,
      AppSessionStorage.legacySessionTokenKey: 'old-token',
    });

    await storage.replaceToken('replacement-token');

    final prefs = await SharedPreferences.getInstance();
    expect(secureStore.token, 'replacement-token');
    expect(prefs.containsKey(AppSessionStorage.legacySessionTokenKey), isFalse);
  });

  test('logout clears secure and non-secret session metadata', () async {
    secureStore.token = 'opaque-token';
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSessionStorage.loggedInKey: true,
      AppSessionStorage.userIdKey: 'staff-1',
    });

    await storage.clear();

    final prefs = await SharedPreferences.getInstance();
    expect(secureStore.token, isNull);
    expect(secureStore.deleteCalls, 1);
    expect(prefs.getKeys(), isEmpty);
  });

  test(
    'does not restore a secure token without completed-login metadata',
    () async {
      secureStore.token = 'orphaned-token';

      expect(await storage.readTokenForRestore(), isNull);
      expect(secureStore.token, isNull);
    },
  );
}
