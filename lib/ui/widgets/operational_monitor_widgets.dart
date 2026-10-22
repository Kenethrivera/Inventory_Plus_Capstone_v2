import 'package:flutter/material.dart';

const Color monitorPrimaryBlue = Color(0xFF2563EB);
const Color monitorDarkText = Color(0xFF0F172A);
const Color monitorMutedText = Color(0xFF64748B);
const Color monitorPageBackground = Color(0xFFF4F6F8);
const Color monitorLineColor = Color(0xFFE5E7EB);
const String monitorFontFamily = 'Hellix';

class MonitorPanel extends StatelessWidget {
  const MonitorPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: monitorLineColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class MonitorReadOnlyBadge extends StatelessWidget {
  const MonitorReadOnlyBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: monitorPrimaryBlue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: monitorPrimaryBlue.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.visibility_outlined,
            size: 16,
            color: monitorPrimaryBlue,
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: monitorPrimaryBlue,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              fontFamily: monitorFontFamily,
            ),
          ),
        ],
      ),
    );
  }
}

class MonitorMetricCard extends StatelessWidget {
  const MonitorMetricCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 90,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: monitorLineColor),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 26,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: monitorMutedText,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFamily: monitorFontFamily,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 22,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: const TextStyle(
                        color: monitorDarkText,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        fontFamily: monitorFontFamily,
                        height: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: monitorMutedText,
                    fontSize: 11,
                    fontFamily: monitorFontFamily,
                    height: 1.05,
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

class MonitorTableCell extends StatelessWidget {
  const MonitorTableCell({
    super.key,
    required this.width,
    required this.text,
    this.header = false,
    this.strong = false,
    this.align = TextAlign.left,
  });

  final double width;
  final String text;
  final bool header;
  final bool strong;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: header ? monitorMutedText : monitorDarkText,
          fontSize: header ? 10 : 12,
          fontWeight: header || strong ? FontWeight.w900 : FontWeight.w600,
          fontFamily: monitorFontFamily,
          letterSpacing: header ? 0.35 : 0,
        ),
      ),
    );
  }
}

class MonitorStatusPill extends StatelessWidget {
  const MonitorStatusPill({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          fontFamily: monitorFontFamily,
        ),
      ),
    );
  }
}

class MonitorInfoRow extends StatelessWidget {
  const MonitorInfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: monitorMutedText,
                fontSize: 12,
                fontFamily: monitorFontFamily,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: monitorDarkText,
                fontWeight: FontWeight.w800,
                fontSize: 12,
                fontFamily: monitorFontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MonitorNotice extends StatelessWidget {
  const MonitorNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: monitorDarkText,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: monitorFontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MonitorEmptyState extends StatelessWidget {
  const MonitorEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: monitorMutedText.withValues(alpha: 0.65),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: monitorDarkText,
                fontSize: 16,
                fontWeight: FontWeight.w900,
                fontFamily: monitorFontFamily,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: monitorMutedText,
                fontSize: 12,
                fontFamily: monitorFontFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MonitorLoadError extends StatelessWidget {
  const MonitorLoadError({
    super.key,
    required this.title,
    required this.onRetry,
  });

  final String title;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MonitorPanel(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: monitorMutedText,
              ),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: monitorDarkText,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  fontFamily: monitorFontFamily,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Check the connection and retry.',
                style: TextStyle(
                  color: monitorMutedText,
                  fontSize: 12,
                  fontFamily: monitorFontFamily,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MonitorPaginationFooter extends StatelessWidget {
  const MonitorPaginationFooter({
    super.key,
    required this.rangeLabel,
    required this.currentPage,
    required this.totalPages,
    required this.compact,
    required this.onPageSelected,
  });

  final String rangeLabel;
  final int currentPage;
  final int totalPages;
  final bool compact;
  final ValueChanged<int> onPageSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 18,
            child: Text(
              rangeLabel,
              style: const TextStyle(
                color: monitorMutedText,
                fontSize: 11,
                fontFamily: monitorFontFamily,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MonitorPageButton(
                icon: Icons.chevron_left,
                enabled: currentPage > 1,
                onTap: () => onPageSelected(currentPage - 1),
              ),
              if (compact)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '$currentPage / $totalPages',
                    style: const TextStyle(
                      color: monitorDarkText,
                      fontWeight: FontWeight.w800,
                      fontFamily: monitorFontFamily,
                    ),
                  ),
                )
              else
                ..._pageEntries().map((page) {
                  if (page == null) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5),
                      child: Text(
                        '…',
                        style: TextStyle(color: monitorMutedText),
                      ),
                    );
                  }
                  return _MonitorPageButton(
                    label: '$page',
                    selected: page == currentPage,
                    enabled: true,
                    onTap: () => onPageSelected(page),
                  );
                }),
              _MonitorPageButton(
                icon: Icons.chevron_right,
                enabled: currentPage < totalPages,
                onTap: () => onPageSelected(currentPage + 1),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<int?> _pageEntries() {
    if (totalPages <= 7) {
      return List<int>.generate(totalPages, (index) => index + 1);
    }
    final pages = <int>{1, totalPages};
    for (var page = currentPage - 1; page <= currentPage + 1; page++) {
      if (page > 1 && page < totalPages) pages.add(page);
    }
    final sorted = pages.toList()..sort();
    final result = <int?>[];
    for (var index = 0; index < sorted.length; index++) {
      if (index > 0 && sorted[index] - sorted[index - 1] > 1) {
        result.add(null);
      }
      result.add(sorted[index]);
    }
    return result;
  }
}

class _MonitorPageButton extends StatelessWidget {
  const _MonitorPageButton({
    this.label,
    this.icon,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final String? label;
  final IconData? icon;
  final bool enabled;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? monitorPrimaryBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? monitorPrimaryBlue : monitorLineColor,
            ),
          ),
          child: icon != null
              ? Icon(
                  icon,
                  size: 18,
                  color: enabled
                      ? monitorDarkText
                      : monitorMutedText.withValues(alpha: 0.4),
                )
              : Text(
                  label ?? '',
                  style: TextStyle(
                    color: selected ? Colors.white : monitorDarkText,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    fontFamily: monitorFontFamily,
                  ),
                ),
        ),
      ),
    );
  }
}

Widget buildMonitorSkeleton() {
  return MonitorPanel(
    padding: const EdgeInsets.all(20),
    child: Column(
      children: List.generate(
        7,
        (index) => Container(
          height: 58,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    ),
  );
}
