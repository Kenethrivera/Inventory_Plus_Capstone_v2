import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/report_export_controller.dart';

void main() {
  test(
    'report keeps building while the UI is free, then saves on tap',
    () async {
      final build = Completer<Uint8List>();
      final saved = <String>[];
      final export = ReportExportController(
        save: (fileName, bytes) async {
          saved.add('$fileName:${bytes.length}');
          return 'Downloads';
        },
      );
      final phases = <ReportExportPhase>[];
      export.addListener(() => phases.add(export.phase));

      expect(
        export.start(
          reportName: 'Inventory report',
          fileName: 'inventory.pdf',
          build: (progress) {
            progress(0.64);
            return build.future;
          },
        ),
        isTrue,
      );
      expect(export.phase, ReportExportPhase.exporting);
      expect(export.progress, 0.64);
      expect(
        export.start(
          reportName: 'Sales report',
          fileName: 'sales.pdf',
          build: (_) async => Uint8List(0),
        ),
        isFalse,
      );

      build.complete(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      expect(export.phase, ReportExportPhase.ready);
      expect(export.progress, 1);
      expect(await export.download(), 'Downloads');
      expect(saved, ['inventory.pdf:3']);
      expect(export.phase, ReportExportPhase.idle);
      expect(
        phases,
        containsAllInOrder([
          ReportExportPhase.exporting,
          ReportExportPhase.ready,
          ReportExportPhase.saving,
          ReportExportPhase.idle,
        ]),
      );
    },
  );

  test('clearing a job discards its late result', () async {
    final build = Completer<Uint8List>();
    final export = ReportExportController(save: (_, _) async => 'Downloads');
    export.start(
      reportName: 'Sales report',
      fileName: 'sales.pdf',
      build: (_) => build.future,
    );
    export.clear();
    build.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);
    expect(export.phase, ReportExportPhase.idle);
    expect(await export.download(), isNull);
  });

  test(
    'progress advances during data and PDF waits without going backwards',
    () async {
      final build = Completer<Uint8List>();
      late ReportProgress reportStage;
      final export = ReportExportController(save: (_, _) async => 'Downloads');
      export.start(
        reportName: 'Inventory report',
        fileName: 'inventory.pdf',
        build: (progress) {
          reportStage = progress;
          return build.future;
        },
      );
      expect(export.progress, 0.02);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(export.progress, greaterThan(0.02));
      reportStage(0.65);
      expect(export.progress, 0.65);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(export.progress, greaterThan(0.65));
      final advanced = export.progress;
      reportStage(0.3);
      expect(export.progress, advanced);
      build.complete(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      expect(export.phase, ReportExportPhase.ready);
      expect(export.progress, 1);
    },
  );

  test('save failure keeps the report ready for another tap', () async {
    var attempts = 0;
    final export = ReportExportController(
      save: (_, _) async {
        attempts++;
        if (attempts == 1) throw Exception('disk full');
        return 'Downloads';
      },
    );
    export.start(
      reportName: 'Inventory report',
      fileName: 'inventory.pdf',
      build: (_) async => Uint8List.fromList([1]),
    );
    await Future<void>.delayed(Duration.zero);
    await expectLater(export.download(), throwsException);
    expect(export.phase, ReportExportPhase.ready);
    expect(await export.download(), 'Downloads');
    expect(export.phase, ReportExportPhase.idle);
  });

  test(
    'clearing during save does not restore a previous session report',
    () async {
      final save = Completer<String>();
      final export = ReportExportController(save: (_, _) => save.future);
      export.start(
        reportName: 'Inventory report',
        fileName: 'inventory.pdf',
        build: (_) async => Uint8List.fromList([1]),
      );
      await Future<void>.delayed(Duration.zero);
      final download = export.download();
      expect(export.phase, ReportExportPhase.saving);
      export.clear();
      save.complete('Downloads');
      expect(await download, isNull);
      expect(export.phase, ReportExportPhase.idle);
    },
  );
}
