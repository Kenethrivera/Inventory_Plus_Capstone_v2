import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/services/staff_presence_service.dart';
import 'package:inventory_plus/ui/order_queue_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _HelperController extends InventoryController {
  _HelperController(this.order) {
    currentUserId = 'helper-1';
    currentUserName = 'Helper One';
    currentUserRole = 'helper';
    activeLocationId = 'store-1';
  }

  CustomerOrder order;
  final updates = StreamController<List<CustomerOrder>>.broadcast();
  int claimCount = 0;
  bool loseClaim = false;

  @override
  bool get hasUsableOrdersSnapshot => true;

  @override
  List<CustomerOrder> get currentOrders => [order];

  @override
  Stream<List<CustomerOrder>> get orderSnapshots => updates.stream;

  @override
  Stream<List<CustomerOrder>> streamOrders() async* {
    yield currentOrders;
    yield* updates.stream;
  }

  @override
  Future<void> fetchMapLayout({bool force = false}) async {}

  @override
  Future<bool> claimOrderForCurrentHelper(Object orderId) async {
    claimCount++;
    if (loseClaim) return false;
    order = CustomerOrder.fromJson({
      'id': order.id,
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_helper_id': 'helper-1',
      'assigned_helper_name': 'Helper One',
      'items': [
        {
          'product_id': 'brush-1',
          'product_name': 'Brush',
          'quantity': 1,
          'requires_loading': false,
        },
      ],
    });
    updates.add(currentOrders);
    return true;
  }
}

class _HelperPresence extends StaffPresenceService {
  _HelperPresence()
    : super(
        supabase: Supabase.instance.client,
        locationId: 'store-1',
        userId: 'helper-1',
        userName: 'Helper One',
        userRole: 'helper',
      );

  @override
  bool get isStarted => true;

  @override
  bool get isOnBreak => false;
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

  testWidgets('Helper claims an open order on login without a tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _HelperController(
      CustomerOrder.fromJson({
        'id': 'open-order-1',
        'status': 'pending',
        'created_at': '2026-11-14T08:00:00Z',
        'items': [
          {
            'product_id': 'brush-1',
            'product_name': 'Brush',
            'quantity': 1,
            'requires_loading': false,
          },
        ],
      }),
    );
    final presence = _HelperPresence();
    addTearDown(controller.updates.close);
    addTearDown(presence.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: OrderQueuePage(controller: controller, presenceService: presence),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.claimCount, 1);
    expect(controller.order.assignedHelperId, 'helper-1');
    expect(find.text('Assigned to you'), findsOneWidget);
    expect(find.text('Claim'), findsNothing);
  });
}
