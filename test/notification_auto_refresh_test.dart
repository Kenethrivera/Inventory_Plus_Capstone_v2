import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/notifications/models/app_notification.dart';
import 'package:inventory_plus/notifications/models/notification_priority.dart';
import 'package:inventory_plus/notifications/models/notification_type.dart';
import 'package:inventory_plus/notifications/notification_controller.dart';
import 'package:inventory_plus/notifications/notification_repository.dart';
import 'package:inventory_plus/notifications/notification_service.dart';
import 'package:inventory_plus/services/realtime/realtime_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryNotifications extends Fake implements NotificationRepository {
  List<AppNotification> records = [];
  int fetchCount = 0;

  @override
  Future<List<AppNotification>> fetchNotifications() async {
    fetchCount++;
    return List<AppNotification>.of(records);
  }
}

void main() {
  testWidgets('notification count updates without opening the bell', (
    tester,
  ) async {
    final repository = _MemoryNotifications();
    final controller = NotificationController(NotificationService(repository));
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    controller.bindRealtimeSync(RealtimeSyncService(supabase: client));
    var disposed = false;
    addTearDown(() {
      if (!disposed) {
        controller.dispose();
        client.dispose();
      }
    });

    await controller.loadNotifications();
    expect(controller.unreadCount, 0);

    repository.records = [
      AppNotification(
        id: 'notification-1',
        locationId: 'store-1',
        targetRoles: const ['admin'],
        title: 'New notification',
        body: 'A new event occurred.',
        type: NotificationType.system,
        priority: NotificationPriority.medium,
        payload: const {},
        createdAt: DateTime.utc(2026, 11, 28),
        isRead: false,
        isDeleted: false,
        isResolved: false,
      ),
    ];

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(controller.unreadCount, 1);
    expect(repository.fetchCount, 2);

    controller.dispose();
    client.dispose();
    disposed = true;
    await tester.pump(const Duration(seconds: 10));
    expect(repository.fetchCount, 2);
  });
}
