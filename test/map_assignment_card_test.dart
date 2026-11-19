import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/map_editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _AssignmentController extends InventoryController {
  final List<MapElement> _layout = [
    MapElement(
      id: 'shelf-1',
      type: ElementType.shelf,
      position: const Offset(80, 80),
      label: 'Shelf',
    ),
  ];

  @override
  Future<void> fetchMapLayout({bool force = false}) async {}

  @override
  List<MapElement> get currentMapLayout => _layout;

  @override
  List<InventoryItem> get allItems => [
    _item(
      'mortar',
      'Masonry Mortar Mix 25kg',
      'SIM-SUM-008',
      imageUrl: 'https://example.com/mortar.png',
    ),
    _item('bolts', 'Hex Bolts M8 Box', 'SIM-BOL-001'),
    _item('wrench', 'Adjustable wrench', 'SKU-WRENCH', locationId: 'shelf-1'),
  ];

  InventoryItem _item(
    String id,
    String name,
    String sku, {
    String? locationId,
    String imageUrl = '',
  }) => InventoryItem(
    id: id,
    name: name,
    sku: sku,
    price: 100,
    quantity: 10,
    maxQuantity: 100,
    category: 'Tools',
    description: '',
    imageUrl: imageUrl,
    locationId: locationId,
  );
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

  for (final width in [360.0, 430.0, 1100.0, 1600.0]) {
    testWidgets('assignment card works at ${width.toInt()}px', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: MapEditorPage(controller: _AssignmentController())),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Assign items'));
      await tester.tap(find.text('Assign items'));
      await tester.pump();

      expect(find.text('Items to place'), findsOneWidget);
      expect(find.text('1 of 3 assigned'), findsOneWidget);
      expect(find.text('1 of 3 products assigned'), findsNothing);
      expect(find.text('All 3'), findsOneWidget);
      final allFilter = find.ancestor(
        of: find.text('All 3'),
        matching: find.byType(OutlinedButton),
      );
      expect(tester.getSize(allFilter).height, 40);
      expect(tester.getSize(allFilter).width, greaterThan(90));
      expect(find.text('Masonry Mortar Mix 25kg'), findsOneWidget);
      expect(find.text('Hex Bolts M8 Box'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is NetworkImage &&
              (widget.image as NetworkImage).url ==
                  'https://example.com/mortar.png',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(1 / 3, 0.001),
      );

      await tester.tap(find.text('Unassigned'));
      await tester.pump();
      expect(find.text('Adjustable wrench'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'bolts');
      await tester.pump();
      expect(find.text('Masonry Mortar Mix 25kg'), findsNothing);
      expect(find.text('Hex Bolts M8 Box'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('map-assign-product-bolts')));
      await tester.pump();
      if (width < 920) {
        await tester.tap(find.text('3D'));
        await tester.pump();
        final headingTop = tester.getTopLeft(find.text('Store map')).dy;
        final viewSwitchTop = tester.getTopLeft(find.text('3D')).dy;
        expect((headingTop - viewSwitchTop).abs(), lessThan(20));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
