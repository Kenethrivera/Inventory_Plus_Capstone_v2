import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/report_export_controller.dart';
import 'package:inventory_plus/ui/widgets/report_export_indicator.dart';

void main() {
  testWidgets('circle expands, outside tap collapses, ready pill downloads', (
    tester,
  ) async {
    final build = Completer<Uint8List>();
    final downloaded = <String>[];
    final controller = ReportExportController(
      save: (_, _) async => 'Downloads',
    );
    controller.start(
      reportName: 'Inventory report',
      fileName: 'inventory.pdf',
      build: (progress) {
        progress(0.64);
        return build.future;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const Center(child: Text('Inventory page')),
          floatingActionButton: ReportExportIndicator(
            controller: controller,
            onDownloaded: (name, destination) =>
                downloaded.add('$name:$destination'),
            onDownloadError: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('Exporting 64%'), findsNothing);
    await tester.tap(find.byType(ReportExportIndicator));
    await tester.pump();
    expect(find.text('Exporting 64%'), findsOneWidget);
    expect(find.text('Inventory report'), findsOneWidget);
    await tester.tapAt(const Offset(20, 200));
    await tester.pump();
    expect(find.text('Exporting 64%'), findsNothing);

    build.complete(Uint8List.fromList([1, 2]));
    await tester.pumpAndSettle();
    expect(find.text('Report ready'), findsOneWidget);
    expect(find.text('Tap to download'), findsOneWidget);
    await tester.tap(find.text('Report ready'));
    await tester.pumpAndSettle();
    expect(downloaded, ['Inventory report:Downloads']);
    expect(controller.phase, ReportExportPhase.idle);
    expect(find.text('Report ready'), findsNothing);
  });
}
