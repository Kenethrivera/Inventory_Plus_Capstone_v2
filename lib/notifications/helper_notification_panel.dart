import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/widgets/app_toast.dart';
import 'models/app_notification.dart';
import 'models/notification_type.dart';
import 'notification_controller.dart';

enum _HelperNotificationFilter { all, orders, approvals }

/// The compact notification popover used by the helper's mobile header.
class HelperNotificationPanel extends StatefulWidget {
  const HelperNotificationPanel({
    super.key,
    required this.controller,
    required this.isActionable,
    required this.onValidateNotification,
    required this.onInformationalNotificationsShown,
  });

  final NotificationController controller;
  final bool Function(AppNotification) isActionable;
  final Future<String?> Function(AppNotification)? onValidateNotification;
  final ValueChanged<Iterable<String>> onInformationalNotificationsShown;

  @override
  State<HelperNotificationPanel> createState() =>
      _HelperNotificationPanelState();
}

class _HelperNotificationPanelState extends State<HelperNotificationPanel> {
  static const _ink = Color(0xFF211F1D);
  static const _muted = Color(0xFF827A74);
  static const _line = Color(0xFFE7E1DA);
  _HelperNotificationFilter _filter = _HelperNotificationFilter.all;

  @override
  void initState() {
    super.initState();
    if (!widget.controller.hasLoadedSnapshot) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.loadNotifications();
      });
    }
  }

  bool _isApproval(AppNotification item) =>
      item.payload['category'] == 'inventoryApproval';

  bool _isOrder(AppNotification item) => switch (item.type) {
    NotificationType.newOrder ||
    NotificationType.orderAssigned ||
    NotificationType.orderPrepared ||
    NotificationType.orderCancelled => true,
    _ => false,
  };

  List<AppNotification> _visibleNotifications() {
    final notifications = widget.controller.notifications;
    return switch (_filter) {
      _HelperNotificationFilter.all => notifications,
      _HelperNotificationFilter.orders =>
        notifications.where(_isOrder).toList(),
      _HelperNotificationFilter.approvals =>
        notifications.where(_isApproval).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final notifications = _visibleNotifications();
        widget.onInformationalNotificationsShown(
          notifications
              .where((item) => !item.isRead && !widget.isActionable(item))
              .map((item) => item.id),
        );

        final screenHeight = MediaQuery.sizeOf(context).height;
        final listHeight = notifications.isEmpty
            ? 132.0
            : (notifications.length * 88.0).clamp(88.0, 352.0);
        final maxHeight = (screenHeight * 0.68).clamp(190.0, 440.0);

        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _line),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 13, 14, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Notifications',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.controller.unreadCount == 0
                          ? null
                          : widget.controller.markAllAsRead,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF9B451B),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text(
                        'Mark all read',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 9),
                child: Row(
                  children: [
                    _filterButton(_HelperNotificationFilter.all, 'All'),
                    _filterButton(_HelperNotificationFilter.orders, 'Orders'),
                    _filterButton(
                      _HelperNotificationFilter.approvals,
                      'Approvals',
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _line),
              Flexible(
                child: SizedBox(
                  height: listHeight,
                  child: _buildList(notifications),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _filterButton(_HelperNotificationFilter filter, String label) {
    final selected = _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => setState(() => _filter = filter),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? _ink : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFF5F5955),
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<AppNotification> notifications) {
    if (widget.controller.isLoading && notifications.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.controller.errorMessage != null && notifications.isEmpty) {
      return Center(
        child: TextButton(
          onPressed: widget.controller.refresh,
          child: const Text('Could not load notifications · Retry'),
        ),
      );
    }
    if (notifications.isEmpty) {
      final label = switch (_filter) {
        _HelperNotificationFilter.all => 'No notifications yet',
        _HelperNotificationFilter.orders => 'No order notifications',
        _HelperNotificationFilter.approvals => 'No approval notifications',
      };
      return Center(
        child: Text(label, style: const TextStyle(color: _muted, fontSize: 13)),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: notifications.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: _line),
      itemBuilder: (context, index) => _notificationRow(notifications[index]),
    );
  }

  Widget _notificationRow(AppNotification item) {
    final approval = _isApproval(item);
    final actionable = widget.isActionable(item);
    final time = item.createdAt;
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final timeText =
        '$hour:${time.minute.toString().padLeft(2, '0')} '
        '${time.hour < 12 ? 'AM' : 'PM'}';

    return InkWell(
      onTap: !actionable
          ? null
          : () async {
              final error = await widget.onValidateNotification?.call(item);
              if (!mounted) return;
              if (error != null) {
                AppToast.error(context, error);
              } else {
                Navigator.pop(context, item);
              }
            },
      child: Container(
        constraints: const BoxConstraints(minHeight: 82),
        padding: const EdgeInsets.fromLTRB(18, 14, 17, 14),
        color: item.isRead ? Colors.white : const Color(0xFFFFFAF7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: approval
                  ? const Color(0xFFFFEBDD)
                  : const Color(0xFFE2EDFB),
              child: Icon(
                approval ? LucideIcons.shieldCheck : LucideIcons.shoppingBag,
                size: 16,
                color: approval
                    ? const Color(0xFFD4460B)
                    : const Color(0xFF1761AD),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _ink,
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: item.isRead
                          ? FontWeight.w600
                          : FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(timeText, style: const TextStyle(color: _muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
