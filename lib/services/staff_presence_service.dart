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
  final String sessionToken;

  Timer? _heartbeatTimer;
  Timer? _expiryTimer;
  StreamSubscription<void>? _realtimeSubscription;
  String _currentModule = 'Main Screen';
  String? _workMode;
  String? _workOrderId;

  Future<void> _heartbeatQueue = Future<void>.value();
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
    required this.sessionToken,
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
  // POS_BODEGERO_ASSIGNMENT_V1: same location/presence freshness as Helper.
  List<HelperAssignmentCandidate> get eligibleBodegerosForAssignment =>
      eligibleHelpersFromPresence(
        presenceRows: _activeStaff,
        locationId: locationId,
        now: DateTime.now().toUtc(),
        activeTimeout: activeTimeout,
        targetRole: 'bodegero',
      );
  bool get isLoading => _isLoading;
  bool get isOnBreak => _isOnBreak;
  bool get isStarted => _started;
  String? get workMode => _workMode;

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

    // A new session clears any legacy break state left by older clients.
    _isOnBreak = false;

    await _writePresence('login', true, currentModule);

    _started = true;
    notifyListeners();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_runHeartbeat());
    });

    // Make the newly online staff member visible to automatic assignment now.
    // The realtime refresh may have completed before this presence upsert.
    await refreshActiveStaff();
  }

  Future<void> heartbeat({required String currentModule}) {
    if (_disposed || !_started) {
      return Future<void>.value();
    }

    _currentModule = currentModule;

    // Serialize presence writes so a delayed "Preparing" update
    // cannot overwrite a later "Available" update.
    _heartbeatQueue = _heartbeatQueue.catchError((Object _) {}).then((_) async {
      if (_disposed || !_started) return;

      await _writePresence(
        'heartbeat',
        !_isOnBreak,
        _isOnBreak
            ? 'On break'
            : _workMode == null
                ? _currentModule
                : _workOrderId == null
                    ? _workMode
                    : '$_workMode:$_workOrderId',
      );
    });

    return _heartbeatQueue;
  }

  Future<void> setWorkMode(String? mode, {String? orderId}) async {
    if (_disposed || !_started) return;

    if (mode != null &&
        mode != staffPreparingModule &&
        mode != staffLoadingModule) {
      throw ArgumentError.value(mode, 'mode');
    }

    if (mode != null && _isOnBreak) return;
    final trimmedOrderId = orderId?.trim();
    final activeOrderId = mode == null || trimmedOrderId == null || trimmedOrderId.isEmpty
        ? null
        : trimmedOrderId;
    if (_workMode == mode && _workOrderId == activeOrderId) return;

    _workMode = mode;
    _workOrderId = activeOrderId;

    // Update the local header immediately.
    notifyListeners();

    try {
      // Publish the activity without waiting for the next heartbeat.
      await heartbeat(currentModule: _currentModule);
      await refreshActiveStaff();
    } catch (error, stackTrace) {
      // Keep the desired local state; the next heartbeat can retry it.
      debugPrint('[StaffPresence] work mode update failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> setOnBreak(bool onBreak) async {
    if (_disposed ||
        !_started ||
        (userRole.toLowerCase() != 'helper' &&
            userRole.toLowerCase() != 'bodegero')) {
      throw StateError('Staff availability is not ready.');
    }
    if (_isOnBreak == onBreak) return;

    if (onBreak && _workMode != null) {
      throw StateError('Close the active order before taking a break.');
    }

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
    _workMode = null;
    _workOrderId = null;

    try {
      await _heartbeatQueue;
    } catch (_) {
      // Logout must still proceed if an earlier heartbeat failed.
    }

    if (!_disposed) notifyListeners();

    try {
      await _writePresence('logout', false, null);
    } catch (error, stackTrace) {
      // A revoked or restricted presence write must not block session cleanup.
      debugPrint('[StaffPresence] logout presence update failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _removeUserFromSnapshot(userId);
    }
  }

  Future<void> _writePresence(
    String event,
    bool isOnline,
    String? currentModule,
  ) async {
    await supabase.rpc(
      'staff_presence_write_v1',
      params: <String, dynamic>{
        'p_session_token': sessionToken,
        'p_event': event,
        'p_is_online': isOnline,
        'p_current_module': currentModule,
      },
    );
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
          sessionToken: sessionToken,
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
    required String sessionToken,
    required String reason,
  }) async {
    await supabase.rpc(
      'record_blocked_staff_login_v1',
      params: <String, dynamic>{
        'p_session_token': sessionToken,
        'p_reason': reason,
      },
    );
  }

  static Future<List<Map<String, dynamic>>> fetchActiveStaff({
    required SupabaseClient supabase,
    required String locationId,
    required String sessionToken,
  }) async {
    final rows = await fetchPresentStaff(
      supabase: supabase,
      locationId: locationId,
      sessionToken: sessionToken,
    );
    return rows.where((row) => row['is_online'] == true).toList();
  }

  static Future<List<Map<String, dynamic>>> fetchPresentStaff({
    required SupabaseClient supabase,
    required String locationId,
    required String sessionToken,
  }) async {
    final response = await supabase.rpc(
      'staff_presence_list_v1',
      params: <String, dynamic>{'p_session_token': sessionToken},
    );
    final now = DateTime.now().toUtc();
    return List<Map<String, dynamic>>.from(response as List)
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
