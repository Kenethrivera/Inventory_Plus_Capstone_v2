import 'dart:html' as html;
import 'package:flutter/foundation.dart';

// Browsers won't let a web page write to an arbitrary folder — the
// closest equivalent is triggering a download, which most browsers save
// straight into the user's default Downloads folder without a prompt
// (same as a manual screenshot). If the browser is configured to "ask
// where to save every file," the user will see a save dialog instead —
// that's a browser setting, not something this code controls.
Future<void> saveDebugProofPlatform({
  required String fileName,
  required Uint8List pngBytes,
}) async {
  try {
    final blob = html.Blob([pngBytes], 'image/png');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
    debugPrint('[DebugProof] Downloaded: $fileName');
  } catch (e) {
    debugPrint('[DebugProof] Failed to save (web): $e');
  }
}
