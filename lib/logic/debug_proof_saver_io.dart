import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<void> saveDebugProofPlatform({
  required String fileName,
  required Uint8List pngBytes,
}) async {
  try {
    final baseDir = await getApplicationDocumentsDirectory();
    final proofDir = Directory('${baseDir.path}/proof');
    if (!await proofDir.exists()) {
      await proofDir.create(recursive: true);
    }

    final file = File('${proofDir.path}/$fileName');
    await file.writeAsBytes(pngBytes);
    debugPrint('[DebugProof] Saved: ${file.path}');
  } catch (e) {
    debugPrint('[DebugProof] Failed to save (io): $e');
  }
}
