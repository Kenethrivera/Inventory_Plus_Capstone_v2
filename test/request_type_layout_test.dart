import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/cashier_requests_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _EmptyInventoryController extends InventoryController {
  @override
  List<InventoryItem> get allItems => const [];

  @override
  Stream<List<InventoryItem>> streamInventory() => Stream.value(const []);
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

  for (final width in [320.0, 390.0]) {
    testWidgets('request types align at ${width.toInt()}px', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = _EmptyInventoryController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSharedStockRequestDialog(
                  context: context,
                  controller: controller,
                ),
                child: const Text('Open request'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open request'));
      await tester.pumpAndSettle();

      void expectAligned() {
        final restock = find.ancestor(
          of: find.text('Restock'),
          matching: find.byType(InkWell),
        );
        final writeOff = find.ancestor(
          of: find.text('Write-off'),
          matching: find.byType(InkWell),
        );
        expect(tester.getTopLeft(restock).dy, tester.getTopLeft(writeOff).dy);
        expect(
          tester.getBottomLeft(restock).dy,
          tester.getBottomLeft(writeOff).dy,
        );
        final layoutError = tester.takeException();
        expect(
          layoutError,
          isNull,
          reason: layoutError is FlutterError
              ? layoutError.toStringDeep()
              : null,
        );
      }

      expectAligned();
      await tester.tap(find.text('Write-off'));
      await tester.pumpAndSettle();
      expectAligned();
    });
  }
}
