import 'dart:typed_data';

import 'report_download_io.dart'
    if (dart.library.html) 'report_download_web.dart'
    as platform;

Future<String> saveReportPdf(String fileName, Uint8List bytes) =>
    platform.saveReportPdf(fileName, bytes);
