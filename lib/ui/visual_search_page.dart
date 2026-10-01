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
import 'package:flutter/foundation.dart' show kDebugMode;

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
  static const double _alignBoxFactor = 0.55;

  // Mobile guide box: a portrait RECTANGLE, not a square. Hand tools
  // (hammers, wrenches, pliers) are elongated, and a phone is usually
  // held closer to the object than a webcam is — a square box either
  // clips long tools or forces an awkward diagonal hold. Width is wider
  // than height's counterpart on web because phone screens are already
  // narrow; height is shorter than width to fit a tool held vertically
  // without requiring the user to back into a wall.
  static const double _mobileCropWidth = 0.75;
  static const double _mobileCropHeight = 0.55;

  String _liveStatusText = "Point camera at a tool";

  // In-Memory Cache
  //
  // NOTE ON THE THRESHOLD BELOW: each ring's 64 bins are normalized to
  // sum to 1, so the maximum possible total difference across 3 rings
  // is 6.0 (completely different images). The previous threshold of
  // 0.12 effectively required a near pixel-identical frame — ordinary
  // camera noise, auto-exposure micro-adjustments, or a slightly
  // different hand angle will usually exceed that, which is why every
  // scan was a cache miss. 0.45 is a starting point, not a verified
  // value — watch the debug console (prints the actual diff for the
  // closest cached match on every scan) and tune this up/down based on
  // real numbers from your camera and lighting.

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
      debugPrint('[stability check] skipped: $e');
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

  // Computes the crop region in RAW PHOTO fractions (0.0-1.0), so it
  // matches whatever the user actually sees inside the on-screen guide
  // box on each platform — see the box widget in build() below, which
  // uses these same _mobileCropWidth/_mobileCropHeight /
  // _alignBoxFactor constants so the two never drift out of sync.
  Rect _computeCropRect() {
    if (_isMobilePlatform) {
      // Portrait rectangle, not a square — see constant comments above.
      const w = _mobileCropWidth;
      const h = _mobileCropHeight;
      return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
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

  Future<void> _captureAndAnalyze() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_isAnalyzing) return;

    setState(() {
      _isAnalyzing = true;
    });

    await Future.delayed(const Duration(milliseconds: 50));

    try {
      // 1. Capture the photo
      final XFile? photo = await _safeTakePicture();
      if (photo == null) throw Exception("Camera was busy, please try again.");

      final bytes = await photo.readAsBytes();

      // 2. Compute the real crop region (matches on-screen guide box on
      // BOTH platforms now) BEFORE handing off to the isolate.
      final cropRect = _computeCropRect();

      // 3. Process the image
      final backgroundResult = await compute(processImageInBackground, {
        'bytes': bytes,
        'cropLeft': cropRect.left,
        'cropTop': cropRect.top,
        'cropWidth': cropRect.width,
        'cropHeight': cropRect.height,
      });

      final currentHistogram = backgroundResult['histogram'] as List<double>;
      final localBytes = backgroundResult['localBytes'] as Uint8List;
      final apiBytes = backgroundResult['apiBytes'] as Uint8List;

      // 4. Run the hybrid architecture
      final result = await VisionService.processHardwareScan(
        rawBytes: bytes,
        localBytes: localBytes,
        apiBytes: apiBytes,
        histogram: currentHistogram,
      );

      await _routeScanResult(result);
    } catch (e) {
      await _showScanResultModal(
        detectedName: "Connection Error",
        isHardware: false,
        errorMessage: e.toString(),
        similarItems: [],
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
        });
      }
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
      bannerColor = Colors.orange;
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
                          hoverColor: Colors.white.withOpacity(0.05),
                          splashColor: Colors.orange.withOpacity(0.3),
                          highlightColor: Colors.orange.withOpacity(0.1),
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
                                              color: Colors.orange,
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
                                                  ? Colors.green.withOpacity(
                                                      0.2,
                                                    )
                                                  : Colors.red.withOpacity(0.2),
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
                                  color: Colors.orange,
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
                          backgroundColor: Colors.orange,
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
                      if (_isLiveMode)
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
                                  color: Colors.orange,
                                  backgroundColor: Colors.white24,
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  )
                : const Center(
                    child: CircularProgressIndicator(color: Colors.orange),
                  ),
          ),
          // Guide box: shown on BOTH web and mobile now (previously
          // web-only). Web keeps its square box; mobile gets a portrait
          // rectangle sized for elongated hand tools. Box dimensions
          // here MUST match _computeCropRect()'s fractions above, or
          // what the user sees framed won't be what actually gets sent
          // to the model.
          if (!_isLiveMode)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.35),
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: _isMobilePlatform
                        ? _mobileCropWidth
                        : _alignBoxFactor,
                    heightFactor: _isMobilePlatform
                        ? _mobileCropHeight
                        : _alignBoxFactor,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Colors.orange.withOpacity(0.8),
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(
                            _isMobilePlatform
                                ? "Fit tool inside box — step back if needed"
                                : "Align Tool Here",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
                    if (kDebugMode)
                      IconButton(
                        icon: const Icon(LucideIcons.bug, color: Colors.white),
                        onPressed: () {
                          final img = TfliteService.lastDebugImage;
                          if (img == null) return;
                          showDialog(
                            context: context,
                            builder: (_) => Dialog(
                              child: InteractiveViewer(
                                child: Image.memory(img),
                              ),
                            ),
                          );
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
                ? Column(
                    children: const [
                      CircularProgressIndicator(color: Colors.orange),
                      SizedBox(height: 16),
                      Text(
                        "Analyzing tool...",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  )
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
                      : Center(
                          child: ElevatedButton.icon(
                            onPressed: _isCameraInitialized
                                ? _captureAndAnalyze
                                : null,
                            icon: const Icon(LucideIcons.scanLine),
                            label: const Text("Scan Object"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                          ),
                        )),
          ),
        ],
      ),
    );
  }
}

