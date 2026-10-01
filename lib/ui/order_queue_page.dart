import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_controller.dart';
import 'widgets/order_checklist_view.dart';

// --- UPDATE THESE IMPORTS TO MATCH YOUR FILE STRUCTURE ---
import 'widgets/app_toast.dart';

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
  final Set<String> _expandedOrders = {};
   String? _pendingAutoOpenId;

  // Track the selected order to show the checklist inline
  dynamic _selectedOrder;

  List<dynamic> _cachedOrders = [];

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

  void _toggleExpand(String orderId) {
    setState(() {
      if (_expandedOrders.contains(orderId)) {
        _expandedOrders.remove(orderId);
      } else {
        _expandedOrders.add(orderId);
      }
    });
  }

  void _openOrderChecklist(dynamic order) {
    setState(() {
      _selectedOrder = order;
    });
  }

  void _closeOrderChecklist() {
    setState(() {
      _selectedOrder = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedOrder != null) {
      return OrderChecklistPage(
        order: _selectedOrder,
        controller: widget.controller,
        onBack: _closeOrderChecklist,
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text(
          'Helper Dashboard',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: StreamBuilder<List<dynamic>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _cachedOrders.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFF58220)),
            );
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (snapshot.hasData) {
            _cachedOrders = snapshot.data!;
          }

          if (_pendingAutoOpenId != null) {
            final match = _cachedOrders
                .where((o) => o.id.toString() == _pendingAutoOpenId)
                .toList();
            if (match.isNotEmpty) {
              final orderToOpen = match.first;
              _pendingAutoOpenId = null;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _openOrderChecklist(orderToOpen);
                widget.onOrderOpened?.call();
              });
            }
          }

          final pendingOrders =
              _cachedOrders.where((o) => o.status == 'pending').toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStatCard(
                  "ACTIVE QUEUE",
                  "${pendingOrders.length}",
                  const Color(0xFFD67E24),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: pendingOrders.isEmpty
                      ? const Center(
                          child: Text(
                            'No pending orders right now!',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: pendingOrders.length,
                          itemBuilder: (context, index) {
                            final order = pendingOrders[index];
                            return _OrderCard(
                              key: ValueKey(order.id),
                              order: order,
                              controller: widget.controller,
                              isExpanded: _expandedOrders.contains(order.id),
                              onToggle: () => _toggleExpand(order.id),
                              timeAgo: _timeAgo(order.createdAt),
                              onPrepare: () => _openOrderChecklist(order),
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

  Widget _buildStatCard(String title, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEADB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Color(0xFF3E322C),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final dynamic order;
  final InventoryController controller;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String timeAgo;
  final VoidCallback onPrepare;

  const _OrderCard({
    super.key,
    required this.order,
    required this.controller,
    required this.isExpanded,
    required this.onToggle,
    required this.timeAgo,
    required this.onPrepare,
  });

  @override
  Widget build(BuildContext context) {
    final String shortId = order.id.toString().substring(0, 8).toUpperCase();

    return GestureDetector(
      onTap: onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isExpanded ? const Color(0xFFF58220) : Colors.grey.shade200,
          ),
          boxShadow: isExpanded
              ? [
                  BoxShadow(
                    color: const Color(0xFFF58220).withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#ORD-$shortId',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(
                            Icons.inventory_2_outlined,
                            size: 14,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${order.items.length} item${order.items.length == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.access_time,
                            size: 14,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            timeAgo,
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: onPrepare,
                    behavior: HitTestBehavior.opaque,
                    child: ElevatedButton(
                      onPressed: onPrepare,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF58220),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      child: const Text(
                        'Prepare',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOut,
              child: isExpanded
                  ? _ExpandedItems(order: order, controller: controller)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedItems extends StatelessWidget {
  final dynamic order;
  final InventoryController controller;

  const _ExpandedItems({required this.order, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Divider(height: 1, thickness: 1, color: Colors.grey.shade100),
        ...order.items.map<Widget>((item) {
          return AnimatedOpacity(
            opacity: 1.0,
            duration: const Duration(milliseconds: 200),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFAFAFA),
                border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBEADB),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'x${item.quantity.toInt()}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF9E651D),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.productName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ============================================================================
// FULL-SCREEN CHECKLIST (Order Queue / helper flow — unchanged behavior)
// ============================================================================
class OrderChecklistPage extends StatelessWidget {
  final dynamic order;
  final InventoryController controller;
  final VoidCallback onBack;

  const OrderChecklistPage({
    super.key,
    required this.order,
    required this.controller,
    required this.onBack,
  });

  Future<void> _markPrepared(BuildContext context) async {
    await controller.updateOrderStatus(order.id, 'prepared');
    if (context.mounted) {
      onBack();
      AppToast.success(context, 'Order marked as Prepared!');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.black87),
          onPressed: onBack,
        ),
      ),
      body: OrderChecklistView(
        order: order,
        controller: controller,
        finishLabel: "NOTIFY CASHIER (PREPARED)",
        finishIcon: LucideIcons.checkCircle2,
        onFinish: () => _markPrepared(context),
      ),
    );
  }
}

