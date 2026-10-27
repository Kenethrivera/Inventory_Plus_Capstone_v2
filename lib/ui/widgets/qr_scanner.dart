import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../services/app_error_mapper.dart';
import '../../services/app_logger.dart';

class QRScanner extends StatefulWidget {
  final Function(String) onScan;
  final bool isScanning;

  const QRScanner({
    super.key,
    required this.onScan,
    required this.isScanning,
  });

  @override
  State<QRScanner> createState() => _QRScannerState();
}

class _QRScannerState extends State<QRScanner> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _hasScanned = false;
  MobileScannerErrorCode? _lastLoggedError;

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
      _controller.repeat(reverse: true);
    } else if (!widget.isScanning) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
          if (widget.isScanning)
            MobileScanner(
              fit: BoxFit.cover,
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
              onDetect: (capture) {
                if (_hasScanned) return;
                
                final List<Barcode> barcodes = capture.barcodes;
                for (final barcode in barcodes) {
                  final String? code = barcode.rawValue;
                  if (code != null) {
                    _hasScanned = true; 
                    widget.onScan(code);
                    break; 
                  }
                }
              },
            )
          else
            Container(color: Colors.black),

          _buildScannerOverlay(),

          _buildDecorativeElements(),
        ],
      ),
    );
  }

  Widget _buildScannerOverlay() {
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Colors.black.withOpacity(0.5),
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
        color: const Color(0xFF2563EB),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.6),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildCorner({double? top, double? bottom, double? left, double? right, required bool isTop, required bool isLeft}) {
    return Positioned(
      top: top, bottom: bottom, left: left, right: right,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          border: Border(
            top: isTop ? const BorderSide(color: Color(0xFF2563EB), width: 4) : BorderSide.none,
            bottom: !isTop ? const BorderSide(color: Color(0xFF2563EB), width: 4) : BorderSide.none,
            left: isLeft ? const BorderSide(color: Color(0xFF2563EB), width: 4) : BorderSide.none,
            right: !isLeft ? const BorderSide(color: Color(0xFF2563EB), width: 4) : BorderSide.none,
          ),
          borderRadius: BorderRadius.only(
            topLeft: isTop && isLeft ? const Radius.circular(8) : Radius.zero,
            topRight: isTop && !isLeft ? const Radius.circular(8) : Radius.zero,
            bottomLeft: !isTop && isLeft ? const Radius.circular(8) : Radius.zero,
            bottomRight: !isTop && !isLeft ? const Radius.circular(8) : Radius.zero,
          ),
        ),
      ),
    );
  }
}
