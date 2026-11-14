import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/ui/widgets/cashier_order_preparation.dart';

CustomerOrder _order({
  bool picked = false,
  bool heavyScanned = false,
  bool loaded = false,
}) => CustomerOrder.fromJson({
  'id': 'shared-order',
  'status': picked && loaded ? 'prepared' : 'pending',
  'created_at': '2026-11-14T08:00:00Z',
  'assigned_helper_name': 'Kenneth',
  'assigned_bodegero_name': 'Yves',
  'loading_verified_at': loaded ? '2026-11-14T08:15:00Z' : null,
  'items': [
    {
      'product_id': 'hammer',
      'product_name': 'Claw Hammer',
      'quantity': 3,
      'picked': picked,
      'requires_loading': false,
    },
    {
      'product_id': 'wrench',
      'product_name': 'Adjustable wrench',
      'quantity': 2,
      'heavy_verified': heavyScanned,
      'requires_loading': true,
    },
  ],
});

void main() {
  testWidgets('cashier sees both workers update on one mixed order', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> show(CustomerOrder order) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CashierOrderPreparation(order: order),
              for (final item in order.items)
                CashierOrderItemRow(order: order, item: item),
            ],
          ),
        ),
      ),
    );

    final waiting = _order();
    await show(waiting);
    expect(
      cashierPreparationSubtitle(waiting),
      'Preparing · 0/1 light · 0/1 heavy',
    );
    expect(find.text('Helper · Kenneth'), findsOneWidget);
    expect(find.text('Bodegero · Yves'), findsOneWidget);
    expect(find.text('0/1 light items picked'), findsOneWidget);
    expect(find.textContaining('0/1 heavy QR verified'), findsOneWidget);
    expect(find.text('Awaiting Helper scan'), findsOneWidget);
    expect(find.text('Awaiting Bodegero scan'), findsOneWidget);
    expect(
      cashierItemProgress(waiting, waiting.items.first).label,
      'Awaiting Helper scan',
    );
    expect(
      cashierItemProgress(waiting, waiting.items.last).label,
      'Awaiting Bodegero scan',
    );
    expect(tester.takeException(), isNull);

    final scanned = _order(picked: true, heavyScanned: true);
    await show(scanned);
    expect(find.text('1/1 light items picked'), findsOneWidget);
    expect(find.textContaining('1/1 heavy QR verified'), findsOneWidget);
    expect(find.text('QR verified · loading pending'), findsOneWidget);
    expect(
      cashierItemProgress(scanned, scanned.items.last).label,
      'QR verified · loading pending',
    );
    expect(tester.takeException(), isNull);

    final ready = _order(picked: true, heavyScanned: true, loaded: true);
    await show(ready);
    expect(cashierPreparationSubtitle(ready), 'Ready for Pickup');
    expect(find.text('Heavy loading verified'), findsOneWidget);
    expect(find.text('Loaded onto truck'), findsOneWidget);
    expect(
      cashierItemProgress(ready, ready.items.last).label,
      'Loaded onto truck',
    );
    expect(tester.takeException(), isNull);
  });
}
