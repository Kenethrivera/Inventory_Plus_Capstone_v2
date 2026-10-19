import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'realtime/realtime_sync_service.dart';

class StoreAccessSettings {
  final String locationId;
  final String openingTime;
  final String closingTime;
  final int staffAccessBeforeMinutes;
  final int staffAccessAfterMinutes;
  final bool restrictStaffLogin;
  final bool allowAdminAnytime;

  const StoreAccessSettings({
    required this.locationId,
    required this.openingTime,
    required this.closingTime,
    required this.staffAccessBeforeMinutes,
    required this.staffAccessAfterMinutes,
    required this.restrictStaffLogin,
    required this.allowAdminAnytime,
  });

  factory StoreAccessSettings.fromMap(Map<String, dynamic> map) {
    return StoreAccessSettings(
      locationId: map['location_id'].toString(),
      openingTime: map['opening_time'].toString(),
      closingTime: map['closing_time'].toString(),
      staffAccessBeforeMinutes:
          int.tryParse(map['staff_access_before_minutes'].toString()) ?? 30,
      staffAccessAfterMinutes:
          int.tryParse(map['staff_access_after_minutes'].toString()) ?? 30,
      restrictStaffLogin: map['restrict_staff_login'] == true,
      allowAdminAnytime: map['allow_admin_anytime'] != false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'location_id': locationId,
      'opening_time': openingTime,
      'closing_time': closingTime,
      'staff_access_before_minutes': staffAccessBeforeMinutes,
      'staff_access_after_minutes': staffAccessAfterMinutes,
      'restrict_staff_login': restrictStaffLogin,
      'allow_admin_anytime': allowAdminAnytime,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }
}

class StoreAccessResult {
  final bool allowed;
  final String? reason;
  final StoreAccessSettings settings;

  const StoreAccessResult({
    required this.allowed,
    required this.reason,
    required this.settings,
  });
}

class StoreAccessService {
  final SupabaseClient supabase;
  final String locationId;

  StoreAccessService({required this.supabase, required this.locationId});

  final StreamController<StoreAccessSettings> _settingsController =
      StreamController<StoreAccessSettings>.broadcast();
  StreamSubscription<void>? _realtimeSubscription;
  StoreAccessSettings? _currentSettings;
  Future<StoreAccessSettings>? _refreshInFlight;
  bool _refreshQueued = false;
  bool _isDisposed = false;

  StoreAccessSettings? get currentSettings => _currentSettings;

  Stream<StoreAccessSettings> streamSettings() async* {
    final current = _currentSettings;
    if (current != null) yield current;
    yield* _settingsController.stream;
  }

  void bindRealtimeSync(RealtimeSyncService realtimeSync) {
    if (_isDisposed) return;
    _realtimeSubscription ??= realtimeSync.storeAccessChanges.listen(
      (_) => unawaited(_refreshFromRealtime()),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[StoreAccess] Realtime error: $error');
      },
    );
  }

