import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_toast.dart';

class LoadingProofCameraPage extends StatefulWidget {
  const LoadingProofCameraPage({super.key});

  @override
  State<LoadingProofCameraPage> createState() => _LoadingProofCameraPageState();
}

class _LoadingProofCameraPageState extends State<LoadingProofCameraPage> {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _switching = false;
  bool _capturing = false;
  bool _flashOn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_openCamera());
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera is available.');
      _cameras = cameras;
      final rear = cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      await _selectCamera(rear >= 0 ? rear : 0);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Camera unavailable. Check camera access, then try again.');
      }
    }
  }

  Future<void> _selectCamera(int index) async {
    if (_switching || index < 0 || index >= _cameras.length) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    final previous = _controller;
    _controller = null;
    await previous?.dispose();
    CameraController? next;
    try {
      next = CameraController(
        _cameras[index],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await next.initialize();
      if (!mounted) return;
      setState(() {
        _controller = next;
        _cameraIndex = index;
        _flashOn = false;
      });
      next = null;
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Camera unavailable. Check camera access, then try again.');
      }
    } finally {
      if (next != null) await next.dispose();
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _switching || _capturing) return;
    final direction = _cameras[_cameraIndex].lensDirection;
    final opposite = _cameras.indexWhere(
      (camera) => camera.lensDirection != direction,
    );
    await _selectCamera(opposite >= 0
        ? opposite
        : (_cameraIndex + 1) % _cameras.length);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || _switching || _capturing) return;
    try {
      final next = !_flashOn;
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _flashOn = next);
    } catch (_) {
      if (mounted) {
        AppToast.error(context, 'Flashlight is not available on this camera.');
      }
    }
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || _switching || _capturing) return;
    setState(() => _capturing = true);
    try {
      final image = await controller.takePicture();
      if (mounted) Navigator.pop(context, image);
    } catch (_) {
      if (mounted) {
        AppToast.error(context, 'Could not take the photo. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Widget _preview(CameraController controller) {
    final size = controller.value.previewSize;
    if (size == null) return const SizedBox.shrink();
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: kIsWeb ? size.width : size.height,
          height: kIsWeb ? size.height : size.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller?.value.isInitialized == true && !_switching;
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: ready ? _preview(controller!) : const ColoredBox(color: Colors.black),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Colors.transparent, Color(0xB3000000)],
                    stops: [0, 0.35, 1],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close camera',
                        onPressed: _capturing ? null : () => Navigator.pop(context),
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const Expanded(
                        child: Text(
                          'Take photo',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                const Spacer(),
                if (!ready && _error == null)
                  const CircularProgressIndicator(color: Colors.white)
                else if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        Text(_error!, textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white)),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _switching ? null : () => unawaited(_openCamera()),
                          child: const Text('Retry camera'),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, mobile ? 26 : 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: 'Toggle flashlight',
                        onPressed: ready && !_capturing ? _toggleFlash : null,
                        color: Colors.white,
                        disabledColor: Colors.white54,
                        iconSize: mobile ? 28 : 24,
                        icon: Icon(_flashOn ? Icons.flash_on : Icons.flash_off),
                      ),
                      IconButton.filled(
                        tooltip: 'Capture photo',
                        onPressed: ready && !_capturing ? _takePhoto : null,
                        icon: const Icon(Icons.camera_alt, size: 32),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFFC83D08),
                          disabledBackgroundColor: Colors.white54,
                          fixedSize: Size.square(mobile ? 76 : 68),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Flip camera',
                        onPressed: ready && _cameras.length > 1 && !_capturing
                            ? _flipCamera
                            : null,
                        color: Colors.white,
                        disabledColor: Colors.white54,
                        iconSize: mobile ? 28 : 24,
                        icon: const Icon(Icons.cameraswitch_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
