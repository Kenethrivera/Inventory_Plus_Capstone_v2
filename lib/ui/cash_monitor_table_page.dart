import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'widgets/operational_monitor_widgets.dart';

const int _cashPageSize = 20;
const Duration _paymentDelay = Duration(minutes: 15);

class PosMonitorPage extends StatefulWidget {
  const PosMonitorPage({
    super.key,
    required this.controller,
    this.targetOrderId,
    this.onOrderOpened,
  });

  final InventoryController controller;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;

  @override
  State<PosMonitorPage> createState() => _CashMonitorPageState();
}

class _CashMonitorPageState extends State<PosMonitorPage> {
  Timer? _clockTimer;
  String? _selectedOrderId;
  String? _pendingAutoOpenId;
  int _currentPage = 1;

  @override
  void initState() {
    super.initState();
    _pendingAutoOpenId = widget.targetOrderId;
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant PosMonitorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetOrderId != null &&
        widget.targetOrderId != oldWidget.targetOrderId) {
      _pendingAutoOpenId = widget.targetOrderId;
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  bool _isToday(DateTime? date) {
    if (date == null) return false;
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  bool _isReady(CustomerOrder order) =>
      order.status.trim().toLowerCase() == 'prepared';

  DateTime _readyAt(CustomerOrder order) => order.preparedAt ?? order.createdAt;

  Duration _paymentWait(CustomerOrder order) =>
      DateTime.now().difference(_readyAt(order));

  bool _isDelayed(CustomerOrder order) => _paymentWait(order) >= _paymentDelay;

  String _shortId(String id) =>
      (id.length <= 8 ? id : id.substring(0, 8)).toUpperCase();

  String _person(String? value, {String fallback = '—'}) {
    final text = value?.trim();
    return text == null || text.isEmpty || text.toLowerCase() == 'null'
        ? fallback
        : text;
  }

  String _money(num value) => '₱${value.toStringAsFixed(2)}';

  String _elapsed(Duration duration) {
    if (duration.isNegative || duration.inMinutes < 1) return '< 1 min';
    if (duration.inHours < 1) return '${duration.inMinutes} min';
    if (duration.inDays < 1) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    return '${duration.inDays}d ${duration.inHours.remainder(24)}h';
  }

  String _dateTime(DateTime? date) {
    if (date == null) return '—';
    final hour = date.hour > 12
        ? date.hour - 12
        : (date.hour == 0 ? 12 : date.hour);
    final minute = date.minute.toString().padLeft(2, '0');
    final suffix = date.hour >= 12 ? 'PM' : 'AM';
    return '${date.month}/${date.day}/${date.year} $hour:$minute $suffix';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: monitorPageBackground,
      body: StreamBuilder<List<CustomerOrder>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return _initialSurface(child: buildMonitorSkeleton());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return _initialSurface(
              child: MonitorLoadError(
                title: 'Unable to load the payment queue',
                onRetry: () => widget.controller.retryOrdersSnapshot(),
              ),
            );
          }

          if (!widget.controller.hasUsableOrdersSnapshot &&
              widget.controller.ordersSnapshotError != null) {
            return _initialSurface(
              child: MonitorLoadError(
                title: 'Unable to load the payment queue',
                onRetry: () => widget.controller.retryOrdersSnapshot(),
              ),
            );
          }

          final allOrders = snapshot.data ?? const <CustomerOrder>[];
          final readyOrders = allOrders.where(_isReady).toList()
            ..sort((a, b) => _readyAt(a).compareTo(_readyAt(b)));
          _handlePendingAutoOpen(readyOrders);
          _closeStaleSelection(readyOrders);

          final totalPages = math.max(
            1,
            (readyOrders.length / _cashPageSize).ceil(),
          );
          final page = _currentPage.clamp(1, totalPages);
          _schedulePageClamp(page);
          final pageOrders = readyOrders
              .skip((page - 1) * _cashPageSize)
              .take(_cashPageSize)
              .toList(growable: false);
          final selectedOrder = _selected(readyOrders);

          return Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(),
                const SizedBox(height: 20),
                _metrics(allOrders, readyOrders),
                const SizedBox(height: 20),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final showDetail = constraints.maxWidth >= 1180;
                      final table = _table(
                        orders: pageOrders,
                        totalItems: readyOrders.length,
                        page: page,
                        totalPages: totalPages,
                        compact: constraints.maxWidth < 760,
                        useDialog: !showDetail,
                      );
                      if (!showDetail) return table;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 7, child: table),
                          const SizedBox(width: 18),
                          Expanded(flex: 3, child: _detailPanel(selectedOrder)),
                        ],
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

