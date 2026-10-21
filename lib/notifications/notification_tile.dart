import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'models/app_notification.dart';
import 'models/notification_type.dart';
import 'notification_presentation.dart';

class NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback? onTap;
  final VoidCallback onDelete;

  const NotificationTile({
    super.key,
    required this.notification,
    this.onTap,
    required this.onDelete,
  });

  static const Color _darkText = Color(0xFF0F172A);
  static const Color _mutedText = Color(0xFF64748B);
  static const String _fontFam = 'Hellix';

  @override
  Widget build(BuildContext context) {
    final presentation = NotificationPresentationResolver.resolve(notification);
    final timeLabel = _timeAgo(notification.createdAt);
    final isUnread = !notification.isRead;
    final isActionable = onTap != null;

    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isUnread ? presentation.backgroundTint : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isUnread
              ? presentation.accentColor.withValues(alpha: 0.7)
              : const Color(0xFFE5E7EB),
          width: isUnread ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isUnread ? 0.08 : 0.035),
            blurRadius: isUnread ? 16 : 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildIcon(presentation, isUnread),
          const SizedBox(width: 12),
          Expanded(child: _buildContent(timeLabel, isUnread, presentation)),
          const SizedBox(width: 8),
          Column(
            children: [
              if (isUnread)
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: presentation.accentColor,
                    shape: BoxShape.circle,
                  ),
                )
              else
                const SizedBox(height: 15),
              if (isActionable) ...[
                const SizedBox(height: 18),
                Icon(
                  LucideIcons.chevronRight,
                  color: presentation.accentColor.withValues(alpha: 0.65),
                  size: 18,
                ),
              ],
            ],
          ),
        ],
      ),
    );

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: isActionable
          ? MouseRegion(
              cursor: SystemMouseCursors.click,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(18),
                child: tile,
              ),
            )
          : tile,
    );

    return Dismissible(
      key: ValueKey(notification.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: Colors.red,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Icon(LucideIcons.trash2, color: Colors.white),
      ),
      child: Opacity(opacity: isUnread ? 1 : 0.76, child: content),
    );
  }

  Widget _buildIcon(NotificationPresentation presentation, bool isUnread) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 23,
          backgroundColor: presentation.accentColor.withValues(alpha: 0.12),
          child: Icon(
            presentation.icon,
            color: presentation.accentColor,
            size: 22,
          ),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: presentation.accentColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Icon(presentation.badgeIcon, color: Colors.white, size: 10),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    String timeLabel,
    bool isUnread,
    NotificationPresentation presentation,
  ) {
    final body = _cleanBody();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          notification.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isUnread ? _darkText : _darkText,
            fontSize: 14,
            fontWeight: isUnread ? FontWeight.w900 : FontWeight.w800,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isUnread ? const Color(0xFF334155) : _mutedText,
            fontSize: 13,
            height: 1.3,
            fontWeight: FontWeight.w500,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: presentation.accentColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                presentation.statusLabel,
                style: TextStyle(
                  color: presentation.accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(LucideIcons.clock3, size: 13, color: Colors.grey.shade500),
            const SizedBox(width: 4),
            Text(
              timeLabel,
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _cleanBody() {
    if (notification.type != NotificationType.stockAlert) {
      return notification.body;
    }

    final rawItems = notification.payload['items'];

    if (rawItems is! List || rawItems.isEmpty) {
      return notification.body;
    }

    final items = rawItems
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    final preview = items
        .take(3)
        .map((item) {
          final name = item['itemName']?.toString() ?? 'Item';
          final status = item['statusLabel']?.toString() ?? 'Stock Alert';
          final qty = item['quantity']?.toString() ?? '0';
          final unit = item['unit']?.toString() ?? '';

          return '$name — $status, $qty $unit left';
        })
        .join('\n');

    if (items.length > 3) {
      return '$preview\n+${items.length - 3} more items';
    }

    return preview;
  }

  String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) {
      return 'Just now';
    }

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    }

    if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    }

    if (diff.inDays == 1) {
      return 'Yesterday';
    }

    if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    }

    return _formatDate(dateTime);
  }

  String _formatDate(DateTime dateTime) {
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

    return '${months[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year}';
  }
}
