import 'dart:convert';
import 'dart:typed_data';
import 'scan_cache_service.dart';
import 'tflite_service.dart';
import 'gemini_service.dart';
import 'scan_logger.dart';

class VisionService {
  static const double _localModelThreshold = 0.70;
  static const double _nullSceneThreshold = 0.65;

  static Future<Map<String, dynamic>?> processHardwareScan({
    required Float32List modelInput,
    required Uint8List apiBytes,
    required List<double> histogram,
    ScanLogger? logger,
  }) async {
    final activeLogger = logger ?? ScanLogger.current;

    // 1. Cache
    final cached = ScanCacheService.findMatch(histogram);
    if (cached != null) {
      activeLogger?.log('CACHE HIT -> ${cached['item_name'] ?? 'cached'}');
      activeLogger?.log('END (source: cache)');
      return cached;
    }
    activeLogger?.log('CACHE MISS');

    // 2. Local YOLO
    final local = await TfliteService.detectObject(modelInput);
    if (local != null) {
      final confPercent = (local.confidence * 100).toStringAsFixed(1);
      activeLogger?.log('LOCAL MODEL -> ${local.label} ($confPercent%)');

      final isNull = local.label == 'background_null';

      if (isNull && local.confidence >= _nullSceneThreshold) {
        final result = {
          'is_hardware': false,
          'item_name': 'Background',
          'error_message': 'No hardware tool detected in scene.',
          'source': 'local_model',
        };
        activeLogger?.log('END (source: local_model)');
        return result;
      }

      if (!isNull && local.confidence >= _localModelThreshold) {
        final result = {
          'is_hardware': true,
          'item_name': _formatLabel(local.label),
          'confidence': local.confidence,
          'box': {
            'x': local.x,
            'y': local.y,
            'w': local.width,
            'h': local.height,
          },
          'source': 'local_model',
        };
        ScanCacheService.add(histogram, result);
        activeLogger?.log('END (source: local_model)');
        return result;
      }
    } else {
      activeLogger?.log('LOCAL MODEL -> null');
    }

    activeLogger?.log('LOCAL CONFIDENCE TOO LOW -> falling back to Gemini');

    // 3. Gemini
    activeLogger?.log('GEMINI START');
    final cloud = await GeminiService.scanHardwareObject(apiBytes);
    if (cloud != null) {
      cloud['source'] = 'gemini_cloud';
      ScanCacheService.add(histogram, cloud);
      activeLogger?.log('GEMINI END (result: ${jsonEncode(cloud)})');
      activeLogger?.log('END (source: gemini)');
    } else {
      activeLogger?.log('GEMINI END (result: null)');
      activeLogger?.log('END (source: gemini)');
    }
    return cloud;
  }

  /// Live-mode YOLO-only inference. Never contacts Gemini or the scan cache.
  static Future<Map<String, dynamic>?> processLocalOnly({
    required Float32List modelInput,
    ScanLogger? logger,
  }) async {
    final local = await TfliteService.detectObjectLive(modelInput);
    if (local == null) return null;
    return {
      'is_null': local.label == 'background_null',
      'is_hardware': local.label != 'background_null',
      'item_name': _formatLabel(local.label),
      'confidence': local.confidence,
      'box': {
        'x': local.x, 'y': local.y,
        'w': local.width, 'h': local.height,
      },
      'source': 'local_model_live',
    };
  }

  static String _formatLabel(String raw) => raw
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

