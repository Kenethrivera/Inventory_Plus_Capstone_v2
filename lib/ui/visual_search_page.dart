import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:camera/camera.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute, defaultTargetPlatform, TargetPlatform;
import 'package:image/image.dart' as img;
import '../../data/inventory.dart';
import '../../logic/inventory_controller.dart';
import '../../logic/vision_service.dart';
import '../../logic/tflite_service.dart';
import '../../logic/scan_logger.dart';
import '../../logic/gemini_service.dart';
import 'package:flutter/services.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _lightBlue = Color(0xFF3B82F6);
const Color _darkBlue = Color(0xFF1D4ED8);

class VisualSearchPage extends StatefulWidget {
  final InventoryController controller;
  final Function(InventoryItem) onSelectItem;

  const VisualSearchPage({
    super.key,
    required this.controller,
    required this.onSelectItem,
  });

  @override
  State<VisualSearchPage> createState() => _VisualSearchPageState();
}

class _VisualSearchPageState extends State<VisualSearchPage>
    with TickerProviderStateMixin {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  int _selectedCameraIndex = 0;
  bool _isAnalyzing = false;
  bool _isCameraInitialized = false;
  bool _isFlashOn = false;

  // Phones get a top-to-bottom scan line; everything else (web/desktop)
  // keeps the left-to-right sweep. This avoids dart:io so the file builds on Web.
  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  // --- Live mode ---
  bool _isLiveMode = false;
  late AnimationController _radarController; // drives the scan-line sweep

  // Auto-scan countdown (3s), only runs once the frame is judged stable.
  AnimationController? _autoScanController;
  bool _isCountingDown = false;

  // --- Lightweight frame stability check ---
  // Grabs a tiny snapshot directly from the rendered preview widget via
  // RepaintBoundary.toImage() at a very low pixel ratio, and diffs it
  // against the previous one to detect motion — no camera hardware
  // capture involved, so it's cheap enough to run continuously.
  final GlobalKey _previewBoundaryKey = GlobalKey();
  Timer? _stabilityTimer;
  static const _stabilityPollInterval = Duration(milliseconds: 300);
  static const _requiredStableChecks = 3;
  static const _motionThreshold = 6.0; // avg luminance delta (0-255 scale)
  List<double>? _lastSignature;
  int _stableCheckCount = 0;
  bool _isCheckingStability = false;

  // Web guide box: square, tuned for a laptop webcam at typical distance.
  static const double _alignBoxFactor = 0.65;

  // Mobile guide box is only a framing aid; mobile scans use the complete
  // captured camera frame. Keep the portrait rectangle for elongated tools.
  static const double _mobileCropWidth = 0.85;
  static const double _mobileCropHeight = 0.62;

  double get _boxWFactor =>
      _isMobilePlatform ? _mobileCropWidth : _alignBoxFactor;
  double get _boxHFactor =>
      _isMobilePlatform ? _mobileCropHeight : _alignBoxFactor;

  String _liveStatusText = "Point camera at a tool";


  // --- YOLO-FIRST live mode ---
  // Give local inference several attempts, but stop immediately for a strong
  // result. Gemini runs only after exhausted YOLO attempts, or when the user
  // explicitly presses Verify with Gemini.
  Timer? _liveYoloTimer;
  Timer? _liveFallbackTimer;
  bool _isLiveYoloRunning = false;
  bool _isGeminiFallbackRunning = false;
  bool _geminiAttemptedForScene = false;
  bool _strongYoloSeen = false;
  bool _yoloDeadlineReached = false;
  LiveDetection? _currentLiveDetection;
  DateTime? _lastGeminiFallbackAt;
  DateTime? _liveScanStartedAt;
  Uint8List? _lastLiveApiBytes;
  Size? _liveImageSize;
  // Scores are kept separately: Gemini's estimate never replaces YOLO's score.
  String? _lastYoloCandidateName;
  double? _lastYoloCandidateScore;
  String? _liveError;
  int _liveGeneration = 0;
  int _yoloSamples = 0;

  // Tune these values to balance latency and Gemini consumption.
  // Most warm YOLO samples take ~2.5-3s on the tested browser, so 3 samples
  // usually finish in ~8-10s. The first sample may take much longer.
  static const Duration _liveYoloInterval = Duration(milliseconds: 650);
  static const Duration _liveYoloWindow = Duration(seconds: 15);
  static const int _targetYoloSamples = 3;
  // If the 15-second deadline is reached, finish at least two attempts
  // before falling back (unless a camera error prevents it).
  static const int _minimumYoloSamples = 2;
  static const Duration _geminiLiveCooldown = Duration(seconds: 30);
  static const double _strongYoloThreshold = 0.70;
  static const double _weakYoloThreshold = 0.45;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _autoScanController =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _onAutoScanComplete();
            }
          });
    unawaited(TfliteService.initialize());
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        await _setCamera(_selectedCameraIndex);
      }
    } catch (e) {
      _showScanResultModal(
        detectedName: "Camera Error",
        isHardware: false,
        errorMessage: "Failed to initialize camera: $e",
        similarItems: [],
      );
    }
  }

  Future<void> _setCamera(int index) async {
    if (_cameras == null || _cameras!.isEmpty) return;
    final previousController = _cameraController;
    _cameraController = CameraController(
      _cameras![index],
      // Web webcams can be slow to capture/decode at full resolution.
      // The YOLO input is 640x640 anyway; keep mobile camera quality high.
      kIsWeb ? ResolutionPreset.medium : ResolutionPreset.high,
      enableAudio: false,
    );
    await previousController?.dispose();
    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() => _isCameraInitialized = true);
      }
    } catch (e) {
      _showScanResultModal(
        detectedName: "Camera Error",
        isHardware: false,
        errorMessage: "Error initializing camera stream: $e",
        similarItems: [],
      );
    }
  }
