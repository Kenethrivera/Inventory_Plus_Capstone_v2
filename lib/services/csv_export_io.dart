import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String> saveCsv(String filename, String contents) async {
  final directory = await getApplicationDocumentsDirectory();
  final file = File('${directory.path}${Platform.pathSeparator}$filename');
  await file.writeAsString(contents, flush: true);
  return file.path;
}
