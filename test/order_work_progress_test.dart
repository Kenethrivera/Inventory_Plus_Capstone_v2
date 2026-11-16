import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/order_work_progress.dart';

CustomerOrder _mixedOrder({required bool lightPicked, required bool loaded}) =>
    CustomerOrder.fromJson({
      'id': 'shared-order',
      'status': loaded && lightPicked ? 'prepared' : 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'loading_verified_at': loaded ? '2026-11-14T08:20:00Z' : null,
      'assigned_helper_id': 'helper-1',
      'assigned_bodegero_id': 'bodegero-1',
      'items': [
        {
          'product_id': 'brush',
          'product_name': 'Brush',
          'quantity': 1,
          'picked': lightPicked,
          'requires_loading': false,
        },
        {
          'product_id': 'cement',
          'product_name': 'Cement',
          'quantity': 2,
          'heavy_verified': loaded,
          'requires_loading': true,
        },
      ],
    });

void main() {
  test('mixed order needs both independent assignments complete', () {
    for (final lightPicked in [false, true]) {
      for (final loaded in [false, true]) {
        final progress = OrderWorkProgress.fromOrder(
          _mixedOrder(lightPicked: lightPicked, loaded: loaded),
        );
        expect(progress.isMixed, isTrue);
        expect(progress.lightComplete, lightPicked);
        expect(progress.heavyComplete, loaded);
        expect(progress.bothComplete, lightPicked && loaded);
      }
    }
  });

  test('each worker sees the other assignment progress', () {
    final progress = OrderWorkProgress.fromOrder(
      _mixedOrder(lightPicked: true, loaded: false),
    );
    expect(progress.helperSummary, '1/1 light items picked');
    expect(progress.bodegeroSummary, contains('loading pending'));
  });
}
