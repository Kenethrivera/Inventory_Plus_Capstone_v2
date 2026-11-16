import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/logic/staff_performance.dart';
import 'package:inventory_plus/services/staff_presence_service.dart';
import 'package:inventory_plus/ui/staff_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _AdminController extends InventoryController {
  _AdminController(this.assignedOrder);

  final CustomerOrder assignedOrder;
  final _orders = StreamController<List<CustomerOrder>>.broadcast();
  List<CustomerOrder> _current = const [];
  int refreshCount = 0;

  @override
  List<CustomerOrder> get currentOrders => _current;

  @override
  Stream<List<CustomerOrder>> streamOrders() async* {
    yield _current;
    yield* _orders.stream;
  }

  @override
  Future<void> retryOrdersSnapshot() async {
    refreshCount++;
    _current = [assignedOrder];
    _orders.add(_current);
  }

  @override
  Stream<List<Map<String, dynamic>>> streamStaffConfiguration() =>
      Stream.value([
        {'id': 7, 'name': 'Yves', 'role': 'bodegero', 'is_active': true},
      ]);

  @override
  Future<StaffPerformanceSnapshot> loadStaffPerformance({
    required StaffPerformanceRole role,
    required DateTime periodStart,
    required DateTime periodEnd,
    bool forceRefresh = false,
  }) async => StaffPerformanceSnapshot.fromJson(
    const {},
    role: role,
    periodStart: periodStart,
    periodEnd: periodEnd,
  );

  Future<void> close() => _orders.close();
}

class _OnlinePresence extends StaffPresenceService {
  _OnlinePresence()
    : super(
        supabase: Supabase.instance.client,
        locationId: 'store-1',
        userId: 'admin-1',
        userName: 'Admin',
        userRole: 'admin',
      );

  @override
  List<Map<String, dynamic>> get activeStaff => [
    {'user_id': '7', 'user_role': 'bodegero', 'is_online': true},
  ];
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

  testWidgets('Admin Staff refreshes assigned Bodegero status on opening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final order = CustomerOrder.fromJson({
      'id': 'heavy-1',
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_bodegero_id': '7',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
        },
      ],
    });
    final controller = _AdminController(order);
    final presence = _OnlinePresence();
    addTearDown(() async {
      presence.dispose();
      await controller.close();
    });

    Widget page(bool active) => MaterialApp(
      home: Scaffold(
        body: StaffPage(
          controller: controller,
          isActive: active,
          presence: presence,
        ),
      ),
    );

    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(find.text('Available'), findsOneWidget);
    expect(controller.refreshCount, 0);

    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(controller.refreshCount, 1);
    expect(find.text('Busy'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
