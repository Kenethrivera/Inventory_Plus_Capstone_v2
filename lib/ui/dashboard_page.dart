import 'dart:async';

import 'package:flutter/material.dart';

import '../data/ai_insights_service.dart';
import '../data/inventory.dart';
import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import '../services/app_logger.dart';
import '../services/staff_presence_service.dart';
import 'widgets/operations_overview.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.controller,
    required this.aiService,
    required this.onViewTransactions,
    required this.onOpenQueue,
    required this.onViewActivity,
    required this.onOpenForecasting,
    required this.onOpenApprovals,
    required this.onOpenInventory,
    required this.onOpenStaff,
    required this.isActive,
    this.staffPresence,
  });

  final InventoryController controller;
  final AIInsightsService aiService;
  final VoidCallback onViewTransactions;
  final VoidCallback onOpenQueue;
  final VoidCallback onViewActivity;
  final VoidCallback onOpenForecasting;
  final VoidCallback onOpenApprovals;
  final VoidCallback onOpenInventory;
  final VoidCallback onOpenStaff;
  final StaffPresenceService? staffPresence;
  final bool isActive;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<CustomerOrder> _orders = const [];
  List<InventoryItem> _items = const [];
  InventoryApprovalPage? _approvalPage;
  StreamSubscription<List<CustomerOrder>>? _ordersSubscription;
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  StreamSubscription<InventoryApprovalPage>? _approvalSubscription;

  @override
  void initState() {
    super.initState();
    _bindController();
    unawaited(_refreshApprovals());
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unbindController();
      _approvalPage = null;
      _bindController();
    }
    if ((!oldWidget.isActive && widget.isActive) ||
        oldWidget.controller != widget.controller) {
      unawaited(_refreshApprovals());
    }
  }

  void _bindController() {
    _orders = widget.controller.currentOrders;
    _items = widget.controller.allItems;
    _ordersSubscription = widget.controller.orderSnapshots.listen((orders) {
      if (mounted) setState(() => _orders = orders);
    });
    _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
      if (mounted) setState(() => _items = widget.controller.allItems);
    });
    _approvalSubscription = widget.controller.approvalPageSnapshots.listen((
      page,
    ) {
      if (mounted &&
          widget.isActive &&
          page.key.status == InventoryApprovalStatus.pending) {
        setState(() => _approvalPage = page);
      }
    });
  }

  void _unbindController() {
    unawaited(_ordersSubscription?.cancel());
    unawaited(_inventorySubscription?.cancel());
    unawaited(_approvalSubscription?.cancel());
    _ordersSubscription = null;
    _inventorySubscription = null;
    _approvalSubscription = null;
  }

  Future<void> _refreshApprovals() async {
    if (!widget.isActive || !widget.controller.isAdmin) return;
    final controller = widget.controller;
    try {
      final page = await controller.activateApprovalPage(
        status: InventoryApprovalStatus.pending,
        pageSize: 3,
        force: true,
      );
      if (mounted &&
          widget.isActive &&
          identical(controller, widget.controller)) {
        setState(() => _approvalPage = page);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Dashboard approvals failed to load',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _unbindController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OperationsOverview(
    name: widget.controller.currentUserName ?? 'Admin',
    orders: _orders,
    orderUpdates: widget.controller.orderSnapshots,
    items: _items,
    approvals: _approvalPage?.requests ?? const <InventoryApprovalRequest>[],
    approvalCount: _approvalPage?.totalCount ?? 0,
    presence: widget.staffPresence,
    onOrders: widget.onOpenQueue,
    onApprovals: widget.onOpenApprovals,
    onInventory: widget.onOpenInventory,
    onStaff: widget.onOpenStaff,
    onPayments: widget.onViewTransactions,
  );
}
