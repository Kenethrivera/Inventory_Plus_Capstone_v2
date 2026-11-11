import 'dart:async';

import 'package:flutter/material.dart';
import 'package:inventory_plus/notifications/notification_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/helper_assignment.dart';
import '../logic/inventory_controller.dart';
import '../data/inventory.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import '../services/staff_presence_service.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'store_map.dart';
import 'scanner_search_page.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

class OrderQueuePage extends StatefulWidget {
  final InventoryController controller;
  final StaffPresenceService? presenceService;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;
  final ValueChanged<bool>? onChecklistVisibilityChanged;

  const OrderQueuePage({
    super.key,
    required this.controller,
    this.presenceService,
    this.targetOrderId,
    this.onOrderOpened,
    this.onChecklistVisibilityChanged,
  });

  @override
  State<OrderQueuePage> createState() => _OrderQueuePageState();
}

class _OrderQueuePageState extends State<OrderQueuePage> {
  Timer? _timer;
  StreamSubscription<List<MapElement>>? _layoutSubscription;
  Duration? _timeOffset;
  String? _pendingAutoOpenId;
  String _searchQuery = '';

  final TextEditingController _searchController = TextEditingController();

  String? _selectedOrderId;
  CustomerOrder? _preparedConfirmationOrder;
  List<CustomerOrder> _cachedOrders = [];

  final Map<String, Set<String>> _pickedTracker = {};
  bool _progressSyncWarningShown = false;
  final Set<String> _claimingOrderIds = <String>{};

