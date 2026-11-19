import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/report_export_controller.dart';
import 'package:inventory_plus/ui/widgets/analytics_export_menu.dart';

void main() {
  testWidgets('menu shows selected period and explains an ongoing export', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final export = ReportExportController(save: (_, _) async => 'Downloads');
    final building = Completer<Uint8List>();
    var salesTaps = 0;
    var inventoryTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: AnalyticsExportMenu(
              periodLabel: 'This month',
              export: export,
              onSales: () {
                salesTaps++;
                export.start(
                  reportName: 'Sales report',
                  fileName: 'sales.pdf',
                  build: (_) => building.future,
                );
              },
              onInventory: () => inventoryTaps++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(AnalyticsExportMenu));
    await tester.pump();
    expect(find.text('Sales report'), findsOneWidget);
    expect(find.text('Inventory report'), findsOneWidget);
    expect(find.text('This month'), findsNWidgets(2));
    final buttonBottom = tester
        .getBottomLeft(find.byType(AnalyticsExportMenu))
        .dy;
    final menuTop = tester.getTopLeft(find.text('Export report')).dy;
    expect(menuTop, greaterThan(buttonBottom));

    await tester.tap(find.text('Sales report'));
    await tester.pump();
    expect(salesTaps, 1);
    expect(find.text('Export report'), findsNothing);

    await tester.tap(find.byType(AnalyticsExportMenu));
    await tester.pump();
    expect(find.text('Exporting…'), findsOneWidget);
    expect(find.text('Wait'), findsOneWidget);
    expect(find.textContaining('is exporting.'), findsOneWidget);
    await tester.tap(find.text('Inventory report'));
    await tester.pump();
    expect(inventoryTaps, 0);
    await tester.tap(find.text('Sales report'));
    await tester.pump();
    expect(salesTaps, 1);

    building.complete(Uint8List.fromList([1]));
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.textContaining('is ready.'), findsOneWidget);
    expect(inventoryTaps, 0);
    await export.download();
    await tester.pump();
    expect(find.text('Wait'), findsNothing);
    await tester.tap(find.text('Inventory report'));
    await tester.pump();
    expect(inventoryTaps, 1);
    expect(find.text('Export report'), findsNothing);
  });
}
