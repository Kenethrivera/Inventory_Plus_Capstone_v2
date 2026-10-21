import 'models/app_notification.dart';
import 'models/notification_priority.dart';
import 'models/notification_type.dart';

class NotificationFactory {
  NotificationFactory._();

  static AppNotification create({
    required String locationId,
    required List<String> targetRoles,
    required String title,
    required String body,
    required NotificationType type,
    required NotificationPriority priority,
    Map<String, dynamic> payload = const {},
  }) {
    return AppNotification(
      id: '',
      locationId: locationId,
      targetRoles: targetRoles,
      title: title,
      body: body,
      type: type,
      priority: priority,
      payload: payload,
      createdAt: DateTime.now(),
      isRead: false,
      readAt: null,
      isDeleted: false,
      deletedAt: null,
      isResolved: false,
      resolvedAt: null,
    );
  }

  static AppNotification newOrder({
    required String locationId,
    required String orderId,
    required String createdByName,
    required DateTime createdAt,
  }) {
    final shortOrderId = _shortOrderId(orderId);
    final formattedTime = _formatDateTime(createdAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin', 'helper'],
      title: 'New Order #$shortOrderId',
      body: 'Created by $createdByName • $formattedTime',
      type: NotificationType.newOrder,
      priority: NotificationPriority.high,
      payload: {
        'orderId': orderId,
        'createdByName': createdByName,
        'createdAt': createdAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification transaction({
    required String locationId,
    required String orderId,
    required String amount,
    required String processedByName,
    required DateTime completedAt,
  }) {
    final shortOrderId = _shortOrderId(orderId);
    final formattedTime = _formatDateTime(completedAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: 'Transaction Completed #$shortOrderId',
      body: 'Processed by $processedByName • $formattedTime\nAmount: ₱$amount',
      type: NotificationType.transaction,
      priority: NotificationPriority.medium,
      payload: {
        'orderId': orderId,
        'amount': amount,
        'processedByName': processedByName,
        'completedAt': completedAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification exportReminder({
    required String locationId,
    required String reportType,
    required String periodType,
    required String periodKey,
  }) {
    final cleanReportType = reportType.toLowerCase();
    final cleanPeriodType = periodType.toLowerCase();

    final reportLabel = cleanReportType == 'sales' ? 'Sales' : 'Inventory';

    final periodLabel =
        cleanPeriodType[0].toUpperCase() + cleanPeriodType.substring(1);

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: '$periodLabel $reportLabel Report Ready',
      body: '$reportLabel $periodLabel report is ready to export.',
      type: NotificationType.exportReminder,
      priority: NotificationPriority.high,
      payload: {
        'reportType': cleanReportType,
        'periodType': cleanPeriodType,
        'periodKey': periodKey,
      },
    );
  }

  static AppNotification lowStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String quantity,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) {
    final formattedTime = _formatDateTime(triggeredAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: 'Low Stock: $itemName',
      body:
          '$quantity $unit remaining • Triggered by $triggeredByName • $formattedTime',
      type: NotificationType.lowStock,
      priority: NotificationPriority.high,
      payload: {
        'itemId': itemId,
        'itemName': itemName,
        'quantity': quantity,
        'unit': unit,
        'triggeredByName': triggeredByName,
        'triggeredAt': triggeredAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification criticalStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String quantity,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) {
    final formattedTime = _formatDateTime(triggeredAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: 'Critical Stock: $itemName',
      body:
          '$quantity $unit remaining • Triggered by $triggeredByName • $formattedTime',
      type: NotificationType.criticalStock,
      priority: NotificationPriority.critical,
      payload: {
        'itemId': itemId,
        'itemName': itemName,
        'quantity': quantity,
        'unit': unit,
        'triggeredByName': triggeredByName,
        'triggeredAt': triggeredAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification deadStock({
    required String locationId,
    required String itemId,
    required String itemName,
    required String unit,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) {
    final formattedTime = _formatDateTime(triggeredAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: 'Dead Stock: $itemName',
      body:
          '0 $unit remaining • Triggered by $triggeredByName • $formattedTime',
      type: NotificationType.deadStock,
      priority: NotificationPriority.critical,
      payload: {
        'itemId': itemId,
        'itemName': itemName,
        'quantity': '0',
        'unit': unit,
        'triggeredByName': triggeredByName,
        'triggeredAt': triggeredAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification system({
    required String locationId,
    required List<String> targetRoles,
    required String title,
    required String body,
  }) {
    return create(
      locationId: locationId,
      targetRoles: targetRoles,
      title: title,
      body: body,
      type: NotificationType.system,
      priority: NotificationPriority.low,
    );
  }

  static AppNotification storeAccessLifecycle({
    required String locationId,
    required List<String> targetRoles,
    required String lifecycleKind,
    required String windowKey,
    required String stage,
    required String title,
    required String body,
    required DateTime openingAt,
    required DateTime shiftEndAt,
    required DateTime accessEndAt,
  }) {
    return create(
      locationId: locationId,
      targetRoles: targetRoles,
      title: title,
      body: body,
      type: NotificationType.system,
      priority: stage == 'logoutWarning'
          ? NotificationPriority.critical
          : NotificationPriority.high,
      payload: {
        'category': 'storeAccess',
        'lifecycleKind': lifecycleKind,
        'windowKey': windowKey,
        'stage': stage,
        'openingAt': openingAt.toUtc().toIso8601String(),
        'shiftEndAt': shiftEndAt.toUtc().toIso8601String(),
        'accessEndAt': accessEndAt.toUtc().toIso8601String(),
      },
    );
  }

  static String _shortOrderId(String orderId) {
    final clean = orderId.replaceAll('-', '').toUpperCase();

    if (clean.length <= 8) {
      return clean;
    }

    return clean.substring(0, 8);
  }

  static String _formatDateTime(DateTime dateTime) {
    final local = dateTime.toLocal();

    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    final month = months[local.month - 1];
    final day = local.day;
    final year = local.year;

    var hour = local.hour;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';

    hour = hour % 12;
    if (hour == 0) hour = 12;

    return '$month $day, $year, $hour:$minute $period';
  }

  static AppNotification orderAssigned({
    required String locationId,
    required String orderId,
    required String helperId,
    required String helperName,
    required String assignedByName,
    required DateTime assignedAt,
  }) {
    final shortOrderId = _shortOrderId(orderId);
    final formattedTime = _formatDateTime(assignedAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin', 'helper'],
      title: 'Order Assigned #$shortOrderId',
      body: '$assignedByName assigned this order to you • $formattedTime',
      type: NotificationType.orderAssigned,
      priority: NotificationPriority.high,
      payload: {
        'orderId': orderId,
        'helperId': helperId,
        'helperName': helperName,
        'assignedByName': assignedByName,
        'assignedAt': assignedAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification orderPrepared({
    required String locationId,
    required String orderId,
    required String preparedByName,
    required DateTime preparedAt,
  }) {
    final shortOrderId = _shortOrderId(orderId);
    final formattedTime = _formatDateTime(preparedAt);

    return create(
      locationId: locationId,
      targetRoles: const ['admin', 'staff'],
      title: 'Order Prepared #$shortOrderId',
      body: 'Prepared by $preparedByName • $formattedTime',
      type: NotificationType.orderPrepared,
      priority: NotificationPriority.high,
      payload: {
        'orderId': orderId,
        'preparedByName': preparedByName,
        'preparedAt': preparedAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification stockAlert({
    required String locationId,
    required List<Map<String, dynamic>> items,
    required String triggeredByName,
    required DateTime triggeredAt,
  }) {
    final formattedTime = _formatDateTime(triggeredAt);

    final lowCount = items.where((item) => item['status'] == 'low').length;
    final criticalCount = items
        .where((item) => item['status'] == 'critical')
        .length;
    final deadCount = items.where((item) => item['status'] == 'dead').length;

    final totalCount = items.length;

    String title;

    if (totalCount == 1) {
      final item = items.first;
      final itemName = item['itemName']?.toString() ?? 'Item';
      final status = item['status']?.toString() ?? 'stock';

      if (status == 'low') {
        title = 'Low Stock: $itemName';
      } else if (status == 'critical') {
        title = 'Critical Stock: $itemName';
      } else {
        title = 'Dead Stock: $itemName';
      }
    } else {
      title = 'Stock Alert: $totalCount Items Need Attention';
    }

    final parts = <String>[];

    if (lowCount > 0) {
      parts.add('$lowCount low');
    }

    if (criticalCount > 0) {
      parts.add('$criticalCount critical');
    }

    if (deadCount > 0) {
      parts.add('$deadCount dead');
    }

    final itemPreview = items
        .take(3)
        .map((item) {
          final itemName = item['itemName']?.toString() ?? 'Item';
          final status = item['statusLabel']?.toString() ?? 'Stock Alert';
          final quantity = item['quantity']?.toString() ?? '0';
          final unit = item['unit']?.toString() ?? '';

          return '$itemName — $status, $quantity $unit left';
        })
        .join('\n');

    final extraCount = totalCount > 3 ? '\n+${totalCount - 3} more items' : '';

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: title,
      body:
          '${parts.join(', ')} item(s) detected • Triggered by $triggeredByName • $formattedTime\n$itemPreview$extraCount',
      type: NotificationType.stockAlert,
      priority: deadCount > 0 || criticalCount > 0
          ? NotificationPriority.critical
          : NotificationPriority.high,
      payload: {
        'items': items,
        'triggeredByName': triggeredByName,
        'triggeredAt': triggeredAt.toUtc().toIso8601String(),
      },
    );
  }

  static AppNotification inventoryRestocked({
    required String locationId,
    required String transactionId,
    required String productId,
    required String productName,
    required String staffId,
    required String staffName,
    required double quantityAdded,
    required double newQuantity,
  }) {
    String qty(double value) {
      if (value == value.roundToDouble()) {
        return value.toInt().toString();
      }
      return value.toStringAsFixed(2);
    }

    return create(
      locationId: locationId,
      targetRoles: const ['admin'],
      title: 'Inventory Restocked',
      body:
          '$staffName restocked $productName '
          '(+${qty(quantityAdded)}). '
          'New stock: ${qty(newQuantity)}.',
      type: NotificationType.inventoryRestocked,
      priority: NotificationPriority.low,
      payload: {
        'transactionId': transactionId,
        'productId': productId,
        'productName': productName,
        'staffId': staffId,
        'staffName': staffName,
        'quantityAdded': quantityAdded,
        'newQuantity': newQuantity,
      },
    );
  }
}
