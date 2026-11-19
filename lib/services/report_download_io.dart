import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _androidDownloads = MethodChannel('inventory_plus/report_download');

Future<String> saveReportPdf(String fileName, Uint8List bytes) async {
  if (Platform.isAndroid) {
    return await _androidDownloads.invokeMethod<String>('savePdfToDownloads', {
          'fileName': fileName,
          'bytes': bytes,
        }) ??
        'Downloads';
  }

  final downloads = await getDownloadsDirectory();
  final directory = downloads ?? await getApplicationDocumentsDirectory();
  final file = File('${directory.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return downloads == null ? 'Documents' : 'Downloads';
}
