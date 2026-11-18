import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_plus/login/auth_service.dart';
import 'package:inventory_plus/services/app_error_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async {
        final password = (jsonDecode(request.body) as Map)['password'];
        if (password == 'same-password') {
          return http.Response(
            jsonEncode({'success': false, 'reason': 'password_reused'}),
            409,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({'error': 'Recovery is temporarily unavailable'}),
          503,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });

  test('reused password gets a specific message', () async {
    await expectLater(
      AuthService().completePasswordRecovery('reset-token', 'same-password'),
      throwsA(
        isA<AppUserFacingException>().having(
          (error) => error.message,
          'message',
          'Your new password must be different from your current password.',
        ),
      ),
    );
  });

  test('legacy server failure gets a recovery-specific message', () async {
    await expectLater(
      AuthService().completePasswordRecovery('reset-token', 'new-password'),
      throwsA(
        isA<AppUserFacingException>().having(
          (error) => error.message,
          'message',
          contains('Password reset could not be completed.'),
        ),
      ),
    );
  });
}
