import 'package:flutter/material.dart';

const _inventoryBlue = Color(0xFF2563EB);
const _inventoryBlueSoft = Color(0xFFEFF6FF);
const _inventoryBlueRange = Color(0xFFDBEAFE);
const _pickerText = Color(0xFF0F172A);
const _pickerMuted = Color(0xFF64748B);
const _pickerBorder = Color(0xFFE2E8F0);
const _pickerDisabled = Color(0xFFCBD5E1);

enum HistoryPeriodMode { daily, weekly, monthly }

extension HistoryPeriodModeLabel on HistoryPeriodMode {
  String get label => switch (this) {
    HistoryPeriodMode.daily => 'Daily',
    HistoryPeriodMode.weekly => 'Weekly',
    HistoryPeriodMode.monthly => 'Monthly',
  };
}

class HistoryPeriodSelection {
  final HistoryPeriodMode mode;
  final DateTime selectedDay;
  final DateTime selectedWeekStart;
  final DateTime selectedMonth;

  const HistoryPeriodSelection({
    required this.mode,
    required this.selectedDay,
    required this.selectedWeekStart,
    required this.selectedMonth,
  });

  factory HistoryPeriodSelection.current({
    HistoryPeriodMode mode = HistoryPeriodMode.monthly,
    DateTime? now,
  }) {
    final current = _dateOnly(now ?? DateTime.now());
    return HistoryPeriodSelection(
      mode: mode,
      selectedDay: current,
      selectedWeekStart: _mondayFor(current),
      selectedMonth: DateTime(current.year, current.month),
    );
  }

  DateTime get activeStart => switch (mode) {
    HistoryPeriodMode.daily => selectedDay,
    HistoryPeriodMode.weekly => selectedWeekStart,
    HistoryPeriodMode.monthly => selectedMonth,
  };

  DateTime get endExclusive => switch (mode) {
    HistoryPeriodMode.daily => selectedDay.add(const Duration(days: 1)),
    HistoryPeriodMode.weekly => selectedWeekStart.add(const Duration(days: 7)),
    HistoryPeriodMode.monthly => DateTime(
      selectedMonth.year,
      selectedMonth.month + 1,
    ),
  };

  ({DateTime start, DateTime end}) get range =>
      (start: activeStart, end: endExclusive);

  DateTime get pickerDate => activeStart;

  String get stableKey => switch (mode) {
    HistoryPeriodMode.daily => 'daily:${_dateKey(selectedDay)}',
    HistoryPeriodMode.weekly => 'weekly:${_dateKey(selectedWeekStart)}',
    HistoryPeriodMode.monthly =>
      'monthly:${selectedMonth.year}-${_two(selectedMonth.month)}',
  };

  String get displayLabel => switch (mode) {
    HistoryPeriodMode.daily => _formatDay(selectedDay),
    HistoryPeriodMode.weekly => _formatWeek(selectedWeekStart),
    HistoryPeriodMode.monthly => _formatMonth(selectedMonth),
  };

  String get compactDisplayLabel => switch (mode) {
    HistoryPeriodMode.daily => _formatDay(selectedDay),
    HistoryPeriodMode.weekly => _formatCompactWeek(selectedWeekStart),
    HistoryPeriodMode.monthly =>
      '${_shortMonths[selectedMonth.month - 1]} ${selectedMonth.year}',
  };

  bool canMoveNext({DateTime? now}) {
    final current = HistoryPeriodSelection.current(mode: mode, now: now);
    return activeStart.isBefore(current.activeStart);
  }

  HistoryPeriodSelection withMode(HistoryPeriodMode value) =>
      HistoryPeriodSelection(
        mode: value,
        selectedDay: selectedDay,
        selectedWeekStart: selectedWeekStart,
        selectedMonth: selectedMonth,
      );

  HistoryPeriodSelection select(DateTime value) {
    final date = _dateOnly(value);
    return switch (mode) {
      HistoryPeriodMode.daily => HistoryPeriodSelection(
        mode: mode,
        selectedDay: date,
        selectedWeekStart: selectedWeekStart,
        selectedMonth: selectedMonth,
      ),
      HistoryPeriodMode.weekly => HistoryPeriodSelection(
        mode: mode,
        selectedDay: selectedDay,
        selectedWeekStart: _mondayFor(date),
        selectedMonth: selectedMonth,
      ),
      HistoryPeriodMode.monthly => HistoryPeriodSelection(
        mode: mode,
        selectedDay: selectedDay,
        selectedWeekStart: selectedWeekStart,
        selectedMonth: DateTime(date.year, date.month),
      ),
    };
  }