  Future<void> _refreshFromRealtime() async {
    if (_isDisposed) return;
    try {
      await refreshSettings(queueIfBusy: true);
    } catch (error, stackTrace) {
      debugPrint('[StoreAccess] Reconciliation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  StoreAccessSettings defaultSettings() {
    return StoreAccessSettings(
      locationId: locationId,
      openingTime: '08:00:00',
      closingTime: '21:00:00',
      staffAccessBeforeMinutes: 30,
      staffAccessAfterMinutes: 30,
      restrictStaffLogin: true,
      allowAdminAnytime: true,
    );
  }

  Future<StoreAccessSettings> fetchSettings() async {
    final response = await supabase
        .from('store_access_settings')
        .select()
        .eq('location_id', locationId)
        .maybeSingle();

    if (response == null) {
      final defaults = defaultSettings();

      await supabase
          .from('store_access_settings')
          .upsert(defaults.toMap(), onConflict: 'location_id');

      return defaults;
    }

    return StoreAccessSettings.fromMap(Map<String, dynamic>.from(response));
  }

  Future<StoreAccessSettings> refreshSettings({bool queueIfBusy = false}) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      if (queueIfBusy) _refreshQueued = true;
      return inFlight;
    }

    final refresh = _performSettingsRefresh();
    _refreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
      if (_refreshQueued) {
        _refreshQueued = false;
        unawaited(_refreshFromRealtime());
      }
    });
  }

  Future<StoreAccessSettings> _performSettingsRefresh() async {
    final response = await supabase
        .from('store_access_settings')
        .select()
        .eq('location_id', locationId)
        .maybeSingle();
    final settings = response == null
        ? defaultSettings()
        : StoreAccessSettings.fromMap(Map<String, dynamic>.from(response));
    _publish(settings);
    debugPrint('[StoreAccess] SETTINGS REFRESHED location=$locationId');
    return settings;
  }

  Future<void> saveSettings(StoreAccessSettings settings) async {
    await supabase
        .from('store_access_settings')
        .upsert(settings.toMap(), onConflict: 'location_id');
    _publish(settings);
  }

  void _publish(StoreAccessSettings settings) {
    if (_isDisposed) return;
    _currentSettings = settings;
    _settingsController.add(settings);
  }

  Future<StoreAccessResult> canLogin({
    required String role,
    DateTime? now,
  }) async {
    final settings = await fetchSettings();
    final cleanRole = role.toLowerCase();
    final currentTime = now ?? DateTime.now();

    if (!settings.restrictStaffLogin) {
      return StoreAccessResult(allowed: true, reason: null, settings: settings);
    }

    if (cleanRole == 'admin' && settings.allowAdminAnytime) {
      return StoreAccessResult(allowed: true, reason: null, settings: settings);
    }

    final bool allowed = _isWithinAllowedWindow(settings, now: currentTime);

    if (allowed) {
      return StoreAccessResult(allowed: true, reason: null, settings: settings);
    }

    return StoreAccessResult(
      allowed: false,
      reason:
          'Store is currently closed. Staff access is allowed only from '
          '${allowedWindowText(settings)}.',
      settings: settings,
    );
  }

  bool isAccessAllowed({
    required StoreAccessSettings settings,
    required String role,
    DateTime? now,
  }) {
    if (!settings.restrictStaffLogin) return true;
    if (role.toLowerCase() == 'admin' && settings.allowAdminAnytime) {
      return true;
    }
    return _isWithinAllowedWindow(settings, now: now);
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _refreshQueued = false;
    await _realtimeSubscription?.cancel();
    await _settingsController.close();
  }

  String allowedWindowText(StoreAccessSettings settings) {
    final open = _parseTimeOfDay(settings.openingTime);
    final close = _parseTimeOfDay(settings.closingTime);

    final int openMinutes =
        open.hour * 60 + open.minute - settings.staffAccessBeforeMinutes;

    final int closeMinutes =
        close.hour * 60 + close.minute + settings.staffAccessAfterMinutes;

    return '${_formatMinutes(openMinutes)} to '
        '${_formatMinutes(closeMinutes)}';
  }

  bool _isWithinAllowedWindow(StoreAccessSettings settings, {DateTime? now}) {
    final DateTime current = now ?? DateTime.now();

    final _ResolvedAccessWindow window = _resolveAccessWindow(
      settings,
      now: current,
    );

    return !current.isBefore(window.start) && !current.isAfter(window.end);
  }

  /// Builds one store-access session using [openingDate] as the calendar
  /// date on which the store opens.
  ///
  /// Example:
  /// opening = 20:00
  /// closing = 10:00
  ///
  /// openingDate = Oct 17
  ///
  /// Result:
  /// opening = Oct 17 20:00
  /// closing = Oct 18 10:00
  _ResolvedAccessWindow _buildAccessWindowForOpeningDate(
    StoreAccessSettings settings,
    DateTime openingDate,
  ) {
    final _ClockTime open = _parseTimeOfDay(settings.openingTime);

    final _ClockTime close = _parseTimeOfDay(settings.closingTime);

    final int openingMinutes = open.hour * 60 + open.minute;

    final int closingMinutes = close.hour * 60 + close.minute;

    // If closing is earlier than opening, the store closes
    // on the following calendar day.
    //
    // Example:
    // 20:00 -> 10:00
    final bool crossesMidnight = closingMinutes < openingMinutes;

    final DateTime openingDateTime = DateTime(
      openingDate.year,
      openingDate.month,
      openingDate.day,
      open.hour,
      open.minute,
    );

    final DateTime closingCalendarDate = crossesMidnight
        ? openingDate.add(const Duration(days: 1))
        : openingDate;

    final DateTime closingDateTime = DateTime(
      closingCalendarDate.year,
      closingCalendarDate.month,
      closingCalendarDate.day,
      close.hour,
      close.minute,
    );

    final DateTime accessStart = openingDateTime.subtract(
      Duration(minutes: settings.staffAccessBeforeMinutes),
    );

    final DateTime accessEnd = closingDateTime.add(
      Duration(minutes: settings.staffAccessAfterMinutes),
    );

    return _ResolvedAccessWindow(
      opening: openingDateTime,
      closing: closingDateTime,
      start: accessStart,
      end: accessEnd,
    );
  }

  /// Resolves the access session that contains [now].
  ///
  /// If [now] is outside all current sessions, it returns the next
  /// upcoming session. We inspect yesterday, today, and tomorrow because
  /// overnight store hours can belong to the previous day's opening.
  ///
  /// Example:
  ///
  /// Opening: 20:00
  /// Closing: 10:00
  /// Now:     05:48 on Oct 18
  ///
  /// Correct window:
  /// Oct 17 20:00 -> Oct 18 10:00
  _ResolvedAccessWindow _resolveAccessWindow(
    StoreAccessSettings settings, {
    DateTime? now,
  }) {
    final DateTime current = now ?? DateTime.now();

    final DateTime today = DateTime(current.year, current.month, current.day);

    final _ResolvedAccessWindow yesterdayWindow =
        _buildAccessWindowForOpeningDate(
          settings,
          today.subtract(const Duration(days: 1)),
        );

    final _ResolvedAccessWindow todayWindow = _buildAccessWindowForOpeningDate(
      settings,
      today,
    );

    final _ResolvedAccessWindow tomorrowWindow =
        _buildAccessWindowForOpeningDate(
          settings,
          today.add(const Duration(days: 1)),
        );

    final List<_ResolvedAccessWindow> candidates = [
      yesterdayWindow,
      todayWindow,
      tomorrowWindow,
    ];

    // First, find the session that currently contains "now".
    for (final window in candidates) {
      final bool inside =
          !current.isBefore(window.start) && !current.isAfter(window.end);

      if (inside) {
        return window;
      }
    }

    // Otherwise, return the next upcoming session.
    for (final window in candidates) {
      if (window.start.isAfter(current)) {
        return window;
      }
    }

    return tomorrowWindow;
  }

  DateTime accessStartDateTime(StoreAccessSettings settings, {DateTime? now}) {
    return _resolveAccessWindow(settings, now: now).start;
  }

  DateTime accessEndDateTime(StoreAccessSettings settings, {DateTime? now}) {
    return _resolveAccessWindow(settings, now: now).end;
  }

  _ClockTime _parseTimeOfDay(String value) {
    final parts = value.split(':');

    return _ClockTime(
      hour: int.tryParse(parts[0]) ?? 8,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  String _formatMinutes(int totalMinutes) {
    var normalized = totalMinutes % (24 * 60);

    if (normalized < 0) {
      normalized += 24 * 60;
    }

    final int hour = normalized ~/ 60;

    final int minute = normalized % 60;

    final String suffix = hour >= 12 ? 'PM' : 'AM';

    final int hour12 = hour % 12 == 0 ? 12 : hour % 12;

    return '$hour12:'
        '${minute.toString().padLeft(2, '0')} '
        '$suffix';
  }
}

class _ClockTime {
  final int hour;
  final int minute;

  const _ClockTime({required this.hour, required this.minute});
}

class _ResolvedAccessWindow {
  final DateTime opening;
  final DateTime closing;
  final DateTime start;
  final DateTime end;

  const _ResolvedAccessWindow({
    required this.opening,
    required this.closing,
    required this.start,
    required this.end,
  });
}
