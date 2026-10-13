import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

class StaffPresenceService {
  final SupabaseClient supabase;
  final String locationId;
  final String userId;
  final String userName;
  final String userRole;

  Timer? _heartbeatTimer;
  String? _sessionLogId;

  StaffPresenceService({
    required this.supabase,
    required this.locationId,
    required this.userId,
    required this.userName,
    required this.userRole,
  });

  Future<void> start({required String currentModule}) async {
    final now = DateTime.now().toUtc().toIso8601String();

    await supabase.from('staff_presence').upsert({
      'user_id': userId,
      'user_name': userName,
      'user_role': userRole,
      'location_id': locationId,
      'is_online': true,
      'current_module': currentModule,
      'logged_in_at': now,
      'last_seen_at': now,
      'logged_out_at': null,
    }, onConflict: 'user_id');

    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      heartbeat(currentModule: currentModule);
    });
  }

  Future<void> heartbeat({required String currentModule}) async {
    final now = DateTime.now().toUtc().toIso8601String();

    await supabase.from('staff_presence').upsert({
      'user_id': userId,
      'user_name': userName,
      'user_role': userRole,
      'location_id': locationId,
      'is_online': true,
      'current_module': currentModule,
      'last_seen_at': now,
    }, onConflict: 'user_id');
  }

  Future<void> updateModule(String currentModule) async {
    await heartbeat(currentModule: currentModule);
  }

  Future<void> stop({String logoutReason = 'manual_logout'}) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final now = DateTime.now().toUtc().toIso8601String();

    await supabase.from('staff_presence').upsert({
      'user_id': userId,
      'user_name': userName,
      'user_role': userRole,
      'location_id': locationId,
      'is_online': false,
      'current_module': null,
      'last_seen_at': now,
      'logged_out_at': now,
    }, onConflict: 'user_id');
  }

  static Future<void> logBlockedLogin({
    required SupabaseClient supabase,
    required String locationId,
    required String userId,
    required String userName,
    required String userRole,
    required String reason,
  }) async {
    await supabase.from('staff_session_logs').insert({
      'user_id': userId,
      'user_name': userName,
      'user_role': userRole,
      'location_id': locationId,
      'login_at': DateTime.now().toUtc().toIso8601String(),
      'blocked_by_store_hours': true,
      'block_reason': reason,
    });
  }

  static Future<List<Map<String, dynamic>>> fetchActiveStaff({
    required SupabaseClient supabase,
    required String locationId,
  }) async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 2))
        .toIso8601String();

    final response = await supabase
        .from('staff_presence')
        .select()
        .eq('location_id', locationId)
        .eq('is_online', true)
        .gte('last_seen_at', cutoff)
        .order('last_seen_at', ascending: false);

    return List<Map<String, dynamic>>.from(response);
  }
}
