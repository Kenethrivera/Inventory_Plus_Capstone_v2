import 'dart:html' as html;

Future<String> saveCsv(String filename, String contents) async {
  final url = html.Url.createObjectUrlFromBlob(
    html.Blob(<String>[contents], 'text/csv;charset=utf-8'),
  );
  try {
    html.AnchorElement(href: url)
      ..download = filename
      ..click();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
  return filename;
}
