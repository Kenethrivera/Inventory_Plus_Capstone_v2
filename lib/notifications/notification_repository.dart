import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/app_notification.dart';

abstract class NotificationRepository {
  Future<List<AppNotification>> fetchNotifications();

  Future<List<AppNotification>> fetchArchivedNotifications();

  /// Active rows used only by lifecycle-aware persistence. User-specific read
  /// and delete state is intentionally not part of logical event identity.
  Future<List<AppNotification>> fetchActiveLifecycleNotifications();

  Future<void> createNotification(AppNotification notification);

  Future<void> upsertLifecycleNotification(
    AppNotification notification, {
    required String lifecycleKey,
  });

  Future<void> updateNotification(AppNotification notification);

  Future<void> markAsRead(String notificationId);

  Future<void> markAsReadBatch(Iterable<String> notificationIds);

  Future<void> markAllAsRead();

  Future<void> rearmNotificationReads(String notificationId);

  Future<void> archiveNotifications(Iterable<String> notificationIds);

  Future<int> getUnreadCount();

  Future<void> resolveNotificationByPayload({
    required String type,
    required String payloadKey,
    required String payloadValue,
  });

  Future<void> resolveNotificationsByType({required String type});

  Future<Map<String, String>> fetchStockNotificationStates();

  Future<void> upsertStockNotificationStates(List<Map<String, dynamic>> states);

  Future<void> transitionStockNotification({
    required String itemId,
    required String status,
    AppNotification? notification,
  });
}

class SupabaseNotificationRepository implements NotificationRepository {
  final SupabaseClient _supabase;

  final String locationId;
  final String userId;
  final String userRole;
  final String recipientId;
  final String sessionToken;

  SupabaseNotificationRepository({
    required SupabaseClient supabase,
    required this.locationId,
    required this.userId,
    required this.userRole,
    required this.recipientId,
    required this.sessionToken,
  }) : _supabase = supabase;

  @override
  Future<List<AppNotification>> fetchNotifications() async {
    return _fetchFeed(archived: false);
  }

  @override
  Future<List<AppNotification>> fetchArchivedNotifications() async {
    return _fetchFeed(archived: true);
  }

  Future<List<AppNotification>> _fetchFeed({required bool archived}) async {
    final response = await _supabase.rpc(
      'notification_feed_v1',
      params: <String, dynamic>{
        'p_session_token': sessionToken,
        'p_archived': archived,
      },
    );
    final notifications = <AppNotification>[];
    for (final raw in response as List<dynamic>) {
      final row = Map<String, dynamic>.from(raw as Map);
      final read = row['read_state'];
      final notification = AppNotification.fromJson(
        row,
        readState: read is Map ? Map<String, dynamic>.from(read) : null,
      );
      if (notification.isDeleted == archived &&
          _isVisibleToCurrentRecipient(notification)) {
        notifications.add(notification);
      }
    }
    return notifications;
  }

  bool _isVisibleToCurrentRecipient(AppNotification notification) {
    final helperId = notification.payload['helperId']?.toString();

    if (userRole == 'helper' &&
        notification.type.name == 'orderAssigned' &&
        helperId != null &&
        helperId != recipientId) {
      return false;
    }

    final bodegeroId = notification.payload['bodegeroId']?.toString();

    if (userRole == 'bodegero' &&
        notification.type.name == 'orderAssigned' &&
        bodegeroId != null &&
        bodegeroId != recipientId) {
      return false;
    }

    final approvalRecipientId = notification.payload['recipientId']?.toString();

    if (notification.payload['category'] == 'inventoryApproval' &&
        approvalRecipientId != null &&
        approvalRecipientId.isNotEmpty &&
        approvalRecipientId != recipientId) {
      return false;
    }

    return true;
  }

  @override
  Future<void> createNotification(AppNotification notification) async {
    await _supabase.from('notifications').insert(notification.toInsertJson());
  }

  @override
  Future<void> upsertLifecycleNotification(
    AppNotification notification, {
    required String lifecycleKey,
  }) async {
    await _supabase.rpc(
      'upsert_notification_lifecycle_v1',
      params: <String, dynamic>{
        'p_session_token': sessionToken,
        'p_lifecycle_key': lifecycleKey,
        'p_target_roles': notification.targetRoles,
        'p_title': notification.title,
        'p_body': notification.body,
        'p_type': notification.type.name,
        'p_priority': notification.priority.name,
        'p_payload': notification.payload,
        'p_created_at': notification.createdAt.toUtc().toIso8601String(),
      },
    );
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
    final ids = notificationIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    for (var start = 0; start < ids.length; start += 1000) {
      await _supabase.rpc(
        'notification_user_action_v1',
        params: <String, dynamic>{
          'p_session_token': sessionToken,
          'p_notification_ids': ids.skip(start).take(1000).toList(),
          'p_action': 'read',
        },
      );
    }
  }

  @override
  Future<void> markAllAsRead() async {
    final notifications = await fetchNotifications();

    await markAsReadBatch(notifications.map((notification) => notification.id));
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
  Future<void> archiveNotifications(Iterable<String> notificationIds) async {
    final ids = notificationIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    for (var start = 0; start < ids.length; start += 1000) {
      await _supabase.rpc(
        'notification_user_action_v1',
        params: <String, dynamic>{
          'p_session_token': sessionToken,
          'p_notification_ids': ids.skip(start).take(1000).toList(),
          'p_action': 'archive',
        },
      );
    }
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

  @override
  Future<void> transitionStockNotification({
    required String itemId,
    required String status,
    AppNotification? notification,
  }) async {
    await _supabase.rpc(
      'transition_stock_notification_v1',
      params: <String, dynamic>{
        'p_session_token': sessionToken,
        'p_item_id': itemId,
        'p_status': status,
        'p_title': notification?.title,
        'p_body': notification?.body,
        'p_type': notification?.type.name,
        'p_priority': notification?.priority.name,
        'p_payload': notification?.payload,
      },
    );
  }
}
