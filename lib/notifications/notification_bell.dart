import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'models/app_notification.dart';
import 'notification_badge.dart';
import 'notification_page.dart';
import 'notification_provider.dart';

class NotificationBell extends StatelessWidget {
  final Color iconColor;
  final ValueChanged<AppNotification>? onNotificationSelected;

  /// Return null if valid.
  /// Return an error message if invalid.
  final Future<String?> Function(AppNotification notification)?
  onValidateNotification;

  const NotificationBell({
    super.key,
    this.iconColor = const Color(0xFF0F172A),
    this.onNotificationSelected,
    this.onValidateNotification,
  });

  @override
  Widget build(BuildContext context) {
    final controller = NotificationProvider.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return IconButton(
          tooltip: 'Notifications',
          onPressed: () async {
            final selectedNotification = await _showNotificationPanel(
              context,
              controller,
            );

            if (selectedNotification != null) {
              onNotificationSelected?.call(selectedNotification);
            }
          },
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(LucideIcons.bell, color: iconColor, size: 22),
              Positioned(
                top: -8,
                right: -8,
                child: NotificationBadge(count: controller.unreadCount),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<AppNotification?> _showNotificationPanel(
    BuildContext context,
    dynamic controller,
  ) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 700;

    if (!isDesktop) {
      return showModalBottomSheet<AppNotification>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) {
          return FractionallySizedBox(
            heightFactor: 0.92,
            child: NotificationPage(
              controller: controller,
              isModal: true,
              onValidateNotification: onValidateNotification,
            ),
          );
        },
      );
    }

    const sidebarWidth = 250.0;

    return showGeneralDialog<AppNotification>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Notifications',
      barrierColor: Colors.black.withOpacity(0.18),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(
              left: sidebarWidth + 18,
              top: 18,
              bottom: 18,
            ),
            child: Material(
              color: Colors.transparent,
              child: NotificationPage(
                controller: controller,
                isModal: true,
                onValidateNotification: onValidateNotification,
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );

        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-0.08, 0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }
}