  @override
  void initState() {
    super.initState();

    _pendingAutoOpenId = widget.targetOrderId;

    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _layoutSubscription = widget.controller.mapLayoutSnapshots.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_loadMapLayout());
  }

  Future<void> _loadMapLayout() async {
    try {
      await widget.controller.fetchMapLayout();
    } catch (error) {
      debugPrint('[Helper queue] map locations unavailable: $error');
    }
  }

  @override
  void didUpdateWidget(OrderQueuePage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.targetOrderId != null &&
        widget.targetOrderId != oldWidget.targetOrderId) {
      _pendingAutoOpenId = widget.targetOrderId;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_layoutSubscription?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  String _timeAgo(DateTime date) {
    var now = DateTime.now();

    if (date.isAfter(now)) {
      final drift = date.difference(now);

      if (_timeOffset == null || drift > _timeOffset!) {
        _timeOffset = drift;
      }
    }

    if (_timeOffset != null) {
      now = now.add(_timeOffset!);
    }

    final diff = now.difference(date);
    final minutes = diff.inMinutes;

    if (minutes < 1) return 'Just now';
    if (minutes < 60) return '${minutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';

    return '${diff.inDays}d ago';
  }

  bool _openAssignedOrderChecklist(CustomerOrder order) {
    final CustomerOrder? latestOrder = widget.controller.orderById(order.id);

    if (latestOrder == null ||
        latestOrder.status != 'pending' ||
        !_isAssignedToCurrentHelper(latestOrder)) {
      AppToast.error(context, 'This order is no longer assigned to you.');
      return false;
    }

    _openOrderChecklist(latestOrder);
    return true;
  }

  void _openOrderChecklist(CustomerOrder order) {
    setState(() {
      _selectedOrderId = order.id.toString();
      _pickedTracker[order.id] ??= <String>{
        for (final CustomerOrderItem item in order.items)
          if (item.picked) item.productId,
      };
    });
    widget.onChecklistVisibilityChanged?.call(true);
  }

  void _closeOrderChecklist() {
    setState(() {
      _selectedOrderId = null;
      _preparedConfirmationOrder = null;
    });
    widget.onChecklistVisibilityChanged?.call(false);
  }

  Set<String> _pickedIds(CustomerOrder order) => <String>{
    for (final item in order.items)
      if (item.picked) item.productId,
    ...?_pickedTracker[order.id],
  };

  Future<void> _markPickedItem(String orderId, String productId) async {
    final synced = await widget.controller.markOrderItemPicked(
      orderId,
      productId,
    );
    if (!mounted) return;
    setState(() {
      _pickedTracker[orderId] ??= {};
      _pickedTracker[orderId]!.add(productId);
    });
    if (!synced && !_progressSyncWarningShown) {
      _progressSyncWarningShown = true;
      AppToast.error(context, 'Picking progress is saved on this device only.');
    }
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();

    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  Future<void> _claimOrder(CustomerOrder order) async {
    if (_claimingOrderIds.contains(order.id)) return;
    setState(() => _claimingOrderIds.add(order.id));
    final claimed = await widget.controller.claimOrderForCurrentHelper(
      order.id,
    );
    if (!mounted) return;
    setState(() => _claimingOrderIds.remove(order.id));
    if (!claimed) {
      AppToast.error(
        context,
        'This order could not be claimed. It may already be assigned.',
      );
    }
  }

  String _mobileOrderId(CustomerOrder order) {
    final id = order.id.trim();
    return '#${id.length <= 8 ? id : id.substring(0, 8)}';
  }

  String _mobileOrderLocations(CustomerOrder order) {
    final labels = <String>{};
    for (final orderItem in order.items) {
      final item = widget.controller.findAnyItemById(orderItem.productId);
      if (item == null || item.locationId == null) continue;
      for (final element in widget.controller.storeLayout) {
        if (element.id == item.locationId && element.label.trim().isNotEmpty) {
          labels.add(element.label.trim());
          break;
        }
      }
    }
    return labels.isEmpty ? '' : ' · ${labels.join(', ')}';
  }

  Widget _buildMobileQueue({
    required List<CustomerOrder> assignedOrders,
    required List<CustomerOrder> openOrders,
    required int doneToday,
  }) {
    const ink = Color(0xFF171717);
    const muted = Color(0xFF78716C);
    const border = Color(0xFFE1DCD5);
    final presence = widget.presenceService;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        if (presence != null)
          AnimatedBuilder(
            animation: presence,
            builder: (context, _) => presence.isOnBreak
                ? Container(
                    margin: const EdgeInsets.only(bottom: 30),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF2D0),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          LucideIcons.coffee,
                          size: 18,
                          color: Color(0xFFA65A00),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            "You're on break. New orders won't be auto-assigned to you until you switch back to Available.",
                            style: TextStyle(
                              fontSize: 14,
                              color: ink,
                              height: 1.45,
                              fontFamily: _fontFam,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Your orders',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: ink,
                  fontFamily: _fontFam,
                ),
              ),
            ),
            Text(
              '$doneToday done today',
              style: const TextStyle(
                fontSize: 13,
                color: muted,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (assignedOrders.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'No orders assigned to you.',
              style: TextStyle(color: muted, fontFamily: _fontFam),
            ),
          ),
        for (final order in assignedOrders) ...[
          _mobileAssignedCard(order),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 32),
        Row(
          children: [
            const Text(
              'Open orders',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: ink,
                fontFamily: _fontFam,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${openOrders.length}',
              style: const TextStyle(
                fontSize: 17,
                color: muted,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        const Text(
          'Not yet assigned. Claim one if you have capacity.',
          style: TextStyle(fontSize: 13, color: muted, fontFamily: _fontFam),
        ),
        const SizedBox(height: 16),
        if (openOrders.isEmpty)
          Container(
            height: 65,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFEDEBE7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              'No open orders.',
              style: TextStyle(
                color: muted,
                fontSize: 14,
                fontFamily: _fontFam,
              ),
            ),
          ),
        for (final order in openOrders) ...[
          _mobileOpenCard(order),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _mobileAssignedCard(CustomerOrder order) {
    const orange = Color(0xFFC83D08);
    final picked = _pickedIds(order).length.clamp(0, order.items.length);
    final total = order.items.length;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _openAssignedOrderChecklist(order),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE1DCD5)),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _mobileOrderId(order),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF171717),
                        fontFamily: _fontFam,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE4EFFD),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      picked > 0 ? 'Preparing' : 'Assigned',
                      style: const TextStyle(
                        color: Color(0xFF245C9E),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                '$total ${total == 1 ? 'item' : 'items'}${_mobileOrderLocations(order)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF736B65),
                  fontSize: 14,
                  fontFamily: _fontFam,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: total == 0 ? 0 : picked / total,
                        minHeight: 7,
                        backgroundColor: const Color(0xFFECEAE6),
                        valueColor: const AlwaysStoppedAnimation(orange),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$picked/$total verified',
                    style: const TextStyle(
                      color: Color(0xFF736B65),
                      fontSize: 12,
                      fontFamily: _fontFam,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      picked > 0 ? 'Continue picking' : 'Start picking',
                      style: const TextStyle(
                        color: orange,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ),
                  const Icon(LucideIcons.chevronRight, size: 18, color: orange),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mobileOpenCard(CustomerOrder order) {
    final claiming = _claimingOrderIds.contains(order.id);
    final total = order.items.length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE1DCD5)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _mobileOrderId(order),
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF171717),
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$total ${total == 1 ? 'item' : 'items'}${_mobileOrderLocations(order)} · ${_timeAgo(order.createdAt)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF736B65),
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: claiming ? null : () => _claimOrder(order),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF211F1D),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: Text(
              claiming ? 'Claiming…' : 'Claim',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isAssignedToCurrentHelper(CustomerOrder order) {
    final currentUserId = widget.controller.currentUserId;

    if (currentUserId == null) return false;

    return order.assignedHelperId?.toString() == currentUserId.toString();
  }

  Widget _buildPreparedConfirmation(CustomerOrder order) {
    const orange = Color(0xFFC83D08);
    final id = order.id.trim();
    final shortId = (id.length <= 8 ? id : id.substring(0, 8)).toUpperCase();

    return Scaffold(
      backgroundColor: const Color(0xFFF6F5F2),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 36),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 36,
                  backgroundColor: Color(0xFFDDF3E6),
                  child: Icon(
                    LucideIcons.packageCheck,
                    color: Color(0xFF128044),
                    size: 34,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Order #$shortId is ready',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF171717),
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Bring the items to the checkout counter. The cashier will release them to the customer.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF756D67),
                    fontSize: 15,
                    height: 1.45,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 38),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    onPressed: _closeOrderChecklist,
                    style: FilledButton.styleFrom(
                      backgroundColor: orange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'Back to queue',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      backgroundColor: isCompact
          ? const Color(0xFFF6F5F2)
          : const Color(0xFFF4F6F8),
      body: StreamBuilder<List<CustomerOrder>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _cachedOrders.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(color: _primaryBlue),
            );
          }

          if (snapshot.hasError) {
            AppLogger.error(
              'Helper order queue stream failed',
              error: snapshot.error,
              stackTrace: snapshot.stackTrace,
            );
            return const Center(child: Text(AppErrorMapper.dataLoad));
          }

          if (snapshot.hasData) {
            _cachedOrders = snapshot.data!;
          }

          if (isCompact && _preparedConfirmationOrder != null) {
            return _buildPreparedConfirmation(_preparedConfirmationOrder!);
          }

          CustomerOrder? selectedOrder;

          if (_selectedOrderId != null) {
            for (final CustomerOrder order in _cachedOrders) {
              if (order.id.toString() == _selectedOrderId) {
                selectedOrder = order;
                break;
              }
            }

            final bool selectedOrderStillValid =
                selectedOrder != null &&
                (selectedOrder.status == 'pending' ||
                    selectedOrder.status == 'prepared') &&
                _isAssignedToCurrentHelper(selectedOrder);

            if (!selectedOrderStillValid) {
              selectedOrder = null;

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _selectedOrderId == null) {
                  return;
                }

                setState(() {
                  _selectedOrderId = null;
                });
                widget.onChecklistVisibilityChanged?.call(false);
              });
            }
          }

          if (_pendingAutoOpenId != null) {
            final match = _cachedOrders
                .where(
                  (o) =>
                      o.id.toString() == _pendingAutoOpenId &&
                      o.status == 'pending' &&
                      _isAssignedToCurrentHelper(o),
                )
                .toList();

            if (match.isNotEmpty) {
              final orderToOpen = match.first;
              _pendingAutoOpenId = null;

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;

                final bool opened = _openAssignedOrderChecklist(orderToOpen);

                if (opened) {
                  widget.onOrderOpened?.call();
                }
              });
            }
          }

          if (selectedOrder != null) {
            final CustomerOrder currentOrder = selectedOrder;

            return OrderChecklistPage(
              order: currentOrder,
              controller: widget.controller,
              pickedItems: _pickedIds(currentOrder),
              onItemVerified: (productId) =>
                  _markPickedItem(currentOrder.id, productId),
              onBack: _closeOrderChecklist,
              onFinish: () {
                _pickedTracker.remove(currentOrder.id);
                if (isCompact) {
                  setState(() => _preparedConfirmationOrder = currentOrder);
                } else {
                  _closeOrderChecklist();
                }
              },
            );
          }

          final pendingOrders = assignedPendingOrdersForHelper(
            orders: _cachedOrders,
            helperId: widget.controller.currentUserId ?? '',
          ).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final normalizedSearchQuery = _searchQuery.trim().toLowerCase();

          final visiblePendingOrders = pendingOrders.where((order) {
            if (normalizedSearchQuery.isEmpty) {
              return true;
            }

            final orderId = order.id.toString().toLowerCase();
            final helperName =
                order.assignedHelperName?.toString().toLowerCase() ?? '';

            final bool matchesItem = order.items.any(
              (item) => item.productName.toLowerCase().contains(
                normalizedSearchQuery,
              ),
            );

            return orderId.contains(normalizedSearchQuery) ||
                helperName.contains(normalizedSearchQuery) ||
                matchesItem;
          }).toList();

          int waitingCount = 0;
          int pickingCount = 0;

          for (final order in pendingOrders) {
            final picked = _pickedIds(order).length;

            if (picked > 0) {
              pickingCount++;
            } else {
              waitingCount++;
            }
          }

          final readyTodayCount = _cachedOrders
              .where(
                (o) =>
                    o.status == 'prepared' &&
                    _isAssignedToCurrentHelper(o) &&
                    _isToday(o.preparedAt ?? o.createdAt),
              )
              .length;

          if (isCompact) {
            final openOrders =
                _cachedOrders
                    .where(
                      (order) =>
                          order.status == 'pending' &&
                          (order.assignedHelperId == null ||
                              order.assignedHelperId!.trim().isEmpty),
                    )
                    .toList()
                  ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
            final doneToday = _cachedOrders
                .where(
                  (order) =>
                      _isAssignedToCurrentHelper(order) &&
                      order.preparedAt != null &&
                      _isToday(order.preparedAt!),
                )
                .length;
            return _buildMobileQueue(
              assignedOrders: pendingOrders,
              openOrders: openOrders,
              doneToday: doneToday,
            );
          }

          final String emptyQueueMessage;
          if (_searchQuery.trim().isNotEmpty) {
            emptyQueueMessage =
                'No pending orders match "${_searchQuery.trim()}".';
          } else {
            emptyQueueMessage = 'No orders are assigned to you right now.';
          }

          return Padding(
            padding: isCompact
                ? const EdgeInsets.fromLTRB(16, 24, 16, 16)
                : const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.presenceService != null)
                  AnimatedBuilder(
                    animation: widget.presenceService!,
                    builder: (context, _) {
                      if (!widget.presenceService!.isOnBreak) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3D4),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                LucideIcons.coffee,
                                size: 18,
                                color: Color(0xFFA95700),
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  "You're on break. New orders won't be auto-assigned to you until you switch back to Available.",
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF473013),
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                const Text(
                  'Order queue',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pick each item, then notify the cashier.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                    fontFamily: _fontFam,
                  ),
                ),
                SizedBox(height: isCompact ? 20 : 24),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          'Waiting',
                          '$waitingCount',
                          isActive: true,
                          isCompact: isCompact,
                        ),
                      ),
                      SizedBox(width: isCompact ? 8 : 16),
                      Expanded(
                        child: _buildStatCard(
                          'Picking',
                          '$pickingCount',
                          isCompact: isCompact,
                        ),
                      ),
                      SizedBox(width: isCompact ? 8 : 16),
                      Expanded(
                        child: _buildStatCard(
                          'Ready today',
                          '$readyTodayCount',
                          isCompact: isCompact,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                _buildQueueToolbar(),

                const SizedBox(height: 18),

                // Order List
                Expanded(
                  child: visiblePendingOrders.isEmpty
                      ? Center(
                          child: Text(
                            emptyQueueMessage,
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey.shade500,
                              fontFamily: _fontFam,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: visiblePendingOrders.length,
                          itemBuilder: (context, index) {
                            final order = visiblePendingOrders[index];
                            final pickedCount = _pickedIds(order).length;
                            final totalItems = order.items.length;

                            return _OrderCard(
                              key: ValueKey(order.id),
                              order: order,
                              timeAgo: _timeAgo(order.createdAt),
                              pickedCount: pickedCount,
                              totalItems: totalItems,
                              onPrepare: () {
                                _openAssignedOrderChecklist(order);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatCard(
    String title,
    String value, {
    bool isActive = false,
    bool isCompact = false,
  }) {
    return Container(
      padding: EdgeInsets.all(isCompact ? 12 : 20),
      decoration: BoxDecoration(
        color: isActive ? Colors.blue.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? Colors.blue.shade100 : Colors.grey.shade200,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: isActive ? _primaryBlue : const Color(0xFF0F172A),
              fontFamily: _fontFam,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade600,
              fontFamily: _fontFam,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueToolbar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final Widget searchField = SizedBox(
          width: constraints.maxWidth < 600 ? double.infinity : 360,
          height: 44,
          child: TextField(
            controller: _searchController,
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
            style: const TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: _fontFam,
            ),
            decoration: InputDecoration(
              hintText: 'Search orders or items',
              hintStyle: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 13,
                fontFamily: _fontFam,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 20,
                color: Color(0xFF64748B),
              ),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: Color(0xFF64748B),
                      ),
                    ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _primaryBlue, width: 1.5),
              ),
            ),
          ),
        );
        return Align(alignment: Alignment.centerLeft, child: searchField);
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  final CustomerOrder order;
  final String timeAgo;
  final int pickedCount;
  final int totalItems;
  final VoidCallback onPrepare;

  const _OrderCard({
    super.key,
    required this.order,
    required this.timeAgo,
    required this.pickedCount,
    required this.totalItems,
    required this.onPrepare,
  });

  @override
  Widget build(BuildContext context) {
    final String shortId = order.id.toString().substring(0, 8).toUpperCase();
    final bool isPicking = pickedCount > 0;
    const Color assignmentColor = _primaryBlue;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '#ORD-$shortId',
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 18,
            color: Color(0xFF0F172A),
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$totalItems ${totalItems == 1 ? 'item' : 'items'} · $timeAgo'
          '${isPicking ? ' · $pickedCount/$totalItems picked' : ''}',
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 13,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: assignmentColor.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: assignmentColor.withOpacity(0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.person_pin_circle_outlined,
                size: 14,
                color: assignmentColor,
              ),
              const SizedBox(width: 6),
              Text(
                'Assigned to you',
                style: const TextStyle(
                  color: assignmentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final action = ElevatedButton(
      onPressed: onPrepare,
      style: ElevatedButton.styleFrom(
        backgroundColor: _primaryBlue,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      ),
      child: Text(
        isPicking ? 'Continue' : 'Prepare',
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontFamily: _fontFam,
          fontSize: 14,
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 340) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [details, const SizedBox(height: 16), action],
              );
            }
            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 16),
                action,
              ],
            );
          },
        ),
      ),
    );
  }
}

