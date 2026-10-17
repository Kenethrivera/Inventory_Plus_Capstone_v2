import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/realtime/realtime_sync_service.dart';
import 'notification_controller.dart';
import 'notification_repository.dart';
import 'notification_service.dart';

class NotificationBootstrap {
  NotificationBootstrap._();

  static NotificationController create({
    required String locationId,
    required String userId,
    required String userRole,
    required String recipientId,
    required RealtimeSyncService realtimeSync,
  }) {
    final repository = SupabaseNotificationRepository(
      supabase: Supabase.instance.client,
      locationId: locationId,
      userId: userId,
      userRole: userRole,
      recipientId: recipientId,
    );

    final service = NotificationService(repository);

    final controller = NotificationController(service);
    controller.bindRealtimeSync(realtimeSync);
    return controller;
  }
}
