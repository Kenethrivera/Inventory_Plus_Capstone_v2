// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'loading_proof_photo.dart';

Future<Uint8List> prepareLoadingProofPhotoFromPicker(XFile image) async {
  if (await image.length() <= maxLoadingProofPhotoBytes) {
    final source = await image.readAsBytes();
    if (_isValidProofJpeg(source)) return source;
  }

  final photo = html.ImageElement()..src = image.path;
  try {
    await photo.decode();
    final originalWidth = photo.naturalWidth;
    final originalHeight = photo.naturalHeight;
    if (originalWidth <= 0 || originalHeight <= 0) {
      throw StateError('The photo could not be opened.');
    }

    for (final maxEdge in [960, 720, 480]) {
      final scale =
          maxEdge /
          (originalWidth > originalHeight ? originalWidth : originalHeight);
      final width = (originalWidth * (scale < 1 ? scale : 1)).round();
      final height = (originalHeight * (scale < 1 ? scale : 1)).round();
      final canvas = html.CanvasElement(width: width, height: height);
      canvas.context2D.drawImageScaled(photo, 0, 0, width, height);

      for (final quality in [0.65, 0.45]) {
        final jpeg = await canvas.toBlob('image/jpeg', quality);
        if (jpeg.size < 100 || jpeg.size > maxLoadingProofPhotoBytes) {
          continue;
        }
        final url = html.Url.createObjectUrlFromBlob(jpeg);
        try {
          final bytes = await XFile(url).readAsBytes();
          if (_isValidProofJpeg(bytes)) return bytes;
        } finally {
          html.Url.revokeObjectUrl(url);
        }
      }
    }
    throw StateError('Photo is too large. Retake it at lower resolution.');
  } finally {
    photo.remove();
  }
}

bool _isValidProofJpeg(Uint8List bytes) =>
    bytes.length >= 100 &&
    bytes.length <= maxLoadingProofPhotoBytes &&
    bytes[0] == 0xff &&
    bytes[1] == 0xd8 &&
    bytes[2] == 0xff;
