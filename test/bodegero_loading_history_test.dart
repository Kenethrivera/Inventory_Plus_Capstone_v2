import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/bodegero_loading_history.dart';

void main() {
  test('loading history parses worker-safe records and page count', () {
    final page = BodegeroLoadingHistoryPage.fromJson({
      'total_count': 21,
      'page': 2,
      'page_size': 20,
      'records': [
        {
          'order_id': 'order-1',
          'truck_plate': 'ABC-1234',
          'status': 'prepared',
          'captured_at': '2026-11-14T09:00:00Z',
          'items': [
            {'product_name': 'Cement', 'quantity': 2},
          ],
        },
      ],
    });
    expect(page.totalPages, 2);
    expect(page.records.single.truckPlate, 'ABC-1234');
    expect(page.records.single.items.single.name, 'Cement');
    expect(page.records.single.items.single.quantity, 2);
  });
}
