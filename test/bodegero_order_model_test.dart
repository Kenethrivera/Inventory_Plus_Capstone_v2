import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';

void main() {
  test('heavy loading snapshot survives order decoding', () {
    final order = CustomerOrder.fromJson({
      'id': 'order-1',
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_bodegero_id': '42',
      'assigned_bodegero_name': 'Bodegero One',
      'loading_verified_at': '2026-11-14T08:10:00Z',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 5,
          'requires_loading': true,
          'heavy_verified': true,
        },
        {
          'product_id': 'brush-1',
          'product_name': 'Brush',
          'quantity': 1,
          'picked': true,
          'requires_loading': false,
        },
      ],
    });

    expect(order.assignedBodegeroId, '42');
    expect(order.loadingVerifiedAt?.toUtc(), DateTime.utc(2026, 11, 14, 8, 10));
    expect(
      order.items.singleWhere((item) => item.requiresLoading).heavyVerified,
      isTrue,
    );
    expect(
      order.items.singleWhere((item) => !item.requiresLoading).picked,
      isTrue,
    );
  });
}
