import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<void> saveSettings(StoreAccessSettings settings) async {
    await supabase
        .from('store_access_settings')
        .upsert(settings.toMap(), onConflict: 'location_id');
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

    final allowed = _isWithinAllowedWindow(
      now: currentTime,
      openingTime: settings.openingTime,
      closingTime: settings.closingTime,
      beforeMinutes: settings.staffAccessBeforeMinutes,
      afterMinutes: settings.staffAccessAfterMinutes,
    );

    if (allowed) {
      return StoreAccessResult(allowed: true, reason: null, settings: settings);
    }

    final window = allowedWindowText(settings);

    return StoreAccessResult(
      allowed: false,
      reason:
          'Store is currently closed. Staff access is allowed only from $window.',
      settings: settings,
    );
  }

  String allowedWindowText(StoreAccessSettings settings) {
    final open = _parseTimeOfDay(settings.openingTime);
    final close = _parseTimeOfDay(settings.closingTime);

    final openMinutes =
        open.hour * 60 + open.minute - settings.staffAccessBeforeMinutes;
    final closeMinutes =
        close.hour * 60 + close.minute + settings.staffAccessAfterMinutes;

    return '${_formatMinutes(openMinutes)} to ${_formatMinutes(closeMinutes)}';
  }

  bool _isWithinAllowedWindow({
    required DateTime now,
    required String openingTime,
    required String closingTime,
    required int beforeMinutes,
    required int afterMinutes,
  }) {
    final open = _parseTimeOfDay(openingTime);
    final close = _parseTimeOfDay(closingTime);

    final currentMinutes = now.hour * 60 + now.minute;

    final startMinutes = open.hour * 60 + open.minute - beforeMinutes;
    final endMinutes = close.hour * 60 + close.minute + afterMinutes;

    return currentMinutes >= startMinutes && currentMinutes <= endMinutes;
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

    final hour = normalized ~/ 60;
    final minute = normalized % 60;

    final suffix = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;

    return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }

  DateTime accessEndDateTime(
  StoreAccessSettings settings, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final close = _parseTimeOfDay(settings.closingTime);

  final closingDateTime = DateTime(
    current.year,
    current.month,
    current.day,
    close.hour,
    close.minute,
  );

  return closingDateTime.add(
    Duration(minutes: settings.staffAccessAfterMinutes),
  );
}
DateTime accessStartDateTime(StoreAccessSettings settings, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final open = _parseTimeOfDay(settings.openingTime);

    final openingDateTime = DateTime(
      current.year,
      current.month,
      current.day,
      open.hour,
      open.minute,
    );

    return openingDateTime.subtract(
      Duration(minutes: settings.staffAccessBeforeMinutes),
    );
  }

}

class _ClockTime {
  final int hour;
  final int minute;

  const _ClockTime({required this.hour, required this.minute});
}
