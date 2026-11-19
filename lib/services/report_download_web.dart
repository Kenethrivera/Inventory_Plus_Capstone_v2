import 'dart:html' as html;
import 'dart:typed_data';

Future<String> saveReportPdf(String fileName, Uint8List bytes) async {
  final url = html.Url.createObjectUrlFromBlob(
    html.Blob([bytes], 'application/pdf'),
  );
  try {
    html.AnchorElement(href: url)
      ..download = fileName
      ..click();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
  return 'browser downloads';
}
