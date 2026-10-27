import 'dart:async';

import 'package:flutter/material.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_toast.dart';
import 'package:inventory_plus/notifications/notification_provider.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _darkText = Color(0xFF0F172A);
const Color _mutedText = Color(0xFF64748B);
const Color _pageBg = Color(0xFFF4F6F8);
const String _fontFam = 'Hellix';

class OrderQueueMonitorPage extends StatefulWidget {
  final InventoryController controller;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;

  const OrderQueueMonitorPage({
    super.key,
    required this.controller,
    this.targetOrderId,
    this.onOrderOpened,
  });

  @override
  State<OrderQueueMonitorPage> createState() => _OrderQueueMonitorPageState();
}

class _OrderQueueMonitorPageState extends State<OrderQueueMonitorPage> {
  Timer? _timer;
  String? _selectedOrderId;
  String? _selectedOrderStatusAtOpen;

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
  void didUpdateWidget(OrderQueueMonitorPage oldWidget) {
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
    if (id.length <= 8) return id;
    return id.substring(0, 8).toUpperCase();
  }

  bool _isWaiting(CustomerOrder order) {
    return order.status.toLowerCase() == 'pending';
  }

  bool _isReady(CustomerOrder order) {
    return order.status.toLowerCase() == 'prepared';
  }

  bool _isCompleted(CustomerOrder order) {
    return order.status.toLowerCase() == 'completed';
  }

  bool _isDelayedWaiting(CustomerOrder order) {
    return _isWaiting(order) && _ageOf(order).inMinutes >= 30;
  }

