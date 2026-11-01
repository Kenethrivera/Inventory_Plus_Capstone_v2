// Save as: lib/ui/reports/report_period_dialog.dart
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'report_range.dart';

/// Shared "Generate report" dialog: pick the report type, then which period.
/// Calls [onGenerate] with the chosen [ReportRange] after the dialog closes.
Future<void> showReportPeriodDialog(
  BuildContext context, {
  required String title,
  required void Function(ReportRange range) onGenerate,
  String? note,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      String period = 'Daily';
      int offset = 0;

      return StatefulBuilder(
        builder: (stateContext, setState) {
          final options = ReportRange.options(period);

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Container(
              width: 450,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.x, color: Colors.grey),
                        onPressed: () => Navigator.pop(dialogContext),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Report type:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  _box<String>(
                    value: period,
                    items: ReportRange.periods
                        .map(
                          (p) => DropdownMenuItem(
                            value: p,
                            child: Text(
                              p,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        period = v;
                        offset = 0; // reset to the current period
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Select the period:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  _box<int>(
                    value: offset,
                    items: options
                        .map(
                          (r) => DropdownMenuItem(
                            value: r.offset,
                            child: Text(
                              r.optionLabel,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => offset = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ReportRange.limitText(period),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      note,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black87,
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 24,
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () {
                          final range = ReportRange.of(period, offset);
                          Navigator.pop(dialogContext);
                          onGenerate(range);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 32,
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Generate PDF',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Widget _box<T>({
  required T value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?> onChanged,
}) {
  return Builder(
    builder: (context) => Theme(
      data: Theme.of(context).copyWith(
        canvasColor: Colors.white,
        focusColor: const Color(0xFFEFF6FF),
        hoverColor: const Color(0xFFEFF6FF),
        highlightColor: const Color(0xFFDBEAFE),
        splashColor: const Color(0xFFDBEAFE),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            menuMaxHeight: 340,
            itemHeight: 48,
            elevation: 4,
            icon: const Icon(
              LucideIcons.chevronDown,
              size: 18,
              color: Color(0xFF64748B),
            ),
            selectedItemBuilder: (context) => items
                .map(
                  (item) => Align(
                    alignment: Alignment.centerLeft,
                    child: DefaultTextStyle.merge(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: item.child,
                    ),
                  ),
                )
                .toList(),
            items: items
                .map(
                  (item) => DropdownMenuItem<T>(
                    value: item.value,
                    child: Row(
                      children: [
                        Expanded(
                          child: DefaultTextStyle.merge(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: item.value == value
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFF172033),
                            ),
                            child: item.child,
                          ),
                        ),
                        if (item.value == value)
                          const Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: Color(0xFF2563EB),
                          ),
                      ],
                    ),
                  ),
                )
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}