  Widget _initialSurface({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: 20),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _header() {
    return const Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cash Monitor',
                style: TextStyle(
                  color: monitorDarkText,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontFamily: monitorFontFamily,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Monitor prepared orders, payment readiness, and cashier delays.',
                style: TextStyle(
                  color: monitorMutedText,
                  fontSize: 14,
                  fontFamily: monitorFontFamily,
                ),
              ),
            ],
          ),
        ),
        MonitorReadOnlyBadge(label: 'Admin monitor'),
      ],
    );
  }

  Widget _metrics(
    List<CustomerOrder> allOrders,
    List<CustomerOrder> readyOrders,
  ) {
    final paidToday = allOrders
        .where((order) {
          return order.status.toLowerCase() == 'completed' &&
              _isToday(order.completedAt);
        })
        .toList(growable: false);
    final salesToday = paidToday.fold<double>(
      0,
      (total, order) => total + order.totalAmount,
    );
    final delayed = readyOrders.where(_isDelayed).length;
    final oldest = readyOrders.isEmpty
        ? 'None'
        : _elapsed(
            readyOrders
                .map(_paymentWait)
                .reduce((first, second) => first > second ? first : second),
          );
    final cards = <Widget>[
      MonitorMetricCard(
        title: 'Ready for Payment',
        value: '${readyOrders.length}',
        subtitle: 'Waiting for cashier',
        icon: Icons.point_of_sale_outlined,
        color: monitorPrimaryBlue,
      ),
      MonitorMetricCard(
        title: 'Payment Delayed',
        value: '$delayed',
        subtitle: '15+ minutes',
        icon: Icons.warning_amber_rounded,
        color: Colors.red,
      ),
      MonitorMetricCard(
        title: 'Paid Today',
        value: '${paidToday.length}',
        subtitle: 'Completed payments',
        icon: Icons.receipt_long_outlined,
        color: Colors.green,
      ),
      MonitorMetricCard(
        title: 'Sales Today',
        value: _money(salesToday),
        subtitle: 'Completed total',
        icon: Icons.payments_outlined,
        color: Colors.teal,
      ),
      MonitorMetricCard(
        title: 'Oldest Payment Wait',
        value: oldest,
        subtitle: 'Ready queue',
        icon: Icons.timer_outlined,
        color: Colors.orange,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1050
            ? 5
            : constraints.maxWidth >= 620
            ? 3
            : 2;
        final width = (constraints.maxWidth - ((columns - 1) * 12)) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: cards
              .map((card) => SizedBox(width: width, child: card))
              .toList(growable: false),
        );
      },
    );
  }

  Widget _table({
    required List<CustomerOrder> orders,
    required int totalItems,
    required int page,
    required int totalPages,
    required bool compact,
    required bool useDialog,
  }) {
    final first = totalItems == 0 ? 0 : ((page - 1) * _cashPageSize) + 1;
    final last = math.min(page * _cashPageSize, totalItems);
    return MonitorPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active Payment Queue',
                  style: TextStyle(
                    color: monitorDarkText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontFamily: monitorFontFamily,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Only prepared orders waiting for payment are shown.',
                  style: TextStyle(
                    color: monitorMutedText,
                    fontSize: 12,
                    fontFamily: monitorFontFamily,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: monitorLineColor),
          Expanded(
            child: orders.isEmpty
                ? const MonitorEmptyState(
                    icon: Icons.price_check_rounded,
                    title: 'Payment queue is clear',
                    message:
                        'Prepared orders will appear here when they are ready for checkout.',
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final width = math.max(900.0, constraints.maxWidth);
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          height: constraints.maxHeight,
                          child: Column(
                            children: [
                              _tableHeader(),
                              Expanded(
                                child: ListView.separated(
                                  itemCount: orders.length,
                                  separatorBuilder: (_, _) => const Divider(
                                    height: 1,
                                    color: monitorLineColor,
                                  ),
                                  itemBuilder: (context, index) => _tableRow(
                                    orders[index],
                                    useDialog: useDialog,
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
          const Divider(height: 1, color: monitorLineColor),
          MonitorPaginationFooter(
            rangeLabel: totalItems == 0
                ? '0 of 0'
                : '$first–$last of $totalItems',
            currentPage: page,
            totalPages: totalPages,
            compact: compact,
            onPageSelected: (value) => setState(() => _currentPage = value),
          ),
        ],
      ),
    );
  }

  Widget _tableHeader() {
    return Container(
      height: 42,
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: const Row(
        children: [
          MonitorTableCell(width: 130, text: 'ORDER', header: true),
          MonitorTableCell(width: 170, text: 'READY SINCE', header: true),
          MonitorTableCell(width: 150, text: 'CASHIER', header: true),
          MonitorTableCell(width: 75, text: 'ITEMS', header: true),
          MonitorTableCell(width: 115, text: 'AMOUNT', header: true),
          MonitorTableCell(width: 120, text: 'PAYMENT', header: true),
          MonitorTableCell(width: 105, text: 'WAIT', header: true),
        ],
      ),
    );
  }

  Widget _tableRow(CustomerOrder order, {required bool useDialog}) {
    final selected = order.id == _selectedOrderId;
    final delayed = _isDelayed(order);
    return Material(
      color: selected
          ? monitorPrimaryBlue.withValues(alpha: 0.06)
          : Colors.white,
      child: InkWell(
        onTap: () => _selectOrder(order, useDialog: useDialog),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              MonitorTableCell(
                width: 130,
                text: '#${_shortId(order.id)}',
                strong: true,
              ),
              MonitorTableCell(width: 170, text: _dateTime(_readyAt(order))),
              const MonitorTableCell(width: 150, text: '—'),
              MonitorTableCell(width: 75, text: '${order.items.length}'),
              MonitorTableCell(width: 115, text: _money(order.totalAmount)),
              SizedBox(
                width: 120,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MonitorStatusPill(
                    label: delayed ? 'Delayed' : 'Waiting',
                    color: delayed ? Colors.red : monitorPrimaryBlue,
                  ),
                ),
              ),
              MonitorTableCell(width: 105, text: _elapsed(_paymentWait(order))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailPanel(CustomerOrder? order) {
    return MonitorPanel(
      child: order == null
          ? const MonitorEmptyState(
              icon: Icons.ads_click,
              title: 'Select an order',
              message: 'Choose a row to inspect payment details.',
            )
          : _details(order),
    );
  }

  Widget _details(CustomerOrder order, {bool dialog = false}) {
    final delayed = _isDelayed(order);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Payment Details',
                      style: TextStyle(
                        color: monitorDarkText,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        fontFamily: monitorFontFamily,
                      ),
                    ),
                    Text(
                      'Order #${_shortId(order.id)}',
                      style: const TextStyle(
                        color: monitorMutedText,
                        fontSize: 12,
                        fontFamily: monitorFontFamily,
                      ),
                    ),
                  ],
                ),
              ),
              MonitorStatusPill(
                label: delayed ? 'Delayed' : 'Ready',
                color: delayed ? Colors.red : monitorPrimaryBlue,
              ),
              if (dialog)
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: monitorLineColor),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const MonitorInfoRow(
                label: 'Payment status',
                value: 'Waiting for cashier',
              ),
              MonitorInfoRow(
                label: 'Ready since',
                value: _dateTime(_readyAt(order)),
              ),
              MonitorInfoRow(
                label: 'Payment wait',
                value: _elapsed(_paymentWait(order)),
              ),
              MonitorInfoRow(
                label: 'Prepared by',
                value: _person(order.preparedByName, fallback: 'Not recorded'),
              ),
              MonitorInfoRow(
                label: 'Assigned Helper',
                value: _person(order.assignedHelperName),
              ),
              MonitorInfoRow(
                label: 'Created',
                value: _dateTime(order.createdAt),
              ),
              MonitorInfoRow(
                label: 'Created by',
                value: _person(order.createdByName, fallback: 'Not recorded'),
              ),
              MonitorInfoRow(
                label: 'Item count',
                value: '${order.items.length}',
              ),
              MonitorInfoRow(label: 'Amount', value: _money(order.totalAmount)),
              const SizedBox(height: 14),
              const Text(
                'Order items',
                style: TextStyle(
                  color: monitorDarkText,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  fontFamily: monitorFontFamily,
                ),
              ),
              const SizedBox(height: 8),
              ...order.items.map(_itemRow),
              if (delayed) ...[
                const SizedBox(height: 8),
                const MonitorNotice(
                  message:
                      'This order has waited for payment longer than 15 minutes.',
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Checkout actions remain with Cashier staff. This monitor is read-only.',
                style: TextStyle(
                  color: monitorMutedText,
                  fontSize: 12,
                  fontFamily: monitorFontFamily,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _itemRow(CustomerOrderItem item) {
    final quantity = item.quantity == item.quantity.roundToDouble()
        ? item.quantity.toInt().toString()
        : item.quantity.toStringAsFixed(2);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border.all(color: monitorLineColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            size: 16,
            color: monitorMutedText,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.productName,
              style: const TextStyle(
                color: monitorDarkText,
                fontWeight: FontWeight.w700,
                fontFamily: monitorFontFamily,
              ),
            ),
          ),
          Text(
            'x$quantity',
            style: const TextStyle(
              color: monitorMutedText,
              fontWeight: FontWeight.w800,
              fontFamily: monitorFontFamily,
            ),
          ),
        ],
      ),
    );
  }

  void _selectOrder(CustomerOrder order, {required bool useDialog}) {
    setState(() => _selectedOrderId = order.id);
    widget.onOrderOpened?.call();
    if (useDialog) _showDetailsDialog(order.id);
  }

  void _showDetailsDialog(String orderId) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: 520,
          height: 640,
          child: StreamBuilder<List<CustomerOrder>>(
            stream: widget.controller.streamOrders(),
            builder: (context, snapshot) {
              CustomerOrder? current;
              for (final order in snapshot.data ?? const <CustomerOrder>[]) {
                if (order.id == orderId && _isReady(order)) {
                  current = order;
                  break;
                }
              }
              if (current == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (dialogContext.mounted &&
                      Navigator.of(dialogContext).canPop()) {
                    Navigator.of(dialogContext).pop();
                  }
                });
                return const SizedBox.shrink();
              }
              return _details(current, dialog: true);
            },
          ),
        ),
      ),
    );
  }

  CustomerOrder? _selected(List<CustomerOrder> orders) {
    for (final order in orders) {
      if (order.id == _selectedOrderId) return order;
    }
    return null;
  }

  void _closeStaleSelection(List<CustomerOrder> orders) {
    final selectedId = _selectedOrderId;
    if (selectedId == null || orders.any((order) => order.id == selectedId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedOrderId == selectedId) {
        setState(() => _selectedOrderId = null);
      }
    });
  }

  void _handlePendingAutoOpen(List<CustomerOrder> orders) {
    final target = _pendingAutoOpenId;
    if (target == null || !orders.any((order) => order.id == target)) return;
    _pendingAutoOpenId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _selectedOrderId = target);
      widget.onOrderOpened?.call();
    });
  }

  void _schedulePageClamp(int page) {
    if (page == _currentPage) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPage != page) {
        setState(() => _currentPage = page);
      }
    });
  }
}
