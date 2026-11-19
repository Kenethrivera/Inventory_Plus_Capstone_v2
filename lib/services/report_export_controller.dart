import 'dart:async';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'report_download.dart';

enum ReportExportPhase { idle, exporting, ready, saving, failed }

typedef ReportProgress = void Function(double progress);
typedef ReportBuilder = Future<Uint8List> Function(ReportProgress progress);

class ReportExportController extends ChangeNotifier {
  ReportExportController({Future<String> Function(String, Uint8List)? save})
    : _save = save ?? saveReportPdf;

  static final ReportExportController instance = ReportExportController();
  final Future<String> Function(String, Uint8List) _save;

  ReportExportPhase phase = ReportExportPhase.idle;
  String? reportName;
  String? fileName;
  String? errorMessage;
  double progress = 0;
  Uint8List? _pdf;
  Future<void> Function()? _afterDownload;
  int _generation = 0;
  Timer? _progressTimer;

  bool get hasExport => phase != ReportExportPhase.idle;

  bool start({
    required String reportName,
    required String fileName,
    required ReportBuilder build,
    Future<void> Function()? afterDownload,
  }) {
    if (hasExport) return false;
    final generation = ++_generation;
    this.reportName = reportName;
    this.fileName = fileName;
    _afterDownload = afterDownload;
    _pdf = null;
    errorMessage = null;
    progress = 0.02;
    phase = ReportExportPhase.exporting;
    notifyListeners();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (generation != _generation || phase != ReportExportPhase.exporting) {
        timer.cancel();
        return;
      }
      // Fetch and PDF generation do not expose byte-level progress. Ease the
      // visible estimate forward while those asynchronous stages are running.
      if (progress < 0.98) {
        progress += (0.98 - progress) * 0.018;
        notifyListeners();
      }
    });
    unawaited(_build(generation, build));
    return true;
  }

  Future<void> _build(int generation, ReportBuilder build) async {
    try {
      final bytes = await build((value) {
        if (generation != _generation || phase != ReportExportPhase.exporting) {
          return;
        }
        final stage = value.clamp(0.0, 0.99);
        if (stage > progress) {
          progress = stage;
          notifyListeners();
        }
      });
      if (generation != _generation) return;
      _stopProgressAnimation();
      _pdf = bytes;
      progress = 1;
      phase = ReportExportPhase.ready;
      notifyListeners();
    } catch (error, stackTrace) {
      if (generation != _generation) return;
      _stopProgressAnimation();
      AppLogger.error(
        'Report export failed',
        error: error,
        stackTrace: stackTrace,
      );
      errorMessage = error is StateError
          ? error.message
          : 'Could not create the report.';
      phase = ReportExportPhase.failed;
      notifyListeners();
    }
  }

  Future<String?> download() async {
    if (phase != ReportExportPhase.ready || _pdf == null || fileName == null) {
      return null;
    }
    final generation = _generation;
    phase = ReportExportPhase.saving;
    notifyListeners();
    try {
      final destination = await _save(fileName!, _pdf!);
      if (generation != _generation) return null;
      try {
        await _afterDownload?.call();
      } catch (error, stackTrace) {
        AppLogger.error(
          'Report export reminder update failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (generation == _generation) clear();
      return destination;
    } catch (error, stackTrace) {
      if (generation != _generation) return null;
      AppLogger.error(
        'Report download failed',
        error: error,
        stackTrace: stackTrace,
      );
      errorMessage = 'Could not save the report. Tap to try again.';
      phase = ReportExportPhase.ready;
      notifyListeners();
      rethrow;
    }
  }

  void clear() {
    ++_generation;
    _stopProgressAnimation();
    phase = ReportExportPhase.idle;
    reportName = null;
    fileName = null;
    errorMessage = null;
    progress = 0;
    _pdf = null;
    _afterDownload = null;
    notifyListeners();
  }

  void _stopProgressAnimation() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }
}