// --- Scan-line sweep. `vertical: true` sweeps top-to-bottom (a
// horizontal line) — used on phones. `vertical: false` (default) sweeps
// left-to-right (a vertical line) — used on web/desktop. ---
class ScanLinePainter extends CustomPainter {
  final double progress; // 0.0 -> 1.0, loops via AnimationController.repeat()
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

  // Sweeps a vertical line left -> right.
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

  // Sweeps a horizontal line top -> bottom.
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
  bool shouldRepaint(covariant ScanLinePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.vertical != vertical;
  }
}

// --- Background image processing for the capture+analyze flow ---
Map<String, dynamic> processImageInBackground(Map<String, dynamic> params) {
  final bytes = params['bytes'] as Uint8List;
  final originalImage = img.decodeImage(bytes)!;

  final cropLeft = params['cropLeft'] as double;
  final cropTop = params['cropTop'] as double;
  final cropWidthFrac = params['cropWidth'] as double;
  final cropHeightFrac = params['cropHeight'] as double;

  final cropX = (originalImage.width * cropLeft).round();
  final cropY = (originalImage.height * cropTop).round();
  final cropWidth = (originalImage.width * cropWidthFrac).round();
  final cropHeight = (originalImage.height * cropHeightFrac).round();

  img.Image croppedImage = img.copyCrop(
    originalImage,
    x: cropX,
    y: cropY,
    width: cropWidth,
    height: cropHeight,
  );

  // Generate Spatial Histogram for Caching (unchanged logic, just reads
  // from croppedImage as before)
  final small = img.copyResize(croppedImage, width: 32, height: 32);
  final List<double> bins = List.filled(192, 0.0);
  final List<int> ringCounts = List.filled(3, 0);

  final cx = small.width / 2;
  final cy = small.height / 2;
  final maxRadius = math.sqrt(cx * cx + cy * cy);

  for (int y = 0; y < small.height; y++) {
    for (int x = 0; x < small.width; x++) {
      final p = small.getPixel(x, y);
      int r = (p.r / 64).floor().clamp(0, 3);
      int g = (p.g / 64).floor().clamp(0, 3);
      int b = (p.b / 64).floor().clamp(0, 3);
      int colorIndex = (r << 4) | (g << 2) | b;

      final dx = x - cx;
      final dy = y - cy;
      final normalizedRadius = math.sqrt(dx * dx + dy * dy) / maxRadius;
      final ring = normalizedRadius < 0.33
          ? 0
          : (normalizedRadius < 0.66 ? 1 : 2);

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

  // --- Local model: keep near the model's native 640px input and use
  // higher JPEG quality, so _letterbox() isn't upsampling a blurry,
  // heavily-compressed image. ---
  img.Image forLocal = croppedImage;
  if (forLocal.width > 640) {
    forLocal = img.copyResize(forLocal, width: 640);
  }
  final localBytes = img.encodeJpg(forLocal, quality: 90);

  // --- Gemini: small + more compressed, since it only needs enough
  // detail to name the object, not feed a tensor. ---
  img.Image forApi = croppedImage;
  if (forApi.width > 400) {
    forApi = img.copyResize(forApi, width: 400);
  }
  final apiBytes = img.encodeJpg(forApi, quality: 60);

  return {'histogram': bins, 'localBytes': localBytes, 'apiBytes': apiBytes};
}
