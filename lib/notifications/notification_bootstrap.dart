import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_controller.dart';
import 'notification_repository.dart';
import 'notification_service.dart';

class NotificationBootstrap {
  NotificationBootstrap._();

  static NotificationController create({
    required String locationId,
    required String userId,
    required String userRole,
  }) {
    final repository = SupabaseNotificationRepository(
      supabase: Supabase.instance.client,
      locationId: locationId,
      userId: userId,
      userRole: userRole,
    );

    final service = NotificationService(repository);

    return NotificationController(service);
  }
}
