import 'models/app_notification.dart';
import 'models/notification_type.dart';
import 'notification_factory.dart';
import 'notification_repository.dart';

class NotificationService {
  final NotificationRepository _repository;
  Future<void> _writeQueue = Future<void>.value();

  NotificationService(this._repository);

  Future<List<AppNotification>> fetchNotifications() {
    return _repository.fetchNotifications();
  }

  Future<int> getUnreadCount() {
    return _repository.getUnreadCount();
  }

  Future<void> createNotification(AppNotification notification) async {
    await _enqueueWrite(() => _saveLifecycleAware(notification));
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

  Future<void> _saveLifecycleAware(AppNotification notification) async {
    final existingNotifications = await _repository
        .fetchActiveLifecycleNotifications();
    final identity = _logicalIdentity(notification);

    final matches = existingNotifications
        .where((existing) {
          if (identity != null) {
            return _logicalIdentity(existing) == identity;
          }

          return existing.type == notification.type &&
              _sameAudience(existing, notification) &&
              _payloadMatches(existing, notification) &&
              _isSameDay(existing.createdAt, notification.createdAt);
        })
        .toList(growable: false);

    if (matches.isEmpty) {
      await _repository.createNotification(notification);
      return;
    }

    final canonical = matches.first;
    await _repository.updateNotification(
      notification.copyWith(id: canonical.id, createdAt: canonical.createdAt),
    );

    // Reconcile any historical duplicates so only one active lifecycle row
    // remains. This fixes persistence rather than merely hiding duplicates.
    final resolvedAt = DateTime.now();
    for (final duplicate in matches.skip(1)) {
      await _repository.updateNotification(
        duplicate.copyWith(isResolved: true, resolvedAt: resolvedAt),
      );
    }
  }

  String? _logicalIdentity(AppNotification notification) {
    final payload = notification.payload;
    final audience = _audienceKey(notification.targetRoles);
    switch (notification.type) {
      case NotificationType.newOrder:
      case NotificationType.orderAssigned:
      case NotificationType.orderPrepared:
      case NotificationType.orderCancelled:
        final orderId = payload['orderId']?.toString();
        return orderId == null ? null : 'order-workflow:$orderId';
      case NotificationType.lowStock:
      case NotificationType.criticalStock:
      case NotificationType.deadStock:
        final itemId = payload['itemId']?.toString();
        return itemId == null ? null : 'stock-alert:$audience:$itemId';
      case NotificationType.stockAlert:
        final items = payload['items'];
        if (items is List && items.length == 1 && items.first is Map) {
          final itemId = (items.first as Map)['itemId']?.toString();
          return itemId == null ? null : 'stock-alert:$audience:$itemId';
        }
        return null;
      case NotificationType.exportReminder:
        final reportType = payload['reportType']?.toString();
        final periodType = payload['periodType']?.toString();
        final periodKey = payload['periodKey']?.toString();
        if (reportType == null || periodType == null || periodKey == null) {
          return null;
        }
        return 'export:$audience:$reportType:$periodType:$periodKey';
      case NotificationType.transaction:
        final transactionId = payload['transactionId']?.toString();
        final orderId = payload['orderId']?.toString();
        final subjectId = transactionId ?? orderId;
        return subjectId == null ? null : 'transaction:$audience:$subjectId';
      case NotificationType.inventoryRestocked:
        final transactionId = payload['transactionId']?.toString();
        return transactionId == null
            ? null
            : 'restock:$audience:$transactionId';
      case NotificationType.inventoryAdded:
      case NotificationType.inventoryUpdated:
      case NotificationType.inventoryDeleted:
      case NotificationType.system:
        return null;
    }
  }

  bool _sameAudience(AppNotification a, AppNotification b) {
    return _audienceKey(a.targetRoles) == _audienceKey(b.targetRoles);
  }

  String _audienceKey(List<String> roles) {
    final normalized = roles.map((role) => role.toLowerCase()).toList()..sort();
    return normalized.join('|');
  }

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final next = _writeQueue.then((_) => operation());
    _writeQueue = next.catchError((_) {});
    return next;
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

  Future<void> resolveAllStockNotifications({required String itemId}) {
    return _enqueueWrite(() => _resolveAllStockNotifications(itemId));
  }

  Future<void> _resolveAllStockNotifications(String itemId) async {
    final active = await _repository.fetchActiveLifecycleNotifications();
    final identitySuffix = ':$itemId';
    final now = DateTime.now();

    for (final notification in active) {
      final identity = _logicalIdentity(notification);
      if (identity != null &&
          identity.startsWith('stock-alert:') &&
          identity.endsWith(identitySuffix)) {
        await _repository.updateNotification(
          notification.copyWith(isResolved: true, resolvedAt: now),
        );
      }
    }
  }

  Future<void> notifyStockAlert({
    required String locationId,
    required List<Map<String, dynamic>> items,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    if (items.isEmpty) return;

    for (final item in items) {
      final itemId = item['itemId']?.toString();
      if (itemId == null || itemId.isEmpty) continue;

      final itemName = item['itemName']?.toString() ?? 'Item';
      final quantity = item['quantity']?.toString() ?? '0';
      final unit = item['unit']?.toString() ?? '';

      switch (item['status']?.toString()) {
        case 'low':
          await notifyLowStock(
            locationId: locationId,
            itemId: itemId,
            itemName: itemName,
            quantity: quantity,
            unit: unit,
            triggeredByName: triggeredByName,
            triggeredAt: triggeredAt,
          );
          break;
        case 'critical':
          await notifyCriticalStock(
            locationId: locationId,
            itemId: itemId,
            itemName: itemName,
            quantity: quantity,
            unit: unit,
            triggeredByName: triggeredByName,
            triggeredAt: triggeredAt,
          );
          break;
        case 'dead':
          await notifyDeadStock(
            locationId: locationId,
            itemId: itemId,
            itemName: itemName,
            unit: unit,
            triggeredByName: triggeredByName,
            triggeredAt: triggeredAt,
          );
          break;
      }
    }
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

  Future<void> resolveExportReminder({
    required String reportType,
    required String periodType,
    required String periodKey,
  }) {
    return _enqueueWrite(
      () => _resolveExportReminder(reportType, periodType, periodKey),
    );
  }

  Future<void> _resolveExportReminder(
    String reportType,
    String periodType,
    String periodKey,
  ) async {
    final active = await _repository.fetchActiveLifecycleNotifications();
    final identitySuffix =
        ':${reportType.toLowerCase()}:'
        '${periodType.toLowerCase()}:$periodKey';
    final now = DateTime.now();

    for (final notification in active) {
      final identity = _logicalIdentity(notification);
      if (identity != null &&
          identity.startsWith('export:') &&
          identity.endsWith(identitySuffix)) {
        await _repository.updateNotification(
          notification.copyWith(isResolved: true, resolvedAt: now),
        );
      }
    }
  }

  Future<void> notifyOrderAssigned({
    required String locationId,
    required String orderId,
    required String helperId,
    required String helperName,
    required String assignedByName,
    required DateTime assignedAt,
  }) async {
    final notification = NotificationFactory.orderAssigned(
      locationId: locationId,
      orderId: orderId,
      helperId: helperId,
      helperName: helperName,
      assignedByName: assignedByName,
      assignedAt: assignedAt,
    );

    await createNotification(notification);
  }

  Future<void> notifyInventoryRestocked({
    required String locationId,
    required String transactionId,
    required String productId,
    required String productName,
    required String staffId,
    required String staffName,
    required double quantityAdded,
    required double newQuantity,
  }) async {
    await resolveAllStockNotifications(itemId: productId);

    final notification = NotificationFactory.inventoryRestocked(
      locationId: locationId,
      transactionId: transactionId,
      productId: productId,
      productName: productName,
      staffId: staffId,
      staffName: staffName,
      quantityAdded: quantityAdded,
      newQuantity: newQuantity,
    );

    await createNotification(notification);
  }

  Future<void> resolveOrderWorkflowNotification({required String orderId}) {
    return _enqueueWrite(() => _resolveOrderWorkflowNotification(orderId));
  }

  Future<void> _resolveOrderWorkflowNotification(String orderId) async {
    final active = await _repository.fetchActiveLifecycleNotifications();
    final identity = 'order-workflow:$orderId';
    final now = DateTime.now();

    for (final notification in active) {
      if (_logicalIdentity(notification) == identity) {
        await _repository.updateNotification(
          notification.copyWith(isResolved: true, resolvedAt: now),
        );
      }
    }
  }
}
