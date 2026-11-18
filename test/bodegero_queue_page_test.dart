import 'dart:async';

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
  Future<Map<String, dynamic>> startOrderLoadingClock(String orderId) async => {
    'paused': false,
  };

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

class _ClaimQueueController extends _QueueController {
  _ClaimQueueController(super.order) {
    activeLocationId = 'store-1';
  }

  final updates = StreamController<List<CustomerOrder>>.broadcast();
  final moreOrders = <CustomerOrder>[];
  Completer<void>? firstClaimGate;
  CustomerOrder? claimedOrder;
  bool failClaim = false;
  int claimCount = 0;
  int clockCount = 0;

  @override
  bool get hasUsableOrdersSnapshot => true;

  @override
  List<CustomerOrder> get currentOrders => [
    claimedOrder ?? order,
    ...moreOrders,
  ];

  @override
  Stream<List<CustomerOrder>> get orderSnapshots => updates.stream;

  @override
  Stream<List<CustomerOrder>> streamOrders() => updates.stream;

  @override
  CustomerOrder? orderById(Object? orderId) =>
      orderId?.toString() == order.id ? claimedOrder ?? order : null;

  @override
  Future<CustomerOrder> claimOrderLoading(String orderId) async {
    claimCount++;
    if (orderId == order.id) await firstClaimGate?.future;
    if (failClaim) throw StateError('loading_claim_conflict');
    final claimed = CustomerOrder.fromJson({
      'id': orderId,
      'status': 'pending',
      'created_at': '2026-11-14T08:00:00Z',
      'assigned_bodegero_id': 'bodegero-1',
      'assigned_bodegero_name': 'Test Bodegero',
      'items': [
        {
          'product_id': 'cement-1',
          'product_name': 'Cement',
          'quantity': 2,
          'requires_loading': true,
        },
      ],
    });
    if (orderId == order.id) {
      claimedOrder = claimed;
    } else {
      moreOrders.removeWhere((item) => item.id == orderId);
      moreOrders.add(claimed);
    }
    updates.add(currentOrders);
    return claimed;
  }

  @override
  Future<Map<String, dynamic>> startOrderLoadingClock(String orderId) async {
    clockCount++;
    return {'paused': false};
  }

  @override
  Future<void> retryOrdersSnapshot() async {}
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
    expect(find.byTooltip('Account menu'), findsOneWidget);
    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    expect(find.text('Log out'), findsOneWidget);
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
    final openCard = find.ancestor(
      of: find.text('#OPEN-123'),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(openCard.first).onTap, isNull);
    expect(find.text('Claim'), findsNothing);
    await tester.tap(find.byTooltip('Switch to Available'));
    await tester.pumpAndSettle();
    expect(find.text('Available'), findsOneWidget);
    expect(tester.widget<InkWell>(openCard.first).onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Opening an unassigned loading order claims and opens it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    final controller = _ClaimQueueController(openOrder);
    addTearDown(controller.updates.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(controller: controller, onLogout: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Claim'), findsNothing);

    await tester.tap(find.text('#OPEN-123'));
    await tester.pumpAndSettle();

    expect(controller.claimCount, 1);
    expect(controller.clockCount, 1);
    expect(controller.claimedOrder?.assignedBodegeroId, 'bodegero-1');
    expect(find.text('Load onto truck'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Available Bodegero claims a pending order after login', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final order = CustomerOrder.fromJson({
      'id': 'auto-123456',
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
    final controller = _ClaimQueueController(order);
    final presence = _Presence();
    addTearDown(controller.updates.close);
    addTearDown(presence.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(
          controller: controller,
          presenceService: presence,
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.claimCount, 1);
    expect(controller.claimedOrder?.assignedBodegeroId, 'bodegero-1');
    expect(controller.clockCount, 0);
    expect(find.text('Start loading'), findsOneWidget);
    expect(find.text('Claim'), findsNothing);
  });

  testWidgets('An order arriving during a claim is also claimed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    CustomerOrder unassigned(String id) => CustomerOrder.fromJson({
      'id': id,
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
    final controller = _ClaimQueueController(unassigned('first-order'))
      ..firstClaimGate = Completer<void>();
    final presence = _Presence();
    addTearDown(controller.updates.close);
    addTearDown(presence.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(
          controller: controller,
          presenceService: presence,
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();
    expect(controller.claimCount, 1);

    controller.moreOrders.add(unassigned('second-order'));
    controller.updates.add(controller.currentOrders);
    await tester.pump();
    controller.firstClaimGate!.complete();
    await tester.pumpAndSettle();

    expect(controller.claimCount, 2);
    expect(controller.moreOrders.single.assignedBodegeroId, 'bodegero-1');
    expect(find.text('Start loading'), findsNWidgets(2));
  });

  testWidgets('A lost claim leaves the order unopened', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    final controller = _ClaimQueueController(openOrder)..failClaim = true;
    addTearDown(controller.updates.close);
    await tester.pumpWidget(
      MaterialApp(
        home: BodegeroQueuePage(controller: controller, onLogout: () {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('#OPEN-123'));
    await tester.pumpAndSettle();

    expect(controller.claimCount, 1);
    expect(controller.clockCount, 0);
    expect(find.text('Load onto truck'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    testWidgets('Bodegero queue and checklist fit at ${size.width}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
      expect(
        MediaQuery.sizeOf(tester.element(find.byType(BodegeroQueuePage))).width,
        size.width,
      );
      if (size.width < 900) {
        expect(find.text('Open orders'), findsOneWidget);
      } else {
        expect(find.text('Queue'), findsOneWidget);
        expect(find.text('Map'), findsOneWidget);
        expect(find.text('History'), findsOneWidget);
        expect(find.text('Request'), findsOneWidget);
        expect(
          tester
              .widget<Scaffold>(find.byType(Scaffold).first)
              .bottomNavigationBar,
          isNull,
        );
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Start loading'));
      await tester.pumpAndSettle();

      expect(find.text('Load onto truck'), findsOneWidget);
      expect(find.text('Scan shelf QR'), findsOneWidget);
      expect(find.text('Truck loading proof'), findsOneWidget);
      if (size.width >= 900) {
        expect(find.text('Loading list · scan and count'), findsOneWidget);
        expect(find.text('Store map · heavy item locations'), findsOneWidget);
        expect(find.text('Queue'), findsOneWidget);
        await tester.tap(find.byTooltip('Back to queue'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Map'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Store map'), findsOneWidget);
        await tester.tap(find.text('Queue'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Your loading orders'), findsOneWidget);
      }
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
    expect(find.text('Me'), findsNothing);
    expect(
      tester
          .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
          .items,
      hasLength(4),
    );

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

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Test Bodegero'), findsWidgets);
    expect(find.textContaining('Bodegero'), findsWidgets);
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('Your loading orders'), findsOneWidget);
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
