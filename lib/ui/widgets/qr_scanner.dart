import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../services/app_error_mapper.dart';
import '../../services/app_logger.dart';
import 'app_toast.dart';
import 'camera_footer.dart';
import 'qr_web_torch_stub.dart'
    if (dart.library.html) 'qr_web_torch_web.dart'
    as web_torch;

const _scannerOrange = Color(0xFFC83D08);
const _scannerOrangeBright = Color(0xFFEA580C);

class QRScanner extends StatefulWidget {
  final Function(String) onScan;
  final bool isScanning;

  const QRScanner({super.key, required this.onScan, required this.isScanning});

  @override
  State<QRScanner> createState() => _QRScannerState();
}

class _QRScannerState extends State<QRScanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _hasScanned = false;
  bool _isWebTorchOn = false;
  String? _candidateCode;
  DateTime? _candidateSince;
  DateTime? _lastCandidateSeen;
  static const _confirmationTime = Duration(milliseconds: 600);
  static const _maxDetectionGap = Duration(milliseconds: 1200);
  MobileScannerErrorCode? _lastLoggedError;
  final MobileScannerController _scannerController = MobileScannerController();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(_controller);

    if (widget.isScanning) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(QRScanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning && !oldWidget.isScanning) {
      _hasScanned = false;
      _candidateCode = null;
      _candidateSince = null;
      _lastCandidateSeen = null;
      _controller.repeat(reverse: true);
    } else if (!widget.isScanning) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _toggleFlashlight() async {
    try {
      if (kIsWeb) {
        await web_torch.setQrWebTorch(!_isWebTorchOn);
        if (mounted) setState(() => _isWebTorchOn = !_isWebTorchOn);
      } else {
        if (_scannerController.value.torchState == TorchState.unavailable) {
          throw UnsupportedError('This camera has no flashlight.');
        }
        await _scannerController.toggleTorch();
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Scanner flashlight failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(context, 'Flashlight is unavailable on this device.');
      }
    }
  }

  Future<void> _flipCamera() async {
    try {
      if (kIsWeb && mounted) setState(() => _isWebTorchOn = false);
      _candidateCode = null;
      _candidateSince = null;
      _lastCandidateSeen = null;
      await _scannerController.switchCamera();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Scanner camera flip failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) AppToast.error(context, 'Could not switch camera.');
    }
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_hasScanned) return;
    final now = DateTime.now();
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim();
      if (code == null || code.isEmpty) continue;
      if (_candidateCode != code ||
          _lastCandidateSeen == null ||
          now.difference(_lastCandidateSeen!) > _maxDetectionGap) {
        _candidateCode = code;
        _candidateSince = now;
      }
      _lastCandidateSeen = now;
      if (now.difference(_candidateSince!) >= _confirmationTime) {
        _hasScanned = true;
        widget.onScan(code);
      }
      break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
          if (widget.isScanning)
            MobileScanner(
              controller: _scannerController,
              fit: BoxFit.cover,
              scanWindow: Rect.fromCenter(
                center: MediaQuery.sizeOf(context).center(Offset.zero),
                width: 250,
                height: 250,
              ),
              errorBuilder: (context, error, child) {
                if (_lastLoggedError != error.errorCode) {
                  _lastLoggedError = error.errorCode;
                  AppLogger.error('Scanner camera failed', error: error);
                }
                final permissionDenied =
                    error.errorCode == MobileScannerErrorCode.permissionDenied;
                return ColoredBox(
                  color: const Color(0xFF0F172A),
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 360),
                      margin: const EdgeInsets.all(24),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.no_photography_outlined,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            permissionDenied
                                ? AppErrorMapper.scannerCameraPermission
                                : AppErrorMapper.cameraUnavailable,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              onDetect: _handleDetection,
            )
          else
            Container(color: Colors.black),

          _buildScannerOverlay(),

          _buildDecorativeElements(),

          if (widget.isScanning)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 24,
              child: ValueListenableBuilder<MobileScannerState>(
                valueListenable: _scannerController,
                builder: (context, state, _) {
                  final isOn = kIsWeb
                      ? _isWebTorchOn
                      : state.torchState == TorchState.on;
                  return CameraFooter(
                    leading: IconButton.filled(
                      tooltip: isOn
                          ? 'Turn flashlight off'
                          : 'Turn flashlight on',
                      onPressed: state.isInitialized ? _toggleFlashlight : null,
                      style: IconButton.styleFrom(
                        backgroundColor: isOn
                            ? _scannerOrangeBright
                            : _scannerOrange,
                        foregroundColor: Colors.white,
                        fixedSize: const Size(52, 52),
                      ),
                      icon: Icon(
                        isOn ? Icons.flashlight_on : Icons.flashlight_off,
                      ),
                    ),
                    center: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Scan QR',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            shadows: [Shadow(blurRadius: 10)],
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Hold code steady',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            shadows: [Shadow(blurRadius: 10)],
                          ),
                        ),
                      ],
                    ),
                    trailing: IconButton.filled(
                      tooltip: 'Flip camera',
                      onPressed:
                          state.isInitialized &&
                              (state.availableCameras == null ||
                                  state.availableCameras! > 1)
                          ? _flipCamera
                          : null,
                      style: IconButton.styleFrom(
                        backgroundColor: _scannerOrange,
                        foregroundColor: Colors.white,
                        fixedSize: const Size(52, 52),
                      ),
                      icon: const Icon(Icons.cameraswitch_outlined),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScannerOverlay() {
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Colors.black.withValues(alpha: 0.5),
        BlendMode.srcOut,
      ),
      child: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              color: Colors.black,
              backgroundBlendMode: BlendMode.dstOut,
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Container(
              height: 250,
              width: 250,
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDecorativeElements() {
    return Center(
      child: SizedBox(
        width: 250,
        height: 250,
        child: Stack(
          children: [
            _buildCorner(top: 0, left: 0, isTop: true, isLeft: true),
            _buildCorner(top: 0, right: 0, isTop: true, isLeft: false),
            _buildCorner(bottom: 0, left: 0, isTop: false, isLeft: true),
            _buildCorner(bottom: 0, right: 0, isTop: false, isLeft: false),

            if (widget.isScanning)
              AnimatedBuilder(
                animation: _animation,
                builder: (context, child) {
                  return Positioned(
                    top: _animation.value * 250,
                    left: 0,
                    right: 0,
                    child: _buildLaserLine(),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLaserLine() {
    return Container(
      height: 2,
      decoration: BoxDecoration(
        color: _scannerOrangeBright,
        boxShadow: [
          BoxShadow(
            color: _scannerOrangeBright.withValues(alpha: 0.6),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildCorner({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required bool isTop,
    required bool isLeft,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          border: Border(
            top: isTop
                ? const BorderSide(color: _scannerOrangeBright, width: 4)
                : BorderSide.none,
            bottom: !isTop
                ? const BorderSide(color: _scannerOrangeBright, width: 4)
                : BorderSide.none,
            left: isLeft
                ? const BorderSide(color: _scannerOrangeBright, width: 4)
                : BorderSide.none,
            right: !isLeft
                ? const BorderSide(color: _scannerOrangeBright, width: 4)
                : BorderSide.none,
          ),
          borderRadius: BorderRadius.only(
            topLeft: isTop && isLeft ? const Radius.circular(8) : Radius.zero,
            topRight: isTop && !isLeft ? const Radius.circular(8) : Radius.zero,
            bottomLeft: !isTop && isLeft
                ? const Radius.circular(8)
                : Radius.zero,
            bottomRight: !isTop && !isLeft
                ? const Radius.circular(8)
                : Radius.zero,
          ),
        ),
      ),
    );
  }
}
