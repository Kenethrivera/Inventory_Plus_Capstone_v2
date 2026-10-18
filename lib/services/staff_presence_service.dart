import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'realtime/realtime_sync_service.dart';

class StaffPresenceService extends ChangeNotifier {
  static const Duration heartbeatInterval = Duration(seconds: 45);
  static const Duration activeTimeout = Duration(minutes: 2);

  final SupabaseClient supabase;
  final String locationId;
  final String userId;
  final String userName;
  final String userRole;

  Timer? _heartbeatTimer;
  Timer? _expiryTimer;
  StreamSubscription<void>? _realtimeSubscription;
  String _currentModule = 'Main Screen';
  List<Map<String, dynamic>> _activeStaff = const [];
  bool _isLoading = true;
  bool _refreshInFlight = false;
  bool _refreshQueued = false;
  bool _started = false;
  bool _disposed = false;

  StaffPresenceService({
    required this.supabase,
    required this.locationId,
    required this.userId,
    required this.userName,
    required this.userRole,
  });

  List<Map<String, dynamic>> get activeStaff => _activeStaff;
  bool get isLoading => _isLoading;

  void bindRealtimeSync(RealtimeSyncService realtimeSync) {
    unawaited(_realtimeSubscription?.cancel());
    _realtimeSubscription = realtimeSync.staffPresenceChanges.listen(
      (_) => unawaited(refreshActiveStaff()),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[StaffPresence] realtime error: $error');
      },
    );
  }

  Future<void> start({required String currentModule}) async {
    if (_disposed) return;

    _currentModule = currentModule;
    if (_started) {
      await heartbeat(currentModule: currentModule);
      return;
    }

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

    _started = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_runHeartbeat());
    });

    await refreshActiveStaff();
  }

  Future<void> heartbeat({required String currentModule}) async {
    if (_disposed || !_started) return;

    _currentModule = currentModule;
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

  Future<void> _runHeartbeat() async {
    try {
      await heartbeat(currentModule: _currentModule);
    } catch (error, stackTrace) {
      debugPrint('[StaffPresence] heartbeat failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> updateModule(String currentModule) async {
    await heartbeat(currentModule: currentModule);
  }

  Future<void> stop({String logoutReason = 'manual_logout'}) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _started = false;

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

    _removeUserFromSnapshot(userId);
  }

  Future<void> refreshActiveStaff() async {
    if (_disposed) return;

    if (_refreshInFlight) {
      _refreshQueued = true;
      return;
    }

    _refreshInFlight = true;

    do {
      _refreshQueued = false;

      try {
        final rows = await fetchActiveStaff(
          supabase: supabase,
          locationId: locationId,
        );

        if (_disposed) return;

        _activeStaff = List<Map<String, dynamic>>.unmodifiable(
          rows.map((row) => Map<String, dynamic>.unmodifiable(row)),
        );
        _isLoading = false;
        _scheduleNextExpiry();
        notifyListeners();

        debugPrint(
          '[StaffPresence] ACTIVE STAFF REFRESHED '
          'location=$locationId count=${_activeStaff.length}',
        );
      } catch (error, stackTrace) {
        if (_disposed) return;

        // Keep the last good snapshot so a transient background failure does
        // not make every active staff member disappear.
        _isLoading = false;
        notifyListeners();
        debugPrint('[StaffPresence] active staff refresh failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    } while (_refreshQueued && !_disposed);

    _refreshInFlight = false;
  }

  void _scheduleNextExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;

    DateTime? nextExpiry;
    for (final staff in _activeStaff) {
      final lastSeen = _parseTimestamp(staff['last_seen_at']);
      if (lastSeen == null) continue;

      final expiry = lastSeen.add(activeTimeout);
      if (nextExpiry == null || expiry.isBefore(nextExpiry)) {
        nextExpiry = expiry;
      }
    }

    if (nextExpiry == null) return;

    final delay = nextExpiry.difference(DateTime.now().toUtc());
    _expiryTimer = Timer(
      delay.isNegative
          ? Duration.zero
          : delay + const Duration(milliseconds: 50),
      _expireStaleStaff,
    );
  }

  void _expireStaleStaff() {
    if (_disposed) return;

    final fresh = _activeStaff.where(_isActivePresence).toList();
    if (fresh.length != _activeStaff.length) {
      _activeStaff = List<Map<String, dynamic>>.unmodifiable(fresh);
      notifyListeners();
    }

    _scheduleNextExpiry();
  }

  bool _isActivePresence(Map<String, dynamic> row) {
    if (row['is_online'] != true) return false;
    final lastSeen = _parseTimestamp(row['last_seen_at']);
    if (lastSeen == null) return false;
    return DateTime.now().toUtc().difference(lastSeen) < activeTimeout;
  }

  DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  void _removeUserFromSnapshot(String id) {
    final remaining = _activeStaff
        .where((staff) => staff['user_id']?.toString() != id)
        .toList();
    if (remaining.length == _activeStaff.length) return;

    _activeStaff = List<Map<String, dynamic>>.unmodifiable(remaining);
    if (!_disposed) notifyListeners();
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
        .subtract(activeTimeout)
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

  @override
  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _expiryTimer?.cancel();
    unawaited(_realtimeSubscription?.cancel());
    super.dispose();
  }
}