Future<void> _toggleFlash() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;
    try {
      if (_isFlashOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
        setState(() => _isFlashOn = false);
      } else {
        await _cameraController!.setFlashMode(FlashMode.torch);
        setState(() => _isFlashOn = true);
      }
    } catch (e) {
      debugPrint("Failed to toggle flash: $e");
    }
  }


  Widget _buildScanButton() {
    final enabled = _isCameraInitialized;
    return Center(
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(40),
            gradient: const LinearGradient(
              colors: [_lightBlue, _darkBlue],
            ),
            boxShadow: [
              BoxShadow(
                color: _primaryBlue.withValues(alpha: 0.45),
                blurRadius: 20,
                spreadRadius: 1,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(40),
              onTap: enabled
                  ? () {
                      HapticFeedback.mediumImpact();
                      _captureAndAnalyze();
                    }
                  : null,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.scanLine, color: Colors.white, size: 26),
                    SizedBox(width: 12),
                    Text(
                      "SCAN OBJECT",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _liveYoloTimer?.cancel();
    _liveFallbackTimer?.cancel();
    _stabilityTimer?.cancel();
    _radarController.dispose();
    _autoScanController?.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  void _toggleLiveMode() {
    if (_isLiveMode) {
      setState(() => _isLiveMode = false);
      _stopLiveDetection();
    } else {
      setState(() => _isLiveMode = true);
      _startLiveDetection();
    }
  }

  void _startLiveDetection() {
    _liveGeneration++;
    _liveScanStartedAt = DateTime.now();
    _geminiAttemptedForScene = false;
    _strongYoloSeen = false;
    _yoloDeadlineReached = false;
    _currentLiveDetection = null;
    _lastLiveApiBytes = null;
    _liveImageSize = null;
    _lastYoloCandidateName = null;
    _lastYoloCandidateScore = null;
    _liveError = null;
    _yoloSamples = 0;
    _radarController.repeat();
    _stabilityTimer?.cancel();
    _autoScanController?.stop();
    _autoScanController?.reset();
    _isCountingDown = false;

    _liveYoloTimer?.cancel();
    _liveFallbackTimer?.cancel();
    _liveYoloTimer = Timer.periodic(
      _liveYoloInterval, (_) => unawaited(_runLiveYoloTick()),
    );
    _liveFallbackTimer = Timer(_liveYoloWindow, () {
      // Do NOT run Gemini while a YOLO inference is still executing.
      // Wait for its result; it may still be confidently correct.
      _yoloDeadlineReached = true;
      if (!_isLiveYoloRunning) _tryAutomaticGemini();
    });
    setState(() => _liveStatusText = 'Scanning...');
    // Do not wait for the 650ms periodic timer's first tick.
    unawaited(_runLiveYoloTick());
  }

  void _stopLiveDetection() {
    _liveGeneration++;
    // Old HTTP completions are discarded by the generation guard.
    _isGeminiFallbackRunning = false;
    _liveYoloTimer?.cancel();
    _liveYoloTimer = null;
    _liveFallbackTimer?.cancel();
    _liveFallbackTimer = null;
    _stabilityTimer?.cancel();
    _stabilityTimer = null;
    _radarController.stop();
    _radarController.reset();
    _autoScanController?.stop();
    _autoScanController?.reset();
    _isCountingDown = false;
    _geminiAttemptedForScene = false;
    _yoloDeadlineReached = false;
    _currentLiveDetection = null;
    _liveError = null;
    _lastLiveApiBytes = null;
    _liveImageSize = null;
    _lastYoloCandidateName = null;
    _lastYoloCandidateScore = null;
    if (mounted) setState(() => _liveStatusText = 'Point camera at a tool');
  }

  void _resetStabilityState() {
    _lastSignature = null;
    _stableCheckCount = 0;
    _isCountingDown = false;
    _liveStatusText = 'Point camera at a tool';
  }

  // YOLO coordinates are normalized relative to a 640x640 letterboxed image;
  // undo the padding before projecting into the BoxFit.cover camera preview.
  Rect? _modelToFrameBox(Rect box, Map<String, dynamic> preprocessed) {
    const modelSize = 640.0;
    final fittedW = (preprocessed['fittedWidth'] as num).toDouble();
    final fittedH = (preprocessed['fittedHeight'] as num).toDouble();
    if (fittedW <= 0 || fittedH <= 0) return null;
    final padX = ((modelSize - fittedW) / 2).roundToDouble();
    final padY = ((modelSize - fittedH) / 2).roundToDouble();
    final left = ((box.left * modelSize - padX) / fittedW).clamp(0.0, 1.0).toDouble();
    final top = ((box.top * modelSize - padY) / fittedH).clamp(0.0, 1.0).toDouble();
    final right = ((box.right * modelSize - padX) / fittedW).clamp(0.0, 1.0).toDouble();
    final bottom = ((box.bottom * modelSize - padY) / fittedH).clamp(0.0, 1.0).toDouble();
    if (right - left < 0.015 || bottom - top < 0.015) return null;
    if ((right - left) * (bottom - top) > 0.78) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  // A strong YOLO result is final even if the model's box coordinates are
  // malformed. Bounding-box validity affects drawing, not classification.
  // These checks only decide WHEN to give up on local YOLO.
  bool _shouldTryGeminiAfterYolo() {
    if (_yoloSamples >= _targetYoloSamples) return true;
    final start = _liveScanStartedAt;
    final pastDeadline = _yoloDeadlineReached ||
        (start != null && DateTime.now().difference(start) >= _liveYoloWindow);
    return pastDeadline && _yoloSamples >= _minimumYoloSamples;
  }

  void _tryAutomaticGemini() {
    if (!mounted || !_isLiveMode || _strongYoloSeen ||
        _geminiAttemptedForScene || _isGeminiFallbackRunning ||
        _isLiveYoloRunning) return;
    if (!_shouldTryGeminiAfterYolo()) return;

    final basis = _currentLiveDetection;
    final bytes = basis?.snapshotBytes ?? _lastLiveApiBytes;
    if (bytes == null) {
      _liveYoloTimer?.cancel();
      _liveFallbackTimer?.cancel();
      setState(() {
        _liveError = 'Could not obtain a usable camera frame for Gemini.';
        _liveStatusText = 'Camera capture failed';
      });
      return;
    }
    final last = _lastGeminiFallbackAt;
    if (last != null && DateTime.now().difference(last) < _geminiLiveCooldown) {
      _liveYoloTimer?.cancel();
      _liveFallbackTimer?.cancel();
      setState(() {
        _liveError = 'Gemini cooling down to protect the free-tier quota. '
            'YOLO had no confident result; you can scan again or wait.';
        _liveStatusText = 'Gemini cooldown active';
      });
      return;
    }
    debugPrint('[LIVE] YOLO finished $_yoloSamples sample(s) without '
        'a strong classification: Gemini fallback');
    unawaited(_runLiveGeminiFallback(
      apiBytes: bytes,
      weakBox: basis?.box,
      snapshotSize: basis?.snapshotSize ?? _liveImageSize,
      yoloCandidateName: basis?.yoloCandidateName ?? _lastYoloCandidateName,
      yoloCandidateScore: basis?.yoloCandidateScore ?? _lastYoloCandidateScore,
    ));
  }

  Future<void> _verifyWithGemini() async {
    if (!_isLiveMode || _isGeminiFallbackRunning) return;
    final basis = _currentLiveDetection;
    final bytes = basis?.snapshotBytes ?? _lastLiveApiBytes;
    if (bytes == null) {
      setState(() => _liveError = 'No captured frame is available yet.');
      return;
    }
    final last = _lastGeminiFallbackAt;
    if (last != null && DateTime.now().difference(last) < _geminiLiveCooldown) {
      setState(() => _liveError = 'Gemini cooldown: try again in a few seconds.');
      return;
    }
    await _runLiveGeminiFallback(
      apiBytes: bytes,
      weakBox: basis?.box,
      snapshotSize: basis?.snapshotSize ?? _liveImageSize,
      yoloCandidateName: basis?.yoloCandidateName ?? _lastYoloCandidateName,
      yoloCandidateScore: basis?.yoloCandidateScore ?? _lastYoloCandidateScore,
      force: true,
    );
  }

  void _restartLiveDetection() {
    if (!_isLiveMode || _isGeminiFallbackRunning) return;
    _startLiveDetection();
  }

  bool _isCapturing = false;

  /// Every takePicture() call in this file goes through here. The camera
  /// plugin throws CameraException("Previous capture has not returned
  /// yet...") if takePicture() is called again before the last one
  /// finished. Returns null if a capture is already in progress instead
  /// of colliding with it. The stability check no longer uses the
  /// camera hardware at all, so there's no risk of the two colliding.
  Future<XFile?> _safeTakePicture() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return null;
    }
    if (_isCapturing) return null;
    _isCapturing = true;
    try {
      return await _cameraController!.takePicture();
    } finally {
      _isCapturing = false;
    }
  }

  Future<void> _runLiveYoloTick() async {
    if (!_isLiveMode || _isAnalyzing || _isLiveYoloRunning ||
        _isGeminiFallbackRunning || _geminiAttemptedForScene ||
        _strongYoloSeen) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final generation = _liveGeneration;
    _isLiveYoloRunning = true;
    final watch = Stopwatch()..start();
    try {
      final photo = await _safeTakePicture().timeout(
        const Duration(seconds: 4),
      );
      if (photo == null) throw StateError('Camera image unavailable');
      final bytes = await photo.readAsBytes();
      // Allow Gemini to proceed even if preprocessing or YOLO crashes.
      _lastLiveApiBytes = bytes;

      final prepared = await compute(processImageInBackground, {
        'bytes': bytes,
        'cropLeft': 0.0, 'cropTop': 0.0,
        'cropWidth': 1.0, 'cropHeight': 1.0,
        'liveFast': true,
      });
      if (!mounted || !_isLiveMode || generation != _liveGeneration ||
          _isGeminiFallbackRunning) return;

      _lastLiveApiBytes = prepared['apiBytes'] as Uint8List;
      _liveImageSize = Size(
        (prepared['frameWidth'] as num).toDouble(),
        (prepared['frameHeight'] as num).toDouble(),
      );
      final local = await VisionService.processLocalOnly(
        modelInput: prepared['modelInput'] as Float32List,
      );
      if (!mounted || !_isLiveMode || generation != _liveGeneration ||
          _isGeminiFallbackRunning || _geminiAttemptedForScene) return;
      _yoloSamples++;
      debugPrint('[LIVE] YOLO sample $_yoloSamples in ${watch.elapsedMilliseconds}ms: '
          '${local?['item_name'] ?? 'none'} ${local?['confidence'] ?? ''}');

      final isNull = local == null || local['is_null'] == true;
      final confidence = isNull ? 0.0 : (local['confidence'] as num).toDouble();
      Rect? box;
      if (!isNull && local['box'] is Map) {
        final raw = local['box'] as Map;
        box = _modelToFrameBox(Rect.fromLTWH(
          (raw['x'] as num).toDouble(),
          (raw['y'] as num).toDouble(),
          (raw['w'] as num).toDouble(),
          (raw['h'] as num).toDouble(),
        ), prepared);
      }
      final name = isNull ? '' : local['item_name'].toString();
      _lastYoloCandidateName = isNull ? null : name;
      _lastYoloCandidateScore = isNull ? null : confidence;
      if (!isNull && box == null) {
        debugPrint('[LIVE BOX] YOLO returned $name '
            '${(confidence * 100).toStringAsFixed(1)}%, '
            'but its coordinates were unusable. Showing the snapshot without a box.');
      }
      if (!isNull && confidence >= _strongYoloThreshold) {
        // A missing/invalid box must NOT force a high-confidence YOLO
        // classification through Gemini (it only disables the overlay).
        _strongYoloSeen = true;
        _liveYoloTimer?.cancel();
        _liveFallbackTimer?.cancel();
        debugPrint('[LIVE] YOLO ACCEPTED at '
            '${(confidence * 100).toStringAsFixed(1)}% '
            '(usable box: ${box != null}). Gemini NOT called.');
        setState(() {
          _liveError = null;
          _currentLiveDetection = LiveDetection(
            label: name, confidence: confidence, box: box,
            source: LiveDetectionSource.yoloStrong,
            snapshotBytes: prepared['apiBytes'] as Uint8List,
            snapshotSize: _liveImageSize,
            yoloCandidateName: name,
            yoloCandidateScore: confidence,
          );
          _liveStatusText = 'Item found';
        });
        return;
      }

      if (!isNull && confidence >= _weakYoloThreshold) {
        // Between 45% and 70% is only a candidate, not a final result.
        setState(() {
          _liveError = null;
          _currentLiveDetection = LiveDetection(
            label: name, confidence: confidence, box: box,
            source: LiveDetectionSource.yoloWeak,
            snapshotBytes: prepared['apiBytes'] as Uint8List,
            snapshotSize: _liveImageSize,
            yoloCandidateName: name,
            yoloCandidateScore: confidence,
          );
          _liveStatusText = 'Checking item...';
        });
      } else {
        setState(() {
          _currentLiveDetection = null;
          _liveStatusText = 'Scanning...';
        });
      }
      // Gemini is evaluated in finally, only AFTER this inference releases
      // the single-inference guard. No fallback races a running YOLO call.
    } catch (e, st) {
      debugPrint('[LIVE] YOLO / camera failed after ${watch.elapsedMilliseconds}ms: $e\n$st');
      if (mounted && _isLiveMode && generation == _liveGeneration &&
          !_isGeminiFallbackRunning) {
        _yoloSamples++; // A failed attempt also counts toward the limit.
        setState(() {
          _liveError = 'YOLO camera/model error: $e';
          _liveStatusText = 'Scanning...';
        });
      }
    } finally {
      _isLiveYoloRunning = false;
      if (mounted && _isLiveMode && generation == _liveGeneration &&
          !_strongYoloSeen && !_geminiAttemptedForScene &&
          !_isGeminiFallbackRunning && _shouldTryGeminiAfterYolo()) {
        _tryAutomaticGemini();
      }
    }
  }

  Future<void> _runLiveGeminiFallback({
    required Uint8List apiBytes,
    required Rect? weakBox,
    Size? snapshotSize,
    String? yoloCandidateName,
    double? yoloCandidateScore,
    bool force = false,
  }) async {
    if (!mounted || !_isLiveMode || _isGeminiFallbackRunning) return;
    if (!force && (_geminiAttemptedForScene || _strongYoloSeen)) return;
    _geminiAttemptedForScene = true;
    _isGeminiFallbackRunning = true;
    _lastGeminiFallbackAt = DateTime.now();
    _liveFallbackTimer?.cancel();
    _liveYoloTimer?.cancel();
    final generation = _liveGeneration;

    setState(() {
      _liveError = null;
      _liveStatusText = 'Checking item...';
    });
    final watch = Stopwatch()..start();
    try {
      final response = await GeminiService.scanHardwareObjectLive(apiBytes);
      if (!mounted || !_isLiveMode || generation != _liveGeneration) return;
      final cloud = response.data;
      if (cloud == null) {
        setState(() {
          _liveError = response.error ?? 'Gemini returned no result.';
          _liveStatusText = 'Gemini unavailable — ${response.error ?? 'No result'}';
        });
        return;
      }
      final isHardware = cloud['is_hardware'] == true;
      final name = cloud['item_name']?.toString() ?? 'Unknown object';
      final confidence = (cloud['confidence'] as num?)?.toDouble() ?? 0.0;
      debugPrint('[LIVE] Gemini completed in ${watch.elapsedMilliseconds}ms: $name');
      setState(() {
        _liveError = null;
        _currentLiveDetection = LiveDetection(
          label: name, confidence: confidence,
          // These coordinates come from the matching YOLO frame, not Gemini.
          box: isHardware ? weakBox : null,
          source: LiveDetectionSource.geminiFallback,
          isHardware: isHardware,
          snapshotBytes: apiBytes,
          snapshotSize: snapshotSize,
          yoloCandidateName: yoloCandidateName,
          yoloCandidateScore: yoloCandidateScore,
        );
        _liveStatusText = 'Item found';
      });
    } catch (e, st) {
      debugPrint('[LIVE] Gemini crashed: $e\n$st');
      if (mounted && _isLiveMode && generation == _liveGeneration) {
        setState(() {
          _liveError = 'Gemini error: $e';
          _liveStatusText = 'Gemini request failed';
        });
      }
    } finally {
      if (generation == _liveGeneration) {
        _isGeminiFallbackRunning = false;
        if (mounted) setState(() {}); // Immediately update the right panel.
      }
    }
  }

  // --- Lightweight, continuous frame-stability polling ---

  Future<void> _pollStability() async {
    if (!_isLiveMode || _isAnalyzing || _isCheckingStability) return;
    _isCheckingStability = true;
    try {
      final renderObject = _previewBoundaryKey.currentContext
          ?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) return;
      if (renderObject.debugNeedsPaint) return; // not ready this tick

      final uiImage = await renderObject.toImage(pixelRatio: 0.03);
      final byteData = await uiImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      uiImage.dispose();
      if (byteData == null) return;

      final bytes = byteData.buffer.asUint8List();
      final signature = <double>[];
      for (int i = 0; i + 2 < bytes.length; i += 4) {
        signature.add(
          0.299 * bytes[i] + 0.587 * bytes[i + 1] + 0.114 * bytes[i + 2],
        );
      }

      if (!mounted || !_isLiveMode) return;

      final previous = _lastSignature;
      if (previous == null || previous.length != signature.length) {
        setState(() => _liveStatusText = "Hold steady...");
      } else {
        final diff = _signatureDiff(previous, signature);
        if (diff < _motionThreshold) {
          _stableCheckCount++;
        } else {
          _stableCheckCount = 0;
          if (_isCountingDown) {
            _isCountingDown = false;
            _autoScanController?.stop();
            _autoScanController?.reset();
          }
          setState(() => _liveStatusText = "Hold steady...");
        }

        if (_stableCheckCount >= _requiredStableChecks && !_isCountingDown) {
          _isCountingDown = true;
          setState(() => _liveStatusText = "Scanning...");
          _autoScanController?.forward(from: 0);
        }
      }

      _lastSignature = signature;
    } catch (e) {
      // skip this tick
    } finally {
      _isCheckingStability = false;
    }
  }

  double _signatureDiff(List<double> a, List<double> b) {
    double sum = 0;
    final len = math.min(a.length, b.length);
    for (int i = 0; i < len; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return len == 0 ? 0 : sum / len;
  }

  // --- Automatic live-mode scan loop ---

  Future<void> _onAutoScanComplete() async {
    if (!mounted || !_isLiveMode) return;
    _isCountingDown = false;
    _autoScanController?.stop();
    await _captureAndAnalyze();

    _stableCheckCount = 0;
    _lastSignature = null;
    if (mounted && _isLiveMode) {
      setState(() => _liveStatusText = "Point camera at a tool");
      _autoScanController?.reset();
    }
  }

  Future<void> _routeScanResult(
    Map<String, dynamic>? result,
    Uint8List? capturedBytes,
  ) async {
    if (result == null) {
      await _showScanResultModal(
        detectedName: "Scan Error",
        isHardware: false,
        errorMessage: "Failed to parse image result from Gemini.",
        similarItems: [],
        capturedBytes: capturedBytes,
      );
      return;
    }

    final String detectedName = result['item_name'] ?? "Unknown Object";
    final double? confidence = (result['confidence'] as num?)?.toDouble();
    final Map<String, dynamic>? boxData =
        result['box'] as Map<String, dynamic>?;

    if (result['is_hardware'] == true) {
      await _performInventorySearch(
        detectedName,
        capturedBytes: capturedBytes,
        boxData: boxData,
        confidence: confidence,
      );
    } else {
      await _showScanResultModal(
        detectedName: detectedName,
        isHardware: false,
        errorMessage:
            result['error_message'] ??
            "This is a $detectedName, not a hardware tool.",
        similarItems: [],
        capturedBytes: capturedBytes,
        boxData: boxData,
        confidence: confidence,
      );
    }
  }

  Future<void> _performInventorySearch(
    String detectedName, {
    Uint8List? capturedBytes,
    Map<String, dynamic>? boxData,
    double? confidence,
  }) async {
    final String detectedLower = detectedName.toLowerCase().trim();
    final allItems = widget.controller.allItems;

    final exactMatch = allItems
        .where((item) => item.name.toLowerCase().trim() == detectedLower)
        .firstOrNull;

    List<InventoryItem> partialMatches = [];

    if (exactMatch == null) {
      const stopWords = {
        'a',
        'an',
        'the',
        'of',
        'in',
        'and',
        'or',
        'tool',
        'tools',
        'for',
      };
      final keywords = detectedLower
          .split(RegExp(r'\s+'))
          .map((w) => w.replaceAll(RegExp(r'[^\w\s]'), ''))
          .where((w) => w.length > 2 && !stopWords.contains(w))
          .toList();

      if (keywords.isNotEmpty) {
        partialMatches = allItems.where((item) {
          final itemNameLower = item.name.toLowerCase();
          return keywords.any((keyword) => itemNameLower.contains(keyword));
        }).toList();
      }
    }

    await _showScanResultModal(
      detectedName: detectedName,
      isHardware: true,
      exactMatch: exactMatch,
      similarItems: partialMatches,
      capturedBytes: capturedBytes,
      boxData: boxData,
      confidence: confidence,
    );
  }

  // Web scans crop to the visible guide box. Mobile scans retain the full
  // camera frame so tools outside the guide rectangle are not discarded.
  Rect _computeCropRect() {
    if (_isMobilePlatform) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }

    final previewSize = _cameraController?.value.previewSize;
    final screenSize = MediaQuery.of(context).size;
    if (previewSize == null) {
      return const Rect.fromLTWH(0.225, 0.225, 0.55, 0.55);
    }

    final previewW = kIsWeb ? previewSize.width : previewSize.height;
    final previewH = kIsWeb ? previewSize.height : previewSize.width;

    // BoxFit.cover scale: preview is scaled up until it fills the screen
    // in both dimensions, then centered and clipped.
    final scale = math.max(
      screenSize.width / previewW,
      screenSize.height / previewH,
    );

    // Fraction of the raw preview that actually ends up visible on screen
    // after that clipping.
    final visibleFractionX = screenSize.width / (previewW * scale);
    final visibleFractionY = screenSize.height / (previewH * scale);

    // The guide box is _alignBoxFactor of the *visible* (on-screen) area,
    // so as a fraction of the full raw photo it's smaller by that
    // visible fraction.
    final rawFractionW = _alignBoxFactor * visibleFractionX;
    final rawFractionH = _alignBoxFactor * visibleFractionY;

    return Rect.fromLTWH(
      (1 - rawFractionW) / 2,
      (1 - rawFractionH) / 2,
      rawFractionW,
      rawFractionH,
    );
  }

  // Inside _VisualSearchPageState in visual_search_page.dart

  Future<void> _captureAndAnalyze() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_isAnalyzing) return;

    _stabilityTimer?.cancel();
    _stabilityTimer = null;
    _isCountingDown = false;
    _autoScanController?.stop();

    final logger = ScanLogger();
    logger.log('START (button pressed)');

    // 1. Show UI analyzing state immediately
    setState(() => _isAnalyzing = true);
    if (!_isLiveMode) _radarController.repeat();

    // 2. Allow two frames to render so the overlay and spinner start animating smoothly
    await Future.delayed(const Duration(milliseconds: 100));

    Map<String, dynamic>? result;
    String? errorText;
    Uint8List? capturedImageBytes;

    try {
      final XFile? photo = await _safeTakePicture();
      if (photo == null) throw Exception("Camera was busy, please try again.");

      // Yield control so spinner repaints right after camera hardware finishes capture
      await Future.delayed(const Duration(milliseconds: 16));

      final bytes = await photo.readAsBytes();
      final cropRect = _computeCropRect();

      // 3. Process image in isolate
      final backgroundResult = await compute(processImageInBackground, {
        'bytes': bytes,
        'cropLeft': cropRect.left,
        'cropTop': cropRect.top,
        'cropWidth': cropRect.width,
        'cropHeight': cropRect.height,
      });

      capturedImageBytes = backgroundResult['apiBytes'] as Uint8List;
      // Yield UI frame before entering inference
      await Future.delayed(const Duration(milliseconds: 16));

      // 4. Run inference
      result = await VisionService.processHardwareScan(
        modelInput: backgroundResult['modelInput'] as Float32List,
        apiBytes: backgroundResult['apiBytes'] as Uint8List,
        histogram: backgroundResult['histogram'] as List<double>,
        logger: logger,
      );
    } catch (e) {
      errorText = e.toString();
      logger.log('ERROR -> $e');
      logger.log('END (source: error)');
    } finally {
      if (!_isLiveMode) {
        _radarController.stop();
        _radarController.reset();
      }
      if (mounted) setState(() => _isAnalyzing = false);
    }

    if (!mounted) return;
    if (errorText != null) {
      await _showScanResultModal(
        detectedName: "Connection Error",
        isHardware: false,
        errorMessage: errorText,
        similarItems: [],
        capturedBytes: capturedImageBytes,
      );
    } else {
      await _routeScanResult(result, capturedImageBytes);
    }
  }

  Widget _buildFullScreenCameraPreview() {
    if (_cameraController == null) return const SizedBox();
    final previewSize = _cameraController!.value.previewSize;
    if (previewSize == null) return const SizedBox();

    final double previewWidth = kIsWeb ? previewSize.width : previewSize.height;
    final double previewHeight = kIsWeb
        ? previewSize.height
        : previewSize.width;

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewWidth,
          height: previewHeight,
          child: CameraPreview(_cameraController!),
        ),
      ),
    );
  }

  Widget _buildItemImage(String imageUrl) {
    if (imageUrl.isEmpty) {
      return Container(
        color: const Color(0xFF334155),
        child: const Icon(LucideIcons.imageOff, color: Colors.grey, size: 24),
      );
    }
    // Use network rendering here so this file remains Web-compatible.
    // Product images uploaded through Supabase already use public URLs.
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: const Color(0xFF334155),
        child: const Icon(LucideIcons.imageOff, color: Colors.grey, size: 24),
      ),
    );
  }

  // UI-only feedback for live scanning. This reuses the existing radar
  // animation controller and does not request any additional camera frames.
  Widget _buildAnimatedLiveStatus() {
    final bool isChecking = _isGeminiFallbackRunning ||
        _currentLiveDetection?.source == LiveDetectionSource.yoloWeak;
    final bool isActive = _liveError == null &&
        (isChecking || _currentLiveDetection == null);
    final String action = isChecking ? 'Checking item' : 'Scanning';

    return AnimatedBuilder(
      animation: _radarController,
      builder: (context, _) {
        final int dotCount = 1 + (_radarController.value * 3).floor().clamp(0, 2);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isActive) ...[
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF93C5FD),
                    backgroundColor: Colors.white12,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                isActive ? action : _liveStatusText,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              if (isActive)
                SizedBox(
                  width: 19, // Keeps the pill from shifting as dots animate.
                  child: Text(
                    '.' * dotCount,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAnalyzingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.transparent,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
            decoration: BoxDecoration(
              color: const Color(0xE61E293B),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _primaryBlue.withValues(alpha: 0.4)),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                    color: _primaryBlue,
                    backgroundColor: Colors.white12,
                    strokeWidth: 4, // Thinner stroke for a lighter feel
                  ),
                ),
                SizedBox(height: 20),
                Text(
                  "Analyzing tool...",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  "Processing image data...",
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  

  Future<void> _showScanResultModal({
    required String detectedName,
    required bool isHardware,
    String? errorMessage,
    InventoryItem? exactMatch,
    required List<InventoryItem> similarItems,
    Uint8List? capturedBytes,
    Map<String, dynamic>? boxData,
    double? confidence,
  }) {
    final bool isExactMatch = exactMatch != null;
    final bool hasSimilar = similarItems.isNotEmpty;

    Color bannerColor;
    String bannerTitle;
    IconData bannerIcon;
    String descriptionText;

    if (!isHardware) {
      bannerColor = Colors.redAccent;
      bannerTitle = "NOT HARDWARE RELATED";
      bannerIcon = LucideIcons.shieldAlert;
      descriptionText = errorMessage ?? "Not recognized as a hardware tool.";
    } else if (isExactMatch) {
      bannerColor = Colors.green;
      bannerTitle = "EXACT MATCH FOUND";
      bannerIcon = LucideIcons.checkCircle2;
      descriptionText = "Found a match in your inventory.";
    } else if (hasSimilar) {
      bannerColor = _primaryBlue;
      bannerTitle = "SIMILAR ITEMS IN STOCK";
      bannerIcon = LucideIcons.searchCode;
      descriptionText = "We found similar items in stock:";
    } else {
      bannerColor = Colors.orangeAccent;
      bannerTitle = "NOT IN INVENTORY";
      bannerIcon = LucideIcons.packageX;
      descriptionText =
          "Detected '$detectedName', but there are no matches in your database.";
    }

    return showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF1E293B),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Full-Width Top Status Banner
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                color: bannerColor.withOpacity(0.18),
                child: Row(
                  children: [
                    Icon(bannerIcon, color: bannerColor, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        bannerTitle,
                        style: TextStyle(
                          color: bannerColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 2. Main Content Split
              Flexible(
                // Replaced Expanded with Flexible
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 500;

                    // Captured Image with Bounding Box Overlay
                    final imageWidget = capturedBytes != null
                        ? Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: BoundingBoxOverlay(
                              imageBytes: capturedBytes,
                              boxData: boxData,
                              label: detectedName,
                              confidence: confidence,
                            ),
                          )
                        : Container(
                            height: 200,
                            color: const Color(0xFF0F172A),
                            child: const Center(
                              child: Icon(
                                LucideIcons.imageOff,
                                color: Colors.white24,
                                size: 40,
                              ),
                            ),
                          );

                    // Details Panel
                    final detailsWidget = Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min, // Hugs the content tightly
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  detectedName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              if (confidence != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF2563EB,
                                    ).withOpacity(0.2),
                                    border: Border.all(
                                      color: const Color(0xFF2563EB),
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    "${(confidence * 100).toStringAsFixed(1)}%",
                                    style: const TextStyle(
                                      color: Color(0xFF60A5FA),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            descriptionText,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Item List
                          Flexible(
                            // Allows list to shrink if empty or small
                            child: (isHardware && (isExactMatch || hasSimilar))
                                ? ListView.separated(
                                    shrinkWrap:
                                        true, // Eliminates empty space below list items
                                    itemCount: isExactMatch
                                        ? 1
                                        : similarItems.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (context, index) {
                                      final item = isExactMatch
                                          ? exactMatch
                                          : similarItems[index];
                                      return Material(
                                        color: const Color(0xFF0F172A),
                                        borderRadius: BorderRadius.circular(8),
                                        child: InkWell(
                                          onTap: () {
                                            Navigator.pop(dialogContext);
                                            widget.onSelectItem(item);
                                          },
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Row(
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  child: SizedBox(
                                                    width: 42,
                                                    height: 42,
                                                    child: _buildItemImage(
                                                      item.imageUrl,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        item.name,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          fontSize: 13,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        "₱${item.price.toStringAsFixed(2)}  •  Stock: ${item.quantity.toInt()}",
                                                        style: const TextStyle(
                                                          color: Color(
                                                            0xFF60A5FA,
                                                          ),
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const Icon(
                                                  LucideIcons.chevronRight,
                                                  color: Colors.white24,
                                                  size: 18,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  )
                                : Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F172A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      "No matching stock items available.",
                                      style: TextStyle(
                                        color: Colors.white38,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    );

                    return isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment
                                .start, // Prevents stretching children vertically
                            children: [
                              SizedBox(width: 240, child: imageWidget),
                              Expanded(child: detailsWidget),
                            ],
                          )
                        : SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(height: 200, child: imageWidget),
                                detailsWidget,
                              ],
                            ),
                          );
                  },
                ),
              ),
              // 3. Action Buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text("Scan Again"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          _cameraController?.dispose();
                          _cameraController = null;
                          if (mounted) Navigator.pop(context);
                        },
                        child: const Text("Done"),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Simplified live result. The final model's confidence is shown ONCE,
  // without exposing model names or secondary predictions to shop staff.
  // Inference decisions and API usage are unchanged.
  Widget _buildLiveInventoryPanel(LiveDetection detection) {
    final isPending = detection.source == LiveDetectionSource.yoloWeak ||
        _isGeminiFallbackRunning;
    final normalized = detection.label.toLowerCase().trim();
    final inventory = widget.controller.allItems;
    final exact = inventory
        .where((item) => item.name.toLowerCase().trim() == normalized)
        .firstOrNull;
    final stopWords = {'a', 'an', 'the', 'and', 'tool', 'tools'};
    final terms = normalized.split(RegExp(r'\s+'))
        .where((word) => word.length > 2 && !stopWords.contains(word))
        .toList();
    final similar = inventory.where((item) =>
        exact?.id != item.id &&
        (item.name.toLowerCase().contains(normalized) ||
            terms.any((word) => item.name.toLowerCase().contains(word))))
        .take(3).toList();
    final choices = exact == null ? similar : [exact];

    final Color statusColor;
    final IconData statusIcon;
    final String statusText;
    if (isPending) {
      statusColor = Colors.amberAccent;
      statusIcon = LucideIcons.scanLine;
      statusText = 'Checking item...';
    } else if (!detection.isHardware) {
      statusColor = Colors.redAccent;
      statusIcon = LucideIcons.shieldAlert;
      statusText = 'Not a hardware item';
    } else if (exact != null) {
      statusColor = const Color(0xFF6EE7B7);
      statusIcon = LucideIcons.checkCircle2;
      statusText = 'Found in inventory';
    } else if (similar.isNotEmpty) {
      statusColor = const Color(0xFF93C5FD);
      statusIcon = LucideIcons.searchCode;
      statusText = 'Possible matches';
    } else {
      statusColor = Colors.orangeAccent;
      statusIcon = LucideIcons.packageX;
      statusText = 'Not in inventory';
    }

    final rawScore = detection.confidence;
    final score = rawScore.isFinite ? rawScore.clamp(0.0, 1.0) : 0.0;
    final scoreLabel = '${(score * 100).toStringAsFixed(1)}%';
    final previewItem = exact ?? (similar.isNotEmpty ? similar.first : null);
    final Widget thumbnail;
    if (previewItem != null && previewItem.imageUrl.isNotEmpty) {
      thumbnail = _buildItemImage(previewItem.imageUrl);
    } else if (detection.snapshotBytes != null) {
      thumbnail = Image.memory(
        detection.snapshotBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      thumbnail = const Icon(LucideIcons.package, color: Colors.white54, size: 28);
    }

    return Material(
      elevation: 10,
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: statusColor.withValues(alpha: 0.16),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(children: [
                  Icon(statusIcon, color: statusColor, size: 17),
                  const SizedBox(width: 7),
                  Expanded(child: Text(statusText,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: statusColor, fontSize: 12,
                        fontWeight: FontWeight.w800))),
                  PopupMenuButton<String>(
                    tooltip: 'More options',
                    enabled: !_isGeminiFallbackRunning,
                    icon: const Icon(Icons.more_horiz, size: 19,
                        color: Colors.white70),
                    padding: EdgeInsets.zero,
                    onSelected: (choice) {
                      if (choice == 'photo') {
                        _showLiveScanPhoto(detection);
                      } else if (choice == 'check') {
                        _verifyWithGemini();
                      }
                    },
                    itemBuilder: (_) => [
                      if (detection.snapshotBytes != null)
                        const PopupMenuItem<String>(
                            value: 'photo', child: Text('View scan photo')),
                      if (!isPending)
                        const PopupMenuItem<String>(
                            value: 'check', child: Text('Check result')),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Close result',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18,
                        color: Colors.white70),
                    onPressed: () => setState(() {
                      _currentLiveDetection = null;
                      _geminiAttemptedForScene = true;
                      _liveYoloTimer?.cancel();
                      _liveFallbackTimer?.cancel();
                    }),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: SizedBox(width: 72, height: 72,
                            child: ColoredBox(
                              color: const Color(0xFF0F172A),
                              child: thumbnail,
                            )),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(detection.label,
                            maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white,
                              fontWeight: FontWeight.w800, fontSize: 16)),
                          const SizedBox(height: 6),
                          // Only ONE score is displayed: the final result's score.
                          if (!isPending)
                            Tooltip(
                              message: 'AI confidence estimate; not a guarantee.',
                              child: Text('Confidence: $scoreLabel',
                                style: const TextStyle(color: Color(0xFF93C5FD),
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                            )
                          else
                            const Text('Checking...', style: TextStyle(
                                color: Colors.white70, fontSize: 12)),
                          if (exact != null && !isPending) ...[
                            const SizedBox(height: 5),
                            Text('₱${exact.price.toStringAsFixed(2)}',
                              style: const TextStyle(color: Color(0xFF93C5FD),
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                            Text('${exact.quantity.toInt()} in stock',
                              style: const TextStyle(color: Colors.white70,
                                  fontSize: 11)),
                          ],
                        ],
                      )),
                    ]),
                    if (_isGeminiFallbackRunning) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(minHeight: 3),
                    ],
                    if (_liveError != null) ...[
                      const SizedBox(height: 8),
                      Text(_liveError!, style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 11)),
                    ],
                    if (!isPending && detection.isHardware && exact != null) ...[
                      const SizedBox(height: 14),
                      SizedBox(width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => widget.onSelectItem(exact),
                          icon: const Icon(LucideIcons.shoppingCart, size: 18),
                          label: const Text('Add to cart'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryBlue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9)),
                          ),
                        ),
                      ),
                    ] else if (!isPending && detection.isHardware && similar.isNotEmpty) ...[
                      const SizedBox(height: 13),
                      const Text('Choose an item', style: TextStyle(
                          color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 6),
                      ...choices.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            onTap: () => widget.onSelectItem(item),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 9, vertical: 9),
                              child: Row(children: [
                                Expanded(child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.name,
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white,
                                          fontSize: 11, fontWeight: FontWeight.bold)),
                                    Text('₱${item.price.toStringAsFixed(2)} · '
                                        '${item.quantity.toInt()} in stock',
                                      style: const TextStyle(
                                          color: Colors.white60, fontSize: 10)),
                                  ],
                                )),
                                const SizedBox(width: 5),
                                const Icon(Icons.add_circle_outline,
                                    color: Color(0xFF93C5FD), size: 19),
                              ]),
                            ),
                          ),
                        ),
                      )),
                    ] else if (!isPending) ...[
                      const SizedBox(height: 10),
                      Text(
                        detection.isHardware
                            ? 'This item is not in your inventory.'
                            : 'No hardware item found.',
                        style: const TextStyle(color: Colors.white70,
                            fontSize: 12),
                      ),
                    ],
                    if (!isPending) ...[
                      const SizedBox(height: 4),
                      Center(child: TextButton.icon(
                        onPressed: _restartLiveDetection,
                        icon: const Icon(LucideIcons.scanLine, size: 15),
                        label: const Text('Scan another item'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white70,
                          textStyle: const TextStyle(fontSize: 12)),
                      )),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Scan-photo verification is optional, so it doesn't crowd the cart action.
  void _showLiveScanPhoto(LiveDetection detection) {
    if (detection.snapshotBytes == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF1E293B),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Expanded(child: Text('Scan photo', style: TextStyle(
                    color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.bold))),
                IconButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close, color: Colors.white70),
                ),
              ]),
              LiveCapturedFramePreview(
                imageBytes: detection.snapshotBytes,
                imageSize: detection.snapshotSize,
                box: detection.box,
                label: detection.label,
                confidence: detection.source == LiveDetectionSource.yoloStrong
                    ? detection.confidence : detection.yoloCandidateScore,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveFallbackPanel() {
    return Card(
      elevation: 8,
      color: const Color(0xF21E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Colors.white24)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('LIVE SCAN', style: TextStyle(
            color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (_isGeminiFallbackRunning) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('YOLO did not find a confident match.\n'
              'Gemini is checking one frame (bounded request).',
              style: TextStyle(color: Colors.white70)),
          ] else ...[
            const Icon(Icons.error_outline, size: 25, color: Colors.orangeAccent),
            const SizedBox(height: 8),
            Text(_liveError ?? 'The scan could not be completed.',
              style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _restartLiveDetection,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Scan again'),
            ),
            if (_lastLiveApiBytes != null)
              OutlinedButton.icon(
                onPressed: _verifyWithGemini,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Retry Gemini'),
              ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Stack(
        children: [
          Positioned.fill(
            child: _isCameraInitialized
                ? Stack(
                    children: [
                      RepaintBoundary(
                        key: _previewBoundaryKey,
                        child: _buildFullScreenCameraPreview(),
                      ),


                      if (_isLiveMode && _isCountingDown)
                        Center(
                          child: AnimatedBuilder(
                            animation: _autoScanController!,
                            builder: (context, child) {
                              return SizedBox(
                                width: 100,
                                height: 100,
                                child: CircularProgressIndicator(
                                  value: _autoScanController!.value,
                                  strokeWidth: 4,
                                  color: _primaryBlue,
                                  backgroundColor: Colors.white24,
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  )
                : const Center(
                    child: CircularProgressIndicator(color: _primaryBlue),
                  ),
          ),
          // The web guide box is the crop boundary. On mobile it is only
          // a framing aid because the complete camera frame is analyzed.
          if (!_isLiveMode)
            Positioned.fill(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final boxW = size.width * _boxWFactor;
        final boxH = size.height * _boxHFactor;
        final box = Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: boxW,
          height: boxH,
        );
        return Stack(
          children: [
            if (!kIsWeb)
                        ClipPath(
                          clipper: OutsideBoxClipper(box),
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                            child: Container(color: Colors.transparent),
                          ),
                        ),
                      CustomPaint(painter: ScanFramePainter(box), size: size),
            Positioned(
              left: box.left,
              width: box.width,
              top: box.bottom - 48,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: _primaryBlue.withValues(alpha: 0.6)),
                  ),
                  child: Text(
                    _isMobilePlatform
                        ? "Keep the whole tool in view"
                        : "ALIGN TOOL HERE",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  ),
    if (_isAnalyzing) _buildAnalyzingOverlay(),
    if (_isLiveMode && (_currentLiveDetection != null ||
        _isGeminiFallbackRunning || _liveError != null))
      Positioned(
        right: 12,
        top: 112,
        bottom: 94,
        width: math.min(318.0, MediaQuery.sizeOf(context).width *
            (MediaQuery.sizeOf(context).width > 700 ? 0.34 : 0.82)),
        child: Align(
          alignment: Alignment.topRight,
          child: _currentLiveDetection != null
              ? _buildLiveInventoryPanel(_currentLiveDetection!)
              : _buildLiveFallbackPanel(),
        ),
      ),
          Positioned(
            top: 40,
            left: 16,
            right: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Back Button
                IconButton(
                  icon: const Icon(
                    LucideIcons.chevronLeft,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),

                // Disclaimer Banner
                Expanded(
                  child: Center(
                    // <-- Added Center widget here to shrink-wrap the container
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal:
                              16, // slightly wider inner padding for a nice pill shape
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _primaryBlue.withOpacity(0.85),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                        child: const Text(
                          "The AI requires a well-lit background. Factors like low light, blur, and cluttered backgrounds can impact scan results.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Camera Controls
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 1. Highlighted Action Button (Web & Mobile)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        // Green to encourage Live mode, muted white24 to go back to Manual
                        backgroundColor: _isLiveMode
                            ? Colors.white24
                            : Colors.green.shade600,
                        foregroundColor: Colors.white,
                        elevation: _isLiveMode ? 0 : 4,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 26, // Increased horizontal padding
                          vertical:
                              16, // Increased vertical padding for a taller button
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            30,
                          ), // Smoother pill shape
                        ),
                      ),
                      icon: Icon(
                        // Radar icon when offering Live, Camera icon when offering Manual
                        _isLiveMode ? LucideIcons.camera : LucideIcons.radar,
                        size: 22, // Increased icon size
                      ),
                      label: Text(
                        _isLiveMode ? "MANUAL" : "LIVE",
                        style: const TextStyle(
                          fontSize: 15, // Increased font size
                          fontWeight:
                              FontWeight.w900, // Extra bold for dominance
                          letterSpacing: 1.2,
                        ),
                      ),
                      onPressed: _isAnalyzing ? null : _toggleLiveMode,
                    ),

                    // 2. Hardware Controls (Mobile Only)
                    if (!kIsWeb) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          _isFlashOn
                              ? LucideIcons.flashlightOff
                              : LucideIcons.flashlight,
                          color: Colors.white,
                          size: 24,
                        ),
                        onPressed: _toggleFlash,
                      ),
                      IconButton(
                        icon: const Icon(
                          LucideIcons.switchCamera,
                          color: Colors.white,
                          size: 24,
                        ),
                        onPressed: () async {
                          if (_cameras == null || _cameras!.length < 2) return;
                          _selectedCameraIndex =
                              (_selectedCameraIndex + 1) % _cameras!.length;
                          setState(() {
                            _isCameraInitialized = false;
                            _isFlashOn =
                                false; // Reset flash state when swapping lenses
                          });
                          await _setCamera(_selectedCameraIndex);
                        },
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: _isAnalyzing
                ? const SizedBox.shrink() // the overlay below handles this state
                : (_isLiveMode
                      ? (_currentLiveDetection != null &&
                                  _currentLiveDetection!.source !=
                                      LiveDetectionSource.yoloWeak &&
                                  !_isGeminiFallbackRunning
                              ? const SizedBox.shrink()
                              : Center(child: _buildAnimatedLiveStatus()))
                      : _buildScanButton()),
          ),
        ],
      ),
    );
  }
}

class ScanFramePainter extends CustomPainter {
  final Rect box;
  ScanFramePainter(this.box);

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(box, const Radius.circular(16));

    // Full-screen rect + box rect with even-odd fill = dim everywhere
    // EXCEPT inside the box (the box stays 100% untouched).
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(rrect);
    canvas.drawPath(dim, Paint()..color = Colors.black.withOpacity(0.6));

    // Thin border
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _primaryBlue.withValues(alpha: 0.6),
    );

    // Bold corner brackets
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = _primaryBlue;
    const len = 28.0;
    final l = box.left, t = box.top, r = box.right, b = box.bottom;
    canvas.drawPath(
      Path()
        ..moveTo(l, t + len)
        ..lineTo(l, t)
        ..lineTo(l + len, t),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(r - len, t)
        ..lineTo(r, t)
        ..lineTo(r, t + len),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(l, b - len)
        ..lineTo(l, b)
        ..lineTo(l + len, b),
      p,
    );
    canvas.drawPath(
      Path()
        ..moveTo(r - len, b)
        ..lineTo(r, b)
        ..lineTo(r, b - len),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant ScanFramePainter old) => old.box != box;
}

Map<String, dynamic> processImageInBackground(Map<String, dynamic> params) {
  final decoded = img.decodeImage(params['bytes'] as Uint8List)!;

  final cropped = img.copyCrop(
    decoded,
    x: (decoded.width * (params['cropLeft'] as double)).round(),
    y: (decoded.height * (params['cropTop'] as double)).round(),
    width: (decoded.width * (params['cropWidth'] as double)).round(),
    height: (decoded.height * (params['cropHeight'] as double)).round(),
  );

  // One resize to fit 640x640. Everything below derives from this.
  final ratio = math.min(640 / cropped.width, 640 / cropped.height);
  final fitted = img.copyResize(
    cropped,
    width: math.max(1, (cropped.width * ratio).round()),
    height: math.max(1, (cropped.height * ratio).round()),
  );

  // Manual scan uses a histogram cache; live YOLO does not use the cache.
  final fastLive = params['liveFast'] == true;
  final small = fastLive ? null : img.copyResize(fitted, width: 32, height: 32);
  final bins = List<double>.filled(192, 0.0);
  if (small != null) {
    final ringCounts = List<int>.filled(3, 0);
    final cx = small.width / 2;
    final cy = small.height / 2;
    final maxRadius = math.sqrt(cx * cx + cy * cy);
    for (int y = 0; y < small.height; y++) {
      for (int x = 0; x < small.width; x++) {
        final p = small.getPixel(x, y);
        final r = (p.r / 64).floor().clamp(0, 3);
        final g = (p.g / 64).floor().clamp(0, 3);
        final b = (p.b / 64).floor().clamp(0, 3);
        final colorIndex = (r << 4) | (g << 2) | b;
        final dx = x - cx;
        final dy = y - cy;
        final nr = math.sqrt(dx * dx + dy * dy) / maxRadius;
        final ring = nr < 0.33 ? 0 : (nr < 0.66 ? 1 : 2);
        bins[ring * 64 + colorIndex]++;
        ringCounts[ring]++;
      }
    }
    for (int ring = 0; ring < 3; ring++) {
      if (ringCounts[ring] == 0) continue;
      for (int c = 0; c < 64; c++) {
        bins[ring * 64 + c] /= ringCounts[ring];
      }
    }
  }

  // Gemini image, derived from the already-small image.
  final apiBytes = img.encodeJpg(_resizeToMaxEdge(fitted, 400), quality: 60);

  return {
    'histogram': bins,
    'modelInput': _toModelInput(fitted),
    'apiBytes': Uint8List.fromList(apiBytes),
    'frameWidth': cropped.width,
    'frameHeight': cropped.height,
    'fittedWidth': fitted.width,
    'fittedHeight': fitted.height,
  };
}

/// Letterbox (gray 114 padding) + NCHW float tensor, built off the UI thread.
Float32List _toModelInput(img.Image src) {
  const size = 640;
  const plane = size * size;
  final input = Float32List(3 * plane)..fillRange(0, 3 * plane, 114 / 255.0);

  final padX = ((size - src.width) / 2).round();
  final padY = ((size - src.height) / 2).round();

  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final pos = (y + padY) * size + (x + padX);
      input[pos] = p.r / 255.0;
      input[plane + pos] = p.g / 255.0;
      input[2 * plane + pos] = p.b / 255.0;
    }
  }
  return input;
}

img.Image _resizeToMaxEdge(img.Image source, int maxEdge) {
  final longestEdge = math.max(source.width, source.height);
  if (longestEdge <= maxEdge) return source;

  final scale = maxEdge / longestEdge;
  return img.copyResize(
    source,
    width: math.max(1, (source.width * scale).round()),
    height: math.max(1, (source.height * scale).round()),
  );
}

class OutsideBoxClipper extends CustomClipper<Path> {
  final Rect box;
  OutsideBoxClipper(this.box);

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRRect(RRect.fromRectAndRadius(box, const Radius.circular(16)));

  @override
  bool shouldReclip(covariant OutsideBoxClipper old) => old.box != box;
}
class ScanLinePainter extends CustomPainter {
  final double progress;
  final bool vertical;
  ScanLinePainter(this.progress, {this.vertical = false});

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    if (vertical) {
      _paintHorizontalSweep(canvas, size);
    } else {
      _paintVerticalSweep(canvas, size);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.06)
      ..strokeWidth = 1;
    const gridSpacing = 40.0;
    for (double gx = 0; gx < size.width; gx += gridSpacing) {
      canvas.drawLine(Offset(gx, 0), Offset(gx, size.height), gridPaint);
    }
    for (double gy = 0; gy < size.height; gy += gridSpacing) {
      canvas.drawLine(Offset(0, gy), Offset(size.width, gy), gridPaint);
    }
  }

  void _paintVerticalSweep(Canvas canvas, Size size) {
    final x = progress * size.width;
    const trailWidth = 140.0;
    final trailLeft = (x - trailWidth).clamp(0.0, size.width);
    final trailRect = Rect.fromLTRB(trailLeft, 0, x, size.height);
    final trailPaint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.transparent, Colors.greenAccent.withOpacity(0.22)],
      ).createShader(trailRect);
    canvas.drawRect(trailRect, trailPaint);

    final glowPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.45)
      ..strokeWidth = 10
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), glowPaint);

    final linePaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
  }

  void _paintHorizontalSweep(Canvas canvas, Size size) {
    final y = progress * size.height;
    const trailHeight = 140.0;
    final trailTop = (y - trailHeight).clamp(0.0, size.height);
    final trailRect = Rect.fromLTRB(0, trailTop, size.width, y);
    final trailPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.greenAccent.withOpacity(0.22)],
      ).createShader(trailRect);
    canvas.drawRect(trailRect, trailPaint);

    final glowPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.45)
      ..strokeWidth = 10
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), glowPaint);

    final linePaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }

  @override
  bool shouldRepaint(covariant ScanLinePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.vertical != vertical;
}


