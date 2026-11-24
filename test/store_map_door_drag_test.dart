import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/store_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
    );
  });

  testWidgets('existing door moves only after a valid drop without a preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final layout = <MapElement>[
      MapElement(
        id: 'wall-1',
        type: ElementType.wall,
        position: const Offset(100, 100),
        size: const Size(260, 15),
      ),
      MapElement(
        id: 'door-1',
        type: ElementType.door,
        position: const Offset(170, 100),
        size: const Size(80, 15),
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StoreMap(
        controller: InventoryController(),
        layout: layout,
        mode: MapMode.manage,
        viewStyle: MapViewStyle.twoD,
        fitEntireMap: true,
        showZoomControls: false,
        showMobileToolbar: false,
      )),
    ));
    await tester.pump();
    await tester.pump();

    final preview = find.byKey(const ValueKey('store-map-placement-preview'));
    final originalPosition = layout[1].position;
    final start = tester.getCenter(find.byKey(const ValueKey('door-1')));
    final drag = await tester.startGesture(start);
    await drag.moveTo(start + const Offset(30, 0));
    await tester.pump();
    expect(preview, findsNothing);
    expect(layout[1].position, originalPosition);

    final offWall = start + const Offset(30, 100);
    await drag.moveTo(offWall);
    await tester.pump();
    expect(preview, findsNothing);
    expect(layout[1].position, originalPosition);

    await drag.up();
    await tester.pump();
    expect(preview, findsNothing);
    expect(layout[1].position, originalPosition);

    final validDrag = await tester.startGesture(start);
    await validDrag.moveTo(start + const Offset(30, 0));
    await tester.pump();
    expect(preview, findsNothing);
    expect(layout[1].position, originalPosition);
    await validDrag.up();
    await tester.pump();
    expect(layout[1].position.dx, greaterThan(originalPosition.dx));
    expect(tester.takeException(), isNull);
  });
}
