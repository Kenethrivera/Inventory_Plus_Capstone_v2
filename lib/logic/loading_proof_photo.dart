import 'dart:typed_data';

import 'package:image/image.dart' as img;

const maxLoadingProofPhotoBytes = 1048576;

/// Keeps an already small JPEG intact, otherwise prepares it for the proof RPC.
Uint8List prepareLoadingProofPhoto(Uint8List source) {
  if (source.length >= 100 &&
      source.length <= maxLoadingProofPhotoBytes &&
      source[0] == 0xff &&
      source[1] == 0xd8 &&
      source[2] == 0xff) {
    return source;
  }

  final decoded = img.decodeImage(source);
  if (decoded == null) {
    throw StateError('The photo could not be opened.');
  }

  for (final maxEdge in [960, 720, 480]) {
    final fitted = decoded.width > maxEdge || decoded.height > maxEdge
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxEdge : null,
            height: decoded.height > decoded.width ? maxEdge : null,
          )
        : decoded;
    for (final quality in [65, 45]) {
      final jpeg = Uint8List.fromList(img.encodeJpg(fitted, quality: quality));
      if (jpeg.length <= maxLoadingProofPhotoBytes) return jpeg;
    }
  }
  throw StateError('Photo is too large. Retake it at lower resolution.');
}
