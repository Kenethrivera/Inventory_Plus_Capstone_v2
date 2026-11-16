import 'package:flutter/foundation.dart';

/// Development-only request timing. Emits no product, location, or user data.
class ForecastingPerformanceDiagnostics {
  ForecastingPerformanceDiagnostics._();

  static int _nextId = 0;
  static int _activeAnalysisRequests = 0;
  static final Map<String, int> _inFlightByProduct = <String, int>{};

  static bool get enabled => kDebugMode;

  static String newOperationId(String operation) =>
      enabled ? '$operation-${++_nextId}' : '';

  static ({int concurrent, bool duplicate}) beginAnalysis({
    required String requestId,
    required String productId,
    required String locationId,
    required String model,
  }) {
    if (!enabled) return (concurrent: 0, duplicate: false);
    final key = '$locationId:$productId';
    final existing = _inFlightByProduct[key] ?? 0;
    _inFlightByProduct[key] = existing + 1;
    final concurrent = ++_activeAnalysisRequests;
    if (kDebugMode) {
      debugPrint(
        '[ForecastPerf] id=$requestId op=analysis.start '
        'model=$model concurrent=$concurrent duplicate_in_flight=${existing > 0} '
        'client_cache=none',
      );
    }
    return (concurrent: concurrent, duplicate: existing > 0);
  }

  static void endAnalysis({
    required String requestId,
    required String productId,
    required String locationId,
    required Stopwatch stopwatch,
    required String outcome,
  }) {
    if (!enabled) return;
    final key = '$locationId:$productId';
    final count = _inFlightByProduct[key] ?? 0;
    if (count <= 1) {
      _inFlightByProduct.remove(key);
    } else {
      _inFlightByProduct[key] = count - 1;
    }
    if (_activeAnalysisRequests > 0) _activeAnalysisRequests--;
    if (kDebugMode) {
      debugPrint(
        '[ForecastPerf] id=$requestId op=analysis.complete '
        'duration_ms=${stopwatch.elapsedMilliseconds} outcome=$outcome '
        'concurrent_after=$_activeAnalysisRequests',
      );
    }
  }

  static void event(String operation, String operationId, String details) {
    if (kDebugMode) {
      debugPrint('[ForecastPerf] id=$operationId op=$operation $details');
    }
  }
}
