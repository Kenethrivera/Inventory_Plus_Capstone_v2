import 'notification_priority.dart';
import 'notification_type.dart';

class AppNotification {
  final String id;
  final String locationId;

  /// Roles that can see this notification.
  /// Example: ['admin'], ['helper'], ['admin', 'helper']
  final List<String> targetRoles;

  final title;
  final String body;

  final NotificationType type;
  final NotificationPriority priority;

  final Map<String, dynamic> payload;

  final DateTime createdAt;

  /// These come from notification_reads, not directly from notifications.
  final bool isRead;
  final DateTime? readAt;
  final bool isDeleted;
  final DateTime? deletedAt;

  final bool isResolved;
  final DateTime? resolvedAt;

  const AppNotification({
    required this.id,
    required this.locationId,
    required this.targetRoles,
    required this.title,
    required this.body,
    required this.type,
    required this.priority,
    required this.payload,
    required this.createdAt,
    required this.isRead,
    required this.isDeleted,
    this.readAt,
    this.deletedAt,
    required this.isResolved,
    this.resolvedAt,
  });

  AppNotification copyWith({
    String? id,
    String? locationId,
    List<String>? targetRoles,
    String? title,
    String? body,
    NotificationType? type,
    NotificationPriority? priority,
    Map<String, dynamic>? payload,
    DateTime? createdAt,
    bool? isRead,
    DateTime? readAt,
    bool? isDeleted,
    DateTime? deletedAt,
    bool? isResolved,
    DateTime? resolvedAt,
  }) {
    return AppNotification(
      id: id ?? this.id,
      locationId: locationId ?? this.locationId,
      targetRoles: targetRoles ?? this.targetRoles,
      title: title ?? this.title,
      body: body ?? this.body,
      type: type ?? this.type,
      priority: priority ?? this.priority,
      payload: payload ?? this.payload,
      createdAt: createdAt ?? this.createdAt,
      isRead: isRead ?? this.isRead,
      readAt: readAt ?? this.readAt,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      isResolved: isResolved ?? this.isResolved,
      resolvedAt: resolvedAt ?? this.resolvedAt,
    );
  }

  factory AppNotification.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? readState,
  }) {
    return AppNotification(
      id: json['id'].toString(),
      locationId: json['location_id'].toString(),
      targetRoles: List<String>.from(json['target_roles'] ?? []),
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      type: NotificationType.values.byName(json['type'] as String),
      priority: NotificationPriority.values.byName(json['priority'] as String),
      payload: Map<String, dynamic>.from(json['payload'] ?? {}),
      createdAt: DateTime.parse(json['created_at'].toString()).toLocal(),
      isRead: readState?['is_read'] as bool? ?? false,
      readAt: readState?['read_at'] != null
          ? DateTime.parse(readState!['read_at'].toString()).toLocal()
          : null,
      isDeleted: readState?['is_deleted'] as bool? ?? false,
      deletedAt: readState?['deleted_at'] != null
          ? DateTime.parse(readState!['deleted_at'].toString()).toLocal()
          : null,
      isResolved: json['is_resolved'] as bool? ?? false,
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'].toString()).toLocal()
          : null,
    );
  }

  Map<String, dynamic> toInsertJson() {
    return {
      'location_id': locationId,
      'target_roles': targetRoles,
      'title': title,
      'body': body,
      'type': type.name,
      'priority': priority.name,
      'payload': payload,
      'created_at': createdAt.toUtc().toIso8601String(),
      'is_resolved': isResolved,
      'resolved_at': resolvedAt?.toUtc().toIso8601String(),
    };
  }
}
