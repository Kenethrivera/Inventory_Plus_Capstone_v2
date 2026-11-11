import 'dart:math' as math;

import 'package:flutter/material.dart';

const _ink = Color(0xFF171717);
const _muted = Color(0xFF817A75);
const _line = Color(0xFFE6E1DC);
const _orange = Color(0xFFC83D08);
const _selected = Color(0xFFFFF1E9);

/// A dropdown with the same anchored menu and selected row as the staff filter.
class AppStyledDropdown<T> extends StatelessWidget {
  const AppStyledDropdown({
    super.key,
    this.value,
    this.initialValue,
    required this.items,
    required this.onChanged,
    this.decoration,
    this.style,
    this.hint,
    this.isDense = false,
    this.menuMaxHeight = 360,
  });

  final T? value;
  final T? initialValue;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final TextStyle? style;
  final Widget? hint;
  final bool isDense;
  final double menuMaxHeight;

  @override
  Widget build(BuildContext context) {
    final selectedValue = value ?? initialValue;
    final selectedIndex = items.indexWhere(
      (item) => item.value == selectedValue,
    );
    final selectedChild = selectedIndex < 0
        ? hint ?? const SizedBox.shrink()
        : items[selectedIndex].child;
    final enabled = onChanged != null && items.any((item) => item.enabled);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 180.0;
        final maxHeight = math.min(
          menuMaxHeight,
          MediaQuery.sizeOf(context).height - 32,
        );
        final label = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: DefaultTextStyle.merge(
                style: style ?? const TextStyle(color: _ink, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: _styledLabel(selectedChild, selected: false),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: _muted,
            ),
          ],
        );
        final field = decoration == null
            ? Container(
                height: isDense ? 36 : 44,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: label,
              )
            : InputDecorator(
                isEmpty: selectedIndex < 0,
                decoration: decoration!.copyWith(
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: _line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: const BorderSide(color: _orange),
                  ),
                ),
                child: label,
              );

        return SizedBox(
          width: width,
          child: PopupMenuButton<int>(
            tooltip: 'Choose an option',
            enabled: enabled,
            position: PopupMenuPosition.under,
            offset: const Offset(0, 6),
            padding: EdgeInsets.zero,
            menuPadding: const EdgeInsets.symmetric(vertical: 5),
            constraints: BoxConstraints(
              minWidth: width,
              maxWidth: width,
              maxHeight: maxHeight,
            ),
            color: Colors.white,
            surfaceTintColor: Colors.transparent,
            shadowColor: const Color(0x33000000),
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: _line),
            ),
            onSelected: (index) => onChanged?.call(items[index].value),
            itemBuilder: (context) => [
              for (var index = 0; index < items.length; index++)
                PopupMenuItem<int>(
                  value: index,
                  enabled: items[index].enabled,
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: index == selectedIndex
                          ? _selected
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: DefaultTextStyle.merge(
                            style: TextStyle(
                              color: index == selectedIndex ? _orange : _ink,
                              fontSize: style?.fontSize ?? 13,
                              fontWeight: index == selectedIndex
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            child: _styledLabel(
                              items[index].child,
                              selected: index == selectedIndex,
                            ),
                          ),
                        ),
                        if (index == selectedIndex) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.check_rounded,
                            size: 16,
                            color: _orange,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
            child: Opacity(opacity: enabled ? 1 : .5, child: field),
          ),
        );
      },
    );
  }
}

Widget _styledLabel(Widget child, {required bool selected}) {
  if (child is Text && child.data != null && child.data!.isNotEmpty) {
    return Text(
      child.data!,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (child.style ?? const TextStyle()).copyWith(
        color: selected ? _orange : _ink,
        fontWeight: selected ? FontWeight.w600 : null,
      ),
    );
  }
  return child;
}
