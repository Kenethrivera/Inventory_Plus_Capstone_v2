import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/inventory.dart';
import '../../logic/inventory_approval.dart';
import '../../services/staff_presence_service.dart';
import 'order_details_drawer.dart';

/// The admin landing page. All figures come from the current store snapshots.
class OperationsOverview extends StatelessWidget {
  const OperationsOverview({
    super.key,
    required this.name,
    required this.orders,
    required this.items,
    required this.approvals,
    required this.approvalCount,
    required this.presence,
    required this.onOrders,
    required this.onApprovals,
    required this.onInventory,
    required this.onStaff,
    required this.onPayments,
    this.orderUpdates,
  });

  final String name;
  final List<CustomerOrder> orders;
  final List<InventoryItem> items;
  final List<InventoryApprovalRequest> approvals;
  final int approvalCount;
  final StaffPresenceService? presence;
  final VoidCallback onOrders;
  final VoidCallback onApprovals;
  final VoidCallback onInventory;
  final VoidCallback onStaff;
  final VoidCallback onPayments;
  final Stream<List<CustomerOrder>>? orderUpdates;

  static const orange = Color(0xFFC83D08);
  static const ink = Color(0xFF171717);
  static const muted = Color(0xFF817A75);
  static const line = Color(0xFFE8E3DF);
  static const canvas = Color(0xFFF7F5F3);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayOrders =
        orders
            .where(
              (o) =>
                  !o.createdAt.isBefore(today) &&
                  o.status != 'cancelled' &&
                  o.status != 'returned',
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final sales = todayOrders.fold<double>(0, (sum, o) => sum + o.totalAmount);
    final cash = todayOrders
        .where((o) => (o.paymentMode ?? '').toLowerCase() != 'gcash')
        .fold<double>(0, (sum, o) => sum + o.totalAmount);
    final gcash = sales - cash;
    final pending = orders.where((o) => o.status == 'pending').toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final waiting = pending.where((o) => o.assignedHelperId == null).toList();
    final preparing = pending.where((o) => o.assignedHelperId != null).toList();
    final ready = orders.where((o) => o.status == 'prepared').toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final alerts = items.where((item) => item.quantity <= 10).toList()
      ..sort((a, b) => a.quantity.compareTo(b.quantity));
    final firstName = name.trim().split(RegExp(r'\s+')).first;
    final greeting = now.hour < 12
        ? 'Good morning'
        : now.hour < 17
        ? 'Good afternoon'
        : 'Good evening';

    return ColoredBox(
      color: canvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 36),
        child: LayoutBuilder(
          builder: (context, limits) {
            final wide = limits.maxWidth >= 1020;
            final sidebarWidth = wide ? 392.0 : limits.maxWidth;
            final mainWidth = wide
                ? limits.maxWidth - sidebarWidth - 24
                : limits.maxWidth;
            final main = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _salesCard(todayOrders, sales, cash, gcash, mainWidth),
                const SizedBox(height: 24),
                _sectionTitle('Order queue', 'All orders', onOrders),
                const SizedBox(height: 12),
                _queue(waiting, preparing, ready, mainWidth),
                const SizedBox(height: 24),
                _activity(todayOrders),
              ],
            );
            final aside = Column(
              children: [
                _attention(alerts),
                const SizedBox(height: 24),
                _staff(),
              ],
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$greeting, $firstName',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${_date(now)} · Here’s what’s moving on the floor.',
                  style: const TextStyle(fontSize: 15, color: muted),
                ),
                const SizedBox(height: 24),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: mainWidth, child: main),
                      const SizedBox(width: 24),
                      SizedBox(width: sidebarWidth, child: aside),
                    ],
                  )
                else ...[
                  main,
                  const SizedBox(height: 24),
                  aside,
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _salesCard(
    List<CustomerOrder> todayOrders,
    double sales,
    double cash,
    double gcash,
    double width,
  ) {
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Sales today', style: TextStyle(color: muted, fontSize: 15)),
        const SizedBox(height: 4),
        FittedBox(
          alignment: Alignment.centerLeft,
          fit: BoxFit.scaleDown,
          child: Text(
            _money(sales),
            style: const TextStyle(
              fontSize: 37,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${todayOrders.length} orders · avg ${_money(todayOrders.isEmpty ? 0 : sales / todayOrders.length)}',
          style: const TextStyle(color: muted, fontSize: 14),
        ),
        const SizedBox(height: 24),
        const Divider(color: line, height: 1),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(child: _miniMetric('Cash', _money(cash))),
            Expanded(child: _miniMetric('GCash', _money(gcash))),
          ],
        ),
      ],
    );
    final chart = _InteractiveSalesChart(orders: todayOrders);
    return _panel(
      Padding(
        padding: const EdgeInsets.all(21),
        child: width > 720
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(width: 290, child: summary),
                  const SizedBox(width: 24),
                  Expanded(child: chart),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [summary, const SizedBox(height: 18), chart],
              ),
      ),
    );
  }

  Widget _miniMetric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: muted, fontSize: 13)),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          color: ink,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    ],
  );

  Widget _queue(
    List<CustomerOrder> waiting,
    List<CustomerOrder> preparing,
    List<CustomerOrder> ready,
    double width,
  ) {
    final groups = <(String, List<CustomerOrder>)>[
      ('Waiting for helper', waiting),
      ('Being prepared', preparing),
      ('Ready for release', ready),
    ];
    if (width < 680) {
      return Column(
        children: groups
            .map(
              (group) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _queueColumn(group.$1, group.$2),
              ),
            )
            .toList(),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < groups.length; i++) ...[
          Expanded(child: _queueColumn(groups[i].$1, groups[i].$2)),
          if (i < 2) const SizedBox(width: 14),
        ],
      ],
    );
  }

  Widget _queueColumn(String title, List<CustomerOrder> group) => Container(
    constraints: const BoxConstraints(minHeight: 300),
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: const Color(0xFFEFEEEC),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(9, 6, 9, 9),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
              ),
              Text('${group.length}', style: const TextStyle(color: muted)),
            ],
          ),
        ),
        if (group.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No orders right now', style: TextStyle(color: muted)),
          )
        else
          ...group
              .take(3)
              .map(
                (order) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _orderCard(order, title),
                ),
              ),
        if (group.length > 3)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '+${group.length - 3} more',
              style: const TextStyle(color: muted),
            ),
          ),
      ],
    ),
  );

  Widget _orderCard(CustomerOrder order, String group) {
    final elapsed = _elapsedTime(DateTime.now().difference(order.createdAt));
    final helper = order.assignedHelperName?.trim();
    final pickedCount = order.items.where((item) => item.picked).length;
    final itemCount = order.items.length;
    return Builder(
      builder: (context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: () => OrderDetailsDrawer.show(
            context,
            order: order,
            inventory: items,
            onOpenQueue: onOrders,
            orderUpdates: orderUpdates,
          ),
          borderRadius: BorderRadius.circular(11),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: line),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _shortOrderId(order.id),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                    ),
                    Text(
                      elapsed,
                      style: TextStyle(
                        color: group == 'Waiting for helper' ? orange : muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  '${order.items.length} items · ${_money(order.totalAmount)}',
                  style: const TextStyle(color: muted, fontSize: 13),
                ),
                if (group == 'Being prepared') ...[
                  const SizedBox(height: 8),
                  Semantics(
                    label: '$pickedCount of $itemCount items picked',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                          end: itemCount == 0 ? 0 : pickedCount / itemCount,
                        ),
                        duration: const Duration(milliseconds: 260),
                        builder: (context, progress, _) =>
                            LinearProgressIndicator(
                              key: ValueKey('order-progress-${order.id}'),
                              value: progress,
                              minHeight: 4,
                              backgroundColor: const Color(0xFFF0EEEC),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Color(0xFF2556DB),
                              ),
                            ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 7),
                Text(
                  helper == null || helper.isEmpty
                      ? 'Unassigned · tap to view'
                      : helper,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: helper == null || helper.isEmpty ? orange : ink,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _attention(List<InventoryItem> alerts) => _panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Needs your attention',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        ),
        const Divider(height: 1, color: line),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            children: [
              _sectionTitle(
                'Approvals · $approvalCount',
                'Review',
                onApprovals,
                compact: true,
              ),
              const SizedBox(height: 9),
              if (approvals.isEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'No pending approvals',
                    style: TextStyle(color: muted),
                  ),
                )
              else
                ...approvals
                    .take(3)
                    .map(
                      (a) => Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: InkWell(
                          onTap: onApprovals,
                          child: Row(
                            children: [
                              _badge(
                                a.type.label,
                                a.type == InventoryApprovalType.restock
                                    ? const Color(0xFF15803D)
                                    : orange,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  a.type == InventoryApprovalType.discount
                                      ? '${a.discountDisplay} · ${a.requestedByName}'
                                      : a.productName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: ink,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Text(
                                _ago(a.requestedAt),
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        ),
        const Divider(height: 1, color: line),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Column(
            children: [
              _sectionTitle(
                'Stock alerts · ${alerts.length}',
                'Inventory',
                onInventory,
                compact: true,
              ),
              const SizedBox(height: 9),
              if (alerts.isEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Stock levels look good',
                    style: TextStyle(color: muted),
                  ),
                )
              else
                ...alerts
                    .take(3)
                    .map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: Row(
                          children: [
                            Container(
                              width: 35,
                              height: 35,
                              decoration: BoxDecoration(
                                color: canvas,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(color: line),
                              ),
                              child: const Icon(
                                LucideIcons.package,
                                size: 16,
                                color: muted,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: ink,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    '${item.quantity.toStringAsFixed(0)} / ${item.maxQuantity.toStringAsFixed(0)} ${item.unit}',
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 5),
                            _badge(
                              item.quantity <= 0 ? 'Out of stock' : 'Critical',
                              const Color(0xFFDC2626),
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
  );

  Widget _staff() => AnimatedBuilder(
    animation: presence ?? _silent,
    builder: (context, _) {
      final people = presence?.activeStaff ?? const <Map<String, dynamic>>[];
      return _panel(
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: _sectionTitle(
                'Staff on the floor',
                'Manage ↗',
                onStaff,
                compact: true,
              ),
            ),
            const Divider(height: 1, color: line),
            if (people.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  presence?.isLoading == true
                      ? 'Loading staff…'
                      : 'No staff online',
                  style: const TextStyle(color: muted),
                ),
              )
            else
              ...people.take(6).map((person) {
                final personName = person['user_name']?.toString() ?? 'Staff';
                final role = person['user_role']?.toString() ?? 'Staff';
                final module = person['current_module']?.toString() ?? '';
                final busy =
                    module.toLowerCase().contains('queue') ||
                    module.toLowerCase().contains('pos');
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: const Color(0xFFFFF1E8),
                            child: Text(
                              _initials(personName),
                              style: const TextStyle(
                                color: orange,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  personName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: ink,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  role,
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.circle,
                            size: 9,
                            color: busy
                                ? const Color(0xFF2556DB)
                                : const Color(0xFF15803D),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            busy ? 'Busy' : 'Available',
                            style: const TextStyle(color: ink, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: line),
                  ],
                );
              }),
          ],
        ),
      );
    },
  );

  Widget _activity(List<CustomerOrder> todayOrders) => _panel(
    Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
          child: _sectionTitle(
            'Recent POS activity',
            'Payments',
            onPayments,
            compact: true,
          ),
        ),
        const Divider(height: 1, color: line),
        if (todayOrders.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No sales today', style: TextStyle(color: muted)),
          )
        else
          ...todayOrders
              .take(5)
              .map(
                (order) => InkWell(
                  onTap: onPayments,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Row(
                        children: [
                          SizedBox(
                            width: constraints.maxWidth < 520 ? 72 : 85,
                            child: Text(
                              _time(order.createdAt),
                              style: const TextStyle(
                                color: muted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: constraints.maxWidth < 520 ? 88 : 115,
                            child: Text(
                              _shortOrderId(order.id),
                              style: const TextStyle(
                                color: ink,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (constraints.maxWidth >= 520)
                            Expanded(
                              child: Text(
                                order.createdByName ?? 'Cashier',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: muted),
                              ),
                            ),
                          if (constraints.maxWidth >= 420)
                            _badge(
                              (order.paymentMode ?? 'Cash').toLowerCase() ==
                                      'gcash'
                                  ? 'GCash'
                                  : 'Cash',
                              (order.paymentMode ?? '').toLowerCase() == 'gcash'
                                  ? const Color(0xFF2556DB)
                                  : const Color(0xFF55504B),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _money(order.totalAmount),
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                color: ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ],
    ),
  );

  Widget _panel(Widget child) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: line),
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
  );

  Widget _sectionTitle(
    String title,
    String action,
    VoidCallback onTap, {
    bool compact = false,
  }) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: TextStyle(
            color: ink,
            fontSize: compact ? 14 : 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: orange,
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
        ),
        child: Text(
          action,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    ],
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.22)),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 11, height: 1)),
  );

  static String _shortOrderId(String value) =>
      value.length > 12 ? value.substring(0, 8).toUpperCase() : value;
  static String _elapsedTime(Duration duration) {
    final totalMinutes = duration.inMinutes.clamp(0, 1 << 31);
    final days = totalMinutes ~/ 1440;
    final hours = (totalMinutes % 1440) ~/ 60;
    final minutes = totalMinutes % 60;
    if (days > 0) return '${days}d ${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  static String _initials(String value) => value
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .take(2)
      .map((s) => s[0].toUpperCase())
      .join();
  static String _money(double amount) {
    final parts = amount.toStringAsFixed(2).split('.');
    final digits = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (m) => ',',
    );
    return '₱$digits.${parts[1]}';
  }

  static String _time(DateTime date) {
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    return '$hour:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _ago(DateTime date) {
    final minutes = DateTime.now().difference(date).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    if (minutes < 1440) return '${minutes ~/ 60} hr ago';
    return '${minutes ~/ 1440} d ago';
  }

  static String _date(DateTime date) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${days[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}';
  }

  static final _silent = ValueNotifier<int>(0);
}

class _InteractiveSalesChart extends StatefulWidget {
  const _InteractiveSalesChart({required this.orders});

  final List<CustomerOrder> orders;

  @override
  State<_InteractiveSalesChart> createState() => _InteractiveSalesChartState();
}

class _InteractiveSalesChartState extends State<_InteractiveSalesChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hoverPosition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  bool _showDetails = false;

  void _moveDetails(double x, double width) {
    if (width <= 0) return;
    final position = x <= 4
        ? 0.0
        : x >= width - 4
        ? 1.0
        : (x / width).clamp(0.0, 1.0);
    if (!_showDetails) {
      _hoverPosition.value = position;
      setState(() => _showDetails = true);
    } else {
      _hoverPosition.animateTo(
        position,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _hoverPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final endHour = (DateTime.now().hour + 1).clamp(1, 24);
    final hourlySales = List<double>.filled(endHour, 0);
    for (final order in widget.orders) {
      if (order.createdAt.hour < endHour) {
        hourlySales[order.createdAt.hour] += order.totalAmount;
      }
    }
    final totals = List<double>.filled(endHour + 1, 0);
    for (var hour = 0; hour < endHour; hour++) {
      totals[hour + 1] = totals[hour] + hourlySales[hour];
    }
    return Column(
      children: [
        SizedBox(
          height: 132,
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final tooltipWidth = (width - 16).clamp(0.0, 190.0);
              return MouseRegion(
                key: const ValueKey('sales-chart-hover-region'),
                onHover: (event) => _moveDetails(event.localPosition.dx, width),
                onExit: (_) => setState(() => _showDetails = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _moveDetails(details.localPosition.dx, width),
                  onHorizontalDragUpdate: (details) =>
                      _moveDetails(details.localPosition.dx, width),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          key: const ValueKey('sales-chart-plot'),
                          painter: _SalesPainter(totals),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: _showDetails ? 1 : 0,
                            duration: const Duration(milliseconds: 170),
                            curve: Curves.easeInOut,
                            child: AnimatedBuilder(
                              animation: _hoverPosition,
                              builder: (context, _) {
                                final hourPosition =
                                    _hoverPosition.value * endHour;
                                final lower = hourPosition.floor().clamp(
                                  0,
                                  endHour,
                                );
                                final upper = (lower + 1).clamp(0, endHour);
                                final runningTotal =
                                    totals[lower] +
                                    (totals[upper] - totals[lower]) *
                                        (hourPosition - lower);
                                final x = width * _hoverPosition.value;
                                final y = _SalesPainter.yFor(
                                  runningTotal,
                                  totals.last,
                                  132,
                                );
                                final tooltipLeft = (x - tooltipWidth / 2)
                                    .clamp(8.0, width - tooltipWidth - 8.0);
                                final tooltipTop = y > 80 ? y - 78 : y + 12;
                                return Stack(
                                  children: [
                                    Positioned.fill(
                                      child: CustomPaint(
                                        painter: _HoverPainter(Offset(x, y)),
                                      ),
                                    ),
                                    Positioned(
                                      left: tooltipLeft,
                                      top: tooltipTop,
                                      width: tooltipWidth,
                                      child: Container(
                                        key: const ValueKey(
                                          'sales-chart-tooltip',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            9,
                                          ),
                                          border: Border.all(
                                            color: OperationsOverview.line,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Color(0x16000000),
                                              blurRadius: 8,
                                              offset: Offset(0, 3),
                                            ),
                                          ],
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _timeLabel(hourPosition),
                                              style: const TextStyle(
                                                color: OperationsOverview.ink,
                                                fontSize: 13,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Text(
                                              'Running total: ${OperationsOverview._money(runningTotal)}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color:
                                                    OperationsOverview.orange,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '12 AM',
              style: TextStyle(color: OperationsOverview.muted, fontSize: 12),
            ),
            Text(
              _hourLabel(endHour),
              style: const TextStyle(
                color: OperationsOverview.muted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _hourLabel(int hour) {
    final clockHour = hour % 24;
    final displayHour = clockHour % 12 == 0 ? 12 : clockHour % 12;
    return '$displayHour ${clockHour < 12 ? 'AM' : 'PM'}';
  }

  String _timeLabel(double hourPosition) {
    final minutes = (hourPosition * 60).round();
    final hour = minutes ~/ 60;
    final minute = minutes % 60;
    if (minute == 0) return _hourLabel(hour);
    final clockHour = hour % 24;
    final displayHour = clockHour % 12 == 0 ? 12 : clockHour % 12;
    return '$displayHour:${minute.toString().padLeft(2, '0')} '
        '${clockHour < 12 ? 'AM' : 'PM'}';
  }
}

class _SalesPainter extends CustomPainter {
  const _SalesPainter(this.values);
  final List<double> values;

  static double yFor(double value, double maximum, double height) =>
      maximum == 0 ? height * 0.45 : height * (0.84 - 0.70 * value / maximum);

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFFFBF1EC);
    canvas.drawRect(Offset.zero & size, background);
    final maximum = values.last;
    final paint = Paint()
      ..color = OperationsOverview.orange
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = OperationsOverview.orange.withValues(alpha: 0.10);
    final path = Path();
    final area = Path()..moveTo(0, size.height);
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = yFor(values[i], maximum, size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      area.lineTo(x, y);
    }
    area.lineTo(size.width, size.height);
    area.close();
    canvas.drawPath(area, fill);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SalesPainter oldDelegate) =>
      oldDelegate.values != values;
}

class _HoverPainter extends CustomPainter {
  const _HoverPainter(this.point);

  final Offset point;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(point.dx, 0),
      Offset(point.dx, size.height),
      Paint()
        ..color = const Color(0xFFC9C1BB)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(point, 5, Paint()..color = Colors.white);
    canvas.drawCircle(point, 3.5, Paint()..color = OperationsOverview.orange);
  }

  @override
  bool shouldRepaint(covariant _HoverPainter oldDelegate) =>
      oldDelegate.point != point;
}
