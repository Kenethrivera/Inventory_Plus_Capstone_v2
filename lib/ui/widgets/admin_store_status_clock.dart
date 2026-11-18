import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/store_access_service.dart';

/// Shows the current store-hours status in the Admin header.
class AdminStoreStatusClock extends StatefulWidget {
  final StoreAccessWindow? Function(DateTime) resolveWindow;
  final String? Function(DateTime)? closureReason;
  final bool compact;
  final DateTime Function()? now;

  const AdminStoreStatusClock({
    super.key,
    required this.resolveWindow,
    this.closureReason,
    this.compact = false,
    this.now,
  });

  @override
  State<AdminStoreStatusClock> createState() => _AdminStoreStatusClockState();
}

class _AdminStoreStatusClockState extends State<AdminStoreStatusClock>
    with WidgetsBindingObserver {
  Timer? _minuteTimer;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleNextMinute();
  }

  void _scheduleNextMinute() {
    _minuteTimer?.cancel();
    final now = _now;
    final millisecondsUntilNextMinute =
        60000 - now.second * 1000 - now.millisecond;
    _minuteTimer = Timer(
      Duration(milliseconds: millisecondsUntilNextMinute),
      () {
        if (!mounted) return;
        setState(() {});
        _scheduleNextMinute();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
      _scheduleNextMinute();
    }
  }

  @override
  void dispose() {
    _minuteTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _formatTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return '$hour:${value.minute.toString().padLeft(2, '0')} ${value.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final window = widget.resolveWindow(now);
    final isOpen =
        window != null &&
        !now.isBefore(window.opening) &&
        now.isBefore(window.shiftEnd);
    final reason = isOpen ? '' : widget.closureReason?.call(now)?.trim() ?? '';
    final status = window == null
        ? 'Store hours unavailable'
        : isOpen
        ? 'Open · closes ${_formatTime(window.shiftEnd)}'
        : reason.isEmpty
        ? 'Closed · opens ${_formatTime(window.opening)}'
        : 'Closed · $reason · opens ${_formatTime(window.opening)}';
    final fontSize = widget.compact ? 12.0 : 14.0;
    return Row(
      children: [
        Icon(
          Icons.circle,
          size: 9,
          color: isOpen ? const Color(0xFF16A34A) : const Color(0xFFA8A29E),
        ),
        SizedBox(width: widget.compact ? 9 : 12),
        Expanded(
          child: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: const Color(0xFF171717),
              fontSize: fontSize,
              fontWeight: widget.compact ? null : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
