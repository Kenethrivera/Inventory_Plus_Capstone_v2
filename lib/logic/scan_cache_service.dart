import 'package:flutter/foundation.dart';

class ScanCacheService {
  static final List<Map<String, dynamic>> _scanCache = [];
  static const _cacheTTL = Duration(minutes: 10);
  static const _maxCacheSize = 30;
  static const _cacheMatchThreshold = 1.2;

  static Map<String, dynamic>? findMatch(List<double> currentHistogram) {
    _scanCache.removeWhere(
      (e) => DateTime.now().difference(e['timestamp'] as DateTime) > _cacheTTL,
    );

    double closestDiff = double.infinity;
    Map<String, dynamic>? closestMatch;

    for (var cachedItem in _scanCache) {
      final cachedHistogram = cachedItem['histogram'] as List<double>;
      double difference = 0;
      for (int i = 0; i < 192; i++) {
        difference += (currentHistogram[i] - cachedHistogram[i]).abs();
      }

      if (difference < closestDiff) {
        closestDiff = difference;
        closestMatch = cachedItem['data'] as Map<String, dynamic>;
      }
    }

    if (closestDiff != double.infinity) {
      debugPrint(
        '[Cache] closest diff: ${closestDiff.toStringAsFixed(3)} -> ${closestDiff < _cacheMatchThreshold ? "HIT" : "MISS"}',
      );
    }

    if (closestDiff < _cacheMatchThreshold && closestMatch != null) {
      return closestMatch;
    }
    return null;
  }

  static void add(List<double> histogram, Map<String, dynamic> data) {
    if (_scanCache.length >= _maxCacheSize) {
      _scanCache.removeAt(0);
    }
    _scanCache.add({
      'histogram': histogram,
      'data': data,
      'timestamp': DateTime.now(),
    });
  }
}
