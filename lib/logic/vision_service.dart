import 'package:flutter/foundation.dart';
import 'scan_cache_service.dart';
import 'tflite_service.dart';
import 'gemini_service.dart';

class VisionService {
  static const double _localModelThreshold = 0.70;
  static const double _nullSceneThreshold = 0.65;

  static Future<Map<String, dynamic>?> processHardwareScan({
    required Uint8List rawBytes,
    required Uint8List localBytes,
    required Uint8List apiBytes,
    required List<double> histogram,
  }) async {
    // LAYER 1: CACHE FIRST
    final cachedResult = ScanCacheService.findMatch(histogram);
    if (cachedResult != null) {
      return cachedResult;
    }

    // LAYER 2: LOCAL TFLITE DETECTOR
    final localResult = await TfliteService.detectObject(localBytes);

    if (localResult != null) {
      if (localResult.label == 'background_null' &&
          localResult.confidence >= _nullSceneThreshold) {
        debugPrint(
          '[VisionService] Empty Scene Detected locally (${localResult.confidence}).',
        );
        return {
          'is_hardware': false,
          'item_name': 'Background',
          'error_message': 'No hardware tool detected in scene.',
          'source': 'local_model',
        };
      }

      if (localResult.confidence >= _localModelThreshold &&
          localResult.label != 'background_null') {
        debugPrint(
          '[VisionService] Local Hit: ${localResult.label} (${localResult.confidence})',
        );
        final formattedResult = {
          'is_hardware': true,
          'item_name': _formatLabel(localResult.label),
          'source': 'local_model',
        };
        ScanCacheService.add(histogram, formattedResult);
        return formattedResult;
      }
    }

    // LAYER 3: CLOUD FALLBACK
    debugPrint(
      '[VisionService] Low local confidence or unknown tool. Routing to Gemini API...',
    );
    final cloudResult = await GeminiService.scanHardwareObject(apiBytes);
    
    if (cloudResult != null) {
      cloudResult['source'] = 'gemini_cloud';
      ScanCacheService.add(histogram, cloudResult);
    }

    return cloudResult;
  }

  static String _formatLabel(String rawLabel) {
    return rawLabel
        .split('_')
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }
}
