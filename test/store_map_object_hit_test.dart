import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/store_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
    );
  });

  testWidgets('tapping the raised cashier model selects it', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final cashier = MapElement(
      id: 'cashier',
      type: ElementType.cashier,
      position: const Offset(400, 400),
      size: const Size(168, 64),
    );
    MapElement? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StoreMap(
            controller: InventoryController(),
            layout: [cashier],
            mode: MapMode.manage,
            viewStyle: MapViewStyle.threeD,
            showMobileToolbar: false,
            onManageSelectionChanged: (element) => selected = element,
          ),
        ),
      ),
    );
    await tester.pump();

    final hitSurface = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_MapObjectHitPainter',
    );
    expect(hitSurface, findsOneWidget);
    final widget = tester.widget<CustomPaint>(hitSurface);
    final box = tester.renderObject<RenderBox>(hitSurface);
    expect(widget.painter?.hitTest(Offset.zero), isFalse);
    Offset? raisedPoint;
    for (var y = 0.0; y < 180 && raisedPoint == null; y += 5) {
      for (var x = 0.0; x < box.size.width; x += 5) {
        final point = Offset(x, y);
        if (widget.painter?.hitTest(point) == true) {
          raisedPoint = point;
          break;
        }
      }
    }
    expect(raisedPoint, isNotNull);

    final visualPoint = box.localToGlobal(raisedPoint!);
    final hoverOutline = find.byKey(const ValueKey('map-hover-glow-cashier'));
    expect(hoverOutline, findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await mouse.moveTo(visualPoint);
    await tester.pump();
    expect(hoverOutline, findsOneWidget);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pump();
    expect(hoverOutline, findsNothing);

    await tester.tapAt(visualPoint);
    await tester.pump();
    expect(selected?.id, 'cashier');
  });

  testWidgets('hiding walls leaves other objects and the layout intact', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final wall = MapElement(
      id: 'wall',
      type: ElementType.wall,
      position: const Offset(300, 300),
      size: const Size(320, 15),
    );
    final cashier = MapElement(
      id: 'cashier',
      type: ElementType.cashier,
      position: const Offset(400, 400),
      size: const Size(168, 64),
    );
    final layout = [wall, cashier];
    final controller = InventoryController();
    var hideWalls = false;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Stack(
              children: [
                StoreMap(
                  controller: controller,
                  layout: layout,
                  mode: MapMode.manage,
                viewStyle: MapViewStyle.threeD,
                  hideWalls: hideWalls,
                  showMobileToolbar: false,
                ),
                TextButton(
                  onPressed: () => setState(() => hideWalls = !hideWalls),
                  child: const Text('Toggle walls'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('wall')), findsOneWidget);
    expect(find.byKey(const ValueKey('cashier')), findsOneWidget);

    await tester.tap(find.text('Toggle walls'));
    await tester.pump();
    expect(find.byKey(const ValueKey('wall')), findsNothing);
    expect(find.byKey(const ValueKey('cashier')), findsOneWidget);
    expect(layout, [wall, cashier]);

    await tester.tap(find.text('Toggle walls'));
    await tester.pump();
    expect(find.byKey(const ValueKey('wall')), findsOneWidget);
  });
}
