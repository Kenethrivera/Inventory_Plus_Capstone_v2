import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/inventory_redesign.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _ItemDetailsController extends InventoryController {
  _ItemDetailsController(this.item) {
    currentUserRole = 'admin';
  }

  final InventoryItem item;

  @override
  List<InventoryItem> get allItems => [item];

  @override
  List<InventoryItem> get currentInventory => [item];

  @override
  InventoryItem? findAnyItemById(String id) => id == item.id ? item : null;

  @override
  Stream<List<InventoryItem>> streamInventory() => Stream.value([item]);

  @override
  Future<List<Map<String, dynamic>>> loadProductTransactionHistory(
    String productId, {
    bool force = false,
  }) async => [
    for (var index = 0; index < 730; index++)
      {
        'transaction_type': 'sale',
        'quantity_change': -1,
        'new_quantity': 250 - index,
        'created_at': '2026-11-19T01:00:00Z',
        'user_name': 'Cashier',
      },
  ];

  @override
  Future<void> fetchMapLayout({bool force = false}) async {}
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

  for (final width in [280.0, 390.0]) {
    testWidgets('mobile item details tabs fit ${width.toInt()}px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final item = InventoryItem(
        id: 'wrench',
        name: 'Adjustable wrench',
        sku: 'SKU-3UWPD0GN',
        price: 1000,
        quantity: 250,
        maxQuantity: 500,
        category: 'Wrench',
        description: '',
        imageUrl: '',
        manufacturer: 'test',
        model: 'test',
        productSize: 'test',
      );
      final controller = _ItemDetailsController(item);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: Size(width, 800)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showInventoryItemDetails(
                  context: context,
                  item: item,
                  controller: controller,
                  onSave: (_) async {},
                  onQrLabel: () {},
                ),
                child: const Text('Open details'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open details'));
      await tester.pumpAndSettle();
      expect(find.text('Identity'), findsOneWidget);
      expect(find.text('Product name'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Category')).dy,
        greaterThan(tester.getBottomLeft(find.text('SKU')).dy),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Location'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Move to'), findsOneWidget);
      expect(find.text('Tap a shelf to move this item'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('History 730'));
      await tester.pump();
      expect(find.text('Sale'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
