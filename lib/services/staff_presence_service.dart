import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic/helper_assignment.dart';
import '../logic/staff_availability.dart';
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
  List<Map<String, dynamic>> _presentStaff = const [];
  bool _isLoading = true;
  bool _refreshInFlight = false;
  bool _refreshQueued = false;
  bool _started = false;
  bool _disposed = false;
  bool _isOnBreak = false;

  StaffPresenceService({
    required this.supabase,
    required this.locationId,
    required this.userId,
    required this.userName,
    required this.userRole,
  });

  List<Map<String, dynamic>> get activeStaff => _activeStaff;
  bool isUserOnBreak(String id) => _presentStaff.any(
    (row) =>
        row['user_id']?.toString() == id &&
        row['is_online'] == false &&
        row['current_module'] == 'On break',
  );
  List<HelperAssignmentCandidate> get eligibleHelpersForAssignment =>
      eligibleHelpersFromPresence(
        presenceRows: _activeStaff,
        locationId: locationId,
        now: DateTime.now().toUtc(),
        activeTimeout: activeTimeout,
      );
  bool get isLoading => _isLoading;
  bool get isOnBreak => _isOnBreak;
  bool get isStarted => _started;

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

    // A browser refresh should keep an unfinished break. Explicit logout clears it.
    if (userRole.toLowerCase() == 'helper') {
      final existing = await supabase
          .from('staff_presence')
          .select('current_module,logged_out_at')
          .eq('user_id', userId)
          .maybeSingle();
      _isOnBreak =
          existing?['current_module'] == 'On break' &&
          existing?['logged_out_at'] == null;
    }

    final now = DateTime.now().toUtc().toIso8601String();

    await supabase.from('staff_presence').upsert({
      'user_id': userId,
      'user_name': userName,
      'user_role': userRole,
      'location_id': locationId,
      'is_online': !_isOnBreak,
      'current_module': _isOnBreak ? 'On break' : currentModule,
      'logged_in_at': now,
      'last_seen_at': now,
      'logged_out_at': null,
    }, onConflict: 'user_id');

    _started = true;
    notifyListeners();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_runHeartbeat());
    });

    // RealtimeSyncService emits the guaranteed initial canonical refresh.
    // Keeping startup writes separate avoids fetching the same snapshot twice.
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
      'is_online': !_isOnBreak,
      'current_module': _isOnBreak ? 'On break' : currentModule,
      'last_seen_at': now,
    }, onConflict: 'user_id');
  }

  Future<void> setOnBreak(bool onBreak) async {
    if (_disposed || !_started || userRole.toLowerCase() != 'helper') {
      throw StateError('Helper availability is not ready.');
    }
    if (_isOnBreak == onBreak) return;

    _isOnBreak = onBreak;
    notifyListeners();
    try {
      await heartbeat(currentModule: _currentModule);
      await refreshActiveStaff();
    } catch (_) {
      _isOnBreak = !onBreak;
      notifyListeners();
      await heartbeat(currentModule: _currentModule);
      rethrow;
    }
  }

  Future<void> _runHeartbeat() async {
    try {
      await heartbeat(currentModule: _currentModule);
    } catch (error, stackTrace) {
      debugPrint('[StaffPresence] heartbeat failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Updates the module included in the next scheduled heartbeat without
  /// turning retained-tab navigation into an extra presence write/read cycle.
  void updateModule(String currentModule) {
    if (_disposed) return;
    _currentModule = currentModule;
  }

  Future<void> stop({String logoutReason = 'manual_logout'}) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _started = false;
    _isOnBreak = false;
    if (!_disposed) notifyListeners();

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
        final rows = await fetchPresentStaff(
          supabase: supabase,
          locationId: locationId,
        );

        if (_disposed) return;

        _presentStaff = List<Map<String, dynamic>>.unmodifiable(
          rows.map((row) => Map<String, dynamic>.unmodifiable(row)),
        );
        _activeStaff = List<Map<String, dynamic>>.unmodifiable(
          _presentStaff.where((row) => row['is_online'] == true),
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
    for (final staff in _presentStaff) {
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

    final now = DateTime.now().toUtc();
    final fresh = _presentStaff
        .where(
          (row) => isCurrentStaffPresence(
            row,
            now: now,
            activeTimeout: activeTimeout,
          ),
        )
        .toList();
    if (fresh.length != _presentStaff.length) {
      _presentStaff = List<Map<String, dynamic>>.unmodifiable(fresh);
      _activeStaff = List<Map<String, dynamic>>.unmodifiable(
        fresh.where((row) => row['is_online'] == true),
      );
      notifyListeners();
    }

    _scheduleNextExpiry();
  }

  DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  void _removeUserFromSnapshot(String id) {
    final remaining = _presentStaff
        .where((staff) => staff['user_id']?.toString() != id)
        .toList();
    if (remaining.length == _presentStaff.length) return;

    _presentStaff = List<Map<String, dynamic>>.unmodifiable(remaining);
    _activeStaff = List<Map<String, dynamic>>.unmodifiable(
      remaining.where((row) => row['is_online'] == true),
    );
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

  static Future<List<Map<String, dynamic>>> fetchPresentStaff({
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
        .isFilter('logged_out_at', null)
        .gte('last_seen_at', cutoff)
        .order('last_seen_at', ascending: false);
    final now = DateTime.now().toUtc();
    return List<Map<String, dynamic>>.from(response)
        .where(
          (row) => isCurrentStaffPresence(
            row,
            now: now,
            activeTimeout: activeTimeout,
          ),
        )
        .toList(growable: false);
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