enum LiveDetectionSource {
  yoloStrong,
  yoloWeak,
  geminiFallback,
}

class LiveDetection {
  final String label;
  final double confidence;
  final Rect? box;
  final LiveDetectionSource source;
  final bool isHardware;
  final Uint8List? snapshotBytes;
  final Size? snapshotSize;
  final String? yoloCandidateName;
  final double? yoloCandidateScore;

  const LiveDetection({
    required this.label,
    required this.confidence,
    required this.source,
    this.box,
    this.isHardware = true,
    this.snapshotBytes,
    this.snapshotSize,
    this.yoloCandidateName,
    this.yoloCandidateScore,
  });
}

class LiveDetectionPainter extends CustomPainter {
  final LiveDetection detection;
  final Size frameSize;

  LiveDetectionPainter(this.detection, {required this.frameSize});

  @override
  void paint(Canvas canvas, Size size) {
    final box = detection.box;
    if (box == null) {
      _drawCenterCard(canvas, size);
      return;
    }

    // CameraPreview is displayed using BoxFit.cover, so a normalized
    // image-space box needs that same scale AND the centered crop offset.
    final scale = math.max(size.width / frameSize.width,
        size.height / frameSize.height);
    final cropX = (frameSize.width * scale - size.width) / 2;
    final cropY = (frameSize.height * scale - size.height) / 2;
    final rect = Rect.fromLTWH(
      box.left * frameSize.width * scale - cropX,
      box.top * frameSize.height * scale - cropY,
      box.width * frameSize.width * scale,
      box.height * frameSize.height * scale,
    ).intersect(Offset.zero & size);
    if (rect.isEmpty) return;

    final isWeak = detection.source == LiveDetectionSource.yoloWeak;
    final isGemini = detection.source == LiveDetectionSource.geminiFallback;

    final color = isGemini
        ? Colors.orangeAccent
        : isWeak
            ? Colors.yellowAccent
            : Colors.greenAccent;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isWeak ? 2.0 : 3.5
      ..color = color;

    if (isWeak || isGemini) {
      _drawDashedRect(canvas, rect, paint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paint,
      );
    }

    final sourceText = isGemini
        ? "Gemini fallback"
        : isWeak
            ? "Checking..."
            : "YOLO";

    final label =
        "${detection.label} ${(detection.confidence * 100).toStringAsFixed(1)}% · $sourceText";

    _drawLabel(canvas, size, rect, label, color);
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint) {
    const dashWidth = 10.0;
    const dashSpace = 6.0;

    void drawDashedLine(Offset start, Offset end) {
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance == 0) return;
      final unitX = dx / distance;
      final unitY = dy / distance;

      for (double current = 0; current < distance; current += dashWidth + dashSpace) {
        final next = math.min(current + dashWidth, distance);
        canvas.drawLine(
          Offset(start.dx + unitX * current, start.dy + unitY * current),
          Offset(start.dx + unitX * next, start.dy + unitY * next),
          paint,
        );
      }
    }