class OrderChecklistPage extends StatefulWidget {
  final CustomerOrder order;
  final InventoryController controller;
  final Set<String> pickedItems;
  final Future<void> Function(String) onItemVerified;
  final VoidCallback onBack;
  final VoidCallback onFinish;

  const OrderChecklistPage({
    super.key,
    required this.order,
    required this.controller,
    required this.pickedItems,
    required this.onItemVerified,
    required this.onBack,
    required this.onFinish,
  });

  @override
  State<OrderChecklistPage> createState() => _OrderChecklistPageState();
}

class _OrderChecklistPageState extends State<OrderChecklistPage> {
  bool _isSubmittingPreparation = false;
  MapViewStyle _mobileMapStyle = MapViewStyle.twoD;
  String? _focusedProductId;

  CustomerOrder get order => widget.order;
  InventoryController get controller => widget.controller;
  Set<String> get pickedItems => widget.pickedItems;
  Future<void> Function(String) get onItemVerified => widget.onItemVerified;
  VoidCallback get onBack => widget.onBack;
  VoidCallback get onFinish => widget.onFinish;

  Future<void> _markPrepared(BuildContext context) async {
    if (_isSubmittingPreparation) return;
    setState(() => _isSubmittingPreparation = true);
    final notificationController = NotificationProvider.maybeOf(context);
    final showConfirmation = MediaQuery.sizeOf(context).width < 600;

    try {
      await controller.updateOrderStatus(
        order.id,
        'prepared',
        expectedStatus: 'pending',
      );

      final locationId = controller.activeLocationId;
      final preparedByName = controller.currentUserName ?? 'Unknown User';
      final preparedAt = DateTime.now();

      if (notificationController != null && locationId != null) {
        try {
          await notificationController.notifyOrderPrepared(
            locationId: locationId,
            orderId: order.id,
            preparedByName: preparedByName,
            preparedAt: preparedAt,
          );
        } catch (error, stackTrace) {
          AppLogger.error(
            'Order prepared, but cashier notification failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      if (context.mounted) {
        if (!showConfirmation) {
          final id = order.id.trim();
          final shortId = (id.length <= 8 ? id : id.substring(0, 8))
              .toUpperCase();
          AppToast.success(context, 'Order #$shortId is ready');
        }
        onFinish();
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Order preparation failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmittingPreparation = false);
    }
  }

  void _showItemLocationMap(
    BuildContext context,
    String productId,
    String productName,
  ) {
    MapViewStyle viewStyle = MapViewStyle.twoD;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final screenSize = MediaQuery.sizeOf(dialogContext);
          return Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: (screenSize.width - 24).clamp(0.0, 1000.0),
              height: (screenSize.height - 24).clamp(0.0, 760.0),
              child: Column(
                children: [
                  Container(
                    color: const Color(0xFFEFF6FF),
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Location: $productName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF0F172A),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              fontFamily: _fontFam,
                            ),
                          ),
                        ),
                        for (final style in MapViewStyle.values)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ChoiceChip(
                              label: Text(
                                style == MapViewStyle.twoD ? '2D' : '3D',
                              ),
                              selected: viewStyle == style,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setDialogState(() => viewStyle = style),
                              selectedColor: const Color(0xFFDBEAFE),
                              backgroundColor: Colors.white,
                              labelStyle: TextStyle(
                                color: viewStyle == style
                                    ? const Color(0xFF1D4ED8)
                                    : const Color(0xFF475569),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Color(0xFF1D4ED8),
                          ),
                          onPressed: () => Navigator.pop(dialogContext),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: StoreMap(
                      controller: controller,
                      mode: MapMode.view,
                      viewStyle: viewStyle,
                      fitEntireMap: true,
                      compactZoomControls: true,
                      selectedItemId: productId,
                      onSelectionAssigned: () {},
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openScannerToCheckoff(
    BuildContext context,
    String expectedProductId,
    double targetQuantity,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (scannerContext) => ScannerSearchPage(
          controller: controller,
          onSelectItem: (scannedItem) async {
            Navigator.pop(scannerContext);
            if (!context.mounted) return;

            if (scannedItem.id == expectedProductId) {
              try {
                await onItemVerified(expectedProductId);
              } catch (error, stackTrace) {
                AppLogger.error(
                  'Failed to save order picking progress',
                  error: error,
                  stackTrace: stackTrace,
                );
                if (context.mounted) {
                  AppToast.error(
                    context,
                    AppErrorMapper.message(
                      error,
                      fallback: AppErrorCategory.dataSave,
                    ),
                  );
                }
                return;
              }
              if (!context.mounted) return;
              if (_focusedProductId == expectedProductId) {
                setState(() => _focusedProductId = null);
              }
              showDialog(
                context: context,
                builder: (dialogContext) => PickVerificationDialog(
                  item: scannedItem,
                  targetQuantity: targetQuantity,
                  onClose: () {
                    Navigator.pop(dialogContext);
                    AppToast.success(
                      context,
                      '${scannedItem.name} checked off!',
                    );
                  },
                ),
              );
            } else {
              AppToast.error(
                context,
                '${scannedItem.name} is not the right item!',
              );
            }
          },
        ),
      ),
    );
  }

  List<CustomerOrderItem> _walkingOrderItems() {
    final items = [...order.items];
    final fixtures = {
      for (final element in controller.storeLayout) element.id: element,
    };
    final entrance = controller.storeLayout.where(
      (element) =>
          element.type == ElementType.door &&
          element.label.toLowerCase().contains('entrance'),
    );
    var current = entrance.isEmpty
        ? const Offset(0, 0)
        : entrance.first.position;
    final ordered = <CustomerOrderItem>[];
    while (items.isNotEmpty) {
      var bestIndex = 0;
      var bestDistance = double.infinity;
      for (var i = 0; i < items.length; i++) {
        final fixture =
            fixtures[controller
                .findAnyItemById(items[i].productId)
                ?.locationId];
        if (fixture == null) continue;
        final distance = (fixture.position - current).distanceSquared;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = i;
        }
      }
      final next = items.removeAt(bestIndex);
      ordered.add(next);
      final fixture =
          fixtures[controller.findAnyItemById(next.productId)?.locationId];
      if (fixture != null) current = fixture.position;
    }
    return ordered;
  }

  String _shortOrderId() {
    final id = order.id.trim();
    return '#${(id.length <= 8 ? id : id.substring(0, 8)).toUpperCase()}';
  }

  String _itemLocation(CustomerOrderItem orderItem) {
    final item = controller.findAnyItemById(orderItem.productId);
    if (item == null) return 'Find item in store';
    final fixtures = controller.storeLayout.where(
      (element) => element.id == item.locationId,
    );
    final fixtureName = fixtures.isEmpty
        ? 'Store shelf'
        : fixtures.first.label.trim().isEmpty
        ? 'Store shelf'
        : fixtures.first.label.trim();
    final level = item.shelfLevel?.trim();
    return level == null || level.isEmpty
        ? fixtureName
        : '$fixtureName · Shelf $level';
  }

  Widget _buildMobileChecklist(BuildContext context) {
    const orange = Color(0xFFC83D08);
    const ink = Color(0xFF171717);
    const muted = Color(0xFF756D67);
    final walkingItems = _walkingOrderItems();
    final pickStopMarkers = <PickStopMarker>[];
    for (var i = 0; i < walkingItems.length; i++) {
      final locationId = controller
          .findAnyItemById(walkingItems[i].productId)
          ?.locationId;
      if (locationId != null) {
        pickStopMarkers.add(
          PickStopMarker(
            locationId: locationId,
            number: i + 1,
            label: _itemLocation(walkingItems[i]),
          ),
        );
      }
    }
    final pickedCount = order.items
        .where((item) => pickedItems.contains(item.productId))
        .length;
    final remaining = order.items.length - pickedCount;
    final nextItem = walkingItems.where(
      (item) => !pickedItems.contains(item.productId),
    );
    final highlightedProductId =
        _focusedProductId ??
        (nextItem.isEmpty ? null : nextItem.first.productId);
    final highlightedLocationId = highlightedProductId == null
        ? null
        : controller.findAnyItemById(highlightedProductId)?.locationId;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F5F2),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 12, 20, 14),
            child: Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(LucideIcons.arrowLeft, color: muted),
                  tooltip: 'Back to queue',
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _shortOrderId(),
                        style: const TextStyle(
                          color: ink,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          fontFamily: _fontFam,
                        ),
                      ),
                      const Text(
                        'Deliver to checkout counter',
                        style: TextStyle(
                          color: muted,
                          fontSize: 12,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$pickedCount/${order.items.length}',
                  style: const TextStyle(
                    color: ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEDEBE6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final style in MapViewStyle.values)
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _mobileMapStyle = style),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 9,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _mobileMapStyle == style
                                        ? Colors.white
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    style == MapViewStyle.twoD
                                        ? '2D plan'
                                        : '3D view',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: _mobileMapStyle == style
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: _mobileMapStyle == style
                                          ? ink
                                          : muted,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 310,
                        child: StoreMap(
                          controller: controller,
                          mode: MapMode.view,
                          viewStyle: _mobileMapStyle,
                          highlightId: highlightedLocationId,
                          showProductCounts: false,
                          pickStopMarkers: pickStopMarkers,
                          showItemPopup: false,
                          showZoomControls: true,
                          compactZoomControls: true,
                          miniZoomControls: true,
                          zoomAccentColor: const Color(0xFFC83D08),
                          showMobileToolbar: false,
                          itemAssignmentEnabled: false,
                          fitEntireMap: true,
                        ),
                      ),
                      if (_mobileMapStyle == MapViewStyle.threeD &&
                          pickStopMarkers.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            for (final marker in pickStopMarkers)
                              Container(
                                padding: const EdgeInsets.fromLTRB(5, 4, 8, 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF6F5F2),
                                  border: Border.all(
                                    color: const Color(0xFFE1DCD5),
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircleAvatar(
                                      radius: 9,
                                      backgroundColor: ink,
                                      child: Text(
                                        '${marker.number}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 155,
                                      ),
                                      child: Text(
                                        marker.label ?? 'Pick stop',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: ink,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Text(
                    'Pick list · in walking order',
                    style: const TextStyle(
                      color: ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
                for (var index = 0; index < walkingItems.length; index++)
                  _buildMobilePickCard(context, walkingItems[index], index + 1),
                const SizedBox(height: 16),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE1DCD5))),
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: remaining == 0 && !_isSubmittingPreparation
                      ? () => _markPrepared(context)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: orange,
                    disabledBackgroundColor: const Color(0xFFE9B79F),
                    disabledForegroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _isSubmittingPreparation
                        ? 'Saving preparation…'
                        : remaining == 0
                        ? 'Finish preparing'
                        : 'Scan $remaining more to finish',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobilePickCard(
    BuildContext context,
    CustomerOrderItem orderItem,
    int position,
  ) {
    const ink = Color(0xFF171717);
    const muted = Color(0xFF756D67);
    final verified = pickedItems.contains(orderItem.productId);
    final item = controller.findAnyItemById(orderItem.productId);
    final unit = orderItem.unit ?? item?.unit ?? 'pc';
    final quantity = orderItem.quantity == orderItem.quantity.roundToDouble()
        ? orderItem.quantity.toInt().toString()
        : orderItem.quantity.toString();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE1DCD5)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: verified ? const Color(0xFF168047) : ink,
            child: verified
                ? const Icon(LucideIcons.check, color: Colors.white, size: 16)
                : Text(
                    '$position',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 56,
            height: 56,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFFF0EEEA),
              borderRadius: BorderRadius.circular(8),
            ),
            child: item?.imageUrl.isNotEmpty == true
                ? Image.network(
                    item!.imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      LucideIcons.package,
                      color: Color(0xFF807A73),
                    ),
                  )
                : const Icon(LucideIcons.package, color: Color(0xFF807A73)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () =>
                  setState(() => _focusedProductId = orderItem.productId),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _itemLocation(orderItem),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      fontFamily: _fontFam,
                    ),
                  ),
                  Text(
                    orderItem.productName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 13,
                      fontFamily: _fontFam,
                    ),
                  ),
                  Text(
                    'Qty $quantity $unit${verified ? ' · Verified' : ''}',
                    style: const TextStyle(
                      color: muted,
                      fontSize: 12,
                      fontFamily: _fontFam,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (!verified)
            FilledButton.icon(
              onPressed: () => _openScannerToCheckoff(
                context,
                orderItem.productId,
                orderItem.quantity,
              ),
              icon: const Icon(LucideIcons.scanLine, size: 17),
              label: const Text('Scan'),
              style: FilledButton.styleFrom(
                backgroundColor: ink,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            )
          else
            const Icon(LucideIcons.circleCheck, color: Color(0xFF168047)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return _buildMobileChecklist(context);
    }
    final String shortId = order.id.toString().substring(0, 8).toUpperCase();

    final int pickedCount = pickedItems.length;

    final int totalCount = order.items.length;

    final bool isAllPicked = pickedCount == totalCount;

    final assignedHelperName = order.assignedHelperName?.toString().trim();

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),

      body: Column(
        children: [
          // =====================================================
          // COMPACT HEADER
          // Back button + order information share one row.
          // =====================================================
          Container(
            width: double.infinity,
            color: const Color(0xFFF4F6F8),
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // -------------------------------
                // BACK BUTTON
                // -------------------------------
                InkWell(
                  onTap: onBack,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      LucideIcons.arrowLeft,
                      size: 20,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),

                const SizedBox(width: 16),

                // -------------------------------
                // ORDER HEADING
                // -------------------------------
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Order assignment',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 13,
                          fontFamily: _fontFam,
                        ),
                      ),

                      const SizedBox(height: 3),

                      Text(
                        '#ORD-$shortId',
                        style: const TextStyle(
                          fontSize: 28,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                          fontFamily: _fontFam,
                        ),
                      ),

                      const SizedBox(height: 7),

                      Row(
                        children: [
                          Icon(
                            Icons.person_pin_circle_outlined,
                            size: 15,
                            color: Colors.grey.shade500,
                          ),

                          const SizedBox(width: 6),

                          Flexible(
                            child: Text(
                              assignedHelperName != null &&
                                      assignedHelperName.isNotEmpty
                                  ? 'Assigned to $assignedHelperName'
                                  : 'Ready for picking',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                fontFamily: _fontFam,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 16),

                // -------------------------------
                // HELP BUTTON
                // -------------------------------
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: Color(0xFF0F172A),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.question_mark,
                    color: Colors.white,
                    size: 16,
                  ),
                ),

                const SizedBox(width: 12),

                // -------------------------------
                // PICK PROGRESS
                // -------------------------------
                Container(
                  height: 40,
                  constraints: const BoxConstraints(minWidth: 58),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$pickedCount/$totalCount',
                    style: const TextStyle(
                      color: _primaryBlue,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // =====================================================
          // ITEM CHECKLIST
          // =====================================================
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 8),
              itemCount: order.items.length,
              itemBuilder: (context, index) {
                final item = order.items[index];

                final isPicked = pickedItems.contains(item.productId);

                return _ChecklistItemCard(
                  item: item,
                  isPicked: isPicked,
                  onMapTap: () {
                    _showItemLocationMap(
                      context,
                      item.productId,
                      item.productName,
                    );
                  },
                  onScanTap: () {
                    _openScannerToCheckoff(
                      context,
                      item.productId,
                      item.quantity,
                    );
                  },
                );
              },
            ),
          ),

          // =====================================================
          // BOTTOM ACTION BAR
          // =====================================================
          Container(
            padding: const EdgeInsets.fromLTRB(32, 14, 32, 32),
            decoration: const BoxDecoration(color: Color(0xFFF4F6F8)),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: isAllPicked && !_isSubmittingPreparation
                    ? () => _markPrepared(context)
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue,
                  disabledBackgroundColor: Colors.blue.shade200,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  _isSubmittingPreparation
                      ? 'Saving preparation...'
                      : isAllPicked
                      ? 'Notify Cashier (Prepared)'
                      : 'Pick all items first ($pickedCount/$totalCount)',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChecklistItemCard extends StatelessWidget {
  final CustomerOrderItem item;
  final bool isPicked;
  final VoidCallback onMapTap;
  final VoidCallback onScanTap;

  const _ChecklistItemCard({
    required this.item,
    required this.isPicked,
    required this.onMapTap,
    required this.onScanTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onScanTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPicked ? _primaryBlue : Colors.grey.shade200,
            width: isPicked ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isPicked ? _primaryBlue : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isPicked ? _primaryBlue : Colors.grey.shade300,
                  width: 2,
                ),
              ),
              child: isPicked
                  ? const Icon(LucideIcons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.productName,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: isPicked
                          ? Colors.grey.shade500
                          : const Color(0xFF0F172A),
                      decoration: isPicked ? TextDecoration.lineThrough : null,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'QTY: ${item.quantity.truncateToDouble() == item.quantity ? item.quantity.toInt() : item.quantity}',
                      style: const TextStyle(
                        color: _primaryBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isPicked ? 'QR verified' : 'Tap item to scan QR',
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11,
                      fontFamily: _fontFam,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                _buildActionButton(icon: LucideIcons.mapPin, onTap: onMapTap),
                const SizedBox(width: 8),
                _buildActionButton(
                  icon: LucideIcons.scanLine,
                  onTap: onScanTap,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: _primaryBlue, size: 20),
        ),
      ),
    );
  }
}

class PickVerificationDialog extends StatelessWidget {
  final InventoryItem item;
  final double targetQuantity;
  final VoidCallback onClose;

  const PickVerificationDialog({
    super.key,
    required this.item,
    required this.targetQuantity,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final String displayQty =
        targetQuantity.truncateToDouble() == targetQuantity
        ? targetQuantity.toInt().toString()
        : targetQuantity.toStringAsFixed(2);

    return AppDialog(
      icon: LucideIcons.checkCircle2,
      color: Colors.green,
      title: 'Item Verified!',
      subtitle: 'SKU-${item.sku}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade200),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    image: item.imageUrl.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(item.imageUrl),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: item.imageUrl.isEmpty
                      ? Icon(LucideIcons.image, color: Colors.grey.shade400)
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF0F172A),
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.shoppingBasket,
                  color: Colors.green.shade700,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        color: Colors.green.shade900,
                        fontSize: 14,
                        height: 1.4,
                        fontFamily: _fontFam,
                      ),
                      children: [
                        const TextSpan(text: 'Please pick exactly '),
                        TextSpan(
                          text: '$displayQty ${item.unit}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            fontFamily: _fontFam,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        ElevatedButton.icon(
          onPressed: onClose,
          icon: const Icon(LucideIcons.check, size: 18),
          label: const Text(
            'Done',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: _fontFam,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }
}
