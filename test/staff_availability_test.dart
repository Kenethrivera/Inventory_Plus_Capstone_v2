import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/staff_availability.dart';

void main() {
  test('assigned work alone keeps an online helper available', () {
    expect(
      resolveStaffAvailability(
        isOnline: true,
        isOnBreak: false,
        isHelper: true,
        activeOrders: 5,
      ),
      StaffAvailability.available,
    );

    expect(
      resolveStaffAvailability(
        isOnline: true,
        isOnBreak: false,
        isHelper: true,
        activeOrders: 5,
        currentModule: staffPreparingModule,
      ),
      StaffAvailability.preparing,
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

  test('Bodegero is loading only while inside the loading workflow', () {
    final assigned = CustomerOrder.fromJson({
      'id': 'heavy-1',
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_bodegero_id': 'bodegero-1',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
        },
      ],
    });
    expect(activeLoadingWorkloads([assigned])['bodegero-1'], 1);
    expect(
      resolveStaffAvailability(
        isOnline: true,
        isOnBreak: false,
        isHelper: false,
        isBodegero: true,
        activeOrders: 1,
      ),
      StaffAvailability.available,
    );
    expect(
      resolveStaffAvailability(
        isOnline: false,
        isOnBreak: true,
        isHelper: false,
        isBodegero: true,
        activeOrders: 1,
      ),
      StaffAvailability.onBreak,
    );
    final loaded = CustomerOrder.fromJson({
      'id': 'heavy-1',
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_bodegero_id': 'bodegero-1',
      'loading_verified_at': '2026-11-14T08:15:00Z',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
        },
      ],
    });
    expect(activeLoadingWorkloads([loaded]), isEmpty);
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
        {...row, 'user_role': 'bodegero'},
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
