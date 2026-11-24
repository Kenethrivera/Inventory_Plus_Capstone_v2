import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../data/inventory.dart';
import '../logic/helper_assignment.dart';
import '../logic/staff_availability.dart';
import '../logic/discount_calculation.dart';
import '../logic/inventory_controller.dart';
import '../logic/payment_reference.dart';
import '../services/order_auto_assignment_service.dart';
import '../services/staff_presence_service.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'widgets/helper_assignment_selector.dart';
import 'widgets/order_checklist_view.dart';
import 'widgets/order_details_drawer.dart';
import 'widgets/cashier_order_preparation.dart';
import 'widgets/gcash_qr_image.dart';
import 'widgets/app_styled_dropdown.dart';
import 'visual_search_page.dart';
import 'package:inventory_plus/notifications/notification_provider.dart';
import 'dart:async';
import 'dart:math' as math;

import '../logic/inventory_approval.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

const Color _cashierAccent = Color(0xFFC83D08);
const Color _cashierTint = Color(0xFFFFF1E9);
const Color _cashierBorder = Color(0xFFE3DED7);
const Color _cashierInk = Color(0xFF211F1D);
// Neutral surfaces match the Inventory and Admin pages. Orange stays an accent.
const Color _cashierPrimary = Color(0xFF1C1C1C);
const Color _cashierMuted = Color(0xFF827872);
const Color _cashierSurface = Color(0xFFF7F5F3);
const Color _cashierWarmBorder = Color(0xFFE7E1DB);
// The Details dialog remains available for a later release, but its button is
// hidden from the POS table for now.
const bool _posShowDetailsButton = false;

class _CompletedPayment {
  const _CompletedPayment({
    required this.paymentMode,
    required this.cashReceived,
    required this.change,
    required this.reference,
    required this.gcashDestinationName,
    required this.gcashDestinationNumber,
    required this.times,
  });

  final String paymentMode;
  final double cashReceived;
  final double change;
  final String? reference;
  final String? gcashDestinationName;
  final String? gcashDestinationNumber;
  final ({DateTime createdAt, DateTime completedAt}) times;
}

class PosCartPage extends StatefulWidget {
  final InventoryController controller;
  final StaffPresenceService? presenceService;
  final OrderAutoAssignmentService? autoAssignmentService;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;

  const PosCartPage({
    super.key,
    required this.controller,
    this.presenceService,
    this.autoAssignmentService,
    this.targetOrderId,
    this.onOrderOpened,
  });
  @override
  State<PosCartPage> createState() => _PosCartPageState();
}

class _PosCartPageState extends State<PosCartPage> {
  String _searchQuery = '';
  final TextEditingController _productSearchController =
      TextEditingController();
  final TextEditingController _truckIdentifierController =
      TextEditingController();
  final TextEditingController _bodegeroNoteController = TextEditingController();
  final Set<String> _reviewedLoadingProofOrderIds = <String>{};
  final ValueNotifier<int> _proofReviewVersion = ValueNotifier<int>(0);
  String _selectedCategory = 'All';
  final Map<String, double> _cart = {};
  bool _isProcessingCart = false;
  bool _showMobileCart = false;
  bool _isCartCollapsed = false;
  final Set<String> _preparingOrderIds = <String>{};
  final Set<String> _cancellingOrderIds = <String>{};

  double _discountValue = 0.0;
  bool _isDiscountPercentage = true;
  String _discountReason = '';
  InventoryApprovalRequest? _discountApproval;
  bool _isRequestingDiscountApproval = false;
  late String _checkoutSnapshotToken;

  final bool _soloMode = false;
  String? _selectedHelperId;
  String? _selectedBodegeroId; // POS_BODEGERO_ASSIGNMENT_V1

  String? _pendingAutoOpenOrderId;
  StreamSubscription<InventoryRuntimeSettingsSnapshot>?
  _runtimeSettingsSubscription;
  StreamSubscription<InventoryApprovalRequest?>? _discountApprovalSubscription;

  @override
  void initState() {
    super.initState();
    _checkoutSnapshotToken = _newCheckoutSnapshotToken();
    unawaited(widget.controller.loadStoreSettings());
    _runtimeSettingsSubscription = widget.controller
        .streamRuntimeSettings()
        .listen((_) {
          if (mounted) setState(() {});
        });
    _discountApprovalSubscription = widget.controller
        .streamDiscountApproval()
        .listen((request) {
          if (mounted) setState(() => _discountApproval = request);
        });
    _pendingAutoOpenOrderId = widget.targetOrderId;
  }

  @override
  void dispose() {
    _productSearchController.dispose();
    _truckIdentifierController.dispose();
    _bodegeroNoteController.dispose();
    _proofReviewVersion.dispose();
    unawaited(_runtimeSettingsSubscription?.cancel());
    unawaited(_discountApprovalSubscription?.cancel());
    widget.controller.clearDiscountApprovalTracking();
    super.dispose();
  }

  String _newCheckoutSnapshotToken() {
    final random = math.Random.secure();
    final entropy = List<String>.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$entropy';
  }

  void _invalidateDiscountApproval() {
    _checkoutSnapshotToken = _newCheckoutSnapshotToken();
    _discountApproval = null;
    widget.controller.clearDiscountApprovalTracking();
  }

