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
        .where(
          (notification) =>
              !notification.isDeleted &&
              _isVisibleToCurrentRecipient(notification),
        )
        .toList();

    return notifications;

    
  }

  @override
  Future<List<AppNotification>> fetchArchivedNotifications() async {
    // Only archive records belonging to the signed-in user.
    final readRows = await _supabase
        .from('notification_reads')
        .select()
        .eq('user_id', userId)
        .eq('is_deleted', true);

    final archivedReads = List<Map<String, dynamic>>.from(readRows);

    if (archivedReads.isEmpty) {
      return <AppNotification>[];
    }

    final readsById = <String, Map<String, dynamic>>{
      for (final row in archivedReads) row['notification_id'].toString(): row,
    };

    final ids = readsById.keys.toList(growable: false);
    final archived = <AppNotification>[];

    // Process IDs in batches to avoid an oversized IN filter.
    for (var start = 0; start < ids.length; start += 100) {
      final batch = ids.skip(start).take(100).toList(growable: false);

      final notificationRows = await _supabase
          .from('notifications')
          .select()
          .eq('location_id', locationId)
          .contains('target_roles', [userRole])
          .inFilter('id', batch);

      for (final row in List<Map<String, dynamic>>.from(notificationRows)) {
        final id = row['id'].toString();
        final readState = readsById[id];

        if (readState == null) continue;

        final notification = AppNotification.fromJson(
          row,
          readState: readState,
        );

        if (notification.isDeleted &&
            _isVisibleToCurrentRecipient(notification)) {
          archived.add(notification);
        }
      }
    }

    archived.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return archived;
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

    final now = DateTime.now().toUtc().toIso8601String();

    // Insert missing read-state rows without overwriting
    // existing archived rows.
    final rows = ids
        .map(
          (id) => {
            'notification_id': id,
            'user_id': userId,
            'is_read': false,
            'is_deleted': false,
          },
        )
        .toList();

    await _supabase
        .from('notification_reads')
        .upsert(
          rows,
          onConflict: 'notification_id,user_id',
          ignoreDuplicates: true,
        );

    // Update read state only. Never reset archive state.
    await _supabase
        .from('notification_reads')
        .update({'is_read': true, 'read_at': now})
        .eq('user_id', userId)
        .inFilter('notification_id', ids);
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

    final now = DateTime.now().toUtc().toIso8601String();

    // Archive is per user. No notification is physically deleted.
    // Batch writes avoid sending one request per notification.
    for (var start = 0; start < ids.length; start += 100) {
      final batch = ids
          .skip(start)
          .take(100)
          .map(
            (id) => {
              'notification_id': id,
              'user_id': userId,
              'is_read': true,
              'read_at': now,
              'is_deleted': true,
              'deleted_at': now,
            },
          )
          .toList();

      await _supabase
          .from('notification_reads')
          .upsert(batch, onConflict: 'notification_id,user_id');
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
