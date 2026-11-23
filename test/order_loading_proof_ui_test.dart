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
  test('cashier loading instructions reach the Bodegero order snapshot', () {
    final order = CustomerOrder.fromJson({
      'id': 'order-1',
      'created_at': '2026-11-14T08:00:00Z',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
          'truck_identifier': 'TRUCK-1',
          'bodegero_note': 'Load two bags and photograph the count.',
        },
      ],
    });
    expect(order.truckIdentifier, 'TRUCK-1');
    expect(order.bodegeroNote, 'Load two bags and photograph the count.');
  });

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
    expect(find.text('Open order queue'), findsNothing);
    await tester.ensureVisible(find.text('View truck and item photos'));
    await tester.tap(find.text('View truck and item photos'));
    await tester.pumpAndSettle();

    expect(find.text('2321'), findsOneWidget);
    expect(find.text('Cement · 2 loaded'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cashier sees both proof photos before completing an order', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final photo = base64Encode(img.encodeJpg(img.Image(width: 1, height: 1)));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderDetailsDrawer(
            order: _order(hasLightItem: false),
            inventory: const [],
            loadLoadingProof: (_) async => {
              'truck_plate': 'TRUCK-1',
              'loaded_quantities': {'cement-1': 2},
              'photo_base64': photo,
              'truck_photo_base64': photo,
            },
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('View truck and item photos'));
    await tester.tap(find.text('View truck and item photos'));
    await tester.pumpAndSettle();
    expect(find.text('Truck identifier'), findsOneWidget);
    expect(find.text('Loaded items'), findsOneWidget);
    expect(find.text('TRUCK IDENTIFIER PHOTO'), findsOneWidget);
    expect(find.text('LOADED ITEMS AND QUANTITIES PHOTO'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('Loaded items'));
    await tester.pump();
    expect(find.text('LOADED ITEMS AND QUANTITIES PHOTO'), findsOneWidget);
    expect(find.text('TRUCK IDENTIFIER PHOTO'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
