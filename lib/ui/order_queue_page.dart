import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_controller.dart';
import '../data/inventory.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'store_map.dart';
import 'scanner_search_page.dart';
import 'package:inventory_plus/notifications/notification_provider.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

class OrderQueuePage extends StatefulWidget {
  final InventoryController controller;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;

  const OrderQueuePage({
    super.key,
    required this.controller,
    this.targetOrderId,
    this.onOrderOpened,
  });

  @override
  State<OrderQueuePage> createState() => _OrderQueuePageState();
}

class _OrderQueuePageState extends State<OrderQueuePage> {
  Timer? _timer;
  Duration? _timeOffset;
  String? _pendingAutoOpenId;
  String _pendingFilter = 'All';
  String _searchQuery = '';

  final TextEditingController _searchController = TextEditingController();

  String? _selectedOrderId;
  List<CustomerOrder> _cachedOrders = [];

  final Map<String, Set<String>> _pickedTracker = {};

  @override
  void initState() {
    super.initState();

    _pendingAutoOpenId = widget.targetOrderId;

    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
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

  Future<bool> _claimAndOpenOrderChecklist(CustomerOrder order) async {
    final bool claimed = await widget.controller.claimOrderForCurrentHelper(
      order.id,
    );

    if (!mounted) {
      return false;
    }

    if (!claimed) {
      AppToast.error(
        context,
        'This order was already claimed by another helper.',
      );
      return false;
    }

    final CustomerOrder? latestOrder = widget.controller.orderById(order.id);

    if (latestOrder == null ||
        latestOrder.status != 'pending' ||
        !_canCurrentHelperPrepare(latestOrder)) {
      AppToast.error(
        context,
        'This order is no longer available for preparation.',
      );
      return false;
    }

    final notificationController = NotificationProvider.maybeOf(context);
    final locationId = widget.controller.activeLocationId;
    final helperId = widget.controller.currentUserNumericId?.toString();
    final helperName = widget.controller.currentUserName ?? 'Helper';
    if (notificationController != null &&
        locationId != null &&
        helperId != null) {
      await notificationController.notifyOrderAssigned(
        locationId: locationId,
        orderId: order.id,
        helperId: helperId,
        helperName: helperName,
        assignedByName: helperName,
        assignedAt: DateTime.now(),
      );
    }

    _openOrderChecklist(latestOrder);

    return true;
  }

  void _openOrderChecklist(dynamic order) {
    setState(() {
      _selectedOrderId = order.id.toString();
      _pickedTracker[order.id] ??= {};
    });
  }

  void _closeOrderChecklist() {
    setState(() {
      _selectedOrderId = null;
    });
  }

  void _togglePickedItem(String orderId, String productId, bool isPicked) {
    setState(() {
      _pickedTracker[orderId] ??= {};

      if (isPicked) {
        _pickedTracker[orderId]!.add(productId);
      } else {
        _pickedTracker[orderId]!.remove(productId);
      }
    });
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();

    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  bool _isAssignedToCurrentHelper(CustomerOrder order) {
    final currentUserId = widget.controller.currentUserId;

    if (currentUserId == null) return false;

    return order.assignedHelperId?.toString() == currentUserId.toString();
  }

  bool _isUnassigned(CustomerOrder order) {
    return order.assignedHelperId == null ||
        order.assignedHelperId.toString().trim().isEmpty;
  }

  bool _canCurrentHelperPrepare(CustomerOrder order) {
    return _isUnassigned(order) || _isAssignedToCurrentHelper(order);
  }

  String _assignmentLabel(CustomerOrder order) {
    if (_isAssignedToCurrentHelper(order)) {
      final bool assignedByAdmin =
          order.assignedByAdminId != null ||
          (order.assignedByAdminName?.trim().isNotEmpty ?? false);

      return assignedByAdmin ? 'Assigned to you' : 'Claimed by you';
    }

    if (_isUnassigned(order)) {
      return 'Unassigned';
    }

    return 'Assigned to ${order.assignedHelperName ?? 'another helper'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
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
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.hasData) {
            _cachedOrders = snapshot.data!;
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
                selectedOrder.status == 'pending' &&
                _canCurrentHelperPrepare(selectedOrder);

            if (!selectedOrderStillValid) {
              selectedOrder = null;

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _selectedOrderId == null) {
                  return;
                }

                setState(() {
                  _selectedOrderId = null;
                });
              });
            }
          }

          if (_pendingAutoOpenId != null) {
            final match = _cachedOrders
                .where((o) => o.id.toString() == _pendingAutoOpenId)
                .toList();

            if (match.isNotEmpty) {
              final orderToOpen = match.first;
              _pendingAutoOpenId = null;

              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!mounted) return;

                final bool opened = await _claimAndOpenOrderChecklist(
                  orderToOpen,
                );

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
              pickedItems: _pickedTracker[currentOrder.id] ?? {},
              onToggleItem: (productId, isPicked) {
                _togglePickedItem(currentOrder.id, productId, isPicked);
              },
              onBack: _closeOrderChecklist,
              onFinish: () {
                _pickedTracker.remove(currentOrder.id);
                _closeOrderChecklist();
              },
            );
          }

          final pendingOrders =
              _cachedOrders
                  .where(
                    (o) =>
                        o.status == 'pending' &&
                        (_isUnassigned(o) || _isAssignedToCurrentHelper(o)),
                  )
                  .toList()
                ..sort((a, b) {
                  final aAssignedToMe = _isAssignedToCurrentHelper(a);
                  final bAssignedToMe = _isAssignedToCurrentHelper(b);

                  if (aAssignedToMe && !bAssignedToMe) return -1;
                  if (!aAssignedToMe && bAssignedToMe) return 1;

                  return b.createdAt.compareTo(a.createdAt);
                });

          final normalizedSearchQuery = _searchQuery.trim().toLowerCase();

          final visiblePendingOrders = pendingOrders.where((order) {
            final bool matchesPendingFilter;

            switch (_pendingFilter) {
              case 'Unassigned':
                matchesPendingFilter = _isUnassigned(order);
                break;

              case 'Mine':
                matchesPendingFilter = _isAssignedToCurrentHelper(order);
                break;

              case 'All':
              default:
                matchesPendingFilter = true;
                break;
            }

            if (!matchesPendingFilter) {
              return false;
            }

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
            final picked = _pickedTracker[order.id]?.length ?? 0;

            if (picked > 0) {
              pickingCount++;
            } else {
              waitingCount++;
            }
          }

          final readyTodayCount = _cachedOrders
              .where((o) => o.status == 'prepared' && _isToday(o.createdAt))
              .length;

          final String emptyQueueMessage;
          if (_searchQuery.trim().isNotEmpty) {
            emptyQueueMessage =
                'No pending orders match "${_searchQuery.trim()}".';
          } else if (_pendingFilter == 'Mine') {
            emptyQueueMessage = 'No orders assigned or claimed by you.';
          } else if (_pendingFilter == 'Unassigned') {
            emptyQueueMessage = 'No unassigned pending orders right now.';
          } else {
            emptyQueueMessage = 'No pending orders right now!';
          }

          return Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        'Waiting',
                        '$waitingCount',
                        isActive: true,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: _buildStatCard('Picking', '$pickingCount')),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildStatCard('Ready today', '$readyTodayCount'),
                    ),
                  ],
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
                            final pickedCount =
                                _pickedTracker[order.id]?.length ?? 0;
                            final totalItems = order.items.length;

                            return _OrderCard(
                              key: ValueKey(order.id),
                              order: order,
                              timeAgo: _timeAgo(order.createdAt),
                              pickedCount: pickedCount,
                              totalItems: totalItems,
                              assignmentLabel: _assignmentLabel(order),
                              assignedToMe: _isAssignedToCurrentHelper(order),
                              onPrepare: () {
                                _claimAndOpenOrderChecklist(order);
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

  Widget _buildStatCard(String title, String value, {bool isActive = false}) {
    return Container(
      padding: const EdgeInsets.all(20),
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
        final bool compact = constraints.maxWidth < 820;

        final Widget searchField = SizedBox(
          width: compact ? double.infinity : 360,
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

        final Widget filterControls = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text(
                'Pending filter',
                style: TextStyle(
                  color: Color(0xFF475569),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
            ),
            _buildPendingFilterChip('All'),
            _buildPendingFilterChip('Unassigned'),
            _buildPendingFilterChip('Mine'),
          ],
        );

        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchField,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: filterControls),
            ],
          );
        }

        return Row(children: [searchField, const Spacer(), filterControls]);
      },
    );
  }

  Widget _buildPendingFilterChip(String label) {
    final bool selected = _pendingFilter == label;

    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : const Color(0xFF475569),
          fontWeight: FontWeight.w700,
          fontFamily: _fontFam,
        ),
      ),
      selected: selected,
      onSelected: (_) {
        setState(() {
          _pendingFilter = label;
        });
      },
      selectedColor: _primaryBlue,
      backgroundColor: Colors.white,
      side: BorderSide(
        color: selected ? _primaryBlue : const Color(0xFFE2E8F0),
      ),
      showCheckmark: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final CustomerOrder order;
  final String timeAgo;
  final int pickedCount;
  final int totalItems;
  final String assignmentLabel;
  final bool assignedToMe;
  final VoidCallback onPrepare;

  const _OrderCard({
    super.key,
    required this.order,
    required this.timeAgo,
    required this.pickedCount,
    required this.totalItems,
    required this.assignmentLabel,
    required this.assignedToMe,
    required this.onPrepare,
  });

  @override
  Widget build(BuildContext context) {
    final String shortId = order.id.toString().substring(0, 8).toUpperCase();
    final bool isPicking = pickedCount > 0;
    final Color assignmentColor = assignedToMe ? _primaryBlue : Colors.orange;

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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
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
                    '$totalItems items · $timeAgo'
                    '${isPicking ? ' · $pickedCount/$totalItems picked' : ''}',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 13,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: assignmentColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: assignmentColor.withOpacity(0.22),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          assignedToMe
                              ? Icons.person_pin_circle_outlined
                              : Icons.person_off_outlined,
                          size: 14,
                          color: assignmentColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          assignmentLabel,
                          style: TextStyle(
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
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton(
              onPressed: onPrepare,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryBlue,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
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
            ),
          ],
        ),
      ),
    );
  }
}

