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


  // --- YOLO-first live mode ---
  // Live mode uses cheap, throttled YOLO-only snapshots for bounding boxes.
  // Gemini is called only after repeated weak local detections.
  Timer? _liveYoloTimer;
  bool _isLiveYoloRunning = false;
  bool _isGeminiFallbackRunning = false;
  LiveDetection? _currentLiveDetection;
  DateTime? _lastGeminiFallbackAt;
  String? _lastWeakLabel;
  Rect? _lastWeakBox;
  int _weakStableCount = 0;
  int _noYoloStableCount = 0;
  static const int _requiredNoYoloTicksForGemini = 4; 

  static const Duration _liveYoloInterval = Duration(milliseconds: 700);
  static const Duration _geminiLiveCooldown = Duration(seconds: 20);
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
      ResolutionPreset.high,
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
    _radarController.repeat();
    _resetStabilityState();

    _currentLiveDetection = null;
    _weakStableCount = 0;
    _noYoloStableCount = 0;
    _lastWeakLabel = null;
    _lastWeakBox = null;

    _liveYoloTimer?.cancel();
    _liveYoloTimer = Timer.periodic(
      _liveYoloInterval,
      (_) => _runLiveYoloTick(),
    );

    setState(() {
      _liveStatusText = "Scanning live...";
    });
  }

  void _stopLiveDetection() {
    _radarController.stop();
    _radarController.reset();

    _liveYoloTimer?.cancel();
    _liveYoloTimer = null;

    _stabilityTimer?.cancel();
    _stabilityTimer = null;

    _isCountingDown = false;
    _autoScanController?.stop();
    _autoScanController?.reset();

    _currentLiveDetection = null;
    _weakStableCount = 0;
    _noYoloStableCount = 0;
    _lastWeakLabel = null;
    _lastWeakBox = null;

    if (mounted) {
      setState(() {
        _liveStatusText = "Point camera at a tool";
      });
    }
  }

  void _resetStabilityState() {
    _lastSignature = null;
    _stableCheckCount = 0;
    _isCountingDown = false;
    _liveStatusText = "Point camera at a tool";
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
    if (!_isLiveMode) return;
    if (_isAnalyzing || _isLiveYoloRunning) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    _isLiveYoloRunning = true;

    try {
      final XFile? photo = await _safeTakePicture();
      if (photo == null) return;

      final bytes = await photo.readAsBytes();
      final cropRect = _computeCropRect();

      final backgroundResult = await compute(processImageInBackground, {
        'bytes': bytes,
        'cropLeft': cropRect.left,
        'cropTop': cropRect.top,
        'cropWidth': cropRect.width,
        'cropHeight': cropRect.height,
      });

      final local = await VisionService.processLocalOnly(
        modelInput: backgroundResult['modelInput'] as Float32List,
      );

      if (!mounted || !_isLiveMode) return;

      if (local == null || local['is_null'] == true) {
        _weakStableCount = 0;
        _lastWeakLabel = null;
        _lastWeakBox = null;

        _noYoloStableCount++;

        setState(() {
          _currentLiveDetection = null;
          _liveStatusText = _noYoloStableCount >= 2
              ? "Checking with AI soon..."
              : "Hold steady / improve lighting";
        });

        if (_noYoloStableCount >= _requiredNoYoloTicksForGemini) {
          await _runLiveGeminiFallback(
            apiBytes: backgroundResult['apiBytes'] as Uint8List,
            weakBox: null,
          );

          _noYoloStableCount = 0;
        }

        return;
      }

      final confidence = (local['confidence'] as num).toDouble();
      final label = local['item_name']?.toString() ?? "Unknown Object";
      final boxData = local['box'] as Map<String, dynamic>;
      final box = Rect.fromLTWH(
        (boxData['x'] as num).toDouble(),
        (boxData['y'] as num).toDouble(),
        (boxData['w'] as num).toDouble(),
        (boxData['h'] as num).toDouble(),
      );

      if (confidence >= _strongYoloThreshold) {
        _weakStableCount = 0;
        _lastWeakLabel = null;
        _lastWeakBox = null;
        _noYoloStableCount = 0;

        setState(() {
          _currentLiveDetection = LiveDetection(
            label: label,
            confidence: confidence,
            box: box,
            source: LiveDetectionSource.yoloStrong,
          );
          _liveStatusText =
              "$label ${(confidence * 100).toStringAsFixed(1)}%";
        });
        return;
      }

      if (confidence >= _weakYoloThreshold) {
        _noYoloStableCount = 0;
        _handleWeakLiveDetection(
          label: label,
          confidence: confidence,
          box: box,
          apiBytes: backgroundResult['apiBytes'] as Uint8List,
        );
        return;
      }

      _weakStableCount = 0;
      _lastWeakLabel = null;
      _lastWeakBox = null;

      _noYoloStableCount++;

      setState(() {
        _currentLiveDetection = null;
        _liveStatusText = _noYoloStableCount >= 2
            ? "Checking with AI soon..."
            : "Hold steady / improve lighting";
      });

      if (_noYoloStableCount >= _requiredNoYoloTicksForGemini) {
        await _runLiveGeminiFallback(
          apiBytes: backgroundResult['apiBytes'] as Uint8List,
          weakBox: null,
        );

        _noYoloStableCount = 0;
      }
    } catch (e) {
      debugPrint("Live YOLO tick failed: $e");
    } finally {
      _isLiveYoloRunning = false;
    }
  }

  void _handleWeakLiveDetection({
    required String label,
    required double confidence,
    required Rect box,
    required Uint8List apiBytes,
  }) {
    final sameLabel = _lastWeakLabel == label;
    final sameBox = _lastWeakBox != null && _boxDiff(_lastWeakBox!, box) < 0.08;

    if (sameLabel && sameBox) {
      _weakStableCount++;
    } else {
      _weakStableCount = 1;
      _lastWeakLabel = label;
      _lastWeakBox = box;
    }

    setState(() {
      _currentLiveDetection = LiveDetection(
        label: label,
        confidence: confidence,
        box: box,
        source: LiveDetectionSource.yoloWeak,
      );
      _liveStatusText = "Checking $label...";
    });

    if (_weakStableCount >= 3) {
      _runLiveGeminiFallback(apiBytes: apiBytes, weakBox: box);
    }
  }

  double _boxDiff(Rect a, Rect b) {
    return (a.left - b.left).abs() +
        (a.top - b.top).abs() +
        (a.width - b.width).abs() +
        (a.height - b.height).abs();
  }

  Future<void> _runLiveGeminiFallback({
    required Uint8List apiBytes,
    required Rect? weakBox,
  }) async {
    if (_isGeminiFallbackRunning) return;

    final now = DateTime.now();
    if (_lastGeminiFallbackAt != null &&
        now.difference(_lastGeminiFallbackAt!) < _geminiLiveCooldown) {
      return;
    }

    _isGeminiFallbackRunning = true;
    _lastGeminiFallbackAt = now;

    try {
      if (mounted && _isLiveMode) {
        setState(() => _liveStatusText = "Confirming with AI...");
      }

      final cloud = await GeminiService.scanHardwareObject(apiBytes);
      if (!mounted || !_isLiveMode) return;

      if (cloud == null) {
        setState(() => _liveStatusText = "AI confirmation failed");
        return;
      }

      final isHardware = cloud['is_hardware'] == true;
      final label = cloud['item_name']?.toString() ?? "Unknown Object";
      final confidence = (cloud['confidence'] as num?)?.toDouble() ?? 0.0;

      if (isHardware) {
        setState(() {
          _currentLiveDetection = LiveDetection(
            label: label,
            confidence: confidence,
            box: weakBox,
            source: LiveDetectionSource.geminiFallback,
          );
          _liveStatusText = "$label confirmed by AI";
        });
      } else {
        setState(() {
          _currentLiveDetection = null;
          _liveStatusText = "Not a hardware tool";
        });
      }
    } catch (e) {
      debugPrint("Live Gemini fallback failed: $e");
    } finally {
      _isGeminiFallbackRunning = false;
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

                      if (_isLiveMode && _currentLiveDetection != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: LiveDetectionPainter(
                                _currentLiveDetection!,
                              ),
                            ),
                          ),
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
                      ? Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _liveStatusText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
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

  // Spatial histogram for the cache (same logic as before).
  final small = img.copyResize(fitted, width: 32, height: 32);
  final bins = List<double>.filled(192, 0.0);
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

  // Gemini image, derived from the already-small image.
  final apiBytes = img.encodeJpg(_resizeToMaxEdge(fitted, 400), quality: 60);

  return {
    'histogram': bins,
    'modelInput': _toModelInput(fitted),
    'apiBytes': apiBytes,
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

  const LiveDetection({
    required this.label,
    required this.confidence,
    required this.source,
    this.box,
  });
}

class LiveDetectionPainter extends CustomPainter {
  final LiveDetection detection;

  LiveDetectionPainter(this.detection);

  @override
  void paint(Canvas canvas, Size size) {
    final box = detection.box;
    if (box == null) {
      _drawCenterCard(canvas, size);
      return;
    }

    final rect = Rect.fromLTWH(
      box.left * size.width,
      box.top * size.height,
      box.width * size.width,
      box.height * size.height,
    );

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