    drawDashedLine(rect.topLeft, rect.topRight);
    drawDashedLine(rect.topRight, rect.bottomRight);
    drawDashedLine(rect.bottomRight, rect.bottomLeft);
    drawDashedLine(rect.bottomLeft, rect.topLeft);
  }

  void _drawLabel(Canvas canvas, Size size, Rect rect, String text, Color color) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 260);

    final tagTop = rect.top - 28 < 0 ? rect.top + 4 : rect.top - 28;
    final tagLeft = rect.left.clamp(0.0, math.max(0.0, size.width - textPainter.width - 14)).toDouble();
    final tagRect = Rect.fromLTWH(
      tagLeft,
      tagTop,
      textPainter.width + 14,
      24,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(tagRect, const Radius.circular(6)),
      Paint()..color = color.withOpacity(0.85),
    );

    textPainter.paint(canvas, Offset(tagRect.left + 7, tagRect.top + 4));
  }

  void _drawCenterCard(Canvas canvas, Size size) {
    final textSpan = TextSpan(
      text: "${detection.label}\nGemini fallback",
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.bold,
        height: 1.3,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 220);

    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: textPainter.width + 32,
      height: textPainter.height + 24,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(14)),
      Paint()..color = Colors.black.withOpacity(0.72),
    );

    textPainter.paint(canvas, Offset(rect.left + 16, rect.top + 12));
  }

  @override
  bool shouldRepaint(covariant LiveDetectionPainter oldDelegate) {
    return oldDelegate.detection != detection;
  }
}