class OrderChecklistPage extends StatelessWidget {
  final CustomerOrder order;
  final InventoryController controller;
  final Set<String> pickedItems;
  final Function(String productId, bool isPicked) onToggleItem;
  final VoidCallback onBack;
  final VoidCallback onFinish;

  const OrderChecklistPage({
    super.key,
    required this.order,
    required this.controller,
    required this.pickedItems,
    required this.onToggleItem,
    required this.onBack,
    required this.onFinish,
  });

  Future<void> _markPrepared(BuildContext context) async {
    await controller.updateOrderStatus(order.id, 'prepared');

    final notificationController = NotificationProvider.maybeOf(context);
    final locationId = controller.activeLocationId;
    final preparedByName = controller.currentUserName ?? 'Unknown User';
    final preparedAt = DateTime.now();

    if (notificationController != null && locationId != null) {
      await notificationController.notifyOrderPrepared(
        locationId: locationId,
        orderId: order.id,
        preparedByName: preparedByName,
        preparedAt: preparedAt,
      );
    }

    if (context.mounted) {
      final shortId = order.id.toString().substring(0, 8).toUpperCase();
      AppToast.success(context, 'Cashier notified for #ORD-$shortId');
      onFinish();
    }
  }

  void _showItemLocationMap(
    BuildContext context,
    String productId,
    String productName,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 600,
          height: 500,
          child: Column(
            children: [
              Container(
                color: const Color(0xFF0F172A),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Location: $productName',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StoreMap(
                  controller: controller,
                  mode: MapMode.view,
                  selectedItemId: productId,
                  onSelectionAssigned: () {},
                ),
              ),
            ],
          ),
        ),
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
        builder: (context) => ScannerSearchPage(
          controller: controller,
          onSelectItem: (scannedItem) {
            Navigator.pop(context);

            if (scannedItem.id == expectedProductId) {
              showDialog(
                context: context,
                builder: (context) => PickConfirmationDialog(
                  item: scannedItem,
                  targetQuantity: targetQuantity,
                  onConfirm: () {
                    onToggleItem(expectedProductId, true);
                    Navigator.pop(context);
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

  @override
  Widget build(BuildContext context) {
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
                  onToggle: (val) {
                    onToggleItem(item.productId, val ?? false);
                  },
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
                onPressed: isAllPicked ? () => _markPrepared(context) : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue,
                  disabledBackgroundColor: Colors.blue.shade200,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  isAllPicked
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
  final ValueChanged<bool?> onToggle;
  final VoidCallback onMapTap;
  final VoidCallback onScanTap;

  const _ChecklistItemCard({
    required this.item,
    required this.isPicked,
    required this.onToggle,
    required this.onMapTap,
    required this.onScanTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onToggle(!isPicked),
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

class PickConfirmationDialog extends StatelessWidget {
  final InventoryItem item;
  final double targetQuantity;
  final VoidCallback onConfirm;

  const PickConfirmationDialog({
    super.key,
    required this.item,
    required this.targetQuantity,
    required this.onConfirm,
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
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: const Text(
            'Cancel',
            style: TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.bold,
              fontFamily: _fontFam,
            ),
          ),
        ),
        ElevatedButton.icon(
          onPressed: onConfirm,
          icon: const Icon(LucideIcons.check, size: 18),
          label: const Text(
            'Confirm Pick',
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
