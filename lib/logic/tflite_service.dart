import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart' show rootBundle;
import 'dart:math' as math;
import 'debug_proof_saver.dart';

class LocalDetectionResult {
  final String label;
  final double confidence;
  LocalDetectionResult({required this.label, required this.confidence});
}

class TfliteService {
  static Interpreter? _interpreter;
  static List<String> _classes = [];

  // Debug: PNG bytes of the exact 640x640 letterboxed image the model
  // received, with the model's own predicted box drawn on it. Overwritten
  // every call. Only populated in debug mode. View it with
  // Image.memory(TfliteService.lastDebugImage!) from anywhere in the UI.
  static Uint8List? lastDebugImage;

  static Future<void> initialize() async {
    if (_interpreter != null) return;
    try {
      if (kIsWeb) await initializeWeb();

      final labelsData = await rootBundle.loadString(
        'assets/models/labels.txt',
      );
      _classes = labelsData
          .split('\n')
          .where((s) => s.trim().isNotEmpty)
          .toList();

      _interpreter = await Interpreter.fromAsset('assets/models/best_v1.2.tflite');
    } catch (e) {
      debugPrint('[TFLite] Error loading model: $e');
    }
  }

  static Future<LocalDetectionResult?> detectObject(
    Uint8List imageBytes,
  ) async {
    if (_interpreter == null) await initialize();
    if (_interpreter == null) return null;

    try {
      final originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) return null;

      final resizedImage = _letterbox(originalImage, 640);

      var input = Float32List(1 * 3 * 640 * 640);
      final int planeSize = 640 * 640; // 409600

      for (int y = 0; y < 640; y++) {
        for (int x = 0; x < 640; x++) {
          final pixel = resizedImage.getPixel(x, y);
          final int pixelPos = y * 640 + x;
          input[pixelPos] = pixel.r / 255.0; // R plane
          input[planeSize + pixelPos] = pixel.g / 255.0; // G plane
          input[2 * planeSize + pixelPos] = pixel.b / 255.0; // B plane
        }
      }

      final int numClasses = _classes.length; // 21
      final int tensorSize = 4 + numClasses; // 25

      var output = List.filled(
        1 * tensorSize * 8400,
        0.0,
      ).reshape([1, tensorSize, 8400]);

      _interpreter!.run(input, output);

      double highestConfidence = 0.0;
      int bestClassIndex = -1;
      int bestAnchor = -1;

      for (int anchor = 0; anchor < 8400; anchor++) {
        for (int c = 0; c < numClasses; c++) {
          double confidence = output[0][c + 4][anchor];
          if (confidence > highestConfidence) {
            highestConfidence = confidence;
            bestClassIndex = c;
            bestAnchor = anchor;
          }
        }
      }

      if (bestClassIndex != -1) {
        final detectedLabel = _classes[bestClassIndex];

        // --- Decode the box for the winning anchor and draw it on the
        // exact letterboxed image that was fed to the model. ---
        if (kDebugMode) {
          final cx = output[0][0][bestAnchor];
          final cy = output[0][1][bestAnchor];
          final w = output[0][2][bestAnchor];
          final h = output[0][3][bestAnchor];

          final x1 = (cx - w / 2).round().clamp(0, 639);
          final y1 = (cy - h / 2).round().clamp(0, 639);
          final x2 = (cx + w / 2).round().clamp(0, 639);
          final y2 = (cy + h / 2).round().clamp(0, 639);

          final debugImage = img.Image.from(resizedImage);
          img.drawRect(
            debugImage,
            x1: x1,
            y1: y1,
            x2: x2,
            y2: y2,
            color: img.ColorRgb8(255, 0, 0),
            thickness: 3,
          );
          img.drawString(
            debugImage,
            '$detectedLabel ${(highestConfidence * 100).toStringAsFixed(1)}%',
            font: img.arial24,
            x: 4,
            y: 4,
            color: img.ColorRgb8(255, 0, 0),
          );
          lastDebugImage = Uint8List.fromList(img.encodePng(debugImage));

          // Fire-and-forget, and now cross-platform: saveDebugProofPlatform
          // resolves at compile time to the io version (mobile/desktop,
          // writes to disk) or the web version (triggers a browser
          // download) — this call site doesn't need to know which.
          // Never blocks or delays returning the result below.
          final confidenceLabel = (highestConfidence * 100).toStringAsFixed(1);
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final baseName = '${detectedLabel}_${confidenceLabel}_$timestamp';

          // Annotated copy: for you to visually review (has box + label
          // burned in, so NOT suitable as training data).
          unawaited(
            saveDebugProofPlatform(
              fileName: '${baseName}_debug.png',
              pngBytes: lastDebugImage!,
            ),
          );

          // Clean copy: the exact letterboxed image the model saw, with
          // no overlay — safe to relabel and feed back into training if
          // this prediction turns out to be wrong.
          final cleanBytes = Uint8List.fromList(img.encodePng(resizedImage));
          unawaited(
            saveDebugProofPlatform(
              fileName: '${baseName}_raw.png',
              pngBytes: cleanBytes,
            ),
          );
        }

        debugPrint('=========================================');
        debugPrint('[TFLite] RAW INFERENCE SUCCESS');
        debugPrint('[TFLite] Top Class: $detectedLabel');
        debugPrint(
          '[TFLite] Confidence: ${(highestConfidence * 100).toStringAsFixed(2)}%',
        );
        debugPrint(
          '[TFLite] Full class vector: ${List.generate(
                numClasses,
                (c) => output[0][c + 4][bestAnchor].toStringAsFixed(3),
              ).join(', ')}',
        );
        debugPrint('=========================================');

        return LocalDetectionResult(
          label: detectedLabel,
          confidence: highestConfidence,
        );
      }
      return null;
    } catch (e) {
      debugPrint('[TFLite] Inference failed: $e');
      return null;
    }
  }

  static img.Image _letterbox(img.Image src, int targetSize) {
    final ratio = math.min(targetSize / src.width, targetSize / src.height);
    final newW = (src.width * ratio).round();
    final newH = (src.height * ratio).round();
    final resized = img.copyResize(src, width: newW, height: newH);

    final canvas = img.Image(width: targetSize, height: targetSize);
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));

    final padX = ((targetSize - newW) / 2).round();
    final padY = ((targetSize - newH) / 2).round();
    img.compositeImage(canvas, resized, dstX: padX, dstY: padY);

    return canvas;
  }
}
