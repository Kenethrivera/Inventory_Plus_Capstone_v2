import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'staff_presence_service.dart';

/// Reconciles pending orders with active Helpers through the database's
/// concurrency-safe assignment boundary.
///
/// This service owns no order state. It only coalesces the existing canonical
/// order and staff-presence signals and asks Postgres to reconcile assignments.
class OrderAutoAssignmentService {
  OrderAutoAssignmentService({
    required InventoryController inventoryController,
    required StaffPresenceService presenceService,
    required String locationId,
  }) : _inventoryController = inventoryController,
       _presenceService = presenceService,
       _locationId = locationId,
       _accountId = inventoryController.currentUserId ?? '';

  final InventoryController _inventoryController;
  final StaffPresenceService _presenceService;
  final String _locationId;
  final String _accountId;

  StreamSubscription<List<CustomerOrder>>? _ordersSubscription;
  bool _started = false;
  bool _disposed = false;
  bool _reconcileInFlight = false;
  bool _reconcileQueued = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _presenceService.addListener(_handlePresenceChanged);
    _ordersSubscription = _inventoryController.orderSnapshots.listen(
      (_) => _scheduleReconciliation(),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[OrderAutoAssignment] order snapshot error: $error');
      },
    );
    _scheduleReconciliation();
  }

  void _handlePresenceChanged() => _scheduleReconciliation();

  bool get _hasEligibleHelper {
    return _presenceService.activeStaff.any((staff) {
      final role = staff['user_role']?.toString().trim().toLowerCase();
      return staff['is_online'] == true && role == 'helper';
    });
  }

  bool get _hasUnassignedPendingOrder {
    return _inventoryController.currentOrders.any((order) {
      final status = order.status.trim().toLowerCase();
      final helperId = order.assignedHelperId?.trim();
      return status == 'pending' && (helperId == null || helperId.isEmpty);
    });
  }

  bool get _hasCurrentScope {
    return !_disposed &&
        _started &&
        _accountId.isNotEmpty &&
        _inventoryController.currentUserId == _accountId &&
        _inventoryController.activeLocationId == _locationId;
  }

  void _scheduleReconciliation() {
    if (!_hasCurrentScope) {
      _reconcileQueued = false;
      return;
    }
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    if (!_hasCurrentScope) {
      _reconcileQueued = false;
      return;
    }
    if (_reconcileInFlight) {
      _reconcileQueued = true;
      return;
    }

    _reconcileInFlight = true;
    try {
      do {
        _reconcileQueued = false;

        if (!_hasCurrentScope) break;

        // These are only cheap guards. Eligibility, location, workload, and
        // order ownership are revalidated atomically by the database RPC.
        if (!_hasEligibleHelper || !_hasUnassignedPendingOrder) continue;

        try {
          await _inventoryController.reconcileAutomaticHelperAssignments(
            expectedLocationId: _locationId,
            expectedAccountId: _accountId,
          );
        } catch (error, stackTrace) {
          // Keep the operational snapshot intact. A later order/presence event
          // will retry; monitor pages should never fail because assignment did.
          debugPrint('[OrderAutoAssignment] reconciliation failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      } while (_reconcileQueued && _hasCurrentScope);
    } finally {
      _reconcileInFlight = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    _reconcileQueued = false;
    _presenceService.removeListener(_handlePresenceChanged);
    unawaited(_ordersSubscription?.cancel());
    _ordersSubscription = null;
  }
}
