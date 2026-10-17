import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/realtime/realtime_sync_service.dart';
import 'models/app_notification.dart';
import 'notification_service.dart';

class NotificationController extends ChangeNotifier {
  final NotificationService _service;

  NotificationController(this._service);

  List<AppNotification> _notifications = [];
  bool _isLoading = false;
  String? _errorMessage;
  StreamSubscription<void>? _realtimeSubscription;
  bool _refreshInFlight = false;
  bool _refreshQueued = false;
  bool _disposed = false;

  List<AppNotification> get notifications {
    return List.unmodifiable(_notifications);
  }

  bool get isLoading => _isLoading;

  String? get errorMessage => _errorMessage;

  int get unreadCount {
    return _notifications.where((notification) => !notification.isRead).length;
  }

  bool get hasUnread => unreadCount > 0;

  Future<void> loadNotifications() async {
    return _refreshNotifications(showLoading: true);
  }

  Future<void> refresh() {
    return _refreshNotifications(showLoading: true);
  }

  void bindRealtimeSync(RealtimeSyncService realtimeSync) {
    _realtimeSubscription?.cancel();
    _realtimeSubscription = realtimeSync.notificationChanges.listen((_) {
      unawaited(_refreshNotifications());
    });
  }

  Future<void> _refreshNotifications({bool showLoading = false}) async {
    if (_disposed) return;
    if (_refreshInFlight) {
      _refreshQueued = true;
      return;
    }

    _refreshInFlight = true;
    if (showLoading) _setLoading(true);

    do {
      _refreshQueued = false;
      try {
        _errorMessage = null;
        final notifications = await _service.fetchNotifications();
        if (_disposed) return;
        _notifications = notifications;
        debugPrint(
          '[NotificationController] NOTIFICATIONS REFRESHED '
          'count=${notifications.length}',
        );
        notifyListeners();
      } catch (e) {
        if (_disposed) return;
        _errorMessage = 'Failed to load notifications: $e';
        notifyListeners();
      }
    } while (_refreshQueued && !_disposed);

    _refreshInFlight = false;
    if (showLoading && !_disposed) _setLoading(false);
  }

  Future<void> createNotification(AppNotification notification) async {
    try {
      _errorMessage = null;
      await _service.createNotification(notification);
      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create notification: $e';
      notifyListeners();
    }
  }

  Future<void> markAsRead(String notificationId) async {
    try {
      _errorMessage = null;

      await _service.markAsRead(notificationId);

      final index = _notifications.indexWhere(
        (notification) => notification.id == notificationId,
      );

      if (index != -1) {
        _notifications[index] = _notifications[index].copyWith(
          isRead: true,
          readAt: DateTime.now(),
        );

        notifyListeners();
      }
    } catch (e) {
      _errorMessage = 'Failed to mark notification as read: $e';
      notifyListeners();
    }
  }

  Future<void> markAllAsRead() async {
    try {
      _errorMessage = null;

      await _service.markAllAsRead();

      _notifications = _notifications
          .map(
            (notification) =>
                notification.copyWith(isRead: true, readAt: DateTime.now()),
          )
          .toList();

      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to mark all notifications as read: $e';
      notifyListeners();
    }
  }

