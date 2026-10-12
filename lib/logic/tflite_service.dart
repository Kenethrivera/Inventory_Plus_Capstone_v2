import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart'
    show rootBundle, RootIsolateToken, BackgroundIsolateBinaryMessenger;
import 'package:flutter_litert/flutter_litert.dart';

class LocalDetectionResult {
  final String label;
  final double confidence;
  LocalDetectionResult({required this.label, required this.confidence});
}

class TfliteService {
  static Interpreter? _mainInterpreter;
  static List<String> _classes = [];
  static Future<void>? _initFuture;

  /// Safe to call many times / concurrently; loads only once.
  static Future<void> initialize() => _initFuture ??= _load();

  static Future<void> _load() async {
    try {
      if (kIsWeb) await initializeWeb();
      final labelsData = await rootBundle.loadString(
        'assets/models/labels.txt',
      );
      _classes = labelsData
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      // Load the interpreter on the main thread primarily for Web fallback
      _mainInterpreter = await Interpreter.fromAsset(
        'assets/models/best_v1.2.tflite',
      );
    } catch (_) {
      _initFuture = null;
    }
  }

  /// [input] is the ready 1x3x640x640 letterboxed tensor.
  static Future<LocalDetectionResult?> detectObject(Float32List input) async {
    await initialize();
    final labels = _classes;
    if (labels.isEmpty) return null;

    if (kIsWeb) {
      // Web isolates are limited; run on the main thread for Web
      return _runInference(_mainInterpreter, input, labels);
    }

    // MOBILE/DESKTOP: Offload heavy C++ inference and nested array loops
    // to a background isolate to completely unblock the UI spinner.
    final rootToken = RootIsolateToken.instance;

    return await Isolate.run(() async {
      // We must initialize the messenger to read assets in a background isolate
      if (rootToken != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
      }

      // Load an independent interpreter bound to this background isolate's memory
      final isolateInterpreter = await Interpreter.fromAsset(
        'assets/models/best_v1.2.tflite',
      );

      try {
        return _runInference(isolateInterpreter, input, labels);
      } finally {
        // Free C++ memory explicitly to prevent background memory leaks
        isolateInterpreter.close();
      }
    });
  }

  /// The heavy processing logic (Synchronous)
  static LocalDetectionResult? _runInference(
    Interpreter? interpreter,
    Float32List input,
    List<String> labels,
  ) {
    if (interpreter == null) return null;

    try {
      final numClasses = labels.length;
      final output = List.filled(
        1 * (4 + numClasses) * 8400,
        0.0,
      ).reshape([1, 4 + numClasses, 8400]);

      // Massive blocking C++ execution
      interpreter.run(input, output);

      final rows = output[0] as List;
      double best = 0.0;
      int bestClass = -1;

      // Massive blocking nested loop (hundreds of thousands of lookups)
      for (int c = 0; c < numClasses; c++) {
        final row = rows[c + 4] as List;
        for (int a = 0; a < 8400; a++) {
          final conf = row[a] as double;
          if (conf > best) {
            best = conf;
            bestClass = c;
          }
        }
      }

      if (bestClass == -1) return null;
      return LocalDetectionResult(label: labels[bestClass], confidence: best);
    } catch (_) {
      return null;
    }
  }
}
