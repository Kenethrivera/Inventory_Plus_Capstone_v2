import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Lets the user choose the exact square saved from a selected image.
Future<Uint8List?> showSquareImageCropDialog(
  BuildContext context,
  Uint8List imageBytes,
) => showDialog<Uint8List>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SquareImageCropDialog(imageBytes: imageBytes),
);

class _SquareImageCropDialog extends StatefulWidget {
  const _SquareImageCropDialog({required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<_SquareImageCropDialog> createState() => _SquareImageCropDialogState();
}

class _SquareImageCropDialogState extends State<_SquareImageCropDialog> {
  ui.Image? _image;
  String? _error;
  double _zoom = 1;
  double _centerX = 0;
  double _centerY = 0;
  bool _cropping = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      try {
        final frame = await codec.getNextFrame();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() {
          _image = frame.image;
          _centerX = frame.image.width / 2;
          _centerY = frame.image.height / 2;
        });
      } finally {
        codec.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open this image.');
    }
  }

  double get _cropSide {
    final image = _image!;
    return math.min(image.width, image.height) / _zoom;
  }

  Rect get _sourceRect {
    final side = _cropSide;
    return Rect.fromCenter(
      center: Offset(_centerX, _centerY),
      width: side,
      height: side,
    );
  }

  void _clampCenter() {
    final image = _image!;
    final half = _cropSide / 2;
    _centerX = _centerX.clamp(half, image.width - half);
    _centerY = _centerY.clamp(half, image.height - half);
  }

  Future<void> _crop() async {
    final image = _image;
    if (image == null || _cropping) return;
    setState(() => _cropping = true);
    try {
      final bytes = await cropSquareImage(image, _sourceRect);
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (_) {
      if (mounted) {
        setState(() {
          _cropping = false;
          _error = 'Could not crop this image. Please try another image.';
        });
      }
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final screen = MediaQuery.sizeOf(context);
    final previewSide = math.min(
      360.0,
      math.min(screen.width - 96, screen.height * .43),
    );
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Crop QR image',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              const Text(
                'Drag to position the QR code inside the square.',
                style: TextStyle(color: Color(0xFF746F69), fontSize: 13),
              ),
              const SizedBox(height: 16),
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: previewSide,
                    height: previewSide,
                    color: const Color(0xFFF7F5F3),
                    child: image == null
                        ? Center(
                            child: _error == null
                                ? const CircularProgressIndicator()
                                : Text(_error!, textAlign: TextAlign.center),
                          )
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) {
                              setState(() {
                                _centerX -=
                                    details.delta.dx * _cropSide / previewSide;
                                _centerY -=
                                    details.delta.dy * _cropSide / previewSide;
                                _clampCenter();
                              });
                            },
                            child: CustomPaint(
                              painter: _SquareCropPreviewPainter(
                                image,
                                _sourceRect,
                              ),
                              size: Size.square(previewSide),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.zoom_out,
                    size: 20,
                    color: Color(0xFF746F69),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFFD13E05),
                        thumbColor: const Color(0xFFD13E05),
                      ),
                      child: Slider(
                        value: _zoom,
                        min: 1,
                        max: 4,
                        onChanged: image == null
                            ? null
                            : (value) => setState(() {
                                _zoom = value;
                                _clampCenter();
                              }),
                      ),
                    ),
                  ),
                  const Icon(Icons.zoom_in, size: 20, color: Color(0xFF746F69)),
                ],
              ),
              if (_error != null && image != null)
                Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: _cropping
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: image == null || _cropping ? null : _crop,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD13E05),
                    ),
                    child: Text(_cropping ? 'Cropping...' : 'Use square image'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SquareCropPreviewPainter extends CustomPainter {
  const _SquareCropPreviewPainter(this.image, this.sourceRect);

  final ui.Image image;
  final Rect sourceRect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      sourceRect,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(_SquareCropPreviewPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.sourceRect != sourceRect;
}

/// Exports the previewed square as PNG, keeping QR details up to 2000px.
Future<Uint8List> cropSquareImage(ui.Image image, Rect sourceRect) async {
  final outputSide = math.min(2000, math.min(image.width, image.height));
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    sourceRect,
    Rect.fromLTWH(0, 0, outputSide.toDouble(), outputSide.toDouble()),
    Paint()..filterQuality = FilterQuality.none,
  );
  final picture = recorder.endRecording();
  try {
    final cropped = await picture.toImage(outputSide, outputSide);
    try {
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not encode the cropped image.');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      cropped.dispose();
    }
  } finally {
    picture.dispose();
  }
}