  Future<void> deleteNotification(String notificationId) async {
    try {
      _errorMessage = null;

      await _service.deleteNotification(notificationId);

      _notifications.removeWhere(
        (notification) => notification.id == notificationId,
      );

      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to delete notification: $e';
      notifyListeners();
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  Future<void> notifyNewOrder({
    required String locationId,
    required String orderId,
    required String createdByName,
    required DateTime createdAt,
  }) async {
    try {
      _errorMessage = null;

      await _service.notifyNewOrder(
        locationId: locationId,
        orderId: orderId,
        createdByName: createdByName,
        createdAt: createdAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create new order notification: $e';
      notifyListeners();
    }
  }

  Future<void> notifyTransactionCompleted({
    required String locationId,
    required String orderId,
    required String amount,
    required String processedByName,
    required DateTime completedAt,
  }) async {
    try {
      _errorMessage = null;

      await _service.notifyTransactionCompleted(
        locationId: locationId,
        orderId: orderId,
        amount: amount,
        processedByName: processedByName,
        completedAt: completedAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create transaction notification: $e';
      notifyListeners();
    }
  }

  Future<void> resolveNewOrderNotification({required String orderId}) async {
    try {
      _errorMessage = null;

      await _service.resolveNewOrderNotification(orderId: orderId);

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to resolve new order notification: $e';
      notifyListeners();
    }
  }

  Future<void> notifyOrderPrepared({
    required String locationId,
    required String orderId,
    required String preparedByName,
    required DateTime preparedAt,
  }) async {
    try {
      _errorMessage = null;

      await _service.notifyOrderPrepared(
        locationId: locationId,
        orderId: orderId,
        preparedByName: preparedByName,
        preparedAt: preparedAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create prepared order notification: $e';
      notifyListeners();
    }
  }

  Future<void> resolveOrderPreparedNotification({
    required String orderId,
  }) async {
    try {
      _errorMessage = null;

      await _service.resolveOrderPreparedNotification(orderId: orderId);

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to resolve prepared order notification: $e';
      notifyListeners();
    }
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
    try {
      _errorMessage = null;

      await _service.notifyLowStock(
        locationId: locationId,
        itemId: itemId,
        itemName: itemName,
        quantity: quantity,
        unit: unit,
        triggeredByName: triggeredByName,
        triggeredAt: triggeredAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create low stock notification: $e';
      notifyListeners();
    }
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
    try {
      _errorMessage = null;

      await _service.notifyCriticalStock(
        locationId: locationId,
        itemId: itemId,
        itemName: itemName,
        quantity: quantity,
        unit: unit,
        triggeredByName: triggeredByName,
        triggeredAt: triggeredAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create critical stock notification: $e';
      notifyListeners();
    }
  }

  Future<void> notifyDeadStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    try {
      _errorMessage = null;

      await _service.notifyDeadStock(
        locationId: locationId,
        itemId: itemId,
        itemName: itemName,
        unit: unit,
        triggeredByName: triggeredByName,
        triggeredAt: triggeredAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create dead stock notification: $e';
      notifyListeners();
    }
  }

  Future<void> resolveAllStockNotifications({required String itemId}) async {
    try {
      _errorMessage = null;

      await _service.resolveAllStockNotifications(itemId: itemId);

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to resolve stock notifications: $e';
      notifyListeners();
    }
  }

  Future<void> notifyStockAlert({
    required String locationId,
    required List<Map<String, dynamic>> items,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) async {
    try {
      _errorMessage = null;

      await _service.notifyStockAlert(
        locationId: locationId,
        items: items,
        triggeredByName: triggeredByName,
        triggeredAt: triggeredAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create stock alert notification: $e';
      notifyListeners();
    }
  }

  Future<void> resolveStockAlertNotifications() async {
    try {
      _errorMessage = null;

      await _service.resolveStockAlertNotifications();

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to resolve stock alert notification: $e';
      notifyListeners();
    }
  }

  Future<Map<String, String>> fetchStockNotificationStates() {
    return _service.fetchStockNotificationStates();
  }

  Future<void> upsertStockNotificationStates(
    List<Map<String, dynamic>> states,
  ) {
    return _service.upsertStockNotificationStates(states);
  }

  Future<void> notifyExportReminder({
    required String locationId,
    required String reportType,
    required String periodType,
    required String periodKey,
  }) async {
    try {
      _errorMessage = null;

      await _service.notifyExportReminder(
        locationId: locationId,
        reportType: reportType,
        periodType: periodType,
        periodKey: periodKey,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create export reminder notification: $e';
      notifyListeners();
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
    try {
      _errorMessage = null;

      await _service.notifyOrderAssigned(
        locationId: locationId,
        orderId: orderId,
        helperId: helperId,
        helperName: helperName,
        assignedByName: assignedByName,
        assignedAt: assignedAt,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Failed to create assigned order notification: $e';
      notifyListeners();
    }
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
    _errorMessage = null;

    try {
      await _service.notifyInventoryRestocked(
        locationId: locationId,
        transactionId: transactionId,
        productId: productId,
        productName: productName,
        staffId: staffId,
        staffName: staffName,
        quantityAdded: quantityAdded,
        newQuantity: newQuantity,
      );

      await loadNotifications();
    } catch (e) {
      _errorMessage = 'Could not create restock notification: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> resolveOrderWorkflowNotification({
    required String orderId,
  }) async {
    try {
      _errorMessage = null;
      await _service.resolveOrderWorkflowNotification(orderId: orderId);
      await _refreshNotifications();
    } catch (e) {
      _errorMessage = 'Failed to resolve order notification: $e';
      notifyListeners();
    }
  }

  Future<void> resolveExportReminder({
    required String reportType,
    required String periodType,
    required String periodKey,
  }) async {
    try {
      _errorMessage = null;
      await _service.resolveExportReminder(
        reportType: reportType,
        periodType: periodType,
        periodKey: periodKey,
      );
      await _refreshNotifications();
    } catch (e) {
      _errorMessage = 'Failed to resolve export reminder: $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_realtimeSubscription?.cancel());
    super.dispose();
  }
}
