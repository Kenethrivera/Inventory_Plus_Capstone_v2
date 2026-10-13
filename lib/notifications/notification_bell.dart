import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'models/app_notification.dart';
import 'notification_badge.dart';
import 'notification_page.dart';
import 'notification_provider.dart';

enum NotificationPanelPlacement { besideSidebar, belowBell }

class NotificationBell extends StatelessWidget {
  final Color iconColor;
  final NotificationPanelPlacement placement;
  final ValueChanged<AppNotification>? onNotificationSelected;

  /// Return null if valid.
  /// Return an error message if invalid.
  final Future<String?> Function(AppNotification notification)?
  onValidateNotification;

  const NotificationBell({
    super.key,
    this.iconColor = const Color(0xFF0F172A),
    this.placement = NotificationPanelPlacement.belowBell,
    this.onNotificationSelected,
    this.onValidateNotification,
  });

  @override
  Widget build(BuildContext context) {
    final controller = NotificationProvider.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Builder(
          builder: (buttonContext) {
            return IconButton(
              tooltip: 'Notifications',
              onPressed: () async {
                final selectedNotification = await _showNotificationPanel(
                  buttonContext,
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
      },
    );
  }

  Future<AppNotification?> _showNotificationPanel(
    BuildContext context,
    dynamic controller,
  ) {
    final screen = MediaQuery.of(context).size;
    final isDesktop = screen.width >= 700;

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

    if (placement == NotificationPanelPlacement.besideSidebar) {
      return _showBesideSidebarPanel(context, controller, screen);
    }

    return _showBelowBellPanel(context, controller, screen);
  }

  Future<AppNotification?> _showBesideSidebarPanel(
    BuildContext context,
    dynamic controller,
    Size screen,
  ) {
    const sidebarWidth = 250.0;
    const gap = 16.0;
    const topGap = 18.0;
    const bottomGap = 18.0;

    final panelWidth = (screen.width * 0.42).clamp(440.0, 560.0);
    final panelHeight = screen.height - topGap - bottomGap;

    final left = sidebarWidth + gap;
    final top = topGap;

    return showGeneralDialog<AppNotification>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Notifications',
      barrierColor: Colors.black.withOpacity(0.18),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: panelWidth,
              height: panelHeight,
              child: Material(
                color: Colors.transparent,
                child: NotificationPage(
                  controller: controller,
                  isModal: true,
                  onValidateNotification: onValidateNotification,
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );

        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-0.04, 0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  Future<AppNotification?> _showBelowBellPanel(
    BuildContext context,
    dynamic controller,
    Size screen,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    final offset = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final buttonSize = box?.size ?? const Size(40, 40);

    final panelWidth = (screen.width * 0.36).clamp(420.0, 520.0);
    final panelHeight = screen.height - 112;

    final left = (offset.dx + buttonSize.width - panelWidth).clamp(
      12.0,
      screen.width - panelWidth - 12.0,
    );

    final top = (offset.dy + buttonSize.height + 10).clamp(
      12.0,
      screen.height - panelHeight - 12.0,
    );

    return showGeneralDialog<AppNotification>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Notifications',
      barrierColor: Colors.black.withOpacity(0.14),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: panelWidth,
              height: panelHeight,
              child: Material(
                color: Colors.transparent,
                child: NotificationPage(
                  controller: controller,
                  isModal: true,
                  onValidateNotification: onValidateNotification,
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );

        return ScaleTransition(
          alignment: Alignment.topRight,
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }
}
