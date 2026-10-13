import 'models/app_notification.dart';
import 'models/notification_type.dart';
import 'notification_factory.dart';
import 'notification_repository.dart';

class NotificationService {
  final NotificationRepository _repository;

  NotificationService(this._repository);

  Future<List<AppNotification>> fetchNotifications() {
    return _repository.fetchNotifications();
  }

  Future<int> getUnreadCount() {
    return _repository.getUnreadCount();
  }

  Future<void> createNotification(AppNotification notification) async {
    final shouldCreate = await _shouldCreateNotification(notification);

    if (!shouldCreate) return;

    await _repository.createNotification(notification);
  }

  Future<void> notifyNewOrder({
    required String locationId,
    required String orderId,
    required String createdByName,
    required DateTime createdAt,
  }) async {
    final notification = NotificationFactory.newOrder(
      locationId: locationId,
      orderId: orderId,
      createdByName: createdByName,
      createdAt: createdAt,
    );

    await createNotification(notification);
  }

  Future<void> markAsRead(String id) {
    return _repository.markAsRead(id);
  }

  Future<void> markAllAsRead() {
    return _repository.markAllAsRead();
  }

  Future<void> deleteNotification(String id) {
    return _repository.deleteNotification(id);
  }

  Future<bool> _shouldCreateNotification(AppNotification notification) async {
    final existingNotifications = await _repository.fetchNotifications();

    final hasDuplicate = existingNotifications.any((existing) {
      final sameType = existing.type == notification.type;
      final samePayload = _payloadMatches(existing, notification);

      if (notification.type == NotificationType.transaction ||
          notification.type == NotificationType.newOrder ||
          notification.type == NotificationType.orderPrepared ||
          notification.type == NotificationType.stockAlert ||
          notification.type == NotificationType.exportReminder ||
          notification.type == NotificationType.lowStock ||
          notification.type == NotificationType.criticalStock ||
          notification.type == NotificationType.deadStock) {
        return sameType && samePayload;
      }

      final sameDay = _isSameDay(existing.createdAt, notification.createdAt);

      return sameType && samePayload && sameDay;
    });

    return !hasDuplicate;
  }

  bool _payloadMatches(AppNotification existing, AppNotification incoming) {
    final existingPayload = existing.payload;
    final incomingPayload = incoming.payload;

    if (existingPayload.length != incomingPayload.length) {
      return false;
    }

    for (final key in incomingPayload.keys) {
      if (existingPayload[key]?.toString() !=
          incomingPayload[key]?.toString()) {
        return false;
      }
    }

    return true;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<void> notifyTransactionCompleted({
    required String locationId,
    required String orderId,
    required String amount,
    required String processedByName,
    required DateTime completedAt,
  }) async {
    final notification = NotificationFactory.transaction(
      locationId: locationId,
      orderId: orderId,
      amount: amount,
      processedByName: processedByName,
      completedAt: completedAt,
    );

    await createNotification(notification);
  }

  Future<void> resolveNewOrderNotification({required String orderId}) {
    return _repository.resolveNotificationByPayload(
      type: NotificationType.newOrder.name,
      payloadKey: 'orderId',
      payloadValue: orderId,
    );
  }

  Future<void> notifyOrderPrepared({
    required String locationId,
    required String orderId,
    required String preparedByName,
    required DateTime preparedAt,
  }) async {
    final notification = NotificationFactory.orderPrepared(
      locationId: locationId,
      orderId: orderId,
      preparedByName: preparedByName,
      preparedAt: preparedAt,
    );

    await createNotification(notification);
  }

  Future<void> resolveOrderPreparedNotification({required String orderId}) {
    return _repository.resolveNotificationByPayload(
      type: NotificationType.orderPrepared.name,
      payloadKey: 'orderId',
      payloadValue: orderId,
    );
  }

  Future<void> notifyLowStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String quantity,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    await resolveCriticalStockNotification(itemId: itemId);
    await resolveDeadStockNotification(itemId: itemId);

    final notification = NotificationFactory.lowStock(
      locationId: locationId,
      itemId: itemId,
      itemName: itemName,
      quantity: quantity,
      unit: unit,
      triggeredByName: triggeredByName,
      triggeredAt: triggeredAt,
    );

    await createNotification(notification);
  }

  Future<void> notifyCriticalStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String quantity,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    await resolveLowStockNotification(itemId: itemId);
    await resolveDeadStockNotification(itemId: itemId);

    final notification = NotificationFactory.criticalStock(
      locationId: locationId,
      itemId: itemId,
      itemName: itemName,
      quantity: quantity,
      unit: unit,
      triggeredByName: triggeredByName,
      triggeredAt: triggeredAt,
    );

    await createNotification(notification);
  }

  Future<void> notifyDeadStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    await resolveLowStockNotification(itemId: itemId);
    await resolveCriticalStockNotification(itemId: itemId);

    final notification = NotificationFactory.deadStock(
      locationId: locationId,
      itemId: itemId,
      itemName: itemName,
      unit: unit,
      triggeredByName: triggeredByName,
      triggeredAt: triggeredAt,
    );

    await createNotification(notification);
  }

  Future<void> resolveLowStockNotification({required String itemId}) {
    return _repository.resolveNotificationByPayload(
      type: NotificationType.lowStock.name,
      payloadKey: 'itemId',
      payloadValue: itemId,
    );
  }

  Future<void> resolveCriticalStockNotification({required String itemId}) {
    return _repository.resolveNotificationByPayload(
      type: NotificationType.criticalStock.name,
      payloadKey: 'itemId',
      payloadValue: itemId,
    );
  }

  Future<void> resolveDeadStockNotification({required String itemId}) {
    return _repository.resolveNotificationByPayload(
      type: NotificationType.deadStock.name,
      payloadKey: 'itemId',
      payloadValue: itemId,
    );
  }

  Future<void> resolveAllStockNotifications({required String itemId}) async {
    await resolveLowStockNotification(itemId: itemId);
    await resolveCriticalStockNotification(itemId: itemId);
    await resolveDeadStockNotification(itemId: itemId);
  }

  Future<void> notifyStockAlert({
    required String locationId,
    required List<Map<String, dynamic>> items,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    if (items.isEmpty) return;

    final notification = NotificationFactory.stockAlert(
      locationId: locationId,
      items: items,
      triggeredByName: triggeredByName,
      triggeredAt: triggeredAt,
    );

    await createNotification(notification);
  }

  Future<void> resolveStockAlertNotifications() {
    return _repository.resolveNotificationsByType(
      type: NotificationType.stockAlert.name,
    );
  }

  Future<Map<String, String>> fetchStockNotificationStates() {
    return _repository.fetchStockNotificationStates();
  }

  Future<void> upsertStockNotificationStates(
    List<Map<String, dynamic>> states,
  ) {
    return _repository.upsertStockNotificationStates(states);
  }

  Future<void> notifyExportReminder({
    required String locationId,
    required String reportType,
    required String periodType,
    required String periodKey,
  }) async {
    final notification = NotificationFactory.exportReminder(
      locationId: locationId,
      reportType: reportType,
      periodType: periodType,
      periodKey: periodKey,
    );

    await createNotification(notification);
  }

}