  @override
  void didUpdateWidget(covariant PosCartPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.targetOrderId != null &&
        widget.targetOrderId != oldWidget.targetOrderId) {
      _pendingAutoOpenOrderId = widget.targetOrderId;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;

        _showPendingOrdersModal(
          context,
          targetOrderId: _pendingAutoOpenOrderId,
        );
      });
    }
  }

  List<InventoryItem> get _filteredItems => widget.controller.filterInventory(
    query: _searchQuery,
    category: _selectedCategory,
  );

  bool _addToCart(InventoryItem item) {
    if (_isProcessingCart) return false;
    final currentQty = _cart[item.id] ?? 0;
    if (currentQty >= item.quantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cannot add more of ${item.name}. Stock limit reached.',
          ),
          backgroundColor: _cashierAccent,
        ),
      );
      return false;
    }
    setState(() {
      _invalidateDiscountApproval();
      _cart[item.id] = currentQty + 1;
    });
    return true;
  }

  void _setCartQuantity(String itemId, double qty) {
    if (_isProcessingCart) return;
    try {
      final item = widget.controller.allItems.firstWhere((i) => i.id == itemId);
      if (qty > item.quantity) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Cannot set quantity to $qty. Only ${item.quantity} in stock.',
            ),
            backgroundColor: _cashierAccent,
          ),
        );
        qty = item.quantity;
      }
    } catch (_) {}

    setState(() {
      _invalidateDiscountApproval();
      if (qty <= 0) {
        _cart.remove(itemId);
      } else {
        _cart[itemId] = qty;
      }

      if (_cart.isEmpty) {
        _discountValue = 0.0;
        _discountReason = '';
        _truckIdentifierController.clear();
        _bodegeroNoteController.clear();
      }
    });
  }

  Future<void> _processOrder() async {
    if (_cart.isEmpty || _isProcessingCart) return;
    if (_cartHasHeavyItems && _truckIdentifierController.text.trim().isEmpty) {
      AppToast.error(context, 'Add the truck identifier.');
      return;
    }
    final subtotalBeforeDiscount = _calculateTotal();
    if (_requiresDiscountApproval(subtotalBeforeDiscount) &&
        !_hasUsableDiscountApproval(subtotalBeforeDiscount)) {
      AppToast.error(context, 'Admin approval is required before checkout.');
      return;
    }
    setState(() => _isProcessingCart = true);
    try {
      final items = _cart.entries.map((entry) {
        final item = widget.controller.allItems.firstWhere(
          (i) => i.id == entry.key,
        );
        return CustomerOrderItem(
          productId: item.id,
          productName: item.name,
          quantity: entry.value,
        );
      }).toList();

      final double subtotal = _calculateTotal();
      final discount = _discountCalculation(subtotal);
      final double discountAmt = discount.discountAmount;
      final double totalDue = discount.total;
      final assignedHelper = _soloMode || !_cartHasLightItems
          ? null
          : _selectedEligibleHelper();
      final assignedBodegero = _soloMode || !_cartHasHeavyItems
          ? null
          : _selectedEligibleBodegero();
      if (_cartHasHeavyItems &&
          _selectedBodegeroId != null &&
          assignedBodegero == null) {
        throw StateError(
          'Selected Bodegero is no longer available. Select Auto-assign or another available Bodegero.',
        );
      }

      final CustomerOrder? createdOrder = await widget.controller
          .createCustomerOrder(
            items,
            totalAmount: totalDue,
            discountAmount: discountAmt,
            discountMode: _discountMode,
            discountValue: _discountValue,
            discountReason: _discountReason,
            checkoutToken: _checkoutSnapshotToken,
            discountApprovalRequestId: _requiresDiscountApproval(subtotal)
                ? _discountApproval?.id
                : null,
            soloHandled: _soloMode,
            assignedHelper: assignedHelper,
            assignedBodegero: assignedBodegero,
            truckIdentifier: _truckIdentifierController.text.trim(),
            bodegeroNote: _bodegeroNoteController.text.trim(),
          );
      if (createdOrder == null) {
        throw Exception('Order could not be created.');
      }

      final notificationController = NotificationProvider.maybeOf(context);
      final locationId = widget.controller.activeLocationId;
      final createdByName = widget.controller.currentUserName ?? 'Unknown User';

      if (notificationController != null && locationId != null) {
        await notificationController.notifyNewOrder(
          locationId: locationId,
          orderId: createdOrder.id,
          createdByName: createdByName,
          createdAt: createdOrder.createdAt,
        );
        if (assignedHelper != null) {
          await notificationController.notifyOrderAssigned(
            locationId: locationId,
            orderId: createdOrder.id,
            helperId: assignedHelper.id,
            helperName: assignedHelper.name,
            assignedByName: createdByName,
            assignedAt: createdOrder.assignedAt ?? DateTime.now(),
          );
        }
        final bodegeroId = createdOrder.assignedBodegeroId;
        if (bodegeroId != null && bodegeroId.isNotEmpty) {
          await notificationController.notifyBodegeroOrderAssigned(
            locationId: locationId,
            orderId: createdOrder.id,
            bodegeroId: bodegeroId,
            assignedByName: createdByName,
            assignedAt: createdOrder.createdAt,
          );
        }
      }

      if (!_soloMode && assignedHelper == null) {
        await widget.autoAssignmentService?.reconcileCreatedOrder();
      }

      if (!mounted) return;

      setState(() {
        _invalidateDiscountApproval();
        _cart.clear();
        _showMobileCart = false;
        _discountValue = 0.0;
        _discountReason = '';
        _selectedHelperId = null;
        _selectedBodegeroId = null;
        _truckIdentifierController.clear();
        _bodegeroNoteController.clear();
      });

      if (_soloMode) {
        await _runSoloCheckout(createdOrder);
      } else {
        AppToast.success(
          context,
          assignedHelper == null
              ? 'Order submitted for automatic Helper assignment.'
              : 'Order assigned to ${assignedHelper.name}.',
        );
        try {
          final token = await widget.controller.customerOrderTrackingToken(
            createdOrder.id,
          );
          if (mounted) _showOrderTrackingQR(createdOrder.id, token);
        } catch (error, stackTrace) {
          AppLogger.error(
            'Order tracking QR unavailable',
            error: error,
            stackTrace: stackTrace,
          );
          if (mounted) {
            AppToast.error(context, 'Order saved, but tracking QR is unavailable.');
          }
        }
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        'Order submission failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(e, fallback: AppErrorCategory.dataSave),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessingCart = false);
    }
  }

  List<HelperAssignmentCandidate> _eligibleHelpers() {
    final helpers = widget.presenceService?.eligibleHelpersForAssignment;
    if (helpers == null || helpers.isEmpty) {
      return const <HelperAssignmentCandidate>[];
    }
    return rankHelpersByActiveWorkload(
      helpers: helpers,
      orders: widget.controller.currentOrders,
    );
  }

  HelperAssignmentCandidate? _selectedEligibleHelper() {
    final selectedId = _selectedHelperId;
    if (selectedId == null) return null;
    for (final helper in _eligibleHelpers()) {
      if (helper.id == selectedId) return helper;
    }
    return null;
  }

  // POS_BODEGERO_ASSIGNMENT_V1: use product handling tags in the cart,
  // not a string/name heuristic or the order's not-yet-created line items.
  bool get _cartHasHeavyItems => widget.controller.allItems.any(
    (item) => item.requiresLoading && (_cart[item.id] ?? 0) > 0,
  );

  bool get _cartHasLightItems => widget.controller.allItems.any(
    (item) => !item.requiresLoading && (_cart[item.id] ?? 0) > 0,
  );

  List<HelperAssignmentCandidate> _eligibleBodegeros() {
    final candidates = widget.presenceService?.eligibleBodegerosForAssignment;
    if (candidates == null || candidates.isEmpty) {
      return const <HelperAssignmentCandidate>[];
    }
    final workloads = activeLoadingWorkloads(widget.controller.currentOrders);
    final ranked = candidates.toList();
    ranked.sort((a, b) {
      final byLoad = (workloads[a.id] ?? 0).compareTo(workloads[b.id] ?? 0);
      if (byLoad != 0) return byLoad;
      final aId = BigInt.tryParse(a.id);
      final bId = BigInt.tryParse(b.id);
      if (aId != null && bId != null) return aId.compareTo(bId);
      return a.id.compareTo(b.id);
    });
    return List<HelperAssignmentCandidate>.unmodifiable(ranked);
  }

  HelperAssignmentCandidate? _selectedEligibleBodegero() {
    final selectedId = _selectedBodegeroId;
    if (selectedId == null) return null;
    for (final worker in _eligibleBodegeros()) {
      if (worker.id == selectedId) return worker;
    }
    return null;
  }

  Future<void> _completeOrderFlow(
    CustomerOrder order, {
    VoidCallback? onCompleted,
  }) async {
    if (order.items.any((item) => item.requiresLoading) &&
        !_reviewedLoadingProofOrderIds.contains(order.id)) {
      AppToast.error(context, 'Review the truck and item photos first.');
      return;
    }
    final double orderSubtotal = order.totalAmount + order.discountAmount;
    double orderQty = 0;
    for (final item in order.items) {
      orderQty += item.quantity;
    }

    final payment = await _showPaymentDialog(
      order: order,
      subtotal: orderSubtotal,
      discountAmt: order.discountAmount,
      totalDue: order.totalAmount,
      itemsCount: order.items.length,
      totalQty: orderQty,
    );

    if (payment == null) return;
    final times = payment.times;

    final notificationController = NotificationProvider.maybeOf(context);
    final locationId = widget.controller.activeLocationId;
    final processedByName = widget.controller.currentUserName ?? 'Unknown User';

    if (notificationController != null && locationId != null) {
      await notificationController.notifyTransactionCompleted(
        locationId: locationId,
        orderId: order.id,
        amount: order.totalAmount.toStringAsFixed(2),
        processedByName: processedByName,
        completedAt: times.completedAt,
      );
    }

    if (notificationController != null) {
      await notificationController.resolveOrderWorkflowNotification(
        orderId: order.id,
      );
    }

    onCompleted?.call();

    if (mounted) {
      _showReceiptDialog(
        order,
        paymentMode: payment.paymentMode,
        paymentReference: payment.reference,
        gcashDestinationName: payment.gcashDestinationName,
        gcashDestinationNumber: payment.gcashDestinationNumber,
        cashReceived: payment.cashReceived,
        change: payment.change,
        orderedAt: times.createdAt,
        completedAt: times.completedAt,
      );
    }
  }

  Future<void> _runSoloCheckout(CustomerOrder order) async {
    if (!_preparingOrderIds.add(order.id)) return;
    try {
      final result = await showOrderChecklistModal(
        context: context,
        order: order,
        controller: widget.controller,
        finishLabel: "PROCEED TO PAYMENT",
        onCancelOrder: () => _cancelOrderAndRestoreCart(order),
      );
      if (!mounted) return;

      switch (result) {
        case ChecklistResult.finished:
          await widget.controller.updateOrderStatus(
            order.id,
            'prepared',
            expectedStatus: 'solo_picking',
          );
          var paid = false;
          await _completeOrderFlow(order, onCompleted: () => paid = true);
          if (!paid && mounted) {
            AppToast.success(
              context,
              "Payment not completed — order is waiting in Pending Orders",
            );
          }
          break;
        case ChecklistResult.dismissed:
          await widget.controller.updateOrderStatus(order.id, 'pending');
          if (mounted)
            AppToast.success(context, "Order moved to the Helper queue");
          break;
        case ChecklistResult.cancelled:
          break;
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Solo preparation failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
      }
    } finally {
      _preparingOrderIds.remove(order.id);
    }
  }

  Future<bool> _cancelOrderAndRestoreCart(
    CustomerOrder order, {
    bool fromQueue = false,
  }) async {
    if (!_cancellingOrderIds.add(order.id)) return false;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AppDialog(
          icon: LucideIcons.undo2,
          color: Colors.red.shade600,
          title: "Cancel & Edit This Order?",
          subtitle: "#${order.id.substring(0, 8).toUpperCase()}",
          child: Text(
            fromQueue
                ? "This cancels the order and puts its items back in your cart. "
                      "If your helper is already picking it, let them know."
                : "This cancels the order and puts its items back in your cart so "
                      "you can change quantities before checking out again.",
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: BorderSide(color: Colors.grey.shade300),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text("Keep It"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text(
                "Cancel Order",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );

      if (confirmed != true) return false;

      try {
        final notificationController = NotificationProvider.maybeOf(context);
        await widget.controller.cancelOrder(order);
        await notificationController?.resolveOrderWorkflowNotification(
          orderId: order.id,
        );
        if (!mounted) return true;
        setState(() {
          _invalidateDiscountApproval();
          for (final item in order.items) {
            _cart[item.productId] =
                (_cart[item.productId] ?? 0) + item.quantity;
          }
          if (order.discountAmount > 0 && _discountValue == 0) {
            _discountValue = order.discountAmount;
            _isDiscountPercentage = false;
          }
        });
        AppToast.success(
          context,
          "Order cancelled — items are back in your cart",
        );
        return true;
      } catch (e, stackTrace) {
        AppLogger.error(
          'Order cancellation failed',
          error: e,
          stackTrace: stackTrace,
        );
        if (mounted) {
          AppToast.error(
            context,
            AppErrorMapper.message(e, fallback: AppErrorCategory.dataSave),
          );
        }
        return false;
      }
    } finally {
      _cancellingOrderIds.remove(order.id);
    }
  }

  double _calculateTotal() {
    double total = 0;
    for (var entry in _cart.entries) {
      try {
        final item = widget.controller.allItems.firstWhere(
          (i) => i.id == entry.key,
        );
        total += item.price * entry.value;
      } catch (_) {}
    }
    return total;
  }

  DiscountMode get _selectedDiscountMode =>
      _isDiscountPercentage ? DiscountMode.percentage : DiscountMode.amount;

  String get _discountMode => _selectedDiscountMode.databaseValue;

  DiscountCalculation _discountCalculation(double subtotal) =>
      DiscountCalculation.calculate(
        subtotal: subtotal,
        mode: _selectedDiscountMode,
        enteredValue: _discountValue,
      );

  double _discountAmountFor(double subtotal) =>
      _discountCalculation(subtotal).discountAmount;

  double _effectiveDiscountPercentage(double subtotal) =>
      _discountCalculation(subtotal).effectivePercentage;

  bool _requiresDiscountApproval(double subtotal) {
    final role = widget.controller.currentUserRole?.toLowerCase();
    if (role == 'admin' || _discountValue <= 0) return false;
    return _discountCalculation(
      subtotal,
    ).requiresApproval(widget.controller.cashierAutoApprovedDiscountLimitPct);
  }

  bool _hasUsableDiscountApproval(double subtotal) {
    final request = _discountApproval;
    return request?.authorizesDiscountCheckout(
          mode: _discountMode,
          enteredValue: _discountValue,
          subtotal: subtotal,
          monetaryDiscount: _discountAmountFor(subtotal),
          cartToken: _checkoutSnapshotToken,
        ) ??
        false;
  }

  List<CustomerOrderItem> _currentCartItems() => _cart.entries
      .map((entry) {
        final item = widget.controller.allItems.firstWhere(
          (candidate) => candidate.id == entry.key,
        );
        return CustomerOrderItem(
          productId: item.id,
          productName: item.name,
          quantity: entry.value,
        );
      })
      .toList(growable: false);

  Future<void> _requestDiscountApproval() async {
    if (_cart.isEmpty || _isRequestingDiscountApproval) return;
    final subtotal = _calculateTotal();
    if (!_requiresDiscountApproval(subtotal)) return;
    if (_discountReason.trim().isEmpty) {
      AppToast.error(
        context,
        'Enter a reason before requesting Admin approval.',
      );
      return;
    }
    setState(() => _isRequestingDiscountApproval = true);
    try {
      final request = await widget.controller.submitDiscountApprovalRequest(
        items: _currentCartItems(),
        discountMode: _discountMode,
        discountValue: _discountValue,
        reason: _discountReason,
        checkoutToken: _checkoutSnapshotToken,
      );
      if (!mounted) return;
      setState(() => _discountApproval = request);
      AppToast.success(context, 'Discount approval requested.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Discount approval request failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
      }
    } finally {
      if (mounted) setState(() => _isRequestingDiscountApproval = false);
    }
  }

  void _openAIObjectScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VisualSearchPage(
          controller: widget.controller,
          onSelectItem: (item) {
            if (_addToCart(item)) {
              Navigator.pop(context);
              AppToast.success(context, '${item.name} added to cart!');
            }
          },
        ),
      ),
    );
  }

  void _showDiscountDialog(BuildContext context) {
    final valueCtrl = TextEditingController(
      text: _discountValue > 0
          ? (_discountValue.truncateToDouble() == _discountValue
                ? _discountValue.toInt().toString()
                : _discountValue.toStringAsFixed(2))
          : '',
    );
    final reasonCtrl = TextEditingController(text: _discountReason);
    bool isPercent = _isDiscountPercentage;
    String? errorMessage;
    String? reasonError;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) {
          final enteredValue = double.tryParse(valueCtrl.text.trim()) ?? 0;
          final draftCalculation = DiscountCalculation.calculate(
            subtotal: _calculateTotal(),
            mode: isPercent ? DiscountMode.percentage : DiscountMode.amount,
            enteredValue: enteredValue,
          );
          final role = widget.controller.currentUserRole?.toLowerCase();
          final approvalRequired =
              role != 'admin' &&
              enteredValue > 0 &&
              draftCalculation.requiresApproval(
                widget.controller.cashierAutoApprovedDiscountLimitPct,
              );

          void applyDiscount() {
            final textVal = valueCtrl.text.trim();
            if (textVal.isEmpty) {
              setState(() {
                _invalidateDiscountApproval();
                _discountValue = 0.0;
                _isDiscountPercentage = isPercent;
                _discountReason = '';
              });
              Navigator.pop(dialogContext);
              return;
            }

            final val = double.tryParse(textVal);
            if (val == null || val < 0) {
              setModalState(
                () => errorMessage = 'Please enter a valid positive number.',
              );
              return;
            }
            if (isPercent && val > 100) {
              setModalState(
                () => errorMessage = 'Percentage cannot exceed 100%.',
              );
              return;
            }

            final currentSubtotal = _calculateTotal();
            final calculation = DiscountCalculation.calculate(
              subtotal: currentSubtotal,
              mode: isPercent ? DiscountMode.percentage : DiscountMode.amount,
              enteredValue: val,
            );
            final requiresApproval =
                role != 'admin' &&
                calculation.requiresApproval(
                  widget.controller.cashierAutoApprovedDiscountLimitPct,
                );

            if (!isPercent && val > currentSubtotal) {
              setModalState(
                () => errorMessage =
                    'Discount cannot exceed subtotal (₱${currentSubtotal.toStringAsFixed(2)}).',
              );
              return;
            }
            if (requiresApproval && reasonCtrl.text.trim().isEmpty) {
              setModalState(
                () => reasonError =
                    'A reason is required when Admin approval is needed.',
              );
              return;
            }

            setState(() {
              _invalidateDiscountApproval();
              _discountValue = val;
              _isDiscountPercentage = isPercent;
              _discountReason = reasonCtrl.text;
            });
            Navigator.pop(dialogContext);
            if (requiresApproval) unawaited(_requestDiscountApproval());
          }

          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            backgroundColor: Colors.white,
            child: SizedBox(
              width: 360,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Add Discount",
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _cashierInk,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            LucideIcons.x,
                            size: 20,
                            color: Colors.grey,
                          ),
                          onPressed: () => Navigator.pop(dialogContext),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Choose a discount type and enter the amount.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF655C56)),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2EFEC),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: const Color(0xFFD5CEC7)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setModalState(() {
                                isPercent = true;
                                errorMessage = null;
                                reasonError = null;
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isPercent
                                      ? _cashierPrimary
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: isPercent
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(
                                              0.05,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ]
                                      : [],
                                ),
                                child: Center(
                                  child: Text(
                                    "Percentage",
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: isPercent
                                          ? Colors.white
                                          : _cashierInk,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setModalState(() {
                                isPercent = false;
                                errorMessage = null;
                                reasonError = null;
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: !isPercent
                                      ? _cashierPrimary
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: !isPercent
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(
                                              0.05,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ]
                                      : [],
                                ),
                                child: Center(
                                  child: Text(
                                    "Fixed amount",
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: !isPercent
                                          ? Colors.white
                                          : _cashierInk,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    if (errorMessage != null) ...[
                      Text(
                        errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    TextField(
                      controller: valueCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: const TextStyle(
                        fontSize: 14,
                        color: _cashierInk,
                        fontWeight: FontWeight.w600,
                      ),
                      onChanged: (_) => setModalState(() {
                        errorMessage = null;
                        reasonError = null;
                      }),
                      onSubmitted: (_) => applyDiscount(),
                      decoration: InputDecoration(
                        prefixText: isPercent ? null : "₱ ",
                        suffixText: isPercent ? "%" : null,
                        prefixStyle: const TextStyle(
                          color: _cashierAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        hintText: isPercent
                            ? "Enter Percentage"
                            : "Enter Amount",
                        hintStyle: const TextStyle(
                          color: Color(0xFF736861),
                          fontSize: 13,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFFC8BFB8),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFFC8BFB8),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: _cashierAccent),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reasonCtrl,
                      style: const TextStyle(color: _cashierInk, fontSize: 13),
                      onChanged: (_) => setModalState(() => reasonError = null),
                      onSubmitted: (_) => applyDiscount(),
                      decoration: InputDecoration(
                        hintText: approvalRequired
                            ? "Reason (Required for Approval)"
                            : "Reason (Optional)",
                        errorText: reasonError,
                        hintStyle: const TextStyle(
                          color: Color(0xFF736861),
                          fontSize: 13,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFFC8BFB8),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFFC8BFB8),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: _cashierAccent),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _cashierPrimary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        onPressed: applyDiscount,
                        child: Text(
                          approvalRequired
                              ? "Request Approval"
                              : "Apply Discount",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showLoadingInstructionsDialog(BuildContext context) async {
    final truckDraft = TextEditingController(
      text: _truckIdentifierController.text,
    );
    final noteDraft = TextEditingController(text: _bodegeroNoteController.text);
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Loading instructions',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _cashierInk,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.x, size: 20),
                        onPressed: () => Navigator.pop(dialogContext, false),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Send the truck identifier to Bodegero. Add a note if needed.',
                    style: TextStyle(fontSize: 13, color: Color(0xFF655C56)),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: truckDraft,
                    maxLength: 32,
                    onChanged: (_) => updateDialog(() => error = null),
                    decoration: InputDecoration(
                      labelText: 'Truck plate / identifier',
                      hintText: 'Enter the truck identifier',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _cashierAccent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteDraft,
                    maxLength: 240,
                    minLines: 2,
                    maxLines: 3,
                    onChanged: (_) => updateDialog(() => error = null),
                    decoration: InputDecoration(
                      labelText: 'Note to Bodegero (optional)',
                      hintText: 'What should be loaded and verified?',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _cashierAccent),
                      ),
                    ),
                  ),
                  if (error != null) ...[
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _cashierPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () {
                        if (truckDraft.text.trim().isEmpty) {
                          updateDialog(
                            () => error = 'Enter the truck identifier.',
                          );
                          return;
                        }
                        Navigator.pop(dialogContext, true);
                      },
                      child: const Text(
                        'Save instructions',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        _truckIdentifierController.text = truckDraft.text.trim();
        _bodegeroNoteController.text = noteDraft.text.trim();
      });
    }
  }

  Future<_CompletedPayment?> _showPaymentDialog({
    required CustomerOrder order,
    required double subtotal,
    required double discountAmt,
    required double totalDue,
    required int itemsCount,
    required double totalQty,
  }) async {
    await widget.controller.loadStoreSettings(refresh: true);
    if (!mounted) return null;
    final primaryGcashAccountName = widget.controller.gcashAccountName;
    final primaryGcashNumber = widget.controller.gcashNumber;
    final primaryGcashQrUrl = widget.controller.gcashQrUrl;
    final backupGcashAccountName = widget.controller.alternateGcashAccountName;
    final backupGcashNumber = widget.controller.alternateGcashNumber;
    final backupGcashQrUrl = widget.controller.alternateGcashQrUrl;
    final backupConfigured = widget.controller.hasAlternateGcashAccount;
    final backupAvailable =
        backupConfigured && await widget.controller.canRecordGcashDestination();
    if (!mounted) return null;
    String paymentMode = 'Cash';
    bool useBackupGcash = false;
    final cashCtrl = TextEditingController();
    double cashReceived = 0.0;
    final refCtrl = TextEditingController();
    final refFocusNode = FocusNode();
    String? referenceError;
    String? paymentError;
    bool isSubmitting = false;
    bool orderAlreadyCompleted = false;

    try {
      return await showDialog<_CompletedPayment>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            double change = cashReceived - totalDue;
            if (change < 0) change = 0;

            // --- NEW: Calculate limits dynamically ---
            double maxAllowedCash = (totalDue / 1000).ceil() * 1000.0;
            if (maxAllowedCash == 0) maxAllowedCash = 1000.0;

            bool isCashExcessive = cashReceived > maxAllowedCash;
            bool isCashInsufficient =
                cashReceived > 0 && cashReceived < totalDue;
            bool hasError = isCashExcessive || isCashInsufficient;
            // -----------------------------------------

            String cashText(double value) => value == value.roundToDouble()
                ? value.toStringAsFixed(0)
                : value.toStringAsFixed(2);

            bool canAddCash(int amount) {
              final current = double.tryParse(cashCtrl.text.trim()) ?? 0.0;
              final next = current + amount;
              return !isSubmitting &&
                  !orderAlreadyCompleted &&
                  next <= maxAllowedCash &&
                  cashText(next).length <= 7;
            }

            void addCash(int amount) {
              final current = double.tryParse(cashCtrl.text.trim()) ?? 0.0;
              final next = current + amount;
              final text = cashText(next);
              cashCtrl.value = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
              setDialogState(() => cashReceived = next);
            }

            Widget buildPaymentTile(String title, IconData icon) {
              bool isSelected = paymentMode == title;
              return Expanded(
                child: GestureDetector(
                  onTap: isSubmitting || orderAlreadyCompleted
                      ? null
                      : () => setDialogState(() {
                          paymentMode = title;
                          referenceError = null;
                          paymentError = null;
                        }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? _cashierTint : Colors.white,
                      border: Border.all(
                        color: isSelected
                            ? _cashierAccent
                            : Colors.grey.shade300,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          icon,
                          color: isSelected
                              ? _cashierAccent
                              : Colors.grey.shade400,
                          size: 20,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          title,
                          style: TextStyle(
                            color: isSelected
                                ? _cashierAccent
                                : Colors.grey.shade600,
                            fontSize: 12,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            void selectGcashDestination(bool backup) {
              setDialogState(() {
                useBackupGcash = backup;
                refCtrl.clear();
                referenceError = null;
                paymentError = null;
              });
            }

            Future<void> submitPayment() async {
              String? reference;
              if (paymentMode == 'GCash') {
                final selectedQr = useBackupGcash
                    ? backupGcashQrUrl
                    : primaryGcashQrUrl;
                if (selectedQr.isEmpty) {
                  setDialogState(
                    () => paymentError =
                        'No QR is configured for this GCash account.',
                  );
                  return;
                }
                try {
                  reference = normalizeGcashReference(refCtrl.text);
                } on FormatException catch (error) {
                  setDialogState(() => referenceError = error.message);
                  refFocusNode.requestFocus();
                  return;
                }
              }

              final submittedCash = paymentMode == 'Cash'
                  ? cashReceived
                  : totalDue;
              final submittedChange = paymentMode == 'Cash'
                  ? cashReceived - totalDue
                  : 0.0;
              setDialogState(() {
                isSubmitting = true;
                referenceError = null;
                paymentError = null;
              });

              try {
                final times = await widget.controller.completeOrder(
                  order,
                  paymentMode: paymentMode,
                  cashGiven: submittedCash,
                  changeAmount: submittedChange,
                  paymentReference: reference,
                  gcashAccountSlot: paymentMode == 'GCash'
                      ? (useBackupGcash ? 'alternate' : 'primary')
                      : null,
                  gcashDestinationName: paymentMode == 'GCash'
                      ? (useBackupGcash
                            ? backupGcashAccountName
                            : primaryGcashAccountName)
                      : null,
                  gcashDestinationNumber: paymentMode == 'GCash'
                      ? (useBackupGcash
                            ? backupGcashNumber
                            : primaryGcashNumber)
                      : null,
                );
                if (!dialogContext.mounted) return;
                if (times == null) {
                  setDialogState(() {
                    isSubmitting = false;
                    paymentError = 'Payment is already being processed.';
                  });
                  return;
                }

                Navigator.pop(
                  dialogContext,
                  _CompletedPayment(
                    paymentMode: paymentMode,
                    cashReceived: submittedCash,
                    change: submittedChange,
                    reference: reference,
                    gcashDestinationName: paymentMode == 'GCash'
                        ? (useBackupGcash
                              ? backupGcashAccountName
                              : primaryGcashAccountName)
                        : null,
                    gcashDestinationNumber: paymentMode == 'GCash'
                        ? (useBackupGcash
                              ? backupGcashNumber
                              : primaryGcashNumber)
                        : null,
                    times: times,
                  ),
                );
              } catch (error, stackTrace) {
                AppLogger.error(
                  'Order completion failed',
                  error: error,
                  stackTrace: stackTrace,
                );
                if (!dialogContext.mounted) return;

                final code = error is AppUserFacingException
                    ? error.code
                    : null;
                if (code == AppUserFacingErrorCode.duplicatePaymentReference) {
                  setDialogState(() {
                    isSubmitting = false;
                    referenceError =
                        'This GCash reference has already been used. Enter a unique reference number.';
                  });
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (dialogContext.mounted && refFocusNode.canRequestFocus) {
                      refFocusNode.requestFocus();
                    }
                  });
                  return;
                }

                if (code == AppUserFacingErrorCode.orderAlreadyCompleted) {
                  setDialogState(() {
                    isSubmitting = false;
                    orderAlreadyCompleted = true;
                    paymentError = 'This order has already been completed.';
                  });
                  return;
                }

                setDialogState(() {
                  isSubmitting = false;
                  paymentError = AppErrorMapper.message(
                    error,
                    fallback: AppErrorCategory.dataSave,
                  );
                });
              }
            }

            String qtyStr = totalQty.truncateToDouble() == totalQty
                ? totalQty.toInt().toString()
                : totalQty.toStringAsFixed(2);

            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              backgroundColor: Colors.white,
              child: SizedBox(
                width: 400,
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Confirm Order",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _cashierInk,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "$itemsCount items - $qtyStr total qty",
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 20),

                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade200),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Subtotal',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    '₱${subtotal.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),

                              if (discountAmt > 0) ...[
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Discount',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      "-₱${discountAmt.toStringAsFixed(2)}",
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ],

                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'TOTAL',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Text(
                                    "₱${totalDue.toStringAsFixed(2)}",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),
                        Text(
                          "MODE OF PAYMENT",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade500,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            buildPaymentTile('Cash', LucideIcons.banknote),
                            const SizedBox(width: 8),
                            buildPaymentTile('GCash', LucideIcons.smartphone),
                          ],
                        ),

                        if (paymentMode == 'Cash') ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Text(
                                "Cash Received",
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: TextField(
                                  controller: cashCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  inputFormatters: [
                                    // --- NEW: Block physically typing too many numbers ---
                                    LengthLimitingTextInputFormatter(7),
                                    FilteringTextInputFormatter.allow(
                                      RegExp(
                                        r'^\d*\.?\d{0,2}',
                                      ), // Only allows 2 decimal places
                                    ),
                                  ],
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    color: hasError
                                        ? Colors.red
                                        : Colors.black87,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: "0.00",
                                    hintStyle: TextStyle(
                                      color: Colors.grey.shade400,
                                      fontWeight: FontWeight.normal,
                                    ),
                                    filled: true,
                                    fillColor: hasError
                                        ? Colors.red.shade50
                                        : Colors.transparent,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: BorderSide(
                                        color: Colors.grey.shade400,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: BorderSide(
                                        color: hasError
                                            ? Colors.red.shade300
                                            : Colors.grey.shade400,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: BorderSide(
                                        color: hasError
                                            ? Colors.red
                                            : _cashierAccent,
                                        width: 2,
                                      ),
                                    ),
                                    isDense: true,
                                  ),
                                  onChanged: (val) {
                                    setDialogState(() {
                                      cashReceived =
                                          double.tryParse(val) ?? 0.0;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 8),
                          Row(
                            children: [
                              for (final amount in const [
                                1000,
                                500,
                                100,
                                50,
                              ]) ...[
                                if (amount != 1000) const SizedBox(width: 6),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: canAddCash(amount)
                                        ? () => addCash(amount)
                                        : null,
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 36),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      foregroundColor: _cashierAccent,
                                      side: const BorderSide(
                                        color: _cashierBorder,
                                      ),
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text('+$amount'),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),

                          // --- NEW: Real-time red error UI ---
                          if (isCashExcessive)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  "Max allowed is ₱${maxAllowedCash.toStringAsFixed(0)}",
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            )
                          else if (isCashInsufficient)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  "Insufficient cash",
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),

                          // -------------------------------------
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Change",
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                ),
                              ),
                              Text(
                                "₱${change.toStringAsFixed(2)}",
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                ),
                              ),
                            ],
                          ),
                        ] else if (paymentMode == 'GCash') ...[
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: _cashierTint,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFF2D4C4),
                              ),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  "Scan to Pay with GCash",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: _cashierAccent,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                if (backupAvailable) ...[
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 8,
                                    children: [
                                      ChoiceChip(
                                        label: const Text('Primary QR'),
                                        selected: !useBackupGcash,
                                        onSelected:
                                            isSubmitting ||
                                                orderAlreadyCompleted
                                            ? null
                                            : (_) =>
                                                  selectGcashDestination(false),
                                      ),
                                      ChoiceChip(
                                        label: const Text('Backup QR'),
                                        selected: useBackupGcash,
                                        onSelected:
                                            isSubmitting ||
                                                orderAlreadyCompleted
                                            ? null
                                            : (_) =>
                                                  selectGcashDestination(true),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Use the backup if the primary receiving account cannot accept payment.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _cashierAccent,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                if (backupConfigured && !backupAvailable)
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 12),
                                    child: Text(
                                      'Backup QR is unavailable. Ask an administrator to finish payment setup.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: _cashierAccent,
                                      ),
                                    ),
                                  ),
                                if ((useBackupGcash
                                        ? backupGcashAccountName
                                        : primaryGcashAccountName)
                                    .isNotEmpty)
                                  Text(
                                    useBackupGcash
                                        ? backupGcashAccountName
                                        : primaryGcashAccountName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                if ((useBackupGcash
                                        ? backupGcashNumber
                                        : primaryGcashNumber)
                                    .isNotEmpty)
                                  Text(
                                    useBackupGcash
                                        ? backupGcashNumber
                                        : primaryGcashNumber,
                                  ),
                                const SizedBox(height: 12),
                                (useBackupGcash
                                            ? backupGcashQrUrl
                                            : primaryGcashQrUrl)
                                        .isNotEmpty
                                    ? GcashQrImage(
                                        imageUrl: useBackupGcash
                                            ? backupGcashQrUrl
                                            : primaryGcashQrUrl,
                                      )
                                    : Container(
                                        height: 180,
                                        width: 180,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              LucideIcons.imageOff,
                                              color: Colors.grey.shade400,
                                              size: 32,
                                            ),
                                            const SizedBox(height: 8),
                                            const Text(
                                              "No QR Code Set",
                                              style: TextStyle(
                                                color: Colors.redAccent,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                // --------------------------------------------------
                                const SizedBox(height: 12),
                                const Text(
                                  "Please wait for the customer to confirm transfer.",
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _cashierAccent,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'GCash Reference Number',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: _cashierAccent,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: refCtrl,
                                  focusNode: refFocusNode,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(13),
                                  ],
                                  onChanged: (_) {
                                    setDialogState(() {
                                      referenceError = null;
                                      if (!orderAlreadyCompleted) {
                                        paymentError = null;
                                      }
                                    });
                                  },
                                  decoration: InputDecoration(
                                    hintText: 'GCash Reference Number',
                                    helperText:
                                        'Enter the full reference number',
                                    errorText: referenceError,
                                    hintStyle: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 12,
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    prefixIcon: const Icon(
                                      LucideIcons.hash,
                                      size: 16,
                                      color: _cashierAccent,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: const Color(0xFFE6B7A2),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: const Color(0xFFE6B7A2),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                        color: _cashierAccent,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        if (paymentError != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.shade200),
                            ),
                            child: Text(
                              paymentError!,
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),
                        Row(
                          children: [
                            const Icon(
                              LucideIcons.check,
                              color: Colors.green,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Payment is received',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              LucideIcons.check,
                              color: Colors.green,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Receipt will be generated',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: isSubmitting
                                    ? null
                                    : () => Navigator.pop(dialogContext, null),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.black87,
                                  side: BorderSide(color: Colors.grey.shade300),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                ),
                                child: const Text("Cancel"),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                // --- NEW: Disable button dynamically if rules are broken ---
                                onPressed:
                                    isSubmitting ||
                                        orderAlreadyCompleted ||
                                        (paymentMode == 'Cash' && hasError)
                                    ? null
                                    : submitPayment,
                                // -----------------------------------------------------------
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  disabledBackgroundColor:
                                      Colors.green.shade200,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  elevation: 0,
                                ),
                                child: isSubmitting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        "Confirm",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    } finally {
      cashCtrl.dispose();
      refCtrl.dispose();
      refFocusNode.dispose();
    }
  }

  String _fmtReceiptDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    final hr = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} $hr:$min $ampm';
  }

  // void _showReceiptDialog(
  //   CustomerOrder o, {
  //   String? paymentMode,
  //   double? cashReceived,
  //   double? change,
  //   DateTime? orderedAt,
  //   DateTime? completedAt,
  // }) {
  //   double subtotal = 0;
  //   List<Widget> itemRows = [];

  //   for (var item in o.items) {
  //     double price = 0;
  //     String unit = 'pcs';
  //     try {
  //       final dbItem = widget.controller.allItems.firstWhere(
  //         (i) => i.id == item.productId,
  //       );
  //       price = dbItem.price;
  //       unit = dbItem.unit;
  //     } catch (_) {}

  //     double itemTotal = price * item.quantity;
  //     subtotal += itemTotal;

  //     String qtyStr = item.quantity.truncateToDouble() == item.quantity
  //         ? item.quantity.toInt().toString()
  //         : item.quantity.toStringAsFixed(2);

  //     itemRows.add(
  //       Padding(
  //         padding: const EdgeInsets.symmetric(vertical: 4.0),
  //         child: Row(
  //           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //           crossAxisAlignment: CrossAxisAlignment.start,
  //           children: [
  //             Expanded(
  //               child: Column(
  //                 crossAxisAlignment: CrossAxisAlignment.start,
  //                 children: [
  //                   Text(
  //                     item.productName,
  //                     style: const TextStyle(
  //                       fontWeight: FontWeight.bold,
  //                       fontSize: 12,
  //                     ),
  //                   ),
  //                   Text(
  //                     '$qtyStr $unit x ₱${price.toStringAsFixed(2)}',
  //                     style: const TextStyle(fontSize: 11, color: Colors.grey),
  //                   ),
  //                 ],
  //               ),
  //             ),
  //             Text(
  //               '₱${itemTotal.toStringAsFixed(2)}',
  //               style: const TextStyle(
  //                 fontWeight: FontWeight.bold,
  //                 fontSize: 12,
  //               ),
  //             ),
  //           ],
  //         ),
  //       ),
  //     );
  //   }

  //   final String cashierName =
  //       o.completedByName ??
  //       widget.controller.currentUserName ??
  //       'Unknown Cashier';

  //   final DateTime completedTime = completedAt ?? DateTime.now();
  //   final String completedStr = _fmtReceiptDate(completedTime);
  //   final String? orderedStr =
  //       (orderedAt != null &&
  //           orderedAt.difference(completedTime).inMinutes.abs() >= 1)
  //       ? _fmtReceiptDate(orderedAt)
  //       : null;

  //   showDialog(
  //     context: context,
  //     barrierDismissible: false,
  //     builder: (context) => Dialog(
  //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  //       backgroundColor: Colors.white,
  //       child: SizedBox(
  //         width: 400,
  //         child: Column(
  //           mainAxisSize: MainAxisSize.min,
  //           children: [
  //             Container(
  //               width: double.infinity,
  //               padding: const EdgeInsets.symmetric(vertical: 24),
  //               decoration: BoxDecoration(
  //                 color: Colors.green.shade50,
  //                 borderRadius: const BorderRadius.vertical(
  //                   top: Radius.circular(16),
  //                 ),
  //               ),
  //               child: Column(
  //                 children: [
  //                   Container(
  //                     padding: const EdgeInsets.all(12),
  //                     decoration: const BoxDecoration(
  //                       color: Colors.green,
  //                       shape: BoxShape.circle,
  //                     ),
  //                     child: const Icon(
  //                       LucideIcons.check,
  //                       color: Colors.white,
  //                       size: 32,
  //                     ),
  //                   ),
  //                   const SizedBox(height: 12),
  //                   const Text(
  //                     'Order Completed',
  //                     style: TextStyle(
  //                       fontSize: 18,
  //                       fontWeight: FontWeight.bold,
  //                       color: Colors.black87,
  //                     ),
  //                   ),
  //                   Text(
  //                     'Transaction #${o.id.substring(0, 8).toUpperCase()}',
  //                     style: TextStyle(
  //                       color: Colors.grey.shade600,
  //                       fontSize: 12,
  //                     ),
  //                   ),
  //                 ],
  //               ),
  //             ),
  //             Flexible(
  //               child: SingleChildScrollView(
  //                 child: Padding(
  //                   padding: const EdgeInsets.all(24.0),
  //                   child: Column(
  //                     mainAxisSize: MainAxisSize.min,
  //                     children: [
  //                       const Text(
  //                         'INVENTORY PLUS',
  //                         style: TextStyle(
  //                           fontWeight: FontWeight.w900,
  //                           fontSize: 16,
  //                           letterSpacing: 1.5,
  //                         ),
  //                       ),
  //                       const SizedBox(height: 4),
  //                       Text(
  //                         'SPRJ Paint Center - San Pedro, Laguna',
  //                         style: TextStyle(
  //                           color: Colors.grey.shade600,
  //                           fontSize: 11,
  //                         ),
  //                       ),
  //                       const SizedBox(height: 16),
  //                       const _DashedDivider(),
  //                       const SizedBox(height: 16),
  //                       Row(
  //                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                         children: [
  //                           Text(
  //                             'Order #',
  //                             style: TextStyle(
  //                               color: Colors.grey.shade600,
  //                               fontSize: 11,
  //                             ),
  //                           ),
  //                           Text(
  //                             o.id.substring(0, 8).toUpperCase(),
  //                             style: const TextStyle(
  //                               fontWeight: FontWeight.bold,
  //                               fontSize: 11,
  //                             ),
  //                           ),
  //                         ],
  //                       ),
  //                       if (orderedStr != null) ...[
  //                         const SizedBox(height: 4),
  //                         Row(
  //                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                           children: [
  //                             Text(
  //                               'Ordered',
  //                               style: TextStyle(
  //                                 color: Colors.grey.shade600,
  //                                 fontSize: 11,
  //                               ),
  //                             ),
  //                             Text(
  //                               orderedStr,
  //                               style: const TextStyle(
  //                                 fontWeight: FontWeight.bold,
  //                                 fontSize: 11,
  //                               ),
  //                             ),
  //                           ],
  //                         ),
  //                       ],
  //                       const SizedBox(height: 4),
  //                       Row(
  //                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                         children: [
  //                           Text(
  //                             'Completed',
  //                             style: TextStyle(
  //                               color: Colors.grey.shade600,
  //                               fontSize: 11,
  //                             ),
  //                           ),
  //                           Text(
  //                             completedStr,
  //                             style: const TextStyle(
  //                               fontWeight: FontWeight.bold,
  //                               fontSize: 11,
  //                             ),
  //                           ),
  //                         ],
  //                       ),
  //                       const SizedBox(height: 4),
  //                       Row(
  //                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                         children: [
  //                           Text(
  //                             'Cashier',
  //                             style: TextStyle(
  //                               color: Colors.grey.shade600,
  //                               fontSize: 11,
  //                             ),
  //                           ),
  //                           Text(
  //                             cashierName,
  //                             style: const TextStyle(
  //                               fontWeight: FontWeight.bold,
  //                               fontSize: 11,
  //                             ),
  //                           ),
  //                         ],
  //                       ),
  //                       const SizedBox(height: 16),
  //                       const _DashedDivider(),
  //                       const SizedBox(height: 16),
  //                       ...itemRows,
  //                       const SizedBox(height: 16),
  //                       const _DashedDivider(),
  //                       const SizedBox(height: 16),

  //                       if (paymentMode == 'Cash' && cashReceived != null) ...[
  //                         Row(
  //                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                           children: [
  //                             const Text(
  //                               'Cash Given',
  //                               style: TextStyle(fontSize: 12),
  //                             ),
  //                             Text(
  //                               '₱${cashReceived.toStringAsFixed(2)}',
  //                               style: const TextStyle(
  //                                 fontWeight: FontWeight.bold,
  //                                 fontSize: 12,
  //                               ),
  //                             ),
  //                           ],
  //                         ),
  //                         const SizedBox(height: 4),
  //                       ],

  //                       Row(
  //                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                         children: [
  //                           const Text(
  //                             'Subtotal',
  //                             style: TextStyle(fontSize: 12),
  //                           ),
  //                           Text(
  //                             '₱${subtotal.toStringAsFixed(2)}',
  //                             style: const TextStyle(
  //                               fontWeight: FontWeight.bold,
  //                               fontSize: 12,
  //                             ),
  //                           ),
  //                         ],
  //                       ),

  //                       if (o.discountAmount > 0) ...[
  //                         const SizedBox(height: 4),
  //                         Row(
  //                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                           children: [
  //                             const Text(
  //                               'Discount',
  //                               style: TextStyle(fontSize: 12),
  //                             ),
  //                             Text(
  //                               '-₱${o.discountAmount.toStringAsFixed(2)}',
  //                               style: const TextStyle(
  //                                 fontWeight: FontWeight.bold,
  //                                 fontSize: 12,
  //                               ),
  //                             ),
  //                           ],
  //                         ),
  //                       ],

  //                       const SizedBox(height: 12),
  //                       Row(
  //                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                         children: [
  //                           const Text(
  //                             'TOTAL',
  //                             style: TextStyle(
  //                               fontWeight: FontWeight.w900,
  //                               fontSize: 14,
  //                             ),
  //                           ),
  //                           Text(
  //                             '₱${o.totalAmount.toStringAsFixed(2)}',
  //                             style: const TextStyle(
  //                               fontWeight: FontWeight.w900,
  //                               fontSize: 14,
  //                             ),
  //                           ),
  //                         ],
  //                       ),

  //                       if (paymentMode == 'Cash' && change != null) ...[
  //                         const SizedBox(height: 4),
  //                         Row(
  //                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                           children: [
  //                             const Text(
  //                               'Change',
  //                               style: TextStyle(
  //                                 fontSize: 12,
  //                                 color: Colors.green,
  //                               ),
  //                             ),
  //                             Text(
  //                               '₱${change.toStringAsFixed(2)}',
  //                               style: const TextStyle(
  //                                 fontWeight: FontWeight.bold,
  //                                 fontSize: 12,
  //                                 color: Colors.green,
  //                               ),
  //                             ),
  //                           ],
  //                         ),
  //                       ],

  //                       if (paymentMode != null) ...[
  //                         const SizedBox(height: 16),
  //                         const _DashedDivider(),
  //                         const SizedBox(height: 16),
  //                         Row(
  //                           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //                           children: [
  //                             Text(
  //                               'Mode of Payment',
  //                               style: TextStyle(
  //                                 color: Colors.grey.shade600,
  //                                 fontSize: 11,
  //                               ),
  //                             ),
  //                             Text(
  //                               paymentMode,
  //                               style: const TextStyle(
  //                                 fontWeight: FontWeight.bold,
  //                                 fontSize: 11,
  //                               ),
  //                             ),
  //                           ],
  //                         ),
  //                       ],

  //                       const SizedBox(height: 24),
  //                       Text(
  //                         'Thank you for your purchase!',
  //                         style: TextStyle(
  //                           color: Colors.grey.shade600,
  //                           fontSize: 11,
  //                           fontStyle: FontStyle.italic,
  //                         ),
  //                       ),
  //                       Text(
  //                         'This serves as your official receipt.',
  //                         style: TextStyle(
  //                           color: Colors.grey.shade600,
  //                           fontSize: 11,
  //                           fontStyle: FontStyle.italic,
  //                         ),
  //                       ),
  //                     ],
  //                   ),
  //                 ),
  //               ),
  //             ),

  //             Padding(
  //               padding: const EdgeInsets.only(
  //                 left: 24,
  //                 right: 24,
  //                 bottom: 24,
  //                 top: 12,
  //               ),
  //               child: Row(
  //                 children: [
  //                   Expanded(
  //                     child: ElevatedButton.icon(
  //                       onPressed: () {
  //                         Navigator.pop(context);
  //                         _showQRModal(
  //                           o.id,
  //                           paymentMode: paymentMode,
  //                           cashReceived: cashReceived,
  //                           change: change,
  //                         );
  //                       },
  //                       icon: const Icon(
  //                         LucideIcons.qrCode,
  //                         color: Colors.white,
  //                         size: 16,
  //                       ),
  //                       label: const Text(
  //                         'QR Receipt',
  //                         style: TextStyle(
  //                           color: Colors.white,
  //                           fontWeight: FontWeight.bold,
  //                         ),
  //                       ),
  //                       style: ElevatedButton.styleFrom(
  //                         backgroundColor: _cashierInk,
  //                         shape: RoundedRectangleBorder(
  //                           borderRadius: BorderRadius.circular(8),
  //                         ),
  //                         padding: const EdgeInsets.symmetric(vertical: 14),
  //                         elevation: 0,
  //                       ),
  //                     ),
  //                   ),
  //                   const SizedBox(width: 12),
  //                   Expanded(
  //                     child: OutlinedButton(
  //                       onPressed: () => Navigator.pop(context),
  //                       style: OutlinedButton.styleFrom(
  //                         foregroundColor: Colors.black87,
  //                         side: BorderSide(color: Colors.grey.shade300),
  //                         shape: RoundedRectangleBorder(
  //                           borderRadius: BorderRadius.circular(8),
  //                         ),
  //                         padding: const EdgeInsets.symmetric(vertical: 14),
  //                       ),
  //                       child: const Text(
  //                         'Done',
  //                         style: TextStyle(fontWeight: FontWeight.bold),
  //                       ),
  //                     ),
  //                   ),
  //                 ],
  //               ),
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //   );
  // }
  void _showReceiptDialog(
    CustomerOrder o, {
    String? paymentMode,
    String? paymentReference,
    String? gcashDestinationName,
    String? gcashDestinationNumber,
    double? cashReceived,
    double? change,
    DateTime? orderedAt,
    DateTime? completedAt,
  }) {
    double subtotal = 0;
    List<TableRow> tableRows = [];

    // Table Header
    tableRows.add(
      const TableRow(
        children: [
          Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'QTY.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'UNIT',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'ARTICLES',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'UNIT\nPRICE',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'AMOUNT',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );

    // Populate Items
    for (var item in o.items) {
      double price = 0;
      String unit = 'pcs';
      try {
        final dbItem = widget.controller.allItems.firstWhere(
          (i) => i.id == item.productId,
        );
        price = dbItem.price;
        unit = dbItem.unit;
      } catch (_) {}

      double itemTotal = price * item.quantity;
      subtotal += itemTotal;

      String qtyStr = item.quantity.truncateToDouble() == item.quantity
          ? item.quantity.toInt().toString()
          : item.quantity.toStringAsFixed(2);

      tableRows.add(
        TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Text(
                qtyStr,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Text(
                unit,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Text(
                item.productName,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Text(
                price.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6.0),
              child: Text(
                itemTotal.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
          ],
        ),
      );
    }

    // Add Empty Rows to mimic the physical pad spacing
    int emptyRows = o.items.length < 5 ? 5 - o.items.length : 1;
    for (int i = 0; i < emptyRows; i++) {
      tableRows.add(
        const TableRow(
          children: [
            Padding(padding: EdgeInsets.all(12.0), child: Text('')),
            Text(''),
            Text(''),
            Text(''),
            Text(''),
          ],
        ),
      );
    }

    // Totals Section
    tableRows.add(
      TableRow(
        children: [
          const SizedBox(),
          const SizedBox(),
          const SizedBox(),
          const Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'Total Sales',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6.0),
            child: Text(
              subtotal.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );

    tableRows.add(
      TableRow(
        children: [
          const SizedBox(),
          const SizedBox(),
          const SizedBox(),
          const Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'Less: SC/PWD-\nDiscount',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6.0),
            child: Text(
              o.discountAmount > 0 ? o.discountAmount.toStringAsFixed(2) : '',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11, color: Colors.black),
            ),
          ),
        ],
      ),
    );

    tableRows.add(
      TableRow(
        children: [
          const SizedBox(),
          const SizedBox(),
          const SizedBox(),
          const Padding(
            padding: EdgeInsets.all(6.0),
            child: Text(
              'TOTAL AMOUNT\nDUE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6.0),
            child: Text(
              o.totalAmount.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );

    final String cashierName =
        o.completedByName ?? widget.controller.currentUserName ?? 'Unknown';
    final DateTime completedTime = completedAt ?? DateTime.now();

    // Helper for form fields
    Widget formLine(String label, String value) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.black, width: 0.5),
                ),
              ),
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ],
      );
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Center(
          child: Container(
            width: 550, // Wider for the booklet look
            decoration: BoxDecoration(
              color: const Color(0xFFF7F6F4), // Slight off-white paper color
              borderRadius: BorderRadius.circular(4),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // --- INVOICE PAPER CONTENT (Now Scrollable) ---
                Flexible(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        children: [
                          // Header
                          const Text(
                            'SPRJ PAINT CENTER',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              color: Colors.black87,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Text(
                            '#64 San Vicente, 4023 San Pedro, Laguna, Philippines',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                            ),
                          ),
                          const Text(
                            'Sylvia P. Oroncillo - Prop.',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                            ),
                          ),
                          const Text(
                            'Non-VAT Reg. TIN: 622-145-904-00000',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Title & Number
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text(
                                'SALES INVOICE',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    'No. ',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red.shade700,
                                    ),
                                  ),
                                  Text(
                                    o.id.substring(0, 8).toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red.shade700,
                                      letterSpacing: 1.5,
                                      fontFamily: 'Courier',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),

                          // Customer Details Grid
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: formLine(
                                  'Sold To: ',
                                  'Walk-in Customer',
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 2,
                                child: formLine(
                                  'Date: ',
                                  _fmtReceiptDate(completedTime),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (paymentMode == 'GCash' &&
                              paymentReference?.isNotEmpty == true) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: formLine(
                                    'GCash Reference Number: ',
                                    paymentReference!,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                          ],
                          if (paymentMode == 'GCash' &&
                              gcashDestinationNumber?.isNotEmpty == true) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: formLine(
                                    'GCash paid to: ',
                                    '${gcashDestinationName?.isNotEmpty == true ? '$gcashDestinationName · ' : ''}$gcashDestinationNumber',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                          ],
                          Row(
                            children: [
                              Expanded(flex: 3, child: formLine('TIN: ', '')),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 2,
                                child: formLine(
                                  'Terms: ',
                                  paymentMode ?? 'Cash',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: formLine('Address: ', ''),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 2,
                                child: formLine('OSCA/PWD ID No.: ', ''),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: formLine('Business Style: ', ''),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 2,
                                child: formLine('SC/PWD Signature: ', ''),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Items Table
                          Table(
                            columnWidths: const {
                              0: FlexColumnWidth(1.0),
                              1: FlexColumnWidth(1.0),
                              2: FlexColumnWidth(4.5),
                              3: FlexColumnWidth(2.0),
                              4: FlexColumnWidth(2.5),
                            },
                            border: TableBorder.all(
                              color: Colors.black,
                              width: 1.0,
                            ),
                            defaultVerticalAlignment:
                                TableCellVerticalAlignment.middle,
                            children: tableRows,
                          ),
                          const SizedBox(height: 20),

                          // Footer Area
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // BIR & Printer Info
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '10 Bklts. (50x2) 0501 - 1000',
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black,
                                      ),
                                    ),
                                    Text(
                                      'BIR Authority to Print No. OCN: 057AU20240000000043\nDate Issued: 01-22-2024',
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black,
                                      ),
                                    ),
                                    SizedBox(height: 6),
                                    Text(
                                      'RYAN D. PRINTING SUPPLY AND SERVICES',
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black,
                                      ),
                                    ),
                                    Text(
                                      '158 Garcia St. San Vicente, San Pedro, Laguna\nNON-VAT Reg. TIN: 488-156-983-00000\nTel. No.: 8732-0157 / 09463747264',
                                      style: TextStyle(
                                        fontSize: 8,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Cashier Signature
                              Column(
                                children: [
                                  Text(
                                    cashierName,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black,
                                    ),
                                  ),
                                  Container(
                                    height: 1,
                                    width: 180,
                                    color: Colors.black,
                                  ),
                                  const SizedBox(height: 2),
                                  const Text(
                                    'Cashier/Authorized Representative',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Printer\'s Accreditation No: 057MP20210000000004\nDate Issued 10/13/2021     Valid Until: 10/12/2026',
                                    style: TextStyle(
                                      fontSize: 7,
                                      color: Colors.black,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // --- ACTION BUTTONS (Grey Footer) ---
                Container(
                  color: Colors.grey.shade200,
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(context);
                            await _showTrackingQRForOrder(o.id);
                          },
                          icon: const Icon(
                            LucideIcons.qrCode,
                            color: Colors.white,
                            size: 16,
                          ),
                          label: const Text(
                            'Tracking QR',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black87,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.black87,
                            side: const BorderSide(color: Colors.black45),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: const Text(
                            'Close',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showOrderTrackingQR(String orderId, String token) {
    final trackingUrl = Uri.https(
      'inventoryplusreceipt.netlify.app',
      '/status/',
      {'token': token},
    ).toString();
    final qrSize = math.min(
      220.0,
      math.max(80.0, MediaQuery.sizeOf(context).width - 112),
    );

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.qrCode,
        color: _cashierAccent,
        title: 'Track this order',
        subtitle: 'Order #${orderId.substring(0, 8).toUpperCase()}',
        maxWidth: 420,
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: ElevatedButton.styleFrom(
              backgroundColor: _cashierAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Done'),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ask the customer to scan this QR code to see their order progress.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            QrImageView(
              key: const ValueKey('customer-order-tracking-qr'),
              data: trackingUrl,
              version: QrVersions.auto,
              size: qrSize,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: trackingUrl));
                if (dialogContext.mounted) {
                  AppToast.success(dialogContext, 'Tracking link copied.');
                }
              },
              icon: const Icon(Icons.copy_outlined, size: 17),
              label: const Text('Copy tracking link'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTrackingQRForOrder(String orderId) async {
    try {
      final token = await widget.controller.customerOrderTrackingToken(orderId);
      if (mounted) _showOrderTrackingQR(orderId, token);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Order tracking QR unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(context, 'Tracking QR is unavailable right now.');
      }
    }
  }

  void _showPendingOrdersModal(BuildContext context, {String? targetOrderId}) {
    var targetOrderWasOpened = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: Colors.white,
          child: Container(
            width: 480,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Pending Orders',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _cashierInk,
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            LucideIcons.x,
                            size: 18,
                            color: Colors.grey,
                          ),
                          onPressed: () => Navigator.pop(dialogContext),
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: StreamBuilder<List<CustomerOrder>>(
                    stream: widget.controller.streamOrders(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: _cashierAccent,
                          ),
                        );
                      }
                      final pendingOrders = snapshot.data!
                          .where(
                            (o) =>
                                o.status == 'prepared' || o.status == 'pending',
                          )
                          .toList();

                      if (targetOrderId != null) {
                        final allOrders = snapshot.data!;
                        final matchingOrder = allOrders
                            .where((order) => order.id == targetOrderId)
                            .toList();

                        if (!targetOrderWasOpened &&
                            matchingOrder.isNotEmpty &&
                            (matchingOrder.first.status == 'pending' ||
                                matchingOrder.first.status == 'prepared')) {
                          targetOrderWasOpened = true;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) widget.onOrderOpened?.call();
                          });
                        }

                        if (!targetOrderWasOpened &&
                            matchingOrder.isNotEmpty &&
                            matchingOrder.first.status == 'completed') {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!dialogContext.mounted) return;

                            Navigator.pop(dialogContext);

                            AppToast.error(
                              context,
                              'This order is already completed.',
                            );

                            widget.onOrderOpened?.call();
                          });

                          return const SizedBox.shrink();
                        }
                      }

                      if (pendingOrders.isEmpty) {
                        return const Center(
                          child: Text(
                            'No pending orders.',
                            style: TextStyle(color: Colors.grey, fontSize: 15),
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.all(20),
                        itemCount: pendingOrders.length,
                        itemBuilder: (context, index) {
                          final o = pendingOrders[index];
                          final isReady = o.status == 'prepared';
                          final mainColor = isReady
                              ? Colors.green
                              : _cashierAccent;
                          final bgColor = isReady
                              ? Colors.green.shade50
                              : _cashierTint;
                          final iconData = isReady
                              ? LucideIcons.check
                              : LucideIcons.clock;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade200),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.03),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              children: [
                                Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  child: SizedBox(
                                    width: 6,
                                    child: ColoredBox(color: mainColor),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                      dividerColor: Colors.transparent,
                                    ),
                                    child: ExpansionTile(
                                      key: ValueKey(
                                        '${o.id}-${targetOrderId == o.id}',
                                      ),
                                      initiallyExpanded: targetOrderId == o.id,
                                      tilePadding: const EdgeInsets.only(
                                        left: 12,
                                        right: 16,
                                        top: 4,
                                        bottom: 4,
                                      ),
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: bgColor,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          iconData,
                                          color: mainColor,
                                          size: 16,
                                        ),
                                      ),
                                      title: Text(
                                        'Order #${(o.id.length <= 8 ? o.id : o.id.substring(0, 8)).toUpperCase()}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          color: _cashierInk,
                                        ),
                                      ),
                                      subtitle: Text(
                                        cashierPreparationSubtitle(o),
                                        style: TextStyle(
                                          color: mainColor,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      trailing: SizedBox(
                                        width: 70,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            Text(
                                              '${o.items.length} item${o.items.length == 1 ? '' : 's'}',
                                              style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.arrow_drop_down,
                                              color: Colors.grey.shade400,
                                              size: 20,
                                            ),
                                          ],
                                        ),
                                      ),
                                      childrenPadding: const EdgeInsets.only(
                                        left: 16,
                                        right: 16,
                                        bottom: 16,
                                      ),
                                      children: [
                                        CashierOrderPreparation(order: o),
                                        if (o.loadingVerifiedAt != null &&
                                            o.items.any(
                                              (item) => item.requiresLoading,
                                            )) ...[
                                          const SizedBox(height: 10),
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              final reviewed =
                                                  await OrderDetailsDrawer.showLoadingProof(
                                                    dialogContext,
                                                    order: o,
                                                    loader: widget
                                                        .controller
                                                        .getOrderLoadingProof,
                                                  );
                                              if (reviewed && mounted) {
                                                _reviewedLoadingProofOrderIds
                                                    .add(o.id);
                                                _proofReviewVersion.value++;
                                              }
                                            },
                                            icon: const Icon(
                                              Icons.photo_outlined,
                                            ),
                                            label: const Text(
                                              'Review truck and item photos',
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 10),
                                        ...o.items.map(
                                          (item) => CashierOrderItemRow(
                                            order: o,
                                            item: item,
                                          ),
                                        ),
                                        if (isReady) ...[
                                          const SizedBox(height: 16),
                                          ValueListenableBuilder<int>(
                                            valueListenable:
                                                _proofReviewVersion,
                                            builder: (context, _, child) => SizedBox(
                                              width: double.infinity,
                                              height: 44,
                                              child: ElevatedButton.icon(
                                                icon: const Icon(
                                                  LucideIcons.check,
                                                  color: Colors.white,
                                                  size: 18,
                                                ),
                                                label: const Text(
                                                  'Complete Transaction',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.green,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  elevation: 0,
                                                ),
                                                onPressed:
                                                    o.items.any(
                                                          (item) => item
                                                              .requiresLoading,
                                                        ) &&
                                                        !_reviewedLoadingProofOrderIds
                                                            .contains(o.id)
                                                    ? null
                                                    : () => _completeOrderFlow(
                                                        o,
                                                        onCompleted: () {
                                                          if (dialogContext
                                                              .mounted)
                                                            Navigator.pop(
                                                              dialogContext,
                                                            );
                                                        },
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 10),
                                        SizedBox(
                                          width: double.infinity,
                                          height: 40,
                                          child: OutlinedButton.icon(
                                            icon: Icon(
                                              LucideIcons.undo2,
                                              size: 16,
                                              color: Colors.red.shade400,
                                            ),
                                            label: Text(
                                              'Cancel & Edit',
                                              style: TextStyle(
                                                color: Colors.red.shade400,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                            style: OutlinedButton.styleFrom(
                                              side: BorderSide(
                                                color: Colors.red.shade100,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                            ),
                                            onPressed: () async {
                                              final ok =
                                                  await _cancelOrderAndRestoreCart(
                                                    o,
                                                    fromQueue: true,
                                                  );
                                              if (ok && dialogContext.mounted) {
                                                Navigator.pop(dialogContext);
                                              }
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).then((_) {
      if (!mounted) return;

      _pendingAutoOpenOrderId = null;
      widget.onOrderOpened?.call();
    });
  }

  Widget _buildImage(String imageUrl) {
    if (imageUrl.isEmpty) {
      return Container(
        color: Colors.grey.shade100,
        child: const Center(
          child: Icon(LucideIcons.image, color: Colors.grey, size: 40),
        ),
      );
    }
    if (kIsWeb || imageUrl.startsWith('http')) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: Colors.grey.shade100,
          child: const Center(
            child: Icon(LucideIcons.image, color: Colors.grey),
          ),
        ),
      );
    } else {
      return Image.file(
        File(imageUrl),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: Colors.grey.shade100,
          child: const Center(
            child: Icon(LucideIcons.image, color: Colors.grey),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InventoryItem>>(
      stream: widget.controller.streamInventory(),
      initialData: widget.controller.currentInventory,
      builder: (context, snapshot) => _buildPosView(context),
    );
  }

  Widget _buildCategoryDropdown(List<String> categories) {
    final selectedCategory = categories.contains(_selectedCategory)
        ? _selectedCategory
        : 'All';
    return SizedBox(
      height: 44,
      child: AppStyledDropdown<String>(
        value: selectedCategory,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 9,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _cashierWarmBorder),
          ),
        ),
        items: categories
            .map(
              (category) => DropdownMenuItem<String>(
                value: category,
                child: Text(
                  category == 'All' ? 'All categories' : category,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(growable: false),
        onChanged: (category) {
          if (category != null) {
            setState(() => _selectedCategory = category);
          }
        },
      ),
    );
  }

  Widget _buildCollapsedCartRail() {
    final itemCount = _cart.length;
    final total = _discountCalculation(_calculateTotal()).total;
    return Material(
      color: Colors.white,
      child: Container(
        width: 76,
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: _cashierWarmBorder)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            IconButton(
              tooltip: 'Expand order cart',
              onPressed: () => setState(() => _isCartCollapsed = false),
              icon: const Icon(
                LucideIcons.chevronLeft,
                color: _cashierPrimary,
                size: 20,
              ),
            ),
            const SizedBox(height: 8),
            const Icon(LucideIcons.shoppingCart, size: 20, color: _cashierInk),
            const SizedBox(height: 8),
            Text(
              '$itemCount items',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _cashierInk,
              ),
            ),
            const SizedBox(height: 10),
            Tooltip(
              message: 'Total due: ₱${total.toStringAsFixed(2)}',
              child: const Icon(
                LucideIcons.shoppingCart,
                size: 16,
                color: _cashierMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartHeader({
    required bool mobileFullPage,
    required int distinctItems,
    required String qtyDisplay,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _cashierWarmBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (mobileFullPage)
                IconButton(
                  tooltip: 'Back to products',
                  onPressed: () => setState(() => _showMobileCart = false),
                  icon: const Icon(
                    LucideIcons.arrowLeft,
                    color: _cashierInk,
                    size: 20,
                  ),
                )
              else
                const Icon(
                  LucideIcons.shoppingCart,
                  color: _cashierInk,
                  size: 18,
                ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  mobileFullPage ? 'Your cart' : 'Current order cart',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: _cashierInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!mobileFullPage)
                IconButton(
                  tooltip: 'Collapse order cart',
                  onPressed: () => setState(() => _isCartCollapsed = true),
                  icon: const Icon(
                    LucideIcons.chevronRight,
                    color: _cashierInk,
                    size: 19,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _cartSummaryPill('$distinctItems items'),
              const SizedBox(width: 7),
              _cartSummaryPill('$qtyDisplay qty'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cartSummaryPill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: _cashierSurface,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: _cashierWarmBorder),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: _cashierMuted,
      ),
    ),
  );

  Widget _buildPosView(BuildContext context) {
    return PopScope(
      canPop: !_showMobileCart || MediaQuery.sizeOf(context).width >= 800,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop &&
            _showMobileCart &&
            MediaQuery.sizeOf(context).width < 800) {
          setState(() => _showMobileCart = false);
        }
      },
      child: Scaffold(
        backgroundColor: _cashierSurface,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 800;

            if (isDesktop) {
              final cartWidth = (constraints.maxWidth * 0.34)
                  .clamp(310.0, 390.0)
                  .toDouble();
              return Row(
                children: [
                  Expanded(child: _buildItemList()),
                  SizedBox(
                    width: _isCartCollapsed ? 76 : cartWidth,
                    child: _isCartCollapsed
                        ? _buildCollapsedCartRail()
                        : _buildCartPanel(),
                  ),
                ],
              );
            }

            if (_showMobileCart) {
              return _buildCartPanel(mobileFullPage: true);
            }
            return Column(
              children: [
                Expanded(child: _buildItemList()),
                _buildMobileCartButton(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMobileCartButton() {
    final count = _cart.length;
    final total = _discountCalculation(_calculateTotal()).total;
    return Material(
      color: Colors.white,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: () => setState(() => _showMobileCart = true),
              style: FilledButton.styleFrom(backgroundColor: _cashierPrimary),
              child: Row(
                children: [
                  const Icon(LucideIcons.shoppingCart, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'View cart',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '$count ${count == 1 ? 'item' : 'items'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (MediaQuery.sizeOf(context).width >= 380) ...[
                    const SizedBox(width: 12),
                    Text(
                      '₱${total.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryPosAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    int? badgeCount,
    bool emphasized = false,
  }) {
    final foregroundColor = emphasized ? Colors.white : _cashierInk;
    final backgroundColor = emphasized ? _cashierPrimary : Colors.white;

    final borderColor = emphasized ? _cashierPrimary : _cashierWarmBorder;

    return SizedBox(
      height: 44,
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: emphasized ? 0 : 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: foregroundColor),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foregroundColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (badgeCount != null && badgeCount > 0) ...[
                  const SizedBox(width: 8),

                  Container(
                    height: 24,
                    constraints: const BoxConstraints(minWidth: 24),
                    padding: EdgeInsets.symmetric(
                      horizontal: badgeCount > 9 ? 7 : 0,
                    ),
                    decoration: BoxDecoration(
                      color: emphasized ? Colors.white : _cashierAccent,
                      shape: badgeCount < 10
                          ? BoxShape.circle
                          : BoxShape.rectangle,
                      borderRadius: badgeCount < 10
                          ? null
                          : BorderRadius.circular(999),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      badgeCount > 99 ? '99+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: emphasized ? _cashierAccent : Colors.white,
                        fontSize: 11,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _posQuantity(double quantity) {
    return quantity == quantity.truncateToDouble()
        ? quantity.toInt().toString()
        : quantity.toStringAsFixed(2);
  }

  void _showPosProductDetails(InventoryItem item) {
    Widget detailLine(String label, String? value) {
      final cleaned = value?.trim() ?? '';
      if (cleaned.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: _cashierMuted),
              ),
            ),
            Expanded(
              child: SelectableText(
                cleaned,
                style: const TextStyle(
                  fontSize: 13,
                  color: _cashierInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final available = item.quantity - (_cart[item.id] ?? 0);
        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 500,
              maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.83,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Product details',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _cashierInk,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close details',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(LucideIcons.x, size: 18),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _cashierWarmBorder),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: SizedBox(
                                width: 90,
                                height: 90,
                                child: _buildImage(item.imageUrl),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.displayName,
                                    style: const TextStyle(
                                      color: _cashierInk,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    item.sku.isEmpty ? 'No SKU' : item.sku,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: _cashierMuted,
                                    ),
                                  ),
                                  const SizedBox(height: 9),
                                  Text(
                                    '₱${item.price.toStringAsFixed(2)} / ${item.unit}',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      color: _cashierInk,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        detailLine('Category', item.category),
                        detailLine(
                          'Stock on hand',
                          '${_posQuantity(item.quantity)} ${item.unit}',
                        ),
                        detailLine(
                          'Available to add',
                          '${_posQuantity(math.max(0.0, available))} ${item.unit}',
                        ),
                        detailLine('Manufacturer', item.manufacturer),
                        detailLine('Model', item.model),
                        detailLine('Size', item.productSize),
                        detailLine('Color', item.color),
                        detailLine('Shelf', item.shelfLevel),
                        detailLine('Bin', item.binNumber),
                        if (item.description.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Text(
                            'Description',
                            style: TextStyle(
                              fontSize: 12,
                              color: _cashierMuted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.description,
                            style: const TextStyle(
                              fontSize: 13,
                              color: _cashierInk,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1, color: _cashierWarmBorder),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Close'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _cashierPrimary,
                          ),
                          onPressed: available <= 0 || _isProcessingCart
                              ? null
                              : () {
                                  if (_addToCart(item)) {
                                    Navigator.pop(dialogContext);
                                  }
                                },
                          icon: const Icon(LucideIcons.plus, size: 16),
                          label: const Text('Add to cart'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPosTableHeading(String label, {TextAlign? align}) => Text(
    label,
    textAlign: align,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: _cashierMuted,
    ),
  );

  // Keep secondary product attributes in the main product cell rather than
  // introducing four additional table columns (and horizontal scrolling).
  Widget _buildPosSpecSummary(InventoryItem item) {
    final details = <String>[
      if (item.manufacturer?.trim().isNotEmpty ?? false)
        'Manufacturer: ${item.manufacturer!.trim()}',
      if (item.model?.trim().isNotEmpty ?? false)
        'Model: ${item.model!.trim()}',
      if (item.productSize?.trim().isNotEmpty ?? false)
        'Size: ${item.productSize!.trim()}',
      if (item.color?.trim().isNotEmpty ?? false)
        'Color: ${item.color!.trim()}',
    ];

    if (details.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Wrap(
        spacing: 10,
        runSpacing: 3,
        children: [
          for (final detail in details)
            Text(
              detail,
              softWrap: true,
              style: const TextStyle(
                color: _cashierMuted,
                fontSize: 10,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPosTableRow(InventoryItem item, int index, bool compact) {
    final inCart = _cart[item.id] ?? 0;
    final available = item.quantity - inCart;
    final canAdd = available > 0 && !_isProcessingCart;
    final skuLabel = item.sku.isEmpty ? 'No SKU' : item.sku;

    return Material(
      color: index.isEven ? Colors.white : const Color(0xFFFCFBFA),
      child: InkWell(
        onTap: () => _addToCart(item),
        hoverColor: const Color(0xFFF6F1ED),
        child: Container(
          constraints: const BoxConstraints(minHeight: 74),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _cashierWarmBorder)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 43,
                        width: 43,
                        child: _buildImage(item.imageUrl),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _cashierInk,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            compact ? '$skuLabel · ${item.category}' : skuLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _cashierMuted,
                              fontSize: 10,
                            ),
                          ),
                          _buildPosSpecSummary(item),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: Text(
                    item.category,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: _cashierInk),
                  ),
                ),
              ],
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      available > 0
                          ? '${_posQuantity(available)} ${item.unit}'
                          : 'Out of stock',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: available > 0
                            ? const Color(0xFF206A47)
                            : const Color(0xFFB42318),
                      ),
                    ),
                    if (inCart > 0)
                      Text(
                        '${_posQuantity(inCart)} in cart',
                        style: const TextStyle(
                          fontSize: 10,
                          color: _cashierMuted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Text(
                  '₱${item.price.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: _cashierInk,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Hellix',
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _posShowDetailsButton ? 126 : 76,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_posShowDetailsButton) ...[
                      TextButton(
                        onPressed: () => _showPosProductDetails(item),
                        style: TextButton.styleFrom(
                          foregroundColor: _cashierInk,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(66, 34),
                        ),
                        child: const Text(
                          'Details',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    IconButton(
                      tooltip: canAdd ? 'Add to cart' : 'Stock unavailable',
                      onPressed: canAdd ? () => _addToCart(item) : null,
                      style: IconButton.styleFrom(
                        backgroundColor: _cashierAccent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFFE5E1DD),
                        disabledForegroundColor: _cashierMuted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      icon: const Icon(LucideIcons.plus, size: 17),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // A stacked, POS-friendly row for small viewports. Product rows still add to
  // the cart; no separate grid mode or horizontal scrolling is introduced.
  Widget _buildPosNarrowRow(InventoryItem item, int index) {
    final inCart = _cart[item.id] ?? 0;
    final available = item.quantity - inCart;
    final canAdd = available > 0 && !_isProcessingCart;
    final skuLabel = item.sku.isEmpty ? 'No SKU' : item.sku;

    return Material(
      color: index.isEven ? Colors.white : const Color(0xFFFCFBFA),
      child: InkWell(
        onTap: () => _addToCart(item),
        hoverColor: const Color(0xFFF6F1ED),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _cashierWarmBorder)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: _buildImage(item.imageUrl),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _cashierInk,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$skuLabel · ${item.category}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _cashierMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: canAdd ? 'Add to cart' : 'Stock unavailable',
                    onPressed: canAdd ? () => _addToCart(item) : null,
                    style: IconButton.styleFrom(
                      backgroundColor: _cashierAccent,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE5E1DD),
                      disabledForegroundColor: _cashierMuted,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    icon: const Icon(LucideIcons.plus, size: 17),
                  ),
                ],
              ),
              _buildPosSpecSummary(item),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      available > 0
                          ? 'Available: ${_posQuantity(available)} ${item.unit}'
                          : 'Out of stock',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: available > 0
                            ? const Color(0xFF206A47)
                            : const Color(0xFFB42318),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '₱${item.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: _cashierInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (inCart > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '${_posQuantity(inCart)} in cart',
                    style: const TextStyle(color: _cashierMuted, fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemList() {
    final categories = [
      'All',
      ...widget.controller.getUniqueCategories().where(
        (category) =>
            category.toLowerCase() != 'unassigned' &&
            category.toLowerCase() != 'all',
      ),
    ];
    final products = _filteredItems;
    final hasFilter =
        _searchQuery.trim().isNotEmpty || _selectedCategory != 'All';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              Widget searchField() => SizedBox(
                height: 44,
                child: TextField(
                  controller: _productSearchController,
                  style: const TextStyle(fontSize: 13, color: _cashierInk),
                  decoration: InputDecoration(
                    hintText: 'Search by name, SKU, or color',
                    hintStyle: const TextStyle(
                      fontSize: 12,
                      color: _cashierMuted,
                    ),
                    prefixIcon: const Icon(
                      LucideIcons.search,
                      size: 18,
                      color: _cashierMuted,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: _cashierWarmBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: _cashierWarmBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                      borderSide: const BorderSide(color: _cashierAccent),
                    ),
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              );

              Widget pendingOrdersButton() =>
                  StreamBuilder<List<CustomerOrder>>(
                    stream: widget.controller.streamOrders(),
                    builder: (context, snapshot) {
                      final pendingCount =
                          snapshot.data
                              ?.where(
                                (order) =>
                                    order.status == 'prepared' ||
                                    order.status == 'pending',
                              )
                              .length ??
                          0;
                      return _buildPrimaryPosAction(
                        icon: LucideIcons.clock,
                        label: 'Orders',
                        badgeCount: pendingCount,
                        onPressed: () => _showPendingOrdersModal(context),
                      );
                    },
                  );

              Widget scannerButton() => _buildPrimaryPosAction(
                icon: LucideIcons.scanLine,
                label: 'Object Scanner',
                emphasized: true,
                onPressed: _openAIObjectScanner,
              );

              Widget actionsRow() => Row(
                children: [
                  Expanded(child: pendingOrdersButton()),
                  const SizedBox(width: 10),
                  Expanded(child: scannerButton()),
                ],
              );

              if (constraints.maxWidth < 540) {
                return Column(
                  children: [
                    searchField(),
                    const SizedBox(height: 10),
                    _buildCategoryDropdown(categories),
                    const SizedBox(height: 10),
                    actionsRow(),
                  ],
                );
              }

              if (constraints.maxWidth < 1050) {
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: searchField()),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 170,
                          child: _buildCategoryDropdown(categories),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    actionsRow(),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: searchField()),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 170,
                    child: _buildCategoryDropdown(categories),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(width: 170, child: pendingOrdersButton()),
                  const SizedBox(width: 10),
                  SizedBox(width: 175, child: scannerButton()),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              const Text(
                'Products',
                style: TextStyle(
                  color: _cashierInk,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                '${products.length} found',
                style: const TextStyle(fontSize: 11, color: _cashierMuted),
              ),
              const Spacer(),
              if (MediaQuery.sizeOf(context).width > 700)
                const Text(
                  'Select a row to add to cart',
                  style: TextStyle(fontSize: 11, color: _cashierMuted),
                ),
            ],
          ),
        ),
        Expanded(
          child: products.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          LucideIcons.search,
                          size: 34,
                          color: _cashierMuted,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          hasFilter
                              ? 'No matching products'
                              : 'No products available',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _cashierInk,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          hasFilter
                              ? 'Try another search or select a different category.'
                              : 'Products will appear here once inventory is available.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _cashierMuted,
                            fontSize: 12,
                          ),
                        ),
                        if (hasFilter) ...[
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: () {
                              _productSearchController.clear();
                              setState(() {
                                _searchQuery = '';
                                _selectedCategory = 'All';
                              });
                            },
                            icon: const Icon(LucideIcons.x, size: 15),
                            label: const Text('Clear filters'),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final visibleWidth = math.max(
                      0.0,
                      constraints.maxWidth - 32,
                    );
                    final compact = visibleWidth < 810;
                    final narrow = visibleWidth < 620;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: _cashierWarmBorder),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              if (!narrow)
                                Container(
                                  height: 44,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                  ),
                                  color: const Color(0xFFF4F2F0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        flex: 5,
                                        child: _buildPosTableHeading(
                                          'Product / specifications',
                                        ),
                                      ),
                                      if (!compact) ...[
                                        const SizedBox(width: 12),
                                        Expanded(
                                          flex: 2,
                                          child: _buildPosTableHeading(
                                            'Category',
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 12),
                                      Expanded(
                                        flex: 2,
                                        child: _buildPosTableHeading(
                                          'Available',
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        flex: 2,
                                        child: _buildPosTableHeading(
                                          'Unit price',
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      SizedBox(
                                        width: _posShowDetailsButton ? 126 : 76,
                                        child: _buildPosTableHeading(
                                          'Actions',
                                          align: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: products.length,
                                  itemBuilder: (context, index) => narrow
                                      ? _buildPosNarrowRow(
                                          products[index],
                                          index,
                                        )
                                      : _buildPosTableRow(
                                          products[index],
                                          index,
                                          compact,
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCartPanel({bool mobileFullPage = false}) {
    int distinctItems = _cart.length;
    double totalQty = _cart.values.fold(0.0, (sum, val) => sum + val);
    String qtyDisplay = totalQty.truncateToDouble() == totalQty
        ? totalQty.toInt().toString()
        : totalQty.toStringAsFixed(2);

    double subtotal = _calculateTotal();
    final discount = _discountCalculation(subtotal);
    final discountAmt = discount.discountAmount;
    final totalDue = discount.total;
    final requiresDiscountApproval = _requiresDiscountApproval(subtotal);
    final hasDiscountApproval = _hasUsableDiscountApproval(subtotal);
    final approvalPending =
        requiresDiscountApproval &&
        _discountApproval?.status == InventoryApprovalStatus.pending;

    return ClipRect(
      child: Container(
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _buildCartHeader(
              mobileFullPage: mobileFullPage,
              distinctItems: distinctItems,
              qtyDisplay: qtyDisplay,
            ),

            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final availH = constraints.maxHeight;
                  if (availH <= 0) return const SizedBox.shrink();
                  final opacity = (availH / 60.0).clamp(0.0, 1.0);

                  return AnimatedOpacity(
                    opacity: opacity,
                    duration: const Duration(milliseconds: 80),
                    child: ClipRect(
                      child: _cart.isEmpty
                          ? const Center(
                              child: Text(
                                'Cart is empty',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              itemCount: _cart.length,
                              itemBuilder: (context, index) {
                                final itemId = _cart.keys.elementAt(index);
                                final qty = _cart[itemId]!;
                                InventoryItem item;
                                try {
                                  item = widget.controller.allItems.firstWhere(
                                    (i) => i.id == itemId,
                                  );
                                } catch (_) {
                                  return const SizedBox.shrink();
                                }

                                bool isFractional = ![
                                  'pcs',
                                  'box',
                                  'pack',
                                  '',
                                ].contains(item.unit.toLowerCase());

                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 6,
                                  ),
                                  color: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Wrap(
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                spacing: 6,
                                                children: [
                                                  Text(
                                                    item.displayName,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 14,
                                                      color: _cashierInk,
                                                    ),
                                                  ),
                                                  if (isFractional)
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 4,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: _cashierTint,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              4,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        "BY WEIGHT",
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: _cashierAccent,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            Text(
                                              "₱${(item.price * qty).toStringAsFixed(2)}",
                                              style: const TextStyle(
                                                color: _cashierAccent,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                                fontFamily: 'Hellix',
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Text(
                                              "₱${item.price.toStringAsFixed(2)} / ${item.unit}",
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey.shade500,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            _QuantityStepper(
                                              initialValue: qty,
                                              unit: item.unit,
                                              onChanged: (newQty) =>
                                                  _setCartQuantity(
                                                    itemId,
                                                    newQty,
                                                  ),
                                            ),
                                            IconButton(
                                              icon: Icon(
                                                LucideIcons.trash2,
                                                color: Colors.red.shade400,
                                                size: 18,
                                              ),
                                              onPressed: () =>
                                                  _setCartQuantity(itemId, 0),
                                              constraints:
                                                  const BoxConstraints(),
                                              padding: const EdgeInsets.all(8),
                                              style: IconButton.styleFrom(
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  side: BorderSide(
                                                    color: Colors.red.shade100,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  );
                },
              ),
            ),

            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  if (_discountValue > 0) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _cashierTint,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFF2D4C4)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isDiscountPercentage
                                      ? "${_discountValue.toStringAsFixed(_discountValue.truncateToDouble() == _discountValue ? 0 : 2)}% ${_discountReason.isEmpty ? 'Discount' : _discountReason}"
                                      : "₱${_discountValue.toStringAsFixed(_discountValue.truncateToDouble() == _discountValue ? 0 : 2)} ${_discountReason.isEmpty ? 'Discount' : _discountReason}",
                                  style: const TextStyle(
                                    color: _cashierAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  "Applied to subtotal",
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            "-₱${discountAmt.toStringAsFixed(2)}",
                            style: const TextStyle(
                              color: _cashierAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              fontFamily: 'Hellix',
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            onTap: () {
                              setState(() {
                                _invalidateDiscountApproval();
                                _discountValue = 0.0;
                                _discountReason = '';
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFFF2D4C4),
                                ),
                              ),
                              child: const Icon(
                                LucideIcons.x,
                                size: 14,
                                color: _cashierAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    InkWell(
                      onTap: () => _showDiscountDialog(context),
                      borderRadius: BorderRadius.circular(9),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 13,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: _cashierWarmBorder),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              LucideIcons.plus,
                              size: 16,
                              color: _cashierMuted,
                            ),
                            SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                'Add discount',
                                style: TextStyle(
                                  color: _cashierInk,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              LucideIcons.chevronRight,
                              size: 16,
                              color: _cashierMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Subtotal",
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        "₱${subtotal.toStringAsFixed(2)}",
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                          fontFamily: 'Hellix',
                        ),
                      ),
                    ],
                  ),
                  if (_discountValue > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Discount",
                          style: TextStyle(
                            color: _cashierAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          "-₱${discountAmt.toStringAsFixed(2)}",
                          style: const TextStyle(
                            color: _cashierAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Hellix',
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  const _DashedDivider(),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Total Due",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        "₱${totalDue.toStringAsFixed(2)}",
                        style: const TextStyle(
                          color: _cashierPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          fontFamily: 'Hellix',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (requiresDiscountApproval) ...[
                    _buildDiscountApprovalStatus(
                      subtotal: subtotal,
                      approved: hasDiscountApproval,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_cartHasHeavyItems) ...[
                    InkWell(
                      onTap: () => _showLoadingInstructionsDialog(context),
                      borderRadius: BorderRadius.circular(9),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 13,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: _cashierWarmBorder),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _truckIdentifierController.text.isEmpty
                                  ? LucideIcons.plus
                                  : LucideIcons.pencil,
                              size: 16,
                              color: _cashierMuted,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                _truckIdentifierController.text.isEmpty
                                    ? 'Add loading instructions'
                                    : 'Edit loading instructions · ${_truckIdentifierController.text}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _cashierInk,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Icon(
                              LucideIcons.chevronRight,
                              size: 16,
                              color: _cashierMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _buildHelperAssignmentControl(),
                  const SizedBox(height: 12),

                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed:
                          _cart.isEmpty ||
                              _isProcessingCart ||
                              _isRequestingDiscountApproval ||
                              approvalPending
                          ? null
                          : requiresDiscountApproval && !hasDiscountApproval
                          ? _requestDiscountApproval
                          : _processOrder,
                      icon: _isProcessingCart || _isRequestingDiscountApproval
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(
                              requiresDiscountApproval && !hasDiscountApproval
                                  ? LucideIcons.shieldCheck
                                  : LucideIcons.check,
                              color: Colors.white,
                              size: 20,
                            ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _cashierPrimary,
                        disabledBackgroundColor: Colors.grey.shade300,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
                      ),
                      label: Text(
                        _isProcessingCart
                            ? 'Processing...'
                            : _isRequestingDiscountApproval
                            ? 'Requesting...'
                            : approvalPending
                            ? 'Awaiting Admin Approval'
                            : requiresDiscountApproval && !hasDiscountApproval
                            ? 'Request Approval'
                            : mobileFullPage
                            ? 'Process Order'
                            : (_soloMode ? 'Process & Pack' : 'Process Order'),
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Hellix',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscountApprovalStatus({
    required double subtotal,
    required bool approved,
  }) {
    final request = _discountApproval;
    final rejected = request?.status == InventoryApprovalStatus.rejected;
    final pending = request?.status == InventoryApprovalStatus.pending;
    final color = approved
        ? const Color(0xFF15803D)
        : rejected
        ? const Color(0xFFDC2626)
        : const Color(0xFFD97706);
    final title = approved
        ? 'Discount approved'
        : rejected
        ? 'Discount rejected'
        : pending
        ? 'Admin approval pending'
        : 'Admin approval required';
    final effective = _effectiveDiscountPercentage(subtotal);
    final limit = widget.controller.cashierAutoApprovedDiscountLimitPct;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(
            approved
                ? LucideIcons.badgeCheck
                : rejected
                ? LucideIcons.circleX
                : LucideIcons.shieldAlert,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${effective.toStringAsFixed(2)}% effective discount; '
                  'Cashier limit ${limit.toStringAsFixed(2)}%.',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                  ),
                ),
                if (rejected &&
                    (request?.reviewNote?.trim().isNotEmpty ?? false))
                  Text(
                    request!.reviewNote!,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelperAssignmentControl() {
    final presenceService = widget.presenceService;
    final needsBodegero = _cartHasHeavyItems;
    final hasLightItems = _cartHasLightItems;

    if (presenceService == null && !needsBodegero) {
      return const HelperAssignmentSelector(
        helpers: <HelperAssignmentCandidate>[],
        workloads: <String, int>{},
        selectedHelperId: null,
        enabled: false,
        onChanged: null,
      );
    }

    return StreamBuilder<List<CustomerOrder>>(
      stream: widget.controller.orderSnapshots,
      initialData: widget.controller.currentOrders,
      builder: (context, orderSnapshot) {
        final orders = orderSnapshot.data ?? widget.controller.currentOrders;
        if (presenceService == null) {
          return _buildStaffAssignmentPair(
            helpers: const <HelperAssignmentCandidate>[],
            bodegeros: const <HelperAssignmentCandidate>[],
            helperWorkloads: const <String, int>{},
            bodegeroWorkloads: const <String, int>{},
            hasLightItems: hasLightItems,
          );
        }
        return AnimatedBuilder(
          animation: presenceService,
          builder: (context, _) {
            final helpers = rankHelpersByActiveWorkload(
              helpers: presenceService.eligibleHelpersForAssignment,
              orders: orders,
            );
            if (!needsBodegero) {
              // Preserve the entire existing light-only POS presentation.
              return HelperAssignmentSelector(
                helpers: helpers,
                workloads: activePreparationWorkloads(orders),
                selectedHelperId: _selectedHelperId,
                enabled: !_isProcessingCart,
                onChanged: (helperId) {
                  if (_selectedHelperId == helperId) return;
                  setState(() => _selectedHelperId = helperId);
                },
              );
            }
            final bodegeroWorkloads = activeLoadingWorkloads(orders);
            final bodegeros = presenceService.eligibleBodegerosForAssignment
                .toList();
            bodegeros.sort((a, b) {
              final load = (bodegeroWorkloads[a.id] ?? 0).compareTo(
                bodegeroWorkloads[b.id] ?? 0,
              );
              if (load != 0) return load;
              final aId = BigInt.tryParse(a.id);
              final bId = BigInt.tryParse(b.id);
              if (aId != null && bId != null) return aId.compareTo(bId);
              return a.id.compareTo(b.id);
            });
            return _buildStaffAssignmentPair(
              helpers: helpers,
              bodegeros: bodegeros,
              helperWorkloads: activePreparationWorkloads(orders),
              bodegeroWorkloads: bodegeroWorkloads,
              hasLightItems: hasLightItems,
            );
          },
        );
      },
    );
  }

  // Only the existing staff-assignment footer row changes on heavy carts.
  Widget _buildStaffAssignmentPair({
    required List<HelperAssignmentCandidate> helpers,
    required List<HelperAssignmentCandidate> bodegeros,
    required Map<String, int> helperWorkloads,
    required Map<String, int> bodegeroWorkloads,
    required bool hasLightItems,
  }) {
    final helper = HelperAssignmentSelector(
      key: const ValueKey('pos-dual-helper'),
      helpers: hasLightItems ? helpers : const <HelperAssignmentCandidate>[],
      workloads: helperWorkloads,
      selectedHelperId: hasLightItems ? _selectedHelperId : null,
      enabled:
          hasLightItems && !_isProcessingCart && widget.presenceService != null,
      onChanged: hasLightItems
          ? (id) {
              if (_selectedHelperId != id)
                setState(() => _selectedHelperId = id);
            }
          : null,
      roleName: 'Helper',
      showInlineLabel: false,
      compact: true,
      disabledLabel: hasLightItems ? null : 'Helper: N/A',
    );
    final bodegero = HelperAssignmentSelector(
      key: const ValueKey('pos-dual-bodegero'),
      helpers: bodegeros,
      workloads: bodegeroWorkloads,
      selectedHelperId: _selectedBodegeroId,
      enabled: !_isProcessingCart && widget.presenceService != null,
      onChanged: (id) {
        if (_selectedBodegeroId != id) {
          setState(() => _selectedBodegeroId = id);
        }
      },
      roleName: 'Bodegero',
      showInlineLabel: false,
      compact: true,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          // Very narrow panels: avoid overflowing either dropdown.
          return Column(
            children: [helper, const SizedBox(height: 8), bodegero],
          );
        }
        return Row(
          children: [
            Expanded(child: helper),
            const SizedBox(width: 8),
            Expanded(child: bodegero),
          ],
        );
      },
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        const dashWidth = 5.0;
        const dashHeight = 1.0;
        final dashCount = (boxWidth / (2 * dashWidth)).floor();
        return Flex(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          direction: Axis.horizontal,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: dashHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.grey.shade300),
              ),
            );
          }),
        );
      },
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;

  _DashedRectPainter({
    this.color = Colors.black,
    this.strokeWidth = 1.0,
    this.gap = 5.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(8),
        ),
      );

    final Path dashPath = Path();
    double distance = 0.0;
    for (PathMetric pathMetric in path.computeMetrics()) {
      while (distance < pathMetric.length) {
        dashPath.addPath(
          pathMetric.extractPath(distance, distance + gap),
          Offset.zero,
        );
        distance += gap * 2;
      }
      distance = 0.0;
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _QuantityStepper extends StatefulWidget {
  final double initialValue;
  final String unit;
  final ValueChanged<double> onChanged;

  const _QuantityStepper({
    required this.initialValue,
    required this.unit,
    required this.onChanged,
  });

  @override
  State<_QuantityStepper> createState() => _QuantityStepperState();
}

class _QuantityStepperState extends State<_QuantityStepper> {
  late TextEditingController _controller;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _formatDisplay(widget.initialValue),
    );
  }

  @override
  void didUpdateWidget(covariant _QuantityStepper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue && !_isFocused) {
      _controller.text = _formatDisplay(widget.initialValue);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isSolidItem() {
    final u = widget.unit.toLowerCase();
    return u == 'pcs' || u == 'box' || u == 'pack' || u == '';
  }

  String _formatDisplay(double val) {
    if (_isSolidItem()) return val.toInt().toString();
    return val.truncateToDouble() == val
        ? val.toInt().toString()
        : val
              .toString()
              .replaceAll(RegExp(r'0*$'), '')
              .replaceAll(RegExp(r'\.$'), '');
  }

  void _submit() {
    final val = double.tryParse(_controller.text);
    if (val != null && val > 0) {
      widget.onChanged(_isSolidItem() ? val.truncateToDouble() : val);
    } else {
      _controller.text = _formatDisplay(widget.initialValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSolid = _isSolidItem();
    final step = isSolid ? 1.0 : 0.25;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () {
              if (widget.initialValue > step) {
                widget.onChanged(widget.initialValue - step);
              }
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Icon(Icons.remove, size: 16, color: Colors.black),
            ),
          ),
          SizedBox(
            width: 40,
            child: Focus(
              onFocusChange: (hasFocus) {
                setState(() => _isFocused = hasFocus);
                if (!hasFocus) _submit();
              },
              child: TextField(
                controller: _controller,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
                keyboardType: TextInputType.numberWithOptions(
                  decimal: !isSolid,
                ),
                inputFormatters: isSolid
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d*'),
                        ),
                      ],
                onChanged: (val) {
                  final parsed = double.tryParse(val);
                  if (parsed != null && parsed > 0) {
                    widget.onChanged(
                      isSolid ? parsed.truncateToDouble() : parsed,
                    );
                  }
                },
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          if (!isSolid) ...[
            Text(
              widget.unit,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
          ],
          InkWell(
            onTap: () => widget.onChanged(widget.initialValue + step),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Icon(Icons.add, size: 16, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }
}