// The manual and live preview share the same capture-and-box visual idea,
// but here the overlay is constrained to the *actual letterboxed photo rect*.
// The normalised box came from YOLO and is only shown if validated.
class LiveCapturedFramePreview extends StatelessWidget {
  final Uint8List? imageBytes;
  final Size? imageSize;
  final Rect? box;
  final String label;
  final double? confidence;

  const LiveCapturedFramePreview({
    super.key,
    required this.imageBytes,
    required this.imageSize,
    required this.box,
    required this.label,
    required this.confidence,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 144,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageBytes == null
          ? const Center(child: Icon(LucideIcons.imageOff,
                color: Colors.white24, size: 30))
          : Stack(children: [
              Positioned.fill(child: Image.memory(
                imageBytes!, fit: BoxFit.contain, gaplessPlayback: true)),
              if (box != null && imageSize != null &&
                  imageSize!.width > 0 && imageSize!.height > 0)
                Positioned.fill(child: IgnorePointer(child: CustomPaint(
                  painter: _LiveSnapshotBoxPainter(
                    box: box!, frameSize: imageSize!, label: label,
                    confidence: confidence,
                  ),
                ))),
            ]),
    );
  }
}

class _LiveSnapshotBoxPainter extends CustomPainter {
  final Rect box;
  final Size frameSize;
  final String label;
  final double? confidence;

