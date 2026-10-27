import 'package:flutter/foundation.dart';

class AppLogger {
  AppLogger._();

  /// Suppresses legacy debugPrint calls in release builds while existing
  /// diagnostics are migrated to this helper.
  static void configure() {
    if (kReleaseMode) {
      debugPrint = (String? message, {int? wrapWidth}) {};
    }
  }

  static void debug(String message) {
    if (kDebugMode) debugPrint(message);
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    if (!kDebugMode) return;
    debugPrint(error == null ? message : '$message: $error');
    if (stackTrace != null) debugPrintStack(stackTrace: stackTrace);
  }
}
