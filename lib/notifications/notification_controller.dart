import 'package:flutter/foundation.dart';

import 'models/app_notification.dart';
import 'notification_service.dart';

class NotificationController extends ChangeNotifier {
  final NotificationService _service;

  NotificationController(this._service);

  List<AppNotification> _notifications = [];
  bool _isLoading = false;
  String? _errorMessage;

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
    _setLoading(true);

    try {
      _errorMessage = null;
      _notifications = await _service.fetchNotifications();
    } catch (e) {
      _errorMessage = 'Failed to load notifications: $e';
    } finally {
      _setLoading(false);
    }
  }

  Future<void> refresh() {
    return loadNotifications();
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
}
