import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/notifications/models/app_notification.dart';
import 'package:inventory_plus/notifications/notification_repository.dart';
import 'package:inventory_plus/notifications/notification_service.dart';
import 'package:inventory_plus/notifications/order_delay_policy.dart';

final _start = DateTime.utc(2026, 11, 18, 8);

CustomerOrder _order({
  String status = 'pending',
  bool heavy = false,
  String? helperId,
  String? bodegeroId,
  DateTime? assignedAt,
  DateTime? updatedAt,
  DateTime? preparedAt,
}) => CustomerOrder(
  id: 'order-1',
  status: status,
  createdAt: _start,
  updatedAt: updatedAt,
  assignedAt: assignedAt,
  preparedAt: preparedAt,
  assignedHelperId: helperId,
  assignedBodegeroId: bodegeroId,
  items: [
    CustomerOrderItem(
      productId: 'product-1',
      productName: 'Item',
      quantity: 1,
      requiresLoading: heavy,
    ),
  ],
);

class _MemoryNotifications extends Fake implements NotificationRepository {
  final notifications = <String, AppNotification>{};
  int inserts = 0;

  @override
  Future<List<AppNotification>> fetchActiveLifecycleNotifications() async =>
      notifications.values
          .where((notification) => !notification.isResolved)
          .toList();

  @override
  Future<void> upsertLifecycleNotification(
    AppNotification notification, {
    required String lifecycleKey,
  }) async {
    final existing = notifications.values.where(
      (value) =>
          !value.isResolved &&
          value.payload['orderId'] == notification.payload['orderId'] &&
          value.payload['stage'] == notification.payload['stage'],
    );
    if (existing.isNotEmpty) return;
    inserts++;
    notifications['$lifecycleKey-$inserts'] = notification.copyWith(
      id: '$lifecycleKey-$inserts',
    );
  }

  @override
  Future<void> updateNotification(AppNotification notification) async {
    notifications[notification.id] = notification;
  }
}

void main() {
  test('each order stage starts its own fifteen-minute clock', () {
    expect(
      overdueOrderStage(_order(), _start.add(const Duration(minutes: 14))),
      isNull,
    );
    expect(
      overdueOrderStage(
        _order(),
        _start.add(const Duration(minutes: 15)),
      )?.stage,
      OrderDelayStage.waitingForStaff,
    );

    final assignedAt = _start.add(const Duration(minutes: 20));
    final preparing = _order(helperId: 'helper-1', assignedAt: assignedAt);
    expect(
      overdueOrderStage(preparing, assignedAt.add(const Duration(minutes: 14))),
      isNull,
    );
    expect(
      overdueOrderStage(
        preparing,
        assignedAt.add(const Duration(minutes: 15)),
      )?.stage,
      OrderDelayStage.beingPrepared,
    );

    final preparedAt = assignedAt.add(const Duration(minutes: 20));
    final ready = _order(status: 'prepared', preparedAt: preparedAt);
    expect(
      overdueOrderStage(ready, preparedAt.add(const Duration(minutes: 14))),
      isNull,
    );
    expect(
      overdueOrderStage(
        ready,
        preparedAt.add(const Duration(minutes: 15)),
      )?.stage,
      OrderDelayStage.readyForRelease,
    );
    expect(
      overdueOrderStage(
        _order(status: 'completed'),
        preparedAt.add(const Duration(hours: 1)),
      ),
      isNull,
    );
  });

  test('heavy-only preparation uses its assignment update time', () {
    final assignedAt = _start.add(const Duration(minutes: 30));
    final order = _order(heavy: true, bodegeroId: 'b-1', updatedAt: assignedAt);
    expect(
      overdueOrderStage(order, assignedAt.add(const Duration(minutes: 14))),
      isNull,
    );
    expect(
      overdueOrderStage(
        order,
        assignedAt.add(const Duration(minutes: 15)),
      )?.stage,
      OrderDelayStage.beingPrepared,
    );
  });

  test(
    'alerts are once per stage and resolve when the stage changes',
    () async {
      final repository = _MemoryNotifications();
      final service = NotificationService(repository);
      final firstAlertAt = _start.add(const Duration(minutes: 15));

      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [_order()],
          now: firstAlertAt,
        ),
        isTrue,
      );
      expect(repository.inserts, 1);
      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [_order()],
          now: firstAlertAt.add(const Duration(minutes: 5)),
        ),
        isFalse,
      );
      expect(repository.inserts, 1);

      final assignedAt = firstAlertAt.add(const Duration(minutes: 5));
      final preparing = _order(helperId: 'helper-1', assignedAt: assignedAt);
      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [preparing],
          now: assignedAt,
        ),
        isTrue,
      );
      expect((await repository.fetchActiveLifecycleNotifications()), isEmpty);

      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [preparing],
          now: assignedAt.add(const Duration(minutes: 15)),
        ),
        isTrue,
      );
      expect(repository.inserts, 2);

      final preparedAt = assignedAt.add(const Duration(minutes: 16));
      final ready = _order(status: 'prepared', preparedAt: preparedAt);
      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [ready],
          now: preparedAt,
        ),
        isTrue,
      );
      expect((await repository.fetchActiveLifecycleNotifications()), isEmpty);
      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [ready],
          now: preparedAt.add(const Duration(minutes: 15)),
        ),
        isTrue,
      );
      expect(repository.inserts, 3);

      expect(
        await service.syncOrderDelayNotifications(
          locationId: 'store-1',
          orders: [_order(status: 'completed')],
          now: preparedAt.add(const Duration(minutes: 16)),
        ),
        isTrue,
      );
      expect((await repository.fetchActiveLifecycleNotifications()), isEmpty);
    },
  );

  test('an order update does not restart an active stage alert', () async {
    final repository = _MemoryNotifications();
    final service = NotificationService(repository);
    final assignedAt = _start.add(const Duration(minutes: 5));
    final heavyOrder = _order(
      heavy: true,
      bodegeroId: 'b-1',
      updatedAt: assignedAt,
    );

    await service.syncOrderDelayNotifications(
      locationId: 'store-1',
      orders: [heavyOrder],
      now: assignedAt.add(const Duration(minutes: 15)),
    );
    expect(repository.inserts, 1);

    final updatedOrder = _order(
      heavy: true,
      bodegeroId: 'b-1',
      updatedAt: assignedAt.add(const Duration(minutes: 16)),
    );
    expect(
      await service.syncOrderDelayNotifications(
        locationId: 'store-1',
        orders: [updatedOrder],
        now: assignedAt.add(const Duration(minutes: 16)),
      ),
      isFalse,
    );
    expect(repository.inserts, 1);
    expect(
      (await repository.fetchActiveLifecycleNotifications()),
      hasLength(1),
    );
  });
}
