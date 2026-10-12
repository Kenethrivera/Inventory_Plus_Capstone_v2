import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:camera/camera.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:image/image.dart' as img;
import '../../data/inventory.dart';
import '../../logic/inventory_controller.dart';
import '../../logic/vision_service.dart';
import '../../logic/tflite_service.dart';
import '../../logic/scan_logger.dart';
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

  // Phones get a top-to-bottom scan line; everything else (web/desktop)
  // keeps the left-to-right sweep. kIsWeb is checked first because
  // Platform.isAndroid/isIOS throws on web.
  bool get _isMobilePlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

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
    _stabilityTimer?.cancel();
    _radarController.dispose();
    _autoScanController?.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  void _toggleLiveMode() {
    setState(() {
      _isLiveMode = !_isLiveMode;
      if (_isLiveMode) {
        _radarController.repeat();
        _resetStabilityState();
        _stabilityTimer?.cancel();
        _stabilityTimer = Timer.periodic(
          _stabilityPollInterval,
          (_) => _pollStability(),
        );
      } else {
        _radarController.stop();
        _stabilityTimer?.cancel();
        _stabilityTimer = null;
        _isCountingDown = false;
        _autoScanController?.stop();
        _autoScanController?.reset();
      }
    });
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

  Future<void> _routeScanResult(Map<String, dynamic>? result) async {
    if (result == null) {
      await _showScanResultModal(
        detectedName: "Scan Error",
        isHardware: false,
        errorMessage: "Failed to parse image result from Gemini.",
        similarItems: [],
      );
      return;
    }

    final String detectedName = result['item_name'] ?? "Unknown Object";

    if (result['is_hardware'] == true) {
      await _performInventorySearch(detectedName);
    } else {
      await _showScanResultModal(
        detectedName: detectedName,
        isHardware: false,
        errorMessage: "This is a $detectedName, not a hardware tool.",
        similarItems: [],
      );
    }
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
      );
    } else {
      await _routeScanResult(result);
    }
  }
  

  Future<void> _performInventorySearch(String detectedName) async {
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
    );
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
    if (kIsWeb || imageUrl.startsWith('http')) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: const Color(0xFF334155),
          child: const Icon(LucideIcons.imageOff, color: Colors.grey, size: 24),
        ),
      );
    } else {
      return Image.file(
        File(imageUrl),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: const Color(0xFF334155),
          child: const Icon(LucideIcons.imageOff, color: Colors.grey, size: 24),
        ),
      );
    }
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
                  width: 72,
                  height: 72,
                  child: CircularProgressIndicator(
                    color: _primaryBlue,
                    backgroundColor: Colors.white12,
                    strokeWidth: 6,
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
                  "Hold still for a moment",
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
      descriptionText =
          errorMessage ??
          "The scanned object is not recognized as a hardware tool.";
    } else if (isExactMatch) {
      bannerColor = Colors.green;
      bannerTitle = "EXACT MATCH FOUND";
      bannerIcon = LucideIcons.checkCircle2;
      descriptionText =
          "We found a perfect match for '$detectedName' in your inventory.";
    } else if (hasSimilar) {
      bannerColor = _primaryBlue;
      bannerTitle = "SIMILAR ITEMS IN STOCK";
      bannerIcon = LucideIcons.searchCode;
      descriptionText =
          "We don't have exactly '$detectedName', but we have these similar items:";
    } else {
      bannerColor = Colors.redAccent;
      bannerTitle = "NOT IN INVENTORY";
      bannerIcon = LucideIcons.packageX;
      descriptionText =
          "We detected a '$detectedName', but there are no matches in your database.";
    }

    return showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF1E293B),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 650),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                color: bannerColor.withOpacity(0.15),
                child: Row(
                  children: [
                    Icon(bannerIcon, color: bannerColor, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        bannerTitle,
                        style: TextStyle(
                          color: bannerColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
                child: Text(
                  descriptionText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
              if (isHardware && (isExactMatch || hasSimilar))
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    itemCount: isExactMatch ? 1 : similarItems.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final item = isExactMatch
                          ? exactMatch
                          : similarItems[index];
                      return Material(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(dialogContext);
                            widget.onSelectItem(item);
                          },
                          hoverColor: Colors.white.withValues(alpha: 0.05),
                          splashColor: _primaryBlue.withValues(alpha: 0.3),
                          highlightColor: _primaryBlue.withValues(alpha: 0.1),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 60,
                                    height: 60,
                                    child: _buildItemImage(item.imageUrl),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Text(
                                            "₱${item.price.toStringAsFixed(2)}",
                                            style: const TextStyle(
                                              color: Color(0xFF60A5FA),
                                              fontWeight: FontWeight.w900,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: item.quantity > 0
                                                  ? Colors.green.withValues(
                                                      alpha: 0.2,
                                                    )
                                                  : Colors.red.withValues(alpha: 0.2),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              "Stock: ${item.quantity.toInt()} ${item.unit}",
                                              style: TextStyle(
                                                color: item.quantity > 0
                                                    ? Colors.greenAccent
                                                    : Colors.redAccent,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(
                                  LucideIcons.plusCircle,
                                  color: _primaryBlue,
                                  size: 24,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
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
                          if (mounted) {
                            Navigator.pop(context);
                          }
                        },
                        child: const Text("Done Scanning"),
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
                      if (_isLiveMode || _isAnalyzing)
                        AnimatedBuilder(
                          animation: _radarController,
                          builder: (context, child) {
                            return CustomPaint(
                              painter: ScanLinePainter(
                                _radarController.value,
                                vertical: _isMobilePlatform,
                              ),
                              size: Size.infinite,
                            );
                          },
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(
                    LucideIcons.chevronLeft,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isLiveMode ? LucideIcons.scanLine : LucideIcons.radar,
                        color: Colors.white,
                      ),
                      onPressed: _isAnalyzing ? null : _toggleLiveMode,
                    ),
                    IconButton(
                      icon: const Icon(
                        LucideIcons.switchCamera,
                        color: Colors.white,
                      ),
                      onPressed: () async {
                        if (_cameras == null || _cameras!.length < 2) return;
                        _selectedCameraIndex =
                            (_selectedCameraIndex + 1) % _cameras!.length;
                        setState(() {
                          _isCameraInitialized = false;
                        });
                        await _setCamera(_selectedCameraIndex);
                      },
                    ),
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
