import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/staff_availability.dart';

void main() {
  test('assigned work makes an online helper busy on both screens', () {
    expect(
      resolveStaffAvailability(
        isOnline: true,
        isOnBreak: false,
        isHelper: true,
        activeOrders: 1,
      ),
      StaffAvailability.busy,
    );
    expect(
      resolveStaffAvailability(
        isOnline: true,
        isOnBreak: false,
        isHelper: true,
        activeOrders: 0,
      ),
      StaffAvailability.available,
    );
  });

  test('break takes priority over workload, while logout is offline', () {
    expect(
      resolveStaffAvailability(
        isOnline: false,
        isOnBreak: true,
        isHelper: true,
        activeOrders: 1,
      ),
      StaffAvailability.onBreak,
    );
    expect(
      resolveStaffAvailability(
        isOnline: false,
        isOnBreak: false,
        isHelper: true,
        activeOrders: 1,
      ),
      StaffAvailability.offline,
    );
  });

  test('only recent, signed-in break presence remains visible', () {
    final now = DateTime.utc(2026, 11, 13, 9);
    final row = <String, dynamic>{
      'user_role': 'helper',
      'is_online': false,
      'current_module': 'On break',
      'last_seen_at': now
          .subtract(const Duration(minutes: 1))
          .toIso8601String(),
      'logged_out_at': null,
    };
    expect(
      isCurrentStaffPresence(
        row,
        now: now,
        activeTimeout: const Duration(minutes: 2),
      ),
      isTrue,
    );
    expect(
      isCurrentStaffPresence(
        {...row, 'logged_out_at': now.toIso8601String()},
        now: now,
        activeTimeout: const Duration(minutes: 2),
      ),
      isFalse,
    );
    expect(
      isCurrentStaffPresence(
        {
          ...row,
          'last_seen_at': now
              .subtract(const Duration(minutes: 3))
              .toIso8601String(),
        },
        now: now,
        activeTimeout: const Duration(minutes: 2),
      ),
      isFalse,
    );
  });
}
