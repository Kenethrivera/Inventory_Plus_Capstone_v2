import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
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

  testWidgets(
    'sales chart shows the selected hour and running total on hover',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now();
      final orders = [
        CustomerOrder(
          id: 'early',
          items: const [],
          status: 'completed',
          createdAt: DateTime(now.year, now.month, now.day),
          totalAmount: 50,
        ),
        CustomerOrder(
          id: 'latest',
          items: const [],
          status: 'completed',
          createdAt: DateTime(now.year, now.month, now.day, now.hour),
          totalAmount: 123.45,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OperationsOverview(
              name: 'Admin',
              orders: orders,
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

      final plot = find.byKey(const ValueKey('sales-chart-hover-region'));
      final bounds = tester.getRect(plot);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(
        location: Offset(bounds.right + 10, bounds.center.dy),
      );
      await mouse.moveTo(Offset(bounds.right - 1, bounds.center.dy));
      await tester.pump();

      expect(find.byKey(const ValueKey('sales-chart-tooltip')), findsOneWidget);
      expect(find.text('Running total: ₱173.45'), findsOneWidget);
      final selectedHour = now.hour == 0 ? 1 : now.hour;
      final displayHour = selectedHour % 12 == 0 ? 12 : selectedHour % 12;
      expect(
        find.text('$displayHour ${selectedHour < 12 ? 'AM' : 'PM'}'),
        findsWidgets,
      );

      if (now.hour > 0) {
        await mouse.moveTo(Offset(bounds.left + 1, bounds.center.dy));
        await tester.pump();
        expect(find.text('Running total: ₱50.00'), findsOneWidget);
      }

      await mouse.moveTo(Offset(bounds.right + 10, bounds.center.dy));
      await tester.pump();
      expect(find.byKey(const ValueKey('sales-chart-tooltip')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
