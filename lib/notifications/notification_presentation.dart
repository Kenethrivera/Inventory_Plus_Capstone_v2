import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'models/app_notification.dart';
import 'models/notification_type.dart';

class NotificationPresentation {
  final IconData icon;
  final IconData badgeIcon;
  final Color accentColor;
  final Color backgroundTint;
  final String statusLabel;

  const NotificationPresentation({
    required this.icon,
    required this.badgeIcon,
    required this.accentColor,
    required this.backgroundTint,
    required this.statusLabel,
  });
}

class NotificationPresentationResolver {
  NotificationPresentationResolver._();

  static const Color _blue = Color(0xFF2563EB);
  static const Color _green = Color(0xFF16A34A);
  static const Color _amber = Color(0xFFF59E0B);
  static const Color _orange = Color(0xFFEA580C);
  static const Color _red = Color(0xFFDC2626);
  static const Color _purple = Color(0xFF7C3AED);
  static const Color _teal = Color(0xFF0F766E);
  static const Color _slate = Color(0xFF475569);

  static NotificationPresentation resolve(AppNotification notification) {
    switch (notification.type) {
      case NotificationType.newOrder:
      case NotificationType.orderAssigned:
        return _style(
          icon: LucideIcons.shoppingCart,
          badgeIcon: notification.type == NotificationType.orderAssigned
              ? LucideIcons.userCheck
              : LucideIcons.plus,
          color: _amber,
          label: 'Pending',
        );
      case NotificationType.orderPrepared:
        return _style(
          icon: LucideIcons.packageCheck,
          badgeIcon: LucideIcons.check,
          color: _blue,
          label: 'Ready',
        );
      case NotificationType.orderCancelled:
        return _style(
          icon: LucideIcons.packageX,
          badgeIcon: LucideIcons.x,
          color: _red,
          label: 'Cancelled',
        );
      case NotificationType.transaction:
        return _style(
          icon: LucideIcons.receipt,
          badgeIcon: LucideIcons.badgeDollarSign,
          color: _green,
          label: 'Completed',
        );
      case NotificationType.lowStock:
        return _style(
          icon: LucideIcons.packageMinus,
          badgeIcon: LucideIcons.box,
          color: _orange,
          label: 'Low stock',
        );
      case NotificationType.criticalStock:
        return _style(
          icon: LucideIcons.triangleAlert,
          badgeIcon: LucideIcons.box,
          color: _red,
          label: 'Critical',
        );
      case NotificationType.deadStock:
        return _style(
          icon: LucideIcons.circleX,
          badgeIcon: LucideIcons.box,
          color: _red,
          label: 'Out of stock',
        );
      case NotificationType.stockAlert:
        final items = notification.payload['items'];
        final hasSevere =
            items is List &&
            items.any((item) {
              if (item is! Map) return false;
              final status = item['status']?.toString().toLowerCase();
              return status == 'critical' || status == 'dead';
            });
        return _style(
          icon: LucideIcons.packageSearch,
          badgeIcon: LucideIcons.box,
          color: hasSevere ? _red : _orange,
          label: hasSevere ? 'Critical stock' : 'Stock alert',
        );
      case NotificationType.inventoryRestocked:
        return _style(
          icon: LucideIcons.packageCheck,
          badgeIcon: LucideIcons.plus,
          color: _green,
          label: 'Restocked',
        );
      case NotificationType.inventoryAdded:
        return _style(
          icon: LucideIcons.packagePlus,
          badgeIcon: LucideIcons.plus,
          color: _teal,
          label: 'Inventory',
        );
      case NotificationType.inventoryUpdated:
        return _style(
          icon: LucideIcons.packageOpen,
          badgeIcon: LucideIcons.penLine,
          color: _teal,
          label: 'Inventory',
        );
      case NotificationType.inventoryDeleted:
        return _style(
          icon: LucideIcons.trash2,
          badgeIcon: LucideIcons.trash2,
          color: _red,
          label: 'Removed',
        );
      case NotificationType.exportReminder:
        return _style(
          icon: LucideIcons.download,
          badgeIcon: LucideIcons.fileDown,
          color: _purple,
          label: 'Report',
        );
      case NotificationType.system:
        if (notification.payload['category']?.toString() == 'storeAccess') {
          return _storeAccessStyle(notification.payload['stage']?.toString());
        }
        return _style(
          icon: LucideIcons.info,
          badgeIcon: LucideIcons.info,
          color: _slate,
          label: 'System',
        );
    }
  }

  static NotificationPresentation _storeAccessStyle(String? stage) {
    switch (stage) {
      case 'opened':
        return _style(
          icon: LucideIcons.store,
          badgeIcon: LucideIcons.check,
          color: _blue,
          label: 'Store active',
        );
      case 'logoutWarning':
        return _style(
          icon: LucideIcons.clockAlert,
          badgeIcon: LucideIcons.triangleAlert,
          color: _red,
          label: 'Final warning',
        );
      case 'openingSoon':
        return _style(
          icon: LucideIcons.store,
          badgeIcon: LucideIcons.clock3,
          color: _amber,
          label: 'Opening soon',
        );
      case 'shiftEnd30':
      case 'shiftEnd15':
      case 'shiftEnd5':
        return _style(
          icon: LucideIcons.clock3,
          badgeIcon: LucideIcons.timer,
          color: _amber,
          label: 'Shift warning',
        );
      case 'shiftEnded':
        return _style(
          icon: LucideIcons.clockAlert,
          badgeIcon: LucideIcons.timer,
          color: _orange,
          label: 'Allowance active',
        );
      case 'allowance5':
        return _style(
          icon: LucideIcons.timer,
          badgeIcon: LucideIcons.clockAlert,
          color: _orange,
          label: 'Access warning',
        );
      default:
        return _style(
          icon: LucideIcons.store,
          badgeIcon: LucideIcons.info,
          color: _amber,
          label: 'Store access',
        );
    }
  }

  static NotificationPresentation _style({
    required IconData icon,
    required IconData badgeIcon,
    required Color color,
    required String label,
  }) {
    return NotificationPresentation(
      icon: icon,
      badgeIcon: badgeIcon,
      accentColor: color,
      backgroundTint: color.withValues(alpha: 0.08),
      statusLabel: label,
    );
  }
}
