import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_plus/services/staff_presence_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('logout continues when the presence update is rejected', () async {
    var presenceWrites = 0;
    final supabase = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/staff_presence_write_v1');
        presenceWrites++;
        return http.Response(
          jsonEncode({'code': '42501', 'message': 'permission denied'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final presence = StaffPresenceService(
      supabase: supabase,
      locationId: 'location-1',
      userId: 'user-1',
      userName: 'Admin User',
      userRole: 'admin',
      sessionToken: 'test-session-token',
    );

    await presence.stop();

    expect(presenceWrites, 1);
    expect(presence.isStarted, isFalse);
    presence.dispose();
    await supabase.dispose();
  });
}