  const _LiveSnapshotBoxPainter({
    required this.box,
    required this.frameSize,
    required this.label,
    this.confidence,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Align the bounding coordinates with Image.memory's BoxFit.contain.
    final fit = applyBoxFit(BoxFit.contain, frameSize, size);
    final imageRect = Alignment.center.inscribe(
      fit.destination, Offset.zero & size);
    final rect = Rect.fromLTRB(
      imageRect.left + box.left * imageRect.width,
      imageRect.top + box.top * imageRect.height,
      imageRect.left + box.right * imageRect.width,
      imageRect.top + box.bottom * imageRect.height,
    ).intersect(imageRect);
    if (rect.isEmpty) return;

    final stroke = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(RRect.fromRectAndRadius(
      rect, const Radius.circular(4)), stroke);
    final scoreText = confidence == null
        ? ''
        : ' ${(confidence! * 100).toStringAsFixed(1)}%';
    final tag = '$label$scoreText · YOLO box';
    final painter = TextPainter(
      text: TextSpan(text: tag, style: const TextStyle(
        color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(40.0, size.width - 16));
    final tagX = rect.left.clamp(0.0,
        math.max(0.0, size.width - painter.width - 10)).toDouble();
    final tagY = rect.top >= 21 ? rect.top - 19 : rect.top + 2;
    final labelBg = Rect.fromLTWH(tagX, tagY,
        painter.width + 10, painter.height + 4);
    canvas.drawRRect(RRect.fromRectAndRadius(labelBg,
        const Radius.circular(3)), Paint()..color = const Color(0xD9000000));
    painter.paint(canvas, Offset(tagX + 5, tagY + 2));
  }

  @override
  bool shouldRepaint(covariant _LiveSnapshotBoxPainter old) =>
      old.box != box || old.frameSize != frameSize ||
      old.label != label || old.confidence != confidence;
}

class BoundingBoxOverlay extends StatelessWidget {
  final Uint8List imageBytes;
  final Map<String, dynamic>? boxData;
  final String label;
  final double? confidence;

  const BoundingBoxOverlay({
    super.key,
    required this.imageBytes,
    this.boxData,
    required this.label,
    this.confidence,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            imageBytes,
            fit: BoxFit.contain, // Prevents cutting off the edges of the tool
          ),
        ),
        if (boxData != null)
          Positioned.fill(
            child: CustomPaint(
              painter: BoxPainter(
                box: boxData!,
                label: label,
                confidence: confidence,
              ),
            ),
          ),
      ],
    );
  }
}

