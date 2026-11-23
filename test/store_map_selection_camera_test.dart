import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/models_3d.dart';
import 'package:inventory_plus/ui/store_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _ShelfWithItemController extends InventoryController {
  @override
  List<InventoryItem> get allItems => [
    InventoryItem(
      id: 'item-1',
      name: 'Item',
      sku: 'ITEM-1',
      price: 1,
      quantity: 1,
      maxQuantity: 1,
      category: 'Tools',
      description: '',
      imageUrl: '',
      locationId: 'shelf-1',
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
    );
  });

  testWidgets('2D shelf labels and counts stay upright when rotated', (
    tester,
  ) async {
    final controller = _ShelfWithItemController();

    for (final rotation in [math.pi / 2, math.pi]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 450,
              child: StoreMap(
                controller: controller,
                layout: [
                  MapElement(
                    id: 'shelf-1',
                    type: ElementType.shelf,
                    position: const Offset(80, 80),
                    size: const Size(160, 50),
                    rotation: rotation,
                  ),
                ],
                viewStyle: MapViewStyle.twoD,
                showItemPopup: false,
                showZoomControls: false,
                showMobileToolbar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      for (final label in ['SHELF', '1']) {
        final text = tester.renderObject<RenderBox>(find.text(label));
        final transform = text.getTransformTo(null);
        final angle = math.atan2(transform.entry(1, 0), transform.entry(0, 0));
        expect(angle.abs(), lessThan(0.001), reason: '$label at $rotation');
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('selected 3D cashier glow follows the painted model', (
    tester,
  ) async {
    final key = GlobalKey<StoreMapState>();
    final controller = InventoryController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 450,
            child: StoreMap(
              key: key,
              controller: controller,
              layout: [
                MapElement(
                  id: 'cashier-1',
                  type: ElementType.cashier,
                  position: const Offset(80, 80),
                  size: const Size(180, 64),
                ),
              ],
              mode: MapMode.manage,
              viewStyle: MapViewStyle.threeD,
              showZoomControls: false,
              showMobileToolbar: false,
            ),
          ),
        ),
      ),
    );

    key.currentState!.selectManageElement('cashier-1');
    await tester.pump();

    final glow = find.byKey(const ValueKey('map-selected-outline-cashier-1'));
    expect(glow, findsOneWidget);
    final glowPaint = find.descendant(
      of: glow,
      matching: find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is CashierPainter,
      ),
    );
    expect(glowPaint, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('3D selection stays highlighted without resetting zoom or pan', (
    tester,
  ) async {
    final key = GlobalKey<StoreMapState>();
    final controller = InventoryController();
    final layout = [
      MapElement(
        id: 'shelf-1',
        type: ElementType.shelf,
        position: const Offset(80, 80),
        size: const Size(100, 80),
      ),
    ];

    Widget mapAtSize(
      double width, {
      double height = 360,
      String? highlightId,
    }) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: height,
          child: Column(
            children: [
              Expanded(
                child: StoreMap(
                  key: key,
                  controller: controller,
                  layout: layout,
                  mode: MapMode.view,
                  viewStyle: MapViewStyle.threeD,
                  fitEntireMap: true,
                  showItemPopup: false,
                  showZoomControls: false,
                  showMobileToolbar: false,
                  highlightId: highlightId,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(mapAtSize(700));
    await tester.pump();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final transform = viewer.transformationController!;
    key.currentState!.zoomIn();
    transform.value = Matrix4.translationValues(35, -20, 0)
      ..multiply(transform.value);
    final before = transform.value.clone();

    // The details card reduces the available map width on desktop.
    await tester.pumpWidget(mapAtSize(400, highlightId: 'shelf-1'));
    await tester.pump();

    final after = transform.value;
    expect(
      after.getMaxScaleOnAxis(),
      closeTo(before.getMaxScaleOnAxis(), 0.0001),
    );
    expect(after.entry(0, 3), closeTo(before.entry(0, 3) - 150, 0.01));
    expect(after.entry(1, 3), closeTo(before.entry(1, 3), 0.01));
    expect(
      find.byKey(const ValueKey('map-selected-outline-shelf-1')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is ShelfPainter,
      ),
      findsOneWidget,
    );
    final shelfPaint = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is ShelfPainter,
    );
    expect(tester.getSize(shelfPaint).height, greaterThan(300));

    // Pan the selected shelf toward the edge of the viewport. Its geometry
    // must still have a single paint pass and a separate outline.
    transform.value = Matrix4.translationValues(-80, -100, 0)
      ..multiply(transform.value);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is ShelfPainter,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('map-selected-outline-shelf-1')),
      findsOneWidget,
    );

    // A mobile details card changes the available map height instead.
    final beforeHeightChange = transform.value.clone();
    await tester.pumpWidget(mapAtSize(400, height: 220));
    await tester.pump();
    final afterHeightChange = transform.value;
    expect(
      afterHeightChange.getMaxScaleOnAxis(),
      closeTo(beforeHeightChange.getMaxScaleOnAxis(), 0.0001),
    );
    expect(
      afterHeightChange.entry(0, 3),
      closeTo(beforeHeightChange.entry(0, 3), 0.01),
    );
    expect(
      afterHeightChange.entry(1, 3),
      closeTo(beforeHeightChange.entry(1, 3) - 70, 0.01),
    );
    expect(
      find.byKey(const ValueKey('map-selected-outline-shelf-1')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Manage, Assign, and 3D keep separate centered cameras', (
    tester,
  ) async {
    final key = GlobalKey<StoreMapState>();
    final controller = InventoryController();
    final layout = [
      MapElement(
        id: 'rack-1',
        type: ElementType.rack,
        position: const Offset(80, 80),
        size: const Size(100, 80),
      ),
    ];

    Widget mapAt(double height, MapMode mode, MapViewStyle style) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: height,
              child: Column(
                children: [
                  Expanded(
                    child: StoreMap(
                      key: key,
                      controller: controller,
                      layout: layout,
                      mode: mode,
                      viewStyle: style,
                      fitEntireMap: true,
                      showItemPopup: false,
                      showZoomControls: false,
                      showMobileToolbar: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    await tester.pumpWidget(mapAt(600, MapMode.manage, MapViewStyle.twoD));
    await tester.pump();
    final transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    key.currentState!
      ..zoomIn()
      ..zoomIn();
    transform.value = Matrix4.translationValues(28, -14, 0)
      ..multiply(transform.value);
    final manageCamera = transform.value.clone();

    await tester.pumpWidget(mapAt(330, MapMode.selection, MapViewStyle.twoD));
    await tester.pump();
    final assignCamera = transform.value.clone();
    expect(
      assignCamera.getMaxScaleOnAxis(),
      lessThan(manageCamera.getMaxScaleOnAxis()),
    );

    await tester.pumpWidget(mapAt(600, MapMode.manage, MapViewStyle.twoD));
    await tester.pump();
    for (final column in [0, 1, 3]) {
      expect(
        transform.value.entry(0, column),
        closeTo(manageCamera.entry(0, column), 0.01),
      );
      expect(
        transform.value.entry(1, column),
        closeTo(manageCamera.entry(1, column), 0.01),
      );
    }

    await tester.pumpWidget(mapAt(600, MapMode.view, MapViewStyle.threeD));
    await tester.pump();
    final switched3D = transform.value.clone();

    await tester.pumpWidget(mapAt(330, MapMode.selection, MapViewStyle.twoD));
    await tester.pump();
    expect(
      transform.value.getMaxScaleOnAxis(),
      closeTo(assignCamera.getMaxScaleOnAxis(), 0.0001),
    );
    expect(
      transform.value.entry(0, 3),
      closeTo(assignCamera.entry(0, 3), 0.01),
    );
    expect(
      transform.value.entry(1, 3),
      closeTo(assignCamera.entry(1, 3), 0.01),
    );

    await tester.pumpWidget(mapAt(600, MapMode.view, MapViewStyle.threeD));
    await tester.pump();
    expect(transform.value.entry(0, 3), closeTo(switched3D.entry(0, 3), 0.01));
    expect(transform.value.entry(1, 3), closeTo(switched3D.entry(1, 3), 0.01));

    // Opening 3D from Floor must match a fresh 3D view at this size.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(mapAt(600, MapMode.view, MapViewStyle.threeD));
    await tester.pump();
    final fresh3D = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value;
    expect(
      switched3D.getMaxScaleOnAxis(),
      closeTo(fresh3D.getMaxScaleOnAxis(), 0.0001),
    );
    expect(switched3D.entry(0, 3), closeTo(fresh3D.entry(0, 3), 0.01));
    expect(switched3D.entry(1, 3), closeTo(fresh3D.entry(1, 3), 0.01));
    expect(tester.takeException(), isNull);
  });
}
