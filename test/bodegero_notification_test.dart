import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/notifications/models/app_notification.dart';
import 'package:inventory_plus/notifications/notification_repository.dart';
import 'package:inventory_plus/notifications/notification_service.dart';

class _NotificationRepository implements NotificationRepository {
  final byLifecycle = <String, AppNotification>{};

  @override
  Future<void> upsertLifecycleNotification(
    AppNotification notification, {
    required String lifecycleKey,
  }) async {
    byLifecycle[lifecycleKey] = notification.copyWith(id: lifecycleKey);
  }

  @override
  Future<List<AppNotification>> fetchActiveLifecycleNotifications() async =>
      byLifecycle.values.where((item) => !item.isResolved).toList();

  @override
  Future<void> updateNotification(AppNotification notification) async {
    byLifecycle[notification.id] = notification;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Bodegero loading alert is separate from Helper order alert', () async {
    final repository = _NotificationRepository();
    final service = NotificationService(repository);
    final assignedAt = DateTime.utc(2026, 11, 15);

    await service.notifyOrderAssigned(
      locationId: 'store-1',
      orderId: 'order-1',
      helperId: 'helper-1',
      helperName: 'Helper',
      assignedByName: 'Cashier',
      assignedAt: assignedAt,
    );
    await service.notifyBodegeroOrderAssigned(
      locationId: 'store-1',
      orderId: 'order-1',
      bodegeroId: 'bodegero-1',
      assignedByName: 'Cashier',
      assignedAt: assignedAt,
    );

    expect(repository.byLifecycle.keys, {
      'order-workflow:order-1',
      'order-loading:order-1',
    });
    final loading = repository.byLifecycle['order-loading:order-1']!;
    expect(loading.targetRoles, ['bodegero']);
    expect(loading.payload['bodegeroId'], 'bodegero-1');

    await service.resolveBodegeroLoadingNotification(orderId: 'order-1');
    expect(repository.byLifecycle['order-loading:order-1']!.isResolved, isTrue);
    expect(repository.byLifecycle['order-workflow:order-1']!.isResolved, isFalse);
  });
}
