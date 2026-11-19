import 'package:flutter/material.dart';

import '../ui/widgets/app_dialog.dart';
import 'notification_controller.dart';

class NotificationActionsMenu extends StatelessWidget {
  const NotificationActionsMenu({
    super.key,
    required this.controller,
    required this.onArchivedFromSession,
    this.archivedView = false,
  });

  final NotificationController controller;
  final ValueChanged<String> onArchivedFromSession;
  final bool archivedView;

  static const _orange = Color(0xFFC83D08);
  static const _ink = Color(0xFF211F1D);
  static const _muted = Color(0xFF756D67);
  static const _border = Color(0xFFE8E1DA);
  static const _background = Color(0xFFF7F6F4);

  Future<void> _handleAction(BuildContext context, String action) async {
    if (action == 'read') {
      await controller.markAllAsRead();
      return;
    }

    if (action != 'archive') return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.38),
      builder: (dialogContext) => AppDialog(
        icon: Icons.archive_outlined,
        color: _orange,
        title: 'Archive all notifications?',
        subtitle: 'This affects only your account.',
        child: const Text(
          'All notifications in your inbox will move to '
          'Archived.',
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: _muted,
            fontFamily: 'Hellix',
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              backgroundColor: Colors.white,
              side: const BorderSide(color: _border),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: _orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Archive all'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final ids = controller.notifications
        .map((notification) => notification.id)
        .toList();

    final succeeded = await controller.archiveAllNotifications();

    if (succeeded) {
      for (final id in ids) {
        onArchivedFromSession(id);
      }
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not archive all notifications.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: _background,
        highlightColor: _background,
        splashColor: _orange.withValues(alpha: 0.08),
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Notification actions',
        position: PopupMenuPosition.under,
        offset: const Offset(0, 8),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _border),
        ),
        icon: const Icon(Icons.more_vert, color: _ink, size: 22),
        onSelected: (action) async {
          await _handleAction(context, action);
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            value: 'read',
            enabled: !archivedView && controller.unreadCount > 0,
            child: const Row(
              children: [
                Icon(Icons.done_all, color: _orange, size: 20),
                SizedBox(width: 12),
                Text(
                  'Mark all as read',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontFamily: 'Hellix',
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'archive',
            enabled: !archivedView && controller.notifications.isNotEmpty,
            child: const Row(
              children: [
                Icon(Icons.archive_outlined, color: _orange, size: 20),
                SizedBox(width: 12),
                Text(
                  'Archive all notifications',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontFamily: 'Hellix',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
