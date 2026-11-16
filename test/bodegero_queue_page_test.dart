import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/logic/bodegero_loading_history.dart';
import 'package:inventory_plus/logic/inventory_approval.dart';
import 'package:inventory_plus/notifications/notification_controller.dart';
import 'package:inventory_plus/notifications/notification_provider.dart';
import 'package:inventory_plus/notifications/notification_repository.dart';
import 'package:inventory_plus/notifications/notification_service.dart';
import 'package:inventory_plus/services/staff_presence_service.dart';
import 'package:inventory_plus/ui/bodegero_queue_page.dart';
import 'package:inventory_plus/ui/order_queue_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _QueueController extends InventoryController {
  _QueueController(this.order) {
    currentUserId = 'bodegero-1';
    currentUserName = 'Test Bodegero';
    currentUserRole = 'bodegero';
  }

  final CustomerOrder order;
  bool statusUpdateCalled = false;
  int proofFetchCount = 0;

  @override
  List<CustomerOrder> get currentOrders => [order];

  @override
  Stream<List<CustomerOrder>> streamOrders() => Stream.value([order]);

  @override
  Future<void> fetchMapLayout({bool force = false}) async {}

  @override
  Future<BodegeroLoadingHistoryPage> fetchMyLoadingHistory({
    int page = 1,
    String search = '',
  }) async => BodegeroLoadingHistoryPage(
    records: [
      BodegeroLoadingRecord(
        orderId: 'loaded-123456',
        truckPlate: 'ABC-1234',
        status: 'prepared',
        capturedAt: DateTime.utc(2026, 11, 14, 9),
        items: const [BodegeroLoadingItem(name: 'Cement', quantity: 2)],
      ),
      BodegeroLoadingRecord(
        orderId: 'older-123456',
        truckPlate: 'XYZ-88',
        status: 'completed',
        capturedAt: DateTime.utc(2026, 11, 13, 9),
        items: const [BodegeroLoadingItem(name: 'Roofing', quantity: 3)],
      ),
    ],
    totalCount: 2,
    page: page,
    pageSize: 20,
  );

  @override
  Future<Map<String, dynamic>?> getOrderLoadingProof(String orderId) async {
    proofFetchCount++;
    return {
      'truck_plate': 'ABC-1234',
      'photo_base64':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWQAAAABJRU5ErkJggg==',
    };
  }

  @override
  Future<List<InventoryApprovalRequest>>
  fetchMyInventoryApprovalRequests() async => [];

  @override
  Stream<List<InventoryItem>> streamInventory() => Stream.value([]);

  @override
  Future<CurrentUserProfileSnapshot?> refreshCurrentUserProfile() async => null;

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

class _Presence extends StaffPresenceService {
  _Presence()
    : super(
        supabase: Supabase.instance.client,
        locationId: 'store-1',
        userId: 'bodegero-1',
        userName: 'Test Bodegero',
        userRole: 'bodegero',
      );

  bool _onBreak = false;

  @override
  bool get isStarted => true;

  @override
  bool get isOnBreak => _onBreak;

  @override
  Future<void> setOnBreak(bool onBreak) async {
    _onBreak = onBreak;
    notifyListeners();
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

  test('Bodegero may use the stock request workflow', () {
    expect(_QueueController(order).canRequestInventoryApproval, isTrue);
  });

  testWidgets('Bodegero header shows Busy for assigned loading', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final presence = _Presence();
    addTearDown(presence.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(
          controller: _QueueController(order),
          presenceService: presence,
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Busy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bodegero mobile header shows notifications and logout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final presence = _Presence();
    final notifications = NotificationController(
      NotificationService(
        SupabaseNotificationRepository(
          supabase: Supabase.instance.client,
          locationId: 'store-1',
          userId: 'bodegero-1',
          userRole: 'bodegero',
          recipientId: 'bodegero-1',
          sessionToken: 'test-session',
        ),
      ),
    );
    addTearDown(presence.dispose);
    addTearDown(notifications.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationProvider(
          controller: notifications,
          child: BodegeroQueuePage(
            controller: _QueueController(order),
            presenceService: presence,
            onLogout: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Notifications'), findsOneWidget);
    expect(find.byTooltip('Log out'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bodegero can switch between Available and On break', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final presence = _Presence();
    addTearDown(presence.dispose);
    final openOrder = CustomerOrder.fromJson({
      'id': 'open-123456',
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(
          controller: _QueueController(openOrder),
          presenceService: presence,
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Available'), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to On break'));
    await tester.pumpAndSettle();
    expect(find.text('On break'), findsOneWidget);
    expect(find.textContaining("You're on break"), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Claim'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Switch to Available'));
    await tester.pumpAndSettle();
    expect(find.text('Available'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Claim'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
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

  testWidgets('Bodegero tabs open loading history, requests, and profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _QueueController(order);
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(controller: controller, onLogout: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Request'), findsOneWidget);
    expect(find.text('Me'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('My loading history'), findsOneWidget);
    expect(find.text('SAT, NOV 14'), findsOneWidget);
    expect(find.text('FRI, NOV 13'), findsOneWidget);
    expect(find.textContaining('Truck ABC-1234'), findsOneWidget);
    expect(find.text('Cement · 2 loaded'), findsOneWidget);
    expect(find.text('prepared'), findsOneWidget);
    expect(find.text('completed'), findsOneWidget);
    expect(controller.proofFetchCount, greaterThan(0));
    expect(find.byType(Image), findsWidgets);
    await tester.tap(find.text('#LOADED-1'));
    await tester.pumpAndSettle();
    expect(find.text('LOADING PROOF'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('#LOADED-1'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Dialog>(find.byType(Dialog)).backgroundColor,
      Colors.white,
    );
    expect(find.text('TRUCK'), findsOneWidget);
    expect(find.text('LOADED ITEMS'), findsOneWidget);
    expect(find.text('LOADING PHOTO'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final fetchesBeforeZoom = controller.proofFetchCount;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    expect(controller.proofFetchCount, fetchesBeforeZoom);
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Request'));
    await tester.pumpAndSettle();
    expect(find.text('Stock request'), findsOneWidget);

    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();
    expect(find.text('Test Bodegero'), findsWidgets);
    expect(find.textContaining('Bodegero'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

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
