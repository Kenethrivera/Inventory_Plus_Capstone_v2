import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'models/app_notification.dart';
import 'models/notification_type.dart';
import 'notification_controller.dart';
import 'notification_tile.dart';
import '../ui/widgets/app_toast.dart';

enum NotificationFilter {
  all,
  unread,
  orders,
  stock,
  reports,
  transactions,
  system,
}

class NotificationPage extends StatefulWidget {
  final NotificationController controller;
  final bool isModal;
  final Future<String?> Function(AppNotification notification)?
  onValidateNotification;
  final bool Function(AppNotification notification) isActionable;
  final ValueChanged<Iterable<String>> onInformationalNotificationsShown;
  final ValueChanged<String> onNotificationRemovedFromSession;

  const NotificationPage({
    super.key,
    required this.controller,
    this.isModal = false,
    this.onValidateNotification,
    required this.isActionable,
    required this.onInformationalNotificationsShown,
    required this.onNotificationRemovedFromSession,
  });

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  static const Color _primaryBlue = Color(0xFF2563EB);
  static const Color _darkText = Color(0xFF0F172A);
  static const Color _mutedText = Color(0xFF64748B);
  static const Color _softBg = Color(0xFFF4F6F8);
  static const String _fontFam = 'Hellix';

  NotificationFilter _filter = NotificationFilter.all;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.controller.hasLoadedSnapshot) {
        widget.controller.loadNotifications();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final isDesktop = screen.width >= 700;

    final panelWidth = isDesktop
        ? (screen.width * 0.46).clamp(430.0, 560.0)
        : screen.width;

    final panelHeight = isDesktop ? screen.height - 120 : screen.height * 0.92;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final filtered = _filteredNotifications(
          widget.controller.notifications,
        );
        widget.onInformationalNotificationsShown(
          filtered
              .where(
                (notification) =>
                    !notification.isRead && !widget.isActionable(notification),
              )
              .map((notification) => notification.id),
        );

        return Container(
          width: panelWidth,
          height: panelHeight,
          decoration: BoxDecoration(
            color: _softBg,
            borderRadius: BorderRadius.circular(isDesktop ? 18 : 24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Scaffold(
            backgroundColor: _softBg,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _buildHeader(),
                  _buildFilters(),
                  Expanded(
                    child: RefreshIndicator(
                      color: _primaryBlue,
                      onRefresh: widget.controller.refresh,
                      child: _buildBody(filtered),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 14, 10),
      decoration: const BoxDecoration(color: Colors.white),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Notifications',
              style: TextStyle(
                color: _darkText,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                fontFamily: _fontFam,
              ),
            ),
          ),
          if (widget.controller.unreadCount > 0)
            TextButton(
              onPressed: widget.controller.markAllAsRead,
              child: const Text(
                'Mark all read',
                style: TextStyle(
                  color: _primaryBlue,
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(LucideIcons.x, color: _mutedText, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    final filters = _availableFilters(widget.controller.notifications);

    if (!filters.contains(_filter)) {
      _filter = NotificationFilter.all;
    }

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: filters.map((filter) {
            final selected = _filter == filter;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _filter = filter;
                  });
                },
                borderRadius: BorderRadius.circular(999),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? _primaryBlue : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: selected ? _primaryBlue : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Text(
                    _filterLabel(filter),
                    style: TextStyle(
                      color: selected ? Colors.white : _mutedText,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  List<NotificationFilter> _availableFilters(
    List<AppNotification> notifications,
  ) {
    final filters = <NotificationFilter>[NotificationFilter.all];

    final hasUnread = notifications.any((n) => !n.isRead);

    final hasOrders = notifications.any((n) {
      return n.type == NotificationType.newOrder ||
          n.type == NotificationType.orderAssigned ||
          n.type == NotificationType.orderPrepared ||
          n.type == NotificationType.orderCancelled;
    });

    final hasStock = notifications.any((n) {
      return n.type == NotificationType.stockAlert ||
          n.type == NotificationType.lowStock ||
          n.type == NotificationType.criticalStock ||
          n.type == NotificationType.deadStock;
    });

    final hasReports = notifications.any((n) {
      return n.type == NotificationType.exportReminder ||
          n.type == NotificationType.inventoryRestocked;
    });

    final hasTransactions = notifications.any((n) {
      return n.type == NotificationType.transaction;
    });

    final hasSystem = notifications.any((n) {
      return n.type == NotificationType.system ||
          n.type == NotificationType.inventoryAdded ||
          n.type == NotificationType.inventoryUpdated ||
          n.type == NotificationType.inventoryDeleted;
    });

    if (hasUnread) filters.add(NotificationFilter.unread);
    if (hasOrders) filters.add(NotificationFilter.orders);
    if (hasStock) filters.add(NotificationFilter.stock);
    if (hasReports) filters.add(NotificationFilter.reports);
    if (hasTransactions) filters.add(NotificationFilter.transactions);
    if (hasSystem) filters.add(NotificationFilter.system);

    return filters;
  }

  Widget _buildBody(List<AppNotification> notifications) {
    if (widget.controller.isLoading && notifications.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _primaryBlue),
      );
    }

    if (widget.controller.errorMessage != null && notifications.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          const SizedBox(height: 120),
          Icon(LucideIcons.circleAlert, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 16),
          Text(
            widget.controller.errorMessage!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _mutedText, fontFamily: _fontFam),
          ),
        ],
      );
    }

    if (notifications.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          const SizedBox(height: 120),
          Icon(LucideIcons.bellOff, size: 54, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            _emptyMessage(),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w800,
              fontFamily: _fontFam,
            ),
          ),
        ],
      );
    }

    final groups = _groupNotifications(notifications);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
      itemCount: groups.length,
      itemBuilder: (context, groupIndex) {
        final group = groups[groupIndex];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
              child: Row(
                children: [
                  Text(
                    group.label,
                    style: const TextStyle(
                      color: _darkText,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const Spacer(),
                  if (groupIndex == 0 && group.items.length > 3)
                    Text(
                      '${group.items.length} items',
                      style: const TextStyle(
                        color: _mutedText,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: _fontFam,
                      ),
                    ),
                ],
              ),
            ),
            ...group.items.map((notification) {
              final isActionable = widget.isActionable(notification);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NotificationTile(
                  notification: notification,
                  onTap: !isActionable
                      ? null
                      : () async {
                          final errorMessage = await widget
                              .onValidateNotification
                              ?.call(notification);

                          if (errorMessage != null) {
                            if (!context.mounted) return;
                            AppToast.error(context, errorMessage);
                            return;
                          }

                          if (context.mounted) {
                            Navigator.pop(context, notification);
                          }
                        },
                  onDelete: () {
                    widget.onNotificationRemovedFromSession(notification.id);
                    widget.controller.deleteNotification(notification.id);
                  },
                ),
              );
            }),
          ],
        );
      },
    );
  }

  List<AppNotification> _filteredNotifications(
    List<AppNotification> notifications,
  ) {
    switch (_filter) {
      case NotificationFilter.all:
        return notifications;

      case NotificationFilter.unread:
        return notifications.where((n) => !n.isRead).toList();

      case NotificationFilter.orders:
        return notifications.where((n) {
          return n.type == NotificationType.newOrder ||
              n.type == NotificationType.orderAssigned ||
              n.type == NotificationType.orderPrepared ||
              n.type == NotificationType.orderCancelled;
        }).toList();

      case NotificationFilter.stock:
        return notifications.where((n) {
          return n.type == NotificationType.stockAlert ||
              n.type == NotificationType.lowStock ||
              n.type == NotificationType.criticalStock ||
              n.type == NotificationType.deadStock;
        }).toList();

      case NotificationFilter.reports:
        return notifications.where((n) {
          return n.type == NotificationType.exportReminder;
        }).toList();

      case NotificationFilter.transactions:
        return notifications.where((n) {
          return n.type == NotificationType.transaction;
        }).toList();

      case NotificationFilter.system:
        return notifications.where((n) {
          return n.type == NotificationType.system ||
              n.type == NotificationType.inventoryAdded ||
              n.type == NotificationType.inventoryUpdated ||
              n.type == NotificationType.inventoryDeleted ||
              n.type == NotificationType.inventoryRestocked;
        }).toList();
    }
  }

  List<_NotificationGroup> _groupNotifications(
    List<AppNotification> notifications,
  ) {
    final now = DateTime.now();

    final today = <AppNotification>[];
    final yesterday = <AppNotification>[];
    final earlierThisWeek = <AppNotification>[];
    final earlier = <AppNotification>[];

    for (final notification in notifications) {
      final created = notification.createdAt;

      if (_isSameDay(created, now)) {
        today.add(notification);
      } else if (_isSameDay(created, now.subtract(const Duration(days: 1)))) {
        yesterday.add(notification);
      } else if (now.difference(created).inDays < 7) {
        earlierThisWeek.add(notification);
      } else {
        earlier.add(notification);
      }
    }

    return [
      if (today.isNotEmpty) _NotificationGroup(label: 'Today', items: today),
      if (yesterday.isNotEmpty)
        _NotificationGroup(label: 'Yesterday', items: yesterday),
      if (earlierThisWeek.isNotEmpty)
        _NotificationGroup(label: 'Earlier this week', items: earlierThisWeek),
      if (earlier.isNotEmpty)
        _NotificationGroup(label: 'Earlier', items: earlier),
    ];
  }

  String _filterLabel(NotificationFilter filter) {
    switch (filter) {
      case NotificationFilter.all:
        return 'All';
      case NotificationFilter.unread:
        return 'Unread';
      case NotificationFilter.orders:
        return 'Orders';
      case NotificationFilter.stock:
        return 'Stock';
      case NotificationFilter.reports:
        return 'Reports';
      case NotificationFilter.transactions:
        return 'Transactions';
      case NotificationFilter.system:
        return 'System';
    }
  }

  String _emptyMessage() {
    switch (_filter) {
      case NotificationFilter.all:
        return 'No notifications yet';
      case NotificationFilter.unread:
        return 'No unread notifications';
      case NotificationFilter.orders:
        return 'No order notifications';
      case NotificationFilter.stock:
        return 'No stock notifications';
      case NotificationFilter.reports:
        return 'No report reminders';
      case NotificationFilter.transactions:
        return 'No transaction notifications';
      case NotificationFilter.system:
        return 'No system notifications';
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

class _NotificationGroup {
  final String label;
  final List<AppNotification> items;

  const _NotificationGroup({required this.label, required this.items});
}
