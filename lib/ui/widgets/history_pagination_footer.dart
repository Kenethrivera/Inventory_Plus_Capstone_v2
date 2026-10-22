import 'dart:math' as math;

import 'package:flutter/material.dart';

class HistoryLoadingRows extends StatelessWidget {
  const HistoryLoadingRows({super.key, this.rowCount = 8});

  final int rowCount;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.separated(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rowCount,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: Color(0xFFE2E8F0)),
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF1F5F9),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SkeletonBar(width: 180, color: Color(0xFFE2E8F0)),
                      const SizedBox(height: 8),
                      _SkeletonBar(width: 110, color: Color(0xFFF1F5F9)),
                    ],
                  ),
                ),
                const _SkeletonBar(
                  width: 58,
                  height: 18,
                  color: Color(0xFFF1F5F9),
                ),
              ],
            ),
          ),
        ),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: LinearProgressIndicator(
            minHeight: 2,
            color: Color(0xFF60A5FA),
            backgroundColor: Color(0xFFEFF6FF),
          ),
        ),
      ],
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({
    required this.width,
    required this.color,
    this.height = 9,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}

class HistoryPaginationFooter extends StatelessWidget {
  const HistoryPaginationFooter({
    super.key,
    required this.currentPage,
    required this.totalItems,
    required this.pageSize,
    required this.onPageSelected,
    this.loading = false,
  });

  final int currentPage;
  final int totalItems;
  final int pageSize;
  final ValueChanged<int> onPageSelected;
  final bool loading;

  int get _totalPages => math.max(1, (totalItems / pageSize).ceil());

  @override
  Widget build(BuildContext context) {
    final page = currentPage.clamp(1, _totalPages);
    final first = totalItems == 0 ? 0 : (page - 1) * pageSize + 1;
    final last = math.min(page * pageSize, totalItems);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 520;
          final controls = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ArrowButton(
                icon: Icons.chevron_left,
                enabled: !loading && page > 1,
                onPressed: () => onPageSelected(page - 1),
              ),
              const SizedBox(width: 4),
              if (narrow)
                _CompactPage(page: page, totalPages: _totalPages)
              else
                ..._pageItems(page, _totalPages).map((item) {
                  if (item == null) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5),
                      child: Text(
                        '…',
                        style: TextStyle(color: Color(0xFF64748B)),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _PageButton(
                      page: item,
                      selected: item == page,
                      enabled: !loading,
                      onPressed: () => onPageSelected(item),
                    ),
                  );
                }),
              const SizedBox(width: 4),
              _ArrowButton(
                icon: Icons.chevron_right,
                enabled: !loading && page < _totalPages,
                onPressed: () => onPageSelected(page + 1),
              ),
            ],
          );

          if (narrow) return Center(child: controls);

          return Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$first–$last of $totalItems',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Center(child: controls),
            ],
          );
        },
      ),
    );
  }

  List<int?> _pageItems(int current, int total) {
    if (total <= 7) return List<int>.generate(total, (index) => index + 1);
    final values = <int>{1, total};
    for (var value = current - 2; value <= current + 2; value++) {
      if (value > 1 && value < total) values.add(value);
    }
    final sorted = values.toList()..sort();
    final result = <int?>[];
    for (var index = 0; index < sorted.length; index++) {
      if (index > 0 && sorted[index] - sorted[index - 1] > 1) result.add(null);
      result.add(sorted[index]);
    }
    return result;
  }
}

class _CompactPage extends StatelessWidget {
  const _CompactPage({required this.page, required this.totalPages});

  final int page;
  final int totalPages;

  @override
  Widget build(BuildContext context) => Container(
    height: 30,
    padding: const EdgeInsets.symmetric(horizontal: 11),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFFEFF6FF),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '$page / $totalPages',
      style: const TextStyle(
        color: Color(0xFF2563EB),
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _PageButton extends StatelessWidget {
  const _PageButton({
    required this.page,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final int page;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 30,
    height: 30,
    child: TextButton(
      onPressed: enabled && !selected ? onPressed : null,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: selected
            ? const Color(0xFF2563EB)
            : const Color(0xFF475569),
        disabledForegroundColor: selected
            ? const Color(0xFF2563EB)
            : const Color(0xFF94A3B8),
        backgroundColor: selected ? const Color(0xFFEFF6FF) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      child: Text(
        '$page',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
      ),
    ),
  );
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 30,
    height: 30,
    child: IconButton(
      onPressed: enabled ? onPressed : null,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18),
      color: const Color(0xFF334155),
      disabledColor: const Color(0xFFCBD5E1),
    ),
  );
}
