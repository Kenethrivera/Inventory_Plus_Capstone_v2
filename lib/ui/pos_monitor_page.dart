import 'dart:async';

import 'package:flutter/material.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _darkText = Color(0xFF0F172A);
const Color _mutedText = Color(0xFF64748B);
const Color _pageBg = Color(0xFFF4F6F8);
const String _fontFam = 'Hellix';

class PosMonitorPage extends StatefulWidget {
  final InventoryController controller;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;

  const PosMonitorPage({
    super.key,
    required this.controller,
    this.targetOrderId,
    this.onOrderOpened,
  });

  @override
  State<PosMonitorPage> createState() => _PosMonitorPageState();
}

class _PosMonitorPageState extends State<PosMonitorPage> {
  Timer? _timer;
  String? _selectedOrderId;
  String? _pendingAutoOpenId;

  @override
  void initState() {
    super.initState();

    _pendingAutoOpenId = widget.targetOrderId;

    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(PosMonitorPage oldWidget) {
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

  bool _isToday(DateTime date) {
    final now = DateTime.now();

    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  Duration _ageOf(CustomerOrder order) {
    return DateTime.now().difference(order.createdAt);
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';

    return '${diff.inDays}d ago';
  }

  String _money(num value) {
    return '₱${value.toStringAsFixed(2)}';
  }

  String _shortOrderId(String id) {
    if (id.length <= 8) return id.toUpperCase();
    return id.substring(0, 8).toUpperCase();
  }

  bool _isWaitingForPayment(CustomerOrder order) {
    return order.status.toLowerCase() == 'prepared';
  }

  bool _isStillInQueue(CustomerOrder order) {
    return order.status.toLowerCase() == 'pending';
  }

  bool _isPaidToday(CustomerOrder order) {
    return order.status.toLowerCase() == 'completed' &&
        _isToday(order.createdAt);
  }

  bool _isCancelledToday(CustomerOrder order) {
    return order.status.toLowerCase() == 'cancelled' &&
        _isToday(order.createdAt);
  }

  bool _isDelayedPayment(CustomerOrder order) {
    if (!_isWaitingForPayment(order)) return false;

    final referenceDate = order.preparedAt ?? order.createdAt;

    return DateTime.now().difference(referenceDate).inMinutes >= 15;
  }

  String _statusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return 'Still in queue';
      case 'prepared':
        return 'Ready for payment';
      case 'completed':
        return 'Paid / completed';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Colors.orange;
      case 'prepared':
        return _primaryBlue;
      case 'completed':
        return Colors.green;
      case 'cancelled':
        return Colors.red;
      default:
        return _mutedText;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg,
      body: StreamBuilder<List<CustomerOrder>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: _primaryBlue),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error: ${snapshot.error}',
                style: const TextStyle(fontFamily: _fontFam),
              ),
            );
          }

          final orders = snapshot.data ?? <CustomerOrder>[];
          final selectedOrder = _selectedOrder(orders);

          _handlePendingAutoOpen(orders);

          if (_selectedOrderId != null) {
            final String selectedId = _selectedOrderId!;

            final bool orderNoLongerInPosQueue =
                selectedOrder == null ||
                selectedOrder.status.toString().toLowerCase() != 'prepared';

            if (orderNoLongerInPosQueue) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;

                // Do not clear a different order selected while this callback waited.
                if (_selectedOrderId != selectedId) return;

                setState(() {
                  _selectedOrderId = null;
                });
              });
            }
          }

          final waitingForPayment = orders.where(_isWaitingForPayment).toList()
            ..sort((a, b) {
              final aDate = a.preparedAt ?? a.createdAt;
              final bDate = b.preparedAt ?? b.createdAt;

              return bDate.compareTo(aDate);
            });

          final stillInQueue = orders.where(_isStillInQueue).toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final paidToday = orders.where(_isPaidToday).toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final cancelledToday = orders.where(_isCancelledToday).toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final delayedPayments = waitingForPayment
              .where(_isDelayedPayment)
              .toList();

          final todayRevenue = paidToday.fold<double>(
            0,
            (sum, order) => sum + order.totalAmount,
          );

          final oldestPaymentWaiting = waitingForPayment.isEmpty
              ? 'None'
              : _timeAgo(
                  waitingForPayment.reduce((oldest, current) {
                    final oldestDate = oldest.preparedAt ?? oldest.createdAt;
                    final currentDate = current.preparedAt ?? current.createdAt;

                    return currentDate.isBefore(oldestDate) ? current : oldest;
                  }).createdAt,
                );

          return Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 22),
                _buildStatsRow(
                  readyCount: waitingForPayment.length,
                  delayedCount: delayedPayments.length,
                  paidTodayCount: paidToday.length,
                  cancelledTodayCount: cancelledToday.length,
                  todayRevenue: todayRevenue,
                  oldestPaymentWaiting: oldestPaymentWaiting,
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: _buildOrdersPanel(
                          title: 'Ready for Payment',
                          subtitle: 'Prepared orders waiting for cashier.',
                          count: waitingForPayment.length,
                          orders: waitingForPayment,
                          emptyTitle: 'No orders ready',
                          emptyMessage:
                              'Prepared orders will appear here after helper preparation.',
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        flex: 3,
                        child: _buildOrdersPanel(
                          title: 'Still in Queue',
                          subtitle: 'Orders not yet ready for checkout.',
                          count: stillInQueue.length,
                          orders: stillInQueue,
                          emptyTitle: 'No queue orders',
                          emptyMessage:
                              'Orders still waiting for helper preparation appear here.',
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        flex: 4,
                        child: _buildOrderDetailsPanel(selectedOrder),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  CustomerOrder? _selectedOrder(List<CustomerOrder> orders) {
    if (_selectedOrderId == null) return null;

    final matches = orders.where((order) {
      return order.id.toString() == _selectedOrderId;
    }).toList();

    if (matches.isEmpty) return null;

    return matches.first;
  }

  void _handlePendingAutoOpen(List<CustomerOrder> orders) {
    if (_pendingAutoOpenId == null) return;

    final matches = orders.where((order) {
      return order.id.toString() == _pendingAutoOpenId;
    }).toList();

    if (matches.isEmpty) return;

    final id = _pendingAutoOpenId!;
    _pendingAutoOpenId = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      setState(() {
        _selectedOrderId = id;
      });

      widget.onOrderOpened?.call();
    });
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cash Monitor',
                style: TextStyle(
                  color: _darkText,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Monitor payment readiness, cashier flow, ownership, and checkout delays.',
                style: TextStyle(
                  color: _mutedText,
                  fontSize: 14,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),
        ),
        _buildReadOnlyBadge(),
      ],
    );
  }

  Widget _buildReadOnlyBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _primaryBlue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _primaryBlue.withOpacity(0.25)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_outlined, size: 16, color: _primaryBlue),
          SizedBox(width: 8),
          Text(
            'Admin Monitor',
            style: TextStyle(
              color: _primaryBlue,
              fontWeight: FontWeight.w800,
              fontFamily: _fontFam,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow({
    required int readyCount,
    required int delayedCount,
    required int paidTodayCount,
    required int cancelledTodayCount,
    required double todayRevenue,
    required String oldestPaymentWaiting,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            title: 'Ready',
            value: readyCount.toString(),
            subtitle: 'For payment',
            icon: Icons.credit_card_outlined,
            color: _primaryBlue,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Delayed',
            value: delayedCount.toString(),
            subtitle: '15+ min waiting',
            icon: Icons.warning_amber_rounded,
            color: Colors.red,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Paid Today',
            value: paidTodayCount.toString(),
            subtitle: _money(todayRevenue),
            icon: Icons.receipt_long_outlined,
            color: Colors.green,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Cancelled',
            value: cancelledTodayCount.toString(),
            subtitle: 'Today only',
            icon: Icons.cancel_outlined,
            color: Colors.orange,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Oldest Ready',
            value: oldestPaymentWaiting,
            subtitle: 'Payment wait',
            icon: Icons.timer_outlined,
            color: Colors.teal,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _darkText,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrdersPanel({
    required String title,
    required String subtitle,
    required int count,
    required List<CustomerOrder> orders,
    required String emptyTitle,
    required String emptyMessage,
  }) {
    return _buildPanel(
      title: title,
      subtitle: subtitle,
      count: count,
      child: orders.isEmpty
          ? _buildEmptyState(
              icon: Icons.inbox_outlined,
              title: emptyTitle,
              message: emptyMessage,
            )
          : ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final order = orders[index];

                return _buildOrderCard(order);
              },
            ),
    );
  }

  String _personName(String? value, {String fallback = 'Not recorded'}) {
    final text = value?.trim();

    if (text == null || text.isEmpty || text.toLowerCase() == 'null') {
      return fallback;
    }

    return text;
  }

  String _formatDateTime(DateTime? date) {
    if (date == null) return 'Not recorded';

    final hour = date.hour > 12
        ? date.hour - 12
        : (date.hour == 0 ? 12 : date.hour);

    final minute = date.minute.toString().padLeft(2, '0');
    final suffix = date.hour >= 12 ? 'PM' : 'AM';

    return '${date.month}/${date.day}/${date.year} $hour:$minute $suffix';
  }

  DateTime _paymentReferenceDate(CustomerOrder order) {
    return order.preparedAt ?? order.createdAt;
  }

  Widget _buildOrderCard(CustomerOrder order) {
    final id = order.id.toString();
    final selected = _selectedOrderId == id;
    final status = order.status.toLowerCase();
    final itemCount = order.items.length;
    final total = order.totalAmount;
    final isDelayed = _isDelayedPayment(order);
    final color = isDelayed ? Colors.red : _statusColor(status);

    return InkWell(
      onTap: () {
        setState(() {
          _selectedOrderId = id;
        });
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? _primaryBlue.withOpacity(0.08) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? _primaryBlue : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                isDelayed
                    ? Icons.warning_amber_rounded
                    : status == 'prepared'
                    ? Icons.credit_card_outlined
                    : Icons.hourglass_bottom_rounded,
                color: color,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Order #${_shortOrderId(id)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _darkText,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$itemCount item${itemCount == 1 ? '' : 's'} • Created by ${_personName(order.createdByName)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _mutedText,
                      fontSize: 12,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _statusLabel(status),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    status == 'prepared'
                        ? 'Prepared by ${_personName(order.preparedByName)}'
                        : status == 'completed'
                        ? 'Completed by ${_personName(order.completedByName)}'
                        : 'Assigned to ${_personName(order.assignedHelperName, fallback: 'Unassigned')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _mutedText,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFamily: _fontFam,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _money(total),
              style: const TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w900,
                fontSize: 14,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderDetailsPanel(CustomerOrder? order) {
    return _buildPanel(
      title: 'Payment Details',
      subtitle: 'View-only cashier workflow monitor.',
      count: null,
      child: order == null
          ? _buildEmptyState(
              icon: Icons.ads_click,
              title: 'Select an order',
              message:
                  'Choose an order to inspect payment and checkout details.',
            )
          : _buildOrderDetails(order),
    );
  }

  Widget _buildOrderDetails(CustomerOrder order) {
    final id = order.id.toString();
    final status = order.status.toLowerCase();
    final color = _statusColor(status);
    final isDelayed = _isDelayedPayment(order);

    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Order #${_shortOrderId(id)}',
                style: const TextStyle(
                  color: _darkText,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                status.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoRow('Payment status', _statusLabel(status)),
        _buildInfoRow('Waiting time', _timeAgo(_paymentReferenceDate(order))),
        _buildInfoRow('Created', _formatDateTime(order.createdAt)),
        _buildInfoRow('Created by', _personName(order.createdByName)),

        const SizedBox(height: 8),
        _buildInfoRow(
          'Assigned helper',
          _personName(order.assignedHelperName, fallback: 'Unassigned'),
        ),
        if (order.assignedAt != null)
          _buildInfoRow('Assigned at', _formatDateTime(order.assignedAt)),
        if (order.assignedByAdminName != null)
          _buildInfoRow('Assigned by', _personName(order.assignedByAdminName)),

        const SizedBox(height: 8),
        _buildInfoRow(
          'Prepared by',
          _personName(order.preparedByName, fallback: 'Not prepared yet'),
        ),
        if (order.preparedAt != null)
          _buildInfoRow('Prepared at', _formatDateTime(order.preparedAt)),

        if (order.completedByName != null) ...[
          const SizedBox(height: 8),
          _buildInfoRow('Completed by', _personName(order.completedByName)),
        ],
        if (order.completedAt != null)
          _buildInfoRow('Completed at', _formatDateTime(order.completedAt)),

        _buildInfoRow('Item count', order.items.length.toString()),
        _buildInfoRow('Total amount', _money(order.totalAmount)),
        if (order.paymentMode?.trim().isNotEmpty == true)
          _buildInfoRow('Payment method', order.paymentMode!),
        if (order.paymentMode?.trim().toLowerCase() == 'gcash' &&
            order.paymentReference?.trim().isNotEmpty == true)
          _buildInfoRow('GCash reference', order.paymentReference!.trim()),

        if (isDelayed) ...[
          const SizedBox(height: 14),
          _buildWarningNotice(
            'This order is delayed because it has been ready for payment for 15 minutes or more.',
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'Order items',
          style: TextStyle(
            color: _darkText,
            fontWeight: FontWeight.w900,
            fontSize: 15,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 10),
        ...order.items.map(_buildItemRow),
        const SizedBox(height: 18),
        _buildLockedNotice(
          'Payment actions are disabled for admin. Only staff/cashiers can complete transactions.',
        ),
      ],
    );
  }

  Widget _buildItemRow(dynamic item) {
    String name = 'Unnamed item';
    String qty = '1';

    if (item is CustomerOrderItem) {
      name = item.productName;
      qty = _formatQty(item.quantity);
    } else {
      name =
          _readItemValue(item, [
            'productName',
            'product_name',
            'itemName',
            'item_name',
            'inventoryName',
            'inventory_name',
            'name',
            'title',
            'label',
          ]) ??
          'Unnamed item';

      qty = _readItemValue(item, ['quantity', 'qty', 'count']) ?? '1';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          const Icon(Icons.inventory_2_outlined, size: 16, color: _mutedText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w700,
                fontFamily: _fontFam,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'x$qty',
            style: const TextStyle(
              color: _mutedText,
              fontWeight: FontWeight.w800,
              fontFamily: _fontFam,
            ),
          ),
        ],
      ),
    );
  }

  String _formatQty(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value.toStringAsFixed(2);
  }

  String? _readItemValue(dynamic object, List<String> keys) {
    Map<String, dynamic>? map;

    try {
      final json = object.toJson();
      if (json is Map<String, dynamic>) {
        map = json;
      }
    } catch (_) {
      // Ignore objects without toJson.
    }

    if (map == null) {
      try {
        map = Map<String, dynamic>.from(object as Map);
      } catch (_) {
        // Ignore non-map objects.
      }
    }

    if (map == null) return null;

    for (final key in keys) {
      final value = map[key];

      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }

    for (final entry in map.entries) {
      final key = entry.key.toString().toLowerCase();
      final value = entry.value;

      if (value == null) continue;

      final text = value.toString().trim();

      if (text.isEmpty) continue;

      if (key.contains('name') ||
          key.contains('title') ||
          key.contains('label')) {
        return text;
      }
    }

    return null;
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontFamily: _fontFam,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w800,
                fontSize: 13,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningNotice(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedNotice(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, color: Colors.orange, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel({
    required String title,
    required String subtitle,
    required int? count,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _darkText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
              if (count != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _primaryBlue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    count.toString(),
                    style: const TextStyle(
                      color: _primaryBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _mutedText,
              fontSize: 13,
              fontFamily: _fontFam,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: _mutedText.withOpacity(0.7)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _darkText,
                fontSize: 16,
                fontWeight: FontWeight.w900,
                fontFamily: _fontFam,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _mutedText,
                fontSize: 13,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
