import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'widgets/operational_monitor_widgets.dart';

const int _queuePageSize = 20;
const Duration _preparationDelay = Duration(minutes: 30);

class OrderQueueMonitorPage extends StatefulWidget {
  const OrderQueueMonitorPage({
    super.key,
    required this.controller,
    this.targetOrderId,
    this.onOrderOpened,
  });

  final InventoryController controller;
  final String? targetOrderId;
  final VoidCallback? onOrderOpened;

  @override
  State<OrderQueueMonitorPage> createState() =>
      _OperationalQueueMonitorPageState();
}

class _OperationalQueueMonitorPageState extends State<OrderQueueMonitorPage> {
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
  void didUpdateWidget(covariant OrderQueueMonitorPage oldWidget) {
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

  bool _isActive(CustomerOrder order) =>
      order.status.trim().toLowerCase() == 'pending';

  bool _isAssigned(CustomerOrder order) {
    final id = order.assignedHelperId?.trim();
    return id != null && id.isNotEmpty;
  }

  DateTime _workStart(CustomerOrder order) =>
      order.assignedAt ?? order.createdAt;

  Duration _queueAge(CustomerOrder order) =>
      DateTime.now().difference(order.createdAt);

  Duration _workAge(CustomerOrder order) =>
      DateTime.now().difference(_workStart(order));

  bool _isDelayed(CustomerOrder order) => _workAge(order) >= _preparationDelay;

  String _status(CustomerOrder order) {
    if (_isDelayed(order)) return 'Delayed';
    return _isAssigned(order) ? 'Preparing' : 'Waiting';
  }

  Color _statusColor(CustomerOrder order) {
    if (_isDelayed(order)) return Colors.red;
    return _isAssigned(order) ? monitorPrimaryBlue : Colors.orange;
  }

  String _shortId(String id) =>
      (id.length <= 8 ? id : id.substring(0, 8)).toUpperCase();

  String _person(String? value, {String fallback = 'Unassigned'}) {
    final text = value?.trim();
    return text == null || text.isEmpty || text.toLowerCase() == 'null'
        ? fallback
        : text;
  }

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
                title: 'Unable to load the preparation queue',
                onRetry: () => widget.controller.retryOrdersSnapshot(),
              ),
            );
          }

          if (!widget.controller.hasUsableOrdersSnapshot &&
              widget.controller.ordersSnapshotError != null) {
            return _initialSurface(
              child: MonitorLoadError(
                title: 'Unable to load the preparation queue',
                onRetry: () => widget.controller.retryOrdersSnapshot(),
              ),
            );
          }

          final allOrders = snapshot.data ?? const <CustomerOrder>[];
          final activeOrders = allOrders.where(_isActive).toList()
            ..sort((a, b) {
              if (_isDelayed(a) != _isDelayed(b)) {
                return _isDelayed(a) ? -1 : 1;
              }
              return a.createdAt.compareTo(b.createdAt);
            });
          _handlePendingAutoOpen(activeOrders);
          _closeStaleSelection(activeOrders);

          final totalPages = math.max(
            1,
            (activeOrders.length / _queuePageSize).ceil(),
          );
          final page = _currentPage.clamp(1, totalPages);
          _schedulePageClamp(page);
          final pageOrders = activeOrders
              .skip((page - 1) * _queuePageSize)
              .take(_queuePageSize)
              .toList(growable: false);
          final selectedOrder = _selected(activeOrders);

          return Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(),
                const SizedBox(height: 20),
                _metrics(allOrders, activeOrders),
                const SizedBox(height: 20),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final showDetail = constraints.maxWidth >= 1180;
                      final table = _table(
                        orders: pageOrders,
                        totalItems: activeOrders.length,
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
                'Queue Monitor',
                style: TextStyle(
                  color: monitorDarkText,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontFamily: monitorFontFamily,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Monitor Helper assignment, preparation workload, and queue delays.',
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
    List<CustomerOrder> activeOrders,
  ) {
    final waiting = activeOrders.where((order) => !_isAssigned(order)).length;
    final preparing = activeOrders.where(_isAssigned).length;
    final delayed = activeOrders.where(_isDelayed).length;
    final readyToday = allOrders
        .where((order) => _isToday(order.preparedAt))
        .length;
    final oldest = activeOrders.isEmpty
        ? 'None'
        : _elapsed(
            activeOrders
                .map(_queueAge)
                .reduce((first, second) => first > second ? first : second),
          );
    final cards = <Widget>[
      MonitorMetricCard(
        title: 'Waiting',
        value: '$waiting',
        subtitle: 'Unassigned',
        icon: Icons.hourglass_bottom_rounded,
        color: Colors.orange,
      ),
      MonitorMetricCard(
        title: 'Preparing',
        value: '$preparing',
        subtitle: 'Helper assigned',
        icon: Icons.handyman_outlined,
        color: monitorPrimaryBlue,
      ),
      MonitorMetricCard(
        title: 'Delayed',
        value: '$delayed',
        subtitle: '30+ minutes',
        icon: Icons.warning_amber_rounded,
        color: Colors.red,
      ),
      MonitorMetricCard(
        title: 'Oldest Wait',
        value: oldest,
        subtitle: 'Active queue',
        icon: Icons.timer_outlined,
        color: Colors.teal,
      ),
      MonitorMetricCard(
        title: 'Ready Today',
        value: '$readyToday',
        subtitle: 'Handed to payment',
        icon: Icons.done_all_rounded,
        color: Colors.green,
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
    final first = totalItems == 0 ? 0 : ((page - 1) * _queuePageSize) + 1;
    final last = math.min(page * _queuePageSize, totalItems);
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
                  'Active Preparation Queue',
                  style: TextStyle(
                    color: monitorDarkText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontFamily: monitorFontFamily,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Orders leave this table when they are ready for payment.',
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
                    icon: Icons.task_alt_rounded,
                    title: 'Preparation queue is clear',
                    message:
                        'New unassigned or in-preparation orders will appear here.',
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final width = math.max(920.0, constraints.maxWidth);
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
          MonitorTableCell(width: 145, text: 'QUEUE STATUS', header: true),
          MonitorTableCell(width: 175, text: 'HELPER', header: true),
          MonitorTableCell(width: 80, text: 'ITEMS', header: true),
          MonitorTableCell(width: 110, text: 'WAITING', header: true),
          MonitorTableCell(width: 160, text: 'ASSIGNED', header: true),
          MonitorTableCell(width: 110, text: 'PRIORITY', header: true),
        ],
      ),
    );
  }

  Widget _tableRow(CustomerOrder order, {required bool useDialog}) {
    final selected = order.id == _selectedOrderId;
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
              SizedBox(
                width: 145,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MonitorStatusPill(
                    label: _status(order),
                    color: _statusColor(order),
                  ),
                ),
              ),
              MonitorTableCell(
                width: 175,
                text: _person(order.assignedHelperName),
              ),
              MonitorTableCell(width: 80, text: '${order.items.length}'),
              MonitorTableCell(width: 110, text: _elapsed(_queueAge(order))),
              MonitorTableCell(width: 160, text: _dateTime(order.assignedAt)),
              SizedBox(
                width: 110,
                child: Text(
                  _isDelayed(order) ? 'Delayed' : 'Normal',
                  style: TextStyle(
                    color: _isDelayed(order) ? Colors.red : monitorMutedText,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    fontFamily: monitorFontFamily,
                  ),
                ),
              ),
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
              message: 'Choose a row to inspect preparation details.',
            )
          : _details(order),
    );
  }

  Widget _details(CustomerOrder order, {bool dialog = false}) {
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
                      'Preparation Details',
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
                label: _status(order),
                color: _statusColor(order),
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
              MonitorInfoRow(label: 'Queue status', value: _status(order)),
              MonitorInfoRow(
                label: 'Created',
                value: _dateTime(order.createdAt),
              ),
              MonitorInfoRow(
                label: 'Queue wait',
                value: _elapsed(_queueAge(order)),
              ),
              MonitorInfoRow(
                label: 'Assigned Helper',
                value: _person(order.assignedHelperName),
              ),
              MonitorInfoRow(
                label: 'Assignment time',
                value: _dateTime(order.assignedAt),
              ),
              MonitorInfoRow(
                label: 'Assigned workload age',
                value: _isAssigned(order) ? _elapsed(_workAge(order)) : '—',
              ),
              const MonitorInfoRow(label: 'Preparation start', value: '—'),
              const MonitorInfoRow(label: 'Preparation duration', value: '—'),
              MonitorInfoRow(
                label: 'Item count',
                value: '${order.items.length}',
              ),
              MonitorInfoRow(
                label: 'Delay state',
                value: _isDelayed(order) ? 'Delayed' : 'On track',
              ),
              const SizedBox(height: 14),
              const Text(
                'Items to prepare',
                style: TextStyle(
                  color: monitorDarkText,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  fontFamily: monitorFontFamily,
                ),
              ),
              const SizedBox(height: 8),
              ...order.items.map(_itemRow),
              if (_isDelayed(order)) ...[
                const SizedBox(height: 8),
                const MonitorNotice(
                  message:
                      'This preparation has exceeded the 30-minute operational threshold.',
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Assignments are automatic. This monitor is read-only.',
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
                if (order.id == orderId && _isActive(order)) {
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
    if (target == null) return;
    if (!orders.any((order) => order.id == target)) return;
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
