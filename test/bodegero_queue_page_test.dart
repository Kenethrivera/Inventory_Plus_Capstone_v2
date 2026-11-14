import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/bodegero_queue_page.dart';
import 'package:inventory_plus/ui/order_queue_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _QueueController extends InventoryController {
  _QueueController(this.order) {
    currentUserId = 'bodegero-1';
    currentUserName = 'Test Bodegero';
  }

  final CustomerOrder order;
  bool statusUpdateCalled = false;

  @override
  List<CustomerOrder> get currentOrders => [order];

  @override
  Stream<List<CustomerOrder>> streamOrders() => Stream.value([order]);

  @override
  Future<void> fetchMapLayout({bool force = false}) async {}

  @override
  CustomerOrder? orderById(Object? orderId) =>
      orderId?.toString() == order.id ? order : null;

  @override
  Future<void> updateOrderStatus(
    String orderId,
    String newStatus, {
    String? expectedStatus,
  }) async {
    statusUpdateCalled = true;
  }
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

  final order = CustomerOrder.fromJson({
    'id': 'order-123456',
    'status': 'pending',
    'created_at': '2026-11-14T08:00:00Z',
    'assigned_bodegero_id': 'bodegero-1',
    'items': [
      {
        'product_id': 'cement-1',
        'product_name': 'Portland cement 40kg',
        'quantity': 5,
        'unit': 'bags',
        'requires_loading': true,
        'heavy_verified': false,
      },
    ],
  });

  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    testWidgets('Bodegero queue and checklist fit at ${size.width}px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: BodegeroQueuePage(
            controller: _QueueController(order),
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Your loading orders'), findsOneWidget);
      expect(find.text('Open orders'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Start loading'));
      await tester.pumpAndSettle();

      expect(find.text('Load onto truck'), findsOneWidget);
      expect(find.text('Scan shelf QR'), findsOneWidget);
      expect(find.text('Truck loading proof'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('one mixed order appears in both worker queues', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final mixed = CustomerOrder.fromJson({
      'id': 'shared-123456',
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_helper_id': 'helper-1',
      'assigned_helper_name': 'Helper One',
      'assigned_bodegero_id': 'bodegero-1',
      'assigned_bodegero_name': 'Bodegero One',
      'items': [
        {
          'product_id': 'brush-1',
          'product_name': 'Brush',
          'quantity': 1,
          'picked': false,
          'requires_loading': false,
        },
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
          'heavy_verified': false,
        },
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(
          controller: _QueueController(mixed),
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('#SHARED-1'), findsOneWidget);
    expect(
      find.textContaining('Helper: 0/1 light items picked'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Start loading'));
    await tester.pumpAndSettle();
    final helperProgress = find.textContaining(
      'Helper: 0/1 light items picked',
    );
    final beforeScroll = tester.getTopLeft(helperProgress).dy;
    final headerBeforeScroll = tester.getTopLeft(find.text('#SHARED-1')).dy;
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(helperProgress).dy, lessThan(beforeScroll));
    expect(tester.getTopLeft(find.text('#SHARED-1')).dy, headerBeforeScroll);

    final helperController = _QueueController(mixed)
      ..currentUserId = 'helper-1'
      ..currentUserName = 'Helper One';
    await tester.pumpWidget(
      MaterialApp(home: OrderQueuePage(controller: helperController)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('SHARED-1'), findsOneWidget);
    expect(
      find.textContaining('Bodegero: 0/1 heavy QR verified'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Helper accepts an order Bodegero already made ready', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final ready = CustomerOrder.fromJson({
      'id': 'shared-ready',
      'status': 'prepared',
      'created_at': '2026-11-14T08:00:00Z',
      'loading_verified_at': '2026-11-14T08:15:00Z',
      'items': [
        {
          'product_id': 'brush-1',
          'product_name': 'Brush',
          'quantity': 1,
          'picked': true,
          'requires_loading': false,
        },
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
          'heavy_verified': true,
        },
      ],
    });
    final controller = _QueueController(ready)..currentUserId = 'helper-1';
    var finished = false;

    await tester.pumpWidget(
      MaterialApp(
        home: OrderChecklistPage(
          order: ready,
          controller: controller,
          pickedItems: {'brush-1'},
          onItemVerified: (_) async {},
          onBack: () {},
          onFinish: () => finished = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Order ready · Back to queue'));
    await tester.pump();

    expect(finished, isTrue);
    expect(controller.statusUpdateCalled, isFalse);
    expect(tester.takeException(), isNull);
  });
}
