import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/order_assignment_status.dart';

CustomerOrder _order({
  String status = 'pending',
  bool light = true,
  bool heavy = false,
  String? helperId,
  String? bodegeroId,
}) => CustomerOrder(
  id: 'order-1',
  status: status,
  createdAt: DateTime.utc(2026, 11, 18),
  assignedHelperId: helperId,
  assignedBodegeroId: bodegeroId,
  items: [
    if (light)
      CustomerOrderItem(productId: 'light', productName: 'Light', quantity: 1),
    if (heavy)
      CustomerOrderItem(
        productId: 'heavy',
        productName: 'Heavy',
        quantity: 1,
        requiresLoading: true,
      ),
  ],
);

void main() {
  test('waiting requires every applicable staff assignment', () {
    expect(orderActivityStatusLabel(_order()), 'Waiting');
    expect(orderActivityStatusLabel(_order(helperId: 'helper')), 'Assigned');

    expect(
      orderActivityStatusLabel(_order(light: false, heavy: true)),
      'Waiting',
    );
    expect(
      orderActivityStatusLabel(
        _order(light: false, heavy: true, bodegeroId: 'bodegero'),
      ),
      'Assigned',
    );

    expect(
      orderActivityStatusLabel(
        _order(light: true, heavy: true, helperId: 'helper'),
      ),
      'Waiting',
    );
    expect(
      orderActivityStatusLabel(
        _order(light: true, heavy: true, bodegeroId: 'bodegero'),
      ),
      'Waiting',
    );
    expect(
      orderActivityStatusLabel(
        _order(
          light: true,
          heavy: true,
          helperId: 'helper',
          bodegeroId: 'bodegero',
        ),
      ),
      'Assigned',
    );
  });

  test('solo picking does not require a helper', () {
    expect(
      orderActivityStatusLabel(_order(status: 'solo_picking')),
      'Preparing',
    );
    expect(
      orderActivityStatusLabel(_order(status: 'solo_picking', heavy: true)),
      'Waiting',
    );
    expect(
      orderActivityStatusLabel(_order(status: 'completed', heavy: true)),
      'Completed',
    );
  });
}
