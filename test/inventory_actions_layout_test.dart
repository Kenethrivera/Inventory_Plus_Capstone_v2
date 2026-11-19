import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/inventory_redesign.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _EmptyAdminInventoryController extends InventoryController {
  _EmptyAdminInventoryController() {
    currentUserRole = 'admin';
  }

  @override
  List<InventoryItem> get currentInventory => const [];

  @override
  List<InventoryItem> get disabledItems => const [];
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

  for (final width in [360.0, 800.0, 1100.0]) {
    testWidgets('inventory actions at ${width.toInt()}px show QR only', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var qrTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: InventoryRedesign(
            controller: _EmptyAdminInventoryController(),
            onUpdateItem: (_) async {},
            onQrLabels: (_) => qrTaps++,
            onNewItem: () {},
          ),
        ),
      );

      expect(find.text('Export report'), findsNothing);
      expect(find.text('Export Sales'), findsNothing);
      expect(find.byTooltip('Download QR labels'), findsOneWidget);
      if (width < 720) {
        expect(find.text('Add item'), findsOneWidget);
        expect(find.text('Filter'), findsNothing);
        final qrTop = tester
            .getTopLeft(find.byTooltip('Download QR labels'))
            .dy;
        final addTop = tester.getTopLeft(find.text('Add item')).dy;
        final searchTop = tester.getTopLeft(find.byType(TextField)).dy;
        expect((qrTop - addTop).abs(), lessThan(15));
        expect(qrTop, lessThan(searchTop));
      }
      if (width < 900) {
        await tester.tap(find.byTooltip('Download QR labels'));
        await tester.pump();
        expect(qrTaps, 1);
      } else {
        expect(qrTaps, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