  HistoryPeriodSelection move(int amount, {DateTime? now}) {
    if (amount == 0) return this;
    final candidate = switch (mode) {
      HistoryPeriodMode.daily => select(
        selectedDay.add(Duration(days: amount)),
      ),
      HistoryPeriodMode.weekly => select(
        selectedWeekStart.add(Duration(days: amount * 7)),
      ),
      HistoryPeriodMode.monthly => select(
        DateTime(selectedMonth.year, selectedMonth.month + amount),
      ),
    };
    if (amount > 0 && !canMoveNext(now: now)) return this;
    return candidate;
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime _mondayFor(DateTime value) {
    final date = _dateOnly(value);
    return date.subtract(Duration(days: date.weekday - DateTime.monday));
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _dateKey(DateTime value) =>
      '${value.year}-${_two(value.month)}-${_two(value.day)}';

  static const _shortMonths = [
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

  static const _longMonths = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static String _formatDay(DateTime value) =>
      '${_shortMonths[value.month - 1]} ${value.day}, ${value.year}';

  static String _formatMonth(DateTime value) =>
      '${_longMonths[value.month - 1]} ${value.year}';

  static String _formatWeek(DateTime start) {
    final end = start.add(const Duration(days: 6));
    if (start.year != end.year) {
      return '${_shortMonths[start.month - 1]} ${start.day}, ${start.year} – '
          '${_shortMonths[end.month - 1]} ${end.day}, ${end.year}';
    }
    if (start.month != end.month) {
      return '${_shortMonths[start.month - 1]} ${start.day} – '
          '${_shortMonths[end.month - 1]} ${end.day}, ${end.year}';
    }
    return '${_shortMonths[start.month - 1]} ${start.day} – '
        '${end.day}, ${end.year}';
  }

  static String _formatCompactWeek(DateTime start) {
    final end = start.add(const Duration(days: 6));
    if (start.year != end.year) {
      final startYear = start.year.toString().substring(2);
      final endYear = end.year.toString().substring(2);
      return '${_shortMonths[start.month - 1]} ${start.day} ’$startYear – '
          '${_shortMonths[end.month - 1]} ${end.day} ’$endYear';
    }
    if (start.month != end.month) {
      return '${_shortMonths[start.month - 1]} ${start.day} – '
          '${_shortMonths[end.month - 1]} ${end.day}, ${end.year}';
    }
    return '${_shortMonths[start.month - 1]} ${start.day}–${end.day}, '
        '${end.year}';
  }
}

class HistoryPeriodControls extends StatelessWidget {
  final HistoryPeriodSelection selection;
  final ValueChanged<HistoryPeriodSelection> onChanged;

  const HistoryPeriodControls({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final canMoveNext = selection.canMoveNext();
    final compact = MediaQuery.sizeOf(context).width < 420;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PeriodArrow(
            tooltip: 'Previous ${selection.mode.label.toLowerCase()}',
            icon: Icons.chevron_left,
            onPressed: () => onChanged(selection.move(-1)),
          ),
          const SizedBox(height: 18, child: VerticalDivider(width: 1)),
          Tooltip(
            message: selection.displayLabel,
            child: InkWell(
              onTap: () => _pickPeriod(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!compact) ...[
                      const Icon(
                        Icons.calendar_today_outlined,
                        size: 14,
                        color: Color(0xFF64748B),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      compact
                          ? selection.compactDisplayLabel
                          : selection.displayLabel,
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_drop_down,
                      size: 17,
                      color: Color(0xFF64748B),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18, child: VerticalDivider(width: 1)),
          _PeriodArrow(
            tooltip: 'Next ${selection.mode.label.toLowerCase()}',
            icon: Icons.chevron_right,
            onPressed: canMoveNext ? () => onChanged(selection.move(1)) : null,
          ),
        ],
      ),
    );
  }

  Future<void> _pickPeriod(BuildContext context) async {
    DateTime? picked;
    if (selection.mode == HistoryPeriodMode.monthly) {
      picked = await _showInventoryMonthPicker(
        context,
        initialMonth: selection.selectedMonth,
      );
    } else {
      picked = await _showInventoryDatePicker(
        context,
        initialDate: selection.pickerDate,
        weekly: selection.mode == HistoryPeriodMode.weekly,
      );
    }
    if (picked != null && context.mounted) onChanged(selection.select(picked));
  }
}

Future<DateTime?> _showInventoryDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required bool weekly,
}) {
  final today = HistoryPeriodSelection._dateOnly(DateTime.now());
  var selectedDate = HistoryPeriodSelection._dateOnly(initialDate);
  var visibleMonth = DateTime(selectedDate.year, selectedDate.month);

  return showDialog<DateTime>(
    context: context,
    barrierColor: const Color(0xFF0F172A).withValues(alpha: 0.42),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        final firstDay = DateTime(visibleMonth.year, visibleMonth.month);
        final leadingDays = firstDay.weekday - DateTime.monday;
        final daysInMonth = DateTime(
          visibleMonth.year,
          visibleMonth.month + 1,
          0,
        ).day;
        final cellCount = ((leadingDays + daysInMonth + 6) ~/ 7) * 7;
        final selectedWeekStart = HistoryPeriodSelection._mondayFor(
          selectedDate,
        );
        final selectedWeekEnd = selectedWeekStart.add(const Duration(days: 6));
        final currentMonth = DateTime(today.year, today.month);

        return _PeriodPickerDialog(
          title: weekly ? 'Select week' : 'Select date',
          onClose: () => Navigator.pop(dialogContext),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                weekly
                    ? 'Choose any date. Weeks run Monday to Sunday.'
                    : 'Choose a calendar date for transaction history.',
                style: const TextStyle(
                  color: _pickerMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              _PickerNavigationHeader(
                label: HistoryPeriodSelection._formatMonth(visibleMonth),
                previousTooltip: 'Previous month',
                nextTooltip: 'Next month',
                canMoveBack: visibleMonth.isAfter(DateTime(2000)),
                canMoveForward: visibleMonth.isBefore(currentMonth),
                onPrevious: () => setDialogState(() {
                  visibleMonth = DateTime(
                    visibleMonth.year,
                    visibleMonth.month - 1,
                  );
                }),
                onNext: () => setDialogState(() {
                  visibleMonth = DateTime(
                    visibleMonth.year,
                    visibleMonth.month + 1,
                  );
                }),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final day in [
                    'Mon',
                    'Tue',
                    'Wed',
                    'Thu',
                    'Fri',
                    'Sat',
                    'Sun',
                  ])
                    Expanded(
                      child: Center(
                        child: Text(
                          day,
                          style: TextStyle(
                            color: _pickerMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: cellCount,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                  childAspectRatio: 1,
                ),
                itemBuilder: (context, index) {
                  final dayNumber = index - leadingDays + 1;
                  if (dayNumber < 1 || dayNumber > daysInMonth) {
                    return const SizedBox.shrink();
                  }
                  final date = DateTime(
                    visibleMonth.year,
                    visibleMonth.month,
                    dayNumber,
                  );
                  final selected =
                      HistoryPeriodSelection._dateKey(date) ==
                      HistoryPeriodSelection._dateKey(selectedDate);
                  final isToday =
                      HistoryPeriodSelection._dateKey(date) ==
                      HistoryPeriodSelection._dateKey(today);
                  final inSelectedWeek =
                      weekly &&
                      !date.isBefore(selectedWeekStart) &&
                      !date.isAfter(selectedWeekEnd);
                  return _CalendarDay(
                    date: date,
                    selected: selected,
                    highlighted: inSelectedWeek,
                    today: isToday,
                    enabled: !date.isAfter(today),
                    onPressed: () => setDialogState(() => selectedDate = date),
                  );
                },
              ),
              if (weekly) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: _inventoryBlueSoft,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: _inventoryBlueRange),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.date_range_outlined,
                        size: 16,
                        color: _inventoryBlue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          HistoryPeriodSelection._formatWeek(selectedWeekStart),
                          style: const TextStyle(
                            color: _inventoryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          onCancel: () => Navigator.pop(dialogContext),
          onSelect: () => Navigator.pop(dialogContext, selectedDate),
        );
      },
    ),
  );
}

class _PeriodPickerDialog extends StatelessWidget {
  final String title;
  final Widget body;
  final VoidCallback onClose;
  final VoidCallback onCancel;
  final VoidCallback onSelect;

  const _PeriodPickerDialog({
    required this.title,
    required this.body,
    required this.onClose,
    required this.onCancel,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390, maxHeight: 620),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _pickerBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0x240F172A),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 10, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: _pickerText,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: onClose,
                        icon: const Icon(Icons.close, size: 19),
                        color: _pickerMuted,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _pickerBorder),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: body,
                  ),
                ),
                const Divider(height: 1, color: _pickerBorder),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: onCancel,
                        style: TextButton.styleFrom(
                          foregroundColor: _pickerMuted,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 11,
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: onSelect,
                        style: FilledButton.styleFrom(
                          backgroundColor: _inventoryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 11,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                        child: const Text('Select'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerNavigationHeader extends StatelessWidget {
  final String label;
  final String previousTooltip;
  final String nextTooltip;
  final bool canMoveBack;
  final bool canMoveForward;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _PickerNavigationHeader({
    required this.label,
    required this.previousTooltip,
    required this.nextTooltip,
    required this.canMoveBack,
    required this.canMoveForward,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _pickerBorder),
      ),
      child: Row(
        children: [
          _PickerNavigationButton(
            tooltip: previousTooltip,
            icon: Icons.chevron_left,
            onPressed: canMoveBack ? onPrevious : null,
          ),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _pickerText,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          _PickerNavigationButton(
            tooltip: nextTooltip,
            icon: Icons.chevron_right,
            onPressed: canMoveForward ? onNext : null,
          ),
        ],
      ),
    );
  }
}

class _PickerNavigationButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _PickerNavigationButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      color: _inventoryBlue,
      disabledColor: _pickerDisabled,
      hoverColor: _inventoryBlueSoft,
      focusColor: _inventoryBlueSoft,
      splashRadius: 18,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CalendarDay extends StatelessWidget {
  final DateTime date;
  final bool selected;
  final bool highlighted;
  final bool today;
  final bool enabled;
  final VoidCallback onPressed;

  const _CalendarDay({
    required this.date,
    required this.selected,
    required this.highlighted,
    required this.today,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor = selected
        ? _inventoryBlue
        : highlighted
        ? _inventoryBlueRange
        : Colors.transparent;
    final foregroundColor = !enabled
        ? _pickerDisabled
        : selected
        ? Colors.white
        : (today || highlighted)
        ? _inventoryBlue
        : _pickerText;

    final day = Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: today && !selected
            ? const BorderSide(color: _inventoryBlue)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        hoverColor: enabled ? _inventoryBlueSoft : Colors.transparent,
        focusColor: enabled ? _inventoryBlueSoft : Colors.transparent,
        child: Center(
          child: Text(
            '${date.day}',
            style: TextStyle(
              color: foregroundColor,
              fontSize: 12,
              fontWeight: selected || today ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: enabled,
      enabled: enabled,
      selected: selected,
      label:
          '${HistoryPeriodSelection._formatDay(date)}${today ? ', today' : ''}',
      child: enabled
          ? MouseRegion(cursor: SystemMouseCursors.click, child: day)
          : day,
    );
  }
}

class _PeriodArrow extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _PeriodArrow({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 34),
      visualDensity: VisualDensity.compact,
      color: const Color(0xFF475569),
      disabledColor: const Color(0xFFCBD5E1),
    );
  }
}

Future<DateTime?> _showInventoryMonthPicker(
  BuildContext context, {
  required DateTime initialMonth,
}) {
  var visibleYear = initialMonth.year;
  var selectedMonth = DateTime(initialMonth.year, initialMonth.month);
  final now = DateTime.now();
  const firstYear = 2000;
  const monthNames = [
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

  return showDialog<DateTime>(
    context: context,
    barrierColor: const Color(0xFF0F172A).withValues(alpha: 0.42),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        return _PeriodPickerDialog(
          title: 'Select month',
          onClose: () => Navigator.pop(dialogContext),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Choose a month and year for transaction history.',
                style: TextStyle(
                  color: _pickerMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              _PickerNavigationHeader(
                label: '$visibleYear',
                previousTooltip: 'Previous year',
                nextTooltip: 'Next year',
                canMoveBack: visibleYear > firstYear,
                canMoveForward: visibleYear < now.year,
                onPrevious: () => setDialogState(() => visibleYear--),
                onNext: () => setDialogState(() => visibleYear++),
              ),
              const SizedBox(height: 14),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 12,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.55,
                ),
                itemBuilder: (context, index) {
                  final month = index + 1;
                  final disabled =
                      visibleYear > now.year ||
                      (visibleYear == now.year && month > now.month);
                  final selected =
                      visibleYear == selectedMonth.year &&
                      month == selectedMonth.month;
                  final current = visibleYear == now.year && month == now.month;
                  return _MonthCell(
                    label: monthNames[index],
                    year: visibleYear,
                    selected: selected,
                    current: current,
                    enabled: !disabled,
                    onPressed: () => setDialogState(
                      () => selectedMonth = DateTime(visibleYear, month),
                    ),
                  );
                },
              ),
            ],
          ),
          onCancel: () => Navigator.pop(dialogContext),
          onSelect: () => Navigator.pop(dialogContext, selectedMonth),
        );
      },
    ),
  );
}

class _MonthCell extends StatelessWidget {
  final String label;
  final int year;
  final bool selected;
  final bool current;
  final bool enabled;
  final VoidCallback onPressed;

  const _MonthCell({
    required this.label,
    required this.year,
    required this.selected,
    required this.current,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: selected ? _inventoryBlue : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(
          color: selected || current ? _inventoryBlue : _pickerBorder,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        hoverColor: enabled ? _inventoryBlueSoft : Colors.transparent,
        focusColor: enabled ? _inventoryBlueSoft : Colors.transparent,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: !enabled
                  ? _pickerDisabled
                  : selected
                  ? Colors.white
                  : current
                  ? _inventoryBlue
                  : _pickerText,
              fontSize: 12,
              fontWeight: selected || current
                  ? FontWeight.w800
                  : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: enabled,
      enabled: enabled,
      selected: selected,
      label: '$label $year',
      child: enabled
          ? MouseRegion(cursor: SystemMouseCursors.click, child: button)
          : button,
    );
  }
}