  String _statusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return 'Waiting for helper';
      case 'prepared':
        return 'For payment';
      case 'completed':
        return 'Completed';
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
            AppLogger.error(
              'Order queue monitor stream failed',
              error: snapshot.error,
              stackTrace: snapshot.stackTrace,
            );
            return Center(
              child: const Text(
                AppErrorMapper.dataLoad,
                style: TextStyle(fontFamily: _fontFam),
              ),
            );
          }

          final orders = snapshot.data ?? <CustomerOrder>[];

          _handlePendingAutoOpen(orders);

          final waitingOrders = orders.where(_isWaiting).toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final readyOrders = orders.where(_isReady).toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final delayedWaiting = waitingOrders
              .where(_isDelayedWaiting)
              .toList();

          final completedToday = orders.where((order) {
            return _isCompleted(order) && _isToday(order.createdAt);
          }).length;

          final oldestWaiting = waitingOrders.isEmpty
              ? 'None'
              : _timeAgo(
                  waitingOrders
                      .reduce(
                        (oldest, current) =>
                            current.createdAt.isBefore(oldest.createdAt)
                            ? current
                            : oldest,
                      )
                      .createdAt,
                );

          final selectedOrder = _selectedOrder(orders);

          if (_selectedOrderId != null) {
            final String selectedId = _selectedOrderId!;

            final bool orderDisappeared = selectedOrder == null;

            final bool orderMovedToAnotherStage =
                selectedOrder != null &&
                _selectedOrderStatusAtOpen != null &&
                selectedOrder.status.toLowerCase() !=
                    _selectedOrderStatusAtOpen!.toLowerCase();

            if (orderDisappeared || orderMovedToAnotherStage) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;

                // Do not clear a different order that the Admin selected
                // while this callback was waiting.
                if (_selectedOrderId != selectedId) return;

                _clearSelectedOrder();
              });
            }
          }

          return Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 22),
                _buildStatsRow(
                  waitingCount: waitingOrders.length,
                  readyCount: readyOrders.length,
                  delayedCount: delayedWaiting.length,
                  completedToday: completedToday,
                  oldestWaiting: oldestWaiting,
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: _buildOrdersPanel(
                          title: 'Waiting Orders',
                          subtitle: 'Orders waiting for helper preparation.',
                          count: waitingOrders.length,
                          orders: waitingOrders,
                          emptyTitle: 'No waiting orders',
                          emptyMessage:
                              'New cashier orders will appear here for monitoring.',
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        flex: 3,
                        child: _buildOrdersPanel(
                          title: 'For Payment',
                          subtitle:
                              'Prepared orders waiting for cashier payment.',
                          count: readyOrders.length,
                          orders: readyOrders,
                          emptyTitle: 'No ready orders',
                          emptyMessage:
                              'Orders will appear here after helpers prepare them.',
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

  void _selectOrder(CustomerOrder order) {
    setState(() {
      _selectedOrderId = order.id.toString();
      _selectedOrderStatusAtOpen = order.status;
    });

    widget.onOrderOpened?.call();
  }

  void _clearSelectedOrder() {
    if (_selectedOrderId == null && _selectedOrderStatusAtOpen == null) {
      return;
    }

    setState(() {
      _selectedOrderId = null;
      _selectedOrderStatusAtOpen = null;
    });
  }

  void _handlePendingAutoOpen(List<CustomerOrder> orders) {
    if (_pendingAutoOpenId == null) return;

    final matches = orders.where((order) {
      return order.id.toString() == _pendingAutoOpenId;
    }).toList();

    if (matches.isEmpty) return;

    final CustomerOrder order = matches.first;

    _pendingAutoOpenId = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _selectOrder(order);
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
                'Queue Monitor',
                style: TextStyle(
                  color: _darkText,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Monitor order ownership, helper assignment, preparation time, and queue delays.',
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
          Icon(
            Icons.admin_panel_settings_outlined,
            size: 16,
            color: _primaryBlue,
          ),
          SizedBox(width: 8),
          Text(
            'Admin monitor',
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
    required int waitingCount,
    required int readyCount,
    required int delayedCount,
    required int completedToday,
    required String oldestWaiting,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            title: 'Waiting Orders',
            value: waitingCount.toString(),
            subtitle: 'Pending prep',
            icon: Icons.hourglass_bottom_rounded,
            color: Colors.orange,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Ready for Payment',
            value: readyCount.toString(),
            subtitle: 'For Payment',
            icon: Icons.check_circle_outline,
            color: _primaryBlue,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Delayed Waiting',
            value: delayedCount.toString(),
            subtitle: '30+ minutes',
            icon: Icons.warning_amber_rounded,
            color: Colors.red,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Oldest Waiting',
            value: oldestWaiting,
            subtitle: 'Longest wait',
            icon: Icons.timer_outlined,
            color: Colors.teal,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildStatCard(
            title: 'Completed Today',
            value: completedToday.toString(),
            subtitle: 'Done today',
            icon: Icons.done_all_rounded,
            color: Colors.green,
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

  Widget _buildMiniInfoChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _displayAssignedHelperId(CustomerOrder order) {
    return order.assignedHelperId;
  }

  String? _displayAssignedHelperName(CustomerOrder order) {
    return order.assignedHelperName;
  }

  bool _hasAssignedHelper(CustomerOrder order) {
    final name = _displayAssignedHelperName(order);
    final id = _displayAssignedHelperId(order);

    return (name != null && name.trim().isNotEmpty) ||
        (id != null && id.trim().isNotEmpty);
  }

  Widget _buildOrderCard(CustomerOrder order) {
    final id = order.id.toString();
    final selected = _selectedOrderId == id;
    final status = order.status.toLowerCase();
    final itemCount = order.items.length;
    final total = order.totalAmount;
    final isDelayed = _isDelayedWaiting(order);
    final color = isDelayed ? Colors.red : _statusColor(status);

    return InkWell(
      onTap: () {
        _selectOrder(order);
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
                    ? Icons.check_circle_outline
                    : Icons.assignment_outlined,
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

                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _buildMiniInfoChip(
                        icon: Icons.access_time,
                        text: _timeAgo(order.createdAt),
                        color: _mutedText,
                      ),
                      if (_hasAssignedHelper(order))
                        _buildMiniInfoChip(
                          icon: Icons.person_pin_circle_outlined,
                          text:
                              'Assigned: ${_displayAssignedHelperName(order) ?? 'Helper'}',
                          color: _primaryBlue,
                        )
                      else if (status == 'pending')
                        _buildMiniInfoChip(
                          icon: Icons.person_off_outlined,
                          text: 'Unassigned',
                          color: Colors.orange,
                        ),
                    ],
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
      title: 'Preparation Details',
      subtitle: 'View-only helper workflow monitor.',
      count: null,
      child: order == null
          ? _buildEmptyState(
              icon: Icons.ads_click,
              title: 'Select an order',
              message:
                  'Choose an order to inspect queue and preparation details.',
            )
          : _buildOrderDetails(order),
    );
  }

  Widget _buildOrderDetails(CustomerOrder order) {
    final id = order.id.toString();
    final status = order.status.toLowerCase();
    final color = _statusColor(status);
    final isDelayed = _isDelayedWaiting(order);

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
        _buildInfoRow('Queue status', _statusLabel(status)),
        _buildInfoRow('Waiting time', _timeAgo(order.createdAt)),
        _buildInfoRow('Created', _formatDateTime(order.createdAt)),
        _buildInfoRow('Created by', _personName(order.createdByName)),

        const SizedBox(height: 8),
        _buildInfoRow(
          'Assigned helper',
          _personName(
            _displayAssignedHelperName(order),
            fallback: 'Unassigned',
          ),
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

        if (isDelayed) ...[
          const SizedBox(height: 14),
          _buildWarningNotice(
            'This order is delayed because it has been waiting for 30 minutes or more.',
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'Items to prepare',
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
          'Helper assignment is automatic. This monitor is read-only.',
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

  Future<void> _showAssignHelperDialog(CustomerOrder order) async {
    final pageContext = context;

    final notificationController = NotificationProvider.maybeOf(pageContext);
    final locationId = widget.controller.activeLocationId;

    final staff = await widget.controller.fetchStaff();

    final helpers = staff.where((person) {
      final role = person['role']?.toString().toLowerCase() ?? '';
      return role == 'helper';
    }).toList();

    if (!mounted) return;

    if (helpers.isEmpty) {
      AppToast.error(context, 'No helpers found for this store.');
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: _primaryBlue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.assignment_ind_outlined,
                        color: _primaryBlue,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Assign Helper',
                        style: TextStyle(
                          color: _darkText,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close, color: _mutedText),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Order #${_shortOrderId(order.id)}',
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 18),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: helpers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final helper = helpers[index];
                      final helperId = helper['id'].toString();
                      final helperName =
                          helper['name']?.toString() ?? 'Unknown Helper';

                      final currentHelperId = _displayAssignedHelperId(order);
                      final isCurrent = currentHelperId?.toString() == helperId;

                      return InkWell(
                        onTap: () async {
                          try {
                            final currentHelperId = _displayAssignedHelperId(
                              order,
                            );

                            if (currentHelperId?.toString() == helperId) {
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }

                              AppToast.error(
                                pageContext,
                                '$helperName is already assigned to this order.',
                              );

                              return;
                            }

                            final assignedByName =
                                widget.controller.currentUserName ?? 'Admin';
                            final assignedAt = DateTime.now();

                            await widget.controller.assignOrderToHelper(
                              orderId: order.id,
                              helperId: helperId,
                              helperName: helperName,
                            );

                            if (notificationController == null) {
                              AppToast.error(
                                pageContext,
                                'Order assigned, but notification provider was not found.',
                              );
                            } else if (locationId == null) {
                              AppToast.error(
                                pageContext,
                                'Order assigned, but location ID was not found.',
                              );
                            } else {
                              await notificationController.notifyOrderAssigned(
                                locationId: locationId,
                                orderId: order.id,
                                helperId: helperId,
                                helperName: helperName,
                                assignedByName: assignedByName,
                                assignedAt: assignedAt,
                              );
                            }

                            if (!mounted) return;

                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }

                            AppToast.success(
                              pageContext,
                              'Assigned to $helperName',
                            );
                          } catch (e, stackTrace) {
                            AppLogger.error(
                              'Helper assignment failed',
                              error: e,
                              stackTrace: stackTrace,
                            );
                            if (!mounted) return;

                            AppToast.error(
                              pageContext,
                              AppErrorMapper.message(
                                e,
                                fallback: AppErrorCategory.dataSave,
                              ),
                            );
                          }
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? _primaryBlue.withOpacity(0.08)
                                : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isCurrent
                                  ? _primaryBlue
                                  : const Color(0xFFE5E7EB),
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: _primaryBlue.withOpacity(0.12),
                                child: Text(
                                  helperName.isNotEmpty
                                      ? helperName[0].toUpperCase()
                                      : 'H',
                                  style: const TextStyle(
                                    color: _primaryBlue,
                                    fontWeight: FontWeight.w900,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  helperName,
                                  style: const TextStyle(
                                    color: _darkText,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ),
                              if (isCurrent)
                                const Icon(
                                  Icons.check_circle,
                                  color: _primaryBlue,
                                  size: 20,
                                )
                              else
                                const Icon(
                                  Icons.chevron_right,
                                  color: _mutedText,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
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

    // Last fallback: search any key that looks like a name field.
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
