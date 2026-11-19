import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/ui/widgets/operations_overview.dart';

void main() {
  testWidgets('mobile puts attention panel immediately after sales graph', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OperationsOverview(
            name: 'Admin',
            orders: const [],
            items: const [],
            approvals: const [],
            approvalCount: 0,
            presence: null,
            onOrders: () {},
            onApprovals: () {},
            onInventory: () {},
            onStaff: () {},
            onPayments: () {},
          ),
        ),
      ),
    );

    final salesY = tester.getTopLeft(find.text('Sales today')).dy;
    final attentionY = tester.getTopLeft(find.text('Needs your attention')).dy;
    final queueY = tester.getTopLeft(find.text('Order queue')).dy;
    expect(salesY, lessThan(attentionY));
    expect(attentionY, lessThan(queueY));
    expect(tester.takeException(), isNull);
  });
}