class BoxPainter extends CustomPainter {
  final Map<String, dynamic> box;
  final String label;
  final double? confidence;

  BoxPainter({required this.box, required this.label, this.confidence});

  @override
  void paint(Canvas canvas, Size size) {
    final double left = (box['x'] as num).toDouble() * size.width;
    final double top = (box['y'] as num).toDouble() * size.height;
    final double width = (box['w'] as num).toDouble() * size.width;
    final double height = (box['h'] as num).toDouble() * size.height;

    final rect = Rect.fromLTWH(left, top, width, height);

    // Draw Box
    final paint = Paint()
      ..color = const Color(0xFF2563EB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      paint,
    );

    // Build Label String
    final confString = confidence != null
        ? " ${(confidence! * 100).toStringAsFixed(1)}%"
        : "";
    final textSpan = TextSpan(
      text: "$label$confString",
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    // Draw Tag Background
    final tagBg = Paint()..color = const Color(0xFF2563EB);
    final tagRect = Rect.fromLTWH(
      left,
      (top - 22 < 0) ? top : top - 22,
      textPainter.width + 12,
      22,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(tagRect, const Radius.circular(4)),
      tagBg,
    );

    textPainter.paint(
      canvas,
      Offset(left + 6, (top - 22 < 0) ? top + 3 : top - 19),
    );
  }

  @override
  bool shouldRepaint(covariant BoxPainter oldDelegate) => true;
}
