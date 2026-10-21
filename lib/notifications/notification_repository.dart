import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/app_notification.dart';

abstract class NotificationRepository {
  Future<List<AppNotification>> fetchNotifications();

  /// Active rows used only by lifecycle-aware persistence. User-specific read
  /// and delete state is intentionally not part of logical event identity.
  Future<List<AppNotification>> fetchActiveLifecycleNotifications();

  Future<void> createNotification(AppNotification notification);

  Future<void> updateNotification(AppNotification notification);

  Future<void> markAsRead(String notificationId);

  Future<void> markAsReadBatch(Iterable<String> notificationIds);

  Future<void> markAllAsRead();

  Future<void> rearmNotificationReads(String notificationId);

  Future<void> deleteNotification(String notificationId);

  Future<int> getUnreadCount();

  Future<void> resolveNotificationByPayload({
    required String type,
    required String payloadKey,
    required String payloadValue,
  });

  Future<void> resolveNotificationsByType({required String type});

  Future<Map<String, String>> fetchStockNotificationStates();

  Future<void> upsertStockNotificationStates(List<Map<String, dynamic>> states);
}

class SupabaseNotificationRepository implements NotificationRepository {
  final SupabaseClient _supabase;

  final String locationId;
  final String userId;
  final String userRole;
  final String recipientId;

  SupabaseNotificationRepository({
    required SupabaseClient supabase,
    required this.locationId,
    required this.userId,
    required this.userRole,
    required this.recipientId,
  }) : _supabase = supabase;

  @override
  Future<List<AppNotification>> fetchNotifications() async {
    final notificationRows = await _supabase
        .from('notifications')
        .select()
        .eq('location_id', locationId)
        .eq('is_resolved', false)
        .contains('target_roles', [userRole])
        .order('created_at', ascending: false);

    final notificationsData = List<Map<String, dynamic>>.from(notificationRows);

    if (notificationsData.isEmpty) {
      return [];
    }

    final notificationIds = notificationsData
        .map((row) => row['id'].toString())
        .toList();

    final readRows = await _supabase
        .from('notification_reads')
        .select()
        .eq('user_id', userId)
        .inFilter('notification_id', notificationIds);

    final readsData = List<Map<String, dynamic>>.from(readRows);

    final readsByNotificationId = {
      for (final read in readsData) read['notification_id'].toString(): read,
    };

    final notifications = notificationsData
        .map((row) {
          final notificationId = row['id'].toString();
          final readState = readsByNotificationId[notificationId];

          return AppNotification.fromJson(row, readState: readState);
        })
        .where((notification) {
          if (notification.isDeleted) return false;

          // orderAssigned is role-visible in the schema, while the intended
          // recipient is carried by the existing payload.
          final helperId = notification.payload['helperId']?.toString();
          if (userRole == 'helper' &&
              notification.type.name == 'orderAssigned' &&
              helperId != null &&
              helperId != recipientId) {
            return false;
          }

          return true;
        })
        .toList();

    return notifications;
  }

  @override
  Future<void> createNotification(AppNotification notification) async {
    await _supabase.from('notifications').insert(notification.toInsertJson());
  }

  @override
  Future<List<AppNotification>> fetchActiveLifecycleNotifications() async {
    final rows = await _supabase
        .from('notifications')
        .select()
        .eq('location_id', locationId)
        .eq('is_resolved', false)
        .order('created_at', ascending: true);

    return List<Map<String, dynamic>>.from(
      rows,
    ).map(AppNotification.fromJson).toList(growable: false);
  }

  @override
  Future<void> updateNotification(AppNotification notification) async {
    await _supabase
        .from('notifications')
        .update(notification.toInsertJson())
        .eq('location_id', locationId)
        .eq('id', notification.id);
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    await markAsReadBatch([notificationId]);
  }

  @override
  Future<void> markAsReadBatch(Iterable<String> notificationIds) async {
    final ids = notificationIds.toSet();
    if (ids.isEmpty) return;
    final readAt = DateTime.now().toUtc().toIso8601String();
    final rows = ids
        .map(
          (notificationId) => {
            'notification_id': notificationId,
            'user_id': userId,
            'is_read': true,
            'read_at': readAt,
            'is_deleted': false,
            'deleted_at': null,
          },
        )
        .toList(growable: false);
    await _supabase
        .from('notification_reads')
        .upsert(rows, onConflict: 'notification_id,user_id');
  }

  @override
  Future<void> markAllAsRead() async {
    final notifications = await fetchNotifications();

    if (notifications.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();

    final rows = notifications.map((notification) {
      return {
        'notification_id': notification.id,
        'user_id': userId,
        'is_read': true,
        'read_at': now,
        'is_deleted': false,
        'deleted_at': null,
      };
    }).toList();

    await _supabase
        .from('notification_reads')
        .upsert(rows, onConflict: 'notification_id,user_id');
  }

  @override
  Future<void> rearmNotificationReads(String notificationId) async {
    await _supabase
        .from('notification_reads')
        .update({
          'is_read': false,
          'read_at': null,
          'is_deleted': false,
          'deleted_at': null,
        })
        .eq('notification_id', notificationId);
  }

  @override
  Future<void> deleteNotification(String notificationId) async {
    await _supabase.from('notification_reads').upsert({
      'notification_id': notificationId,
      'user_id': userId,
      'is_read': true,
      'read_at': DateTime.now().toUtc().toIso8601String(),
      'is_deleted': true,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'notification_id,user_id');
  }

  @override
  Future<int> getUnreadCount() async {
    final notifications = await fetchNotifications();

    return notifications.where((notification) => !notification.isRead).length;
  }

  @override
  Future<void> resolveNotificationByPayload({
    required String type,
    required String payloadKey,
    required String payloadValue,
  }) async {
    await _supabase
        .from('notifications')
        .update({
          'is_resolved': true,
          'resolved_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('location_id', locationId)
        .eq('type', type)
        .eq('payload->$payloadKey', payloadValue);
  }

  @override
  Future<void> resolveNotificationsByType({required String type}) async {
    await _supabase
        .from('notifications')
        .update({
          'is_resolved': true,
          'resolved_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('location_id', locationId)
        .eq('type', type)
        .eq('is_resolved', false);
  }

  @override
  Future<Map<String, String>> fetchStockNotificationStates() async {
    final response = await _supabase
        .from('stock_notification_states')
        .select()
        .eq('location_id', locationId);

    final rows = List<Map<String, dynamic>>.from(response);

    return {
      for (final row in rows)
        row['item_id'].toString(): row['last_status'].toString(),
    };
  }

  @override
  Future<void> upsertStockNotificationStates(
    List<Map<String, dynamic>> states,
  ) async {
    if (states.isEmpty) return;

    await _supabase
        .from('stock_notification_states')
        .upsert(states, onConflict: 'location_id,item_id');
  }
}
