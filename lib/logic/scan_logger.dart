import '../services/app_logger.dart';

class ScanLogger {
  static ScanLogger? current;

  final DateTime startTime;
  final Stopwatch _stopwatch;

  ScanLogger({DateTime? startTime})
      : startTime = startTime ?? DateTime.now(),
        _stopwatch = Stopwatch()..start() {
    current = this;
  }

  void log(String message) {
    final now = DateTime.now();
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    final timestamp = formatTimestamp(now);
    AppLogger.debug('[SCAN $timestamp] (+${elapsedMs}ms) $message');
  }

  static String formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$y-$m-${d}T$h:$min:$s.$ms';
  }
}
