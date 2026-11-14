import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/ui/order_assignee_label.dart';
import 'package:inventory_plus/ui/widgets/order_details_drawer.dart';

CustomerOrder _order({required bool hasLightItem}) => CustomerOrder.fromJson({
  'id': 'order-123456',
  'status': 'prepared',
  'created_at': '2026-11-14T08:00:00Z',
  'loading_verified_at': '2026-11-14T08:10:00Z',
  'assigned_bodegero_id': 'bodegero-1',
  'assigned_bodegero_name': 'Yves',
  'items': [
    {
      'product_id': 'cement-1',
      'product_name': 'Cement',
      'quantity': 2,
      'requires_loading': true,
      'heavy_verified': true,
    },
    if (hasLightItem)
      {
        'product_id': 'brush-1',
        'product_name': 'Brush',
        'quantity': 1,
        'requires_loading': false,
        'picked': false,
      },
  ],
});

void main() {
  test('heavy-only orders show their Bodegero as assigned staff', () {
    expect(
      orderAssignedStaffLabel(_order(hasLightItem: false)),
      'Bodegero: Yves',
    );
    expect(orderAssignedStaffLabel(_order(hasLightItem: true)), 'Unassigned');
  });

  testWidgets('loading proof opens when the database base64 wraps lines', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final encoded = base64Encode(img.encodeJpg(img.Image(width: 1, height: 1)));
    final wrapped = RegExp(
      '.{1,76}',
    ).allMatches(encoded).map((match) => match.group(0)!).join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderDetailsDrawer(
            order: _order(hasLightItem: false),
            inventory: const [],
            onOpenQueue: () {},
            loadLoadingProof: (_) async => {
              'truck_plate': '2321',
              'loaded_quantities': {'cement-1': 2},
              'photo_base64': wrapped,
            },
          ),
        ),
      ),
    );

    expect(find.text('Not required'), findsOneWidget);
    await tester.ensureVisible(find.text('View loading photo and counts'));
    await tester.tap(find.text('View loading photo and counts'));
    await tester.pumpAndSettle();

    expect(find.text('Truck: 2321'), findsOneWidget);
    expect(find.textContaining('Cement: 2'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
