import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/inventory.dart';
import '../logic/history_pagination.dart';
import '../logic/inventory_controller.dart';
import '../logic/orders_activity_metrics.dart';
import '../services/csv_export.dart';
import 'widgets/order_details_drawer.dart';
import 'order_assignee_label.dart';
import 'widgets/app_styled_dropdown.dart';

class OrdersActivityPage extends StatefulWidget {
  const OrdersActivityPage({
    super.key,
    required this.controller,
    required this.isActive,
    required this.onOpenQueue,
    this.initialTab = 'Orders',
  });

  final InventoryController controller;
  final bool isActive;
  final ValueChanged<String> onOpenQueue;
  final String initialTab;

  @override
  State<OrdersActivityPage> createState() => _OrdersActivityPageState();
}

class _OrdersActivityPageState extends State<OrdersActivityPage> {
  static const _ink = Color(0xFF171717);
  static const _muted = Color(0xFF817A75);
  static const _line = Color(0xFFE6E1DC);
  static const _orange = Color(0xFFC83D08);
  static const _background = Color(0xFFF7F6F4);
  static const _tabs = ['Orders', 'Payments', 'Stock movements'];
  static const _pageSize = 10;

  late String _tab = widget.initialTab;
  String _status = 'All statuses';
  String _movementFilter = 'All movement types';
  String _staff = 'All staff';
  String _time = 'All time';
  String _search = '';
  int _page = 1;
  bool _exporting = false;
  bool _dirtyOrders = false;
  bool _dirtyStock = false;
  late Future<List<CustomerOrder>> _ordersFuture;
  late Future<List<Map<String, dynamic>>> _stockFuture;
  StreamSubscription<HistoryInvalidation>? _updates;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ordersFuture = widget.controller.loadActivityOrders();
    _stockFuture = widget.controller.loadAllTransactionHistory();
    _updates = widget.controller.historyInvalidations.listen((event) {
      if (event.kind == HistoryInvalidationKind.orderHistory ||
          event.kind == HistoryInvalidationKind.scope) {
        _dirtyOrders = true;
      }
      if (event.kind == HistoryInvalidationKind.transactions ||
          event.kind == HistoryInvalidationKind.scope) {
        _dirtyStock = true;
      }
      if (widget.isActive) _refreshDirty();
    });
  }

  @override
  void didUpdateWidget(covariant OrdersActivityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTab != oldWidget.initialTab ||
        (widget.isActive && !oldWidget.isActive)) {
      _tab = widget.initialTab;
      if (widget.initialTab != oldWidget.initialTab) _page = 1;
    }
    if (widget.controller != oldWidget.controller) {
      _page = 1;
      _ordersFuture = widget.controller.loadActivityOrders();
      _stockFuture = widget.controller.loadAllTransactionHistory();
    } else if (widget.isActive && !oldWidget.isActive) {
      _refreshDirty();
    }
  }

  void _refreshDirty() {
    if (!_dirtyOrders && !_dirtyStock) return;
    setState(() {
      if (_dirtyOrders) _ordersFuture = widget.controller.loadActivityOrders();
      if (_dirtyStock) {
        _stockFuture = widget.controller.loadAllTransactionHistory();
      }
      _dirtyOrders = false;
      _dirtyStock = false;
    });
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _background,
    child: FutureBuilder<List<CustomerOrder>>(
      future: _ordersFuture,
      builder: (context, ordersSnapshot) =>
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _stockFuture,
            builder: (context, stockSnapshot) {
              final orders = ordersSnapshot.data ?? const <CustomerOrder>[];
              final stock =
                  stockSnapshot.data ?? const <Map<String, dynamic>>[];
              final staff = <String>{
                for (final order in orders) ...[
                  if (order.createdByName?.trim().isNotEmpty == true)
                    order.createdByName!,
                  if (order.assignedHelperName?.trim().isNotEmpty == true)
                    order.assignedHelperName!,
                  if (order.assignedBodegeroName?.trim().isNotEmpty == true)
                    order.assignedBodegeroName!,
                ],
                for (final row in stock)
                  if (_actor(row).isNotEmpty) _actor(row),
              }.toList()..sort();
              final visibleOrders = _filterOrders(orders);
              final visibleStock = _filterStock(stock);
              final rowCount = _tab == 'Stock movements'
                  ? visibleStock.length
                  : visibleOrders.length;
              final pageCount = math.max(
                1,
                (rowCount + _pageSize - 1) ~/ _pageSize,
              );
              final currentPage = math.min(_page, pageCount);
              final firstRow = (currentPage - 1) * _pageSize;
              final pageOrders = visibleOrders
                  .skip(firstRow)
                  .take(_pageSize)
                  .toList(growable: false);
              final pageStock = visibleStock
                  .skip(firstRow)
                  .take(_pageSize)
                  .toList(growable: false);
              final loading = _tab == 'Stock movements'
                  ? stockSnapshot.connectionState != ConnectionState.done
                  : ordersSnapshot.connectionState != ConnectionState.done;
              final error = _tab == 'Stock movements'
                  ? stockSnapshot.error
                  : ordersSnapshot.error;

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 20,
                      runSpacing: 16,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Orders & activity',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                color: _ink,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Every order from creation to release, plus payments and stock movements across the store.',
                              style: TextStyle(fontSize: 13, color: _muted),
                            ),
                          ],
                        ),
                        OutlinedButton.icon(
                          onPressed: loading || error != null || _exporting
                              ? null
                              : () => _export(visibleOrders, visibleStock),
                          icon: const Icon(LucideIcons.download, size: 17),
                          label: Text(_exporting ? 'Exporting…' : 'Export CSV'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _ink,
                            backgroundColor: Colors.white,
                            textStyle: const TextStyle(fontSize: 13),
                            side: const BorderSide(color: _line),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 27),
                    DecoratedBox(
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: _line)),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [for (final tab in _tabs) _tabButton(tab)],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _filters(staff),
                    const SizedBox(height: 20),
                    if (_tab == 'Payments' && !loading && error == null) ...[
                      _paymentSummary(PaymentTotals.fromOrders(visibleOrders)),
                      const SizedBox(height: 20),
                    ],
                    if (loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(48),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            children: [
                              const Text(
                                'Could not load activity.',
                                style: TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                style: TextButton.styleFrom(
                                  textStyle: const TextStyle(fontSize: 13),
                                ),
                                onPressed: () => setState(() {
                                  _ordersFuture = widget.controller
                                      .loadActivityOrders();
                                  _stockFuture = widget.controller
                                      .loadAllTransactionHistory();
                                }),
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else ...[
                      _table(pageOrders, pageStock),
                      _pagination(currentPage, pageCount, rowCount),
                    ],
                  ],
                ),
              );
            },
          ),
    ),
  );

  Widget _tabButton(String label) {
    final selected = _tab == label;
    return InkWell(
      onTap: () => setState(() {
        _tab = label;
        _status = 'All statuses';
        _movementFilter = 'All movement types';
        _search = '';
        _page = 1;
        _searchController.clear();
      }),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? _orange : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _ink : _muted,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _filters(List<String> staff) => LayoutBuilder(
    builder: (context, size) {
      final compact = size.maxWidth < 950;
      final search = TextField(
        controller: _searchController,
        style: const TextStyle(fontSize: 13),
        onChanged: (value) => setState(() {
          _search = value.trim().toLowerCase();
          _page = 1;
        }),
        decoration: InputDecoration(
          hintStyle: const TextStyle(fontSize: 13, color: _muted),
          hintText: _tab == 'Stock movements'
              ? 'Search product, SKU, note...'
              : 'Search order #, product, staff, GCash ref...',
          prefixIcon: const Icon(LucideIcons.search, size: 18, color: _muted),
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: _line),
          ),
        ),
      );
      final status = _dropdown(
        _status,
        const [
          'All statuses',
          'Waiting',
          'Assigned',
          'Preparing',
          'Ready',
          'Completed',
          'Cancelled',
          'Returned',
        ],
        (value) => setState(() {
          _status = value;
          _page = 1;
        }),
        compact ? null : 150,
      );
      final movementType = _dropdown(
        _movementFilter,
        const [
          'All movement types',
          'Sale',
          'Restock',
          'Write-off',
          'Adjustment',
          'Return',
        ],
        (value) => setState(() {
          _movementFilter = value;
          _page = 1;
        }),
        compact ? null : 220,
      );
      final staffFilter = _dropdown(
        _staff,
        ['All staff', ...staff],
        (value) => setState(() {
          _staff = value;
          _page = 1;
        }),
        compact ? null : 175,
      );
      final time = _dropdown(
        _time,
        const ['All time', 'Today', 'Last 7 days', 'Last 30 days'],
        (value) => setState(() {
          _time = value;
          _page = 1;
        }),
        compact ? null : 140,
      );
      if (compact) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            search,
            const SizedBox(height: 10),
            Row(
              children: _tab == 'Stock movements'
                  ? [
                      Expanded(flex: 3, child: movementType),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: time),
                    ]
                  : [
                      Expanded(flex: 3, child: status),
                      const SizedBox(width: 8),
                      Expanded(flex: 4, child: staffFilter),
                      const SizedBox(width: 8),
                      Expanded(flex: 3, child: time),
                    ],
            ),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: search),
          const SizedBox(width: 10),
          if (_tab == 'Stock movements')
            movementType
          else ...[
            status,
            const SizedBox(width: 10),
            staffFilter,
          ],
          const SizedBox(width: 10),
          time,
        ],
      );
    },
  );

  Widget _dropdown(
    String value,
    List<String> values,
    ValueChanged<String> change,
    double? width,
  ) => SizedBox(
    width: width,
    height: 46,
    child: AppStyledDropdown<String>(
      key: ValueKey('filter-$width-$value'),
      initialValue: values.contains(value) ? value : values.first,
      style: TextStyle(fontSize: width == null ? 12 : 13, color: _ink),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        contentPadding: EdgeInsets.symmetric(
          horizontal: width == null ? 8 : 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: _line),
        ),
      ),
      items: [
        for (final item in values)
          DropdownMenuItem(
            value: item,
            child: Text(item, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (selected) {
        if (selected != null) change(selected);
      },
    ),
  );

  List<CustomerOrder> _filterOrders(List<CustomerOrder> orders) {
    final filtered = orders.where((order) {
      if (!_inTime(order.createdAt)) return false;
      if (_staff != 'All staff' &&
          order.createdByName != _staff &&
          order.assignedHelperName != _staff &&
          order.assignedBodegeroName != _staff) {
        return false;
      }
      if (_status != 'All statuses' && _orderStatus(order) != _status) {
        return false;
      }
      if (_search.isEmpty) return true;
      return [
        order.id,
        order.createdByName,
        order.assignedHelperName,
        order.assignedBodegeroName,
        order.paymentReference,
        order.paymentMode,
        ...order.items.map((item) => item.productName),
      ].whereType<String>().any(
        (value) => value.toLowerCase().contains(_search),
      );
    }).toList();
    filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered;
  }

  List<Map<String, dynamic>> _filterStock(List<Map<String, dynamic>> stock) {
    final filtered = stock.where((row) {
      final when = DateTime.tryParse(
        row['created_at']?.toString() ?? '',
      )?.toLocal();
      if (when == null || !_inTime(when)) return false;
      if (_movementFilter != 'All movement types' &&
          _movement(row['transaction_type']?.toString() ?? '') !=
              _movementFilter) {
        return false;
      }
      if (_search.isEmpty) return true;
      final product = row['products'] as Map<String, dynamic>?;
      return [
        row['transaction_type'],
        _movement(row['transaction_type']?.toString() ?? ''),
        row['note'],
        product?['product_name'],
        product?['sku'],
      ].whereType<String>().any(
        (value) => value.toLowerCase().contains(_search),
      );
    }).toList();
    filtered.sort(
      (a, b) => (b['created_at']?.toString() ?? '').compareTo(
        a['created_at']?.toString() ?? '',
      ),
    );
    return filtered;
  }

  bool _inTime(DateTime date) {
    final now = DateTime.now();
    return switch (_time) {
      'Today' =>
        date.year == now.year && date.month == now.month && date.day == now.day,
      'Last 7 days' => !date.isBefore(now.subtract(const Duration(days: 7))),
      'Last 30 days' => !date.isBefore(now.subtract(const Duration(days: 30))),
      _ => true,
    };
  }

  Widget _paymentSummary(PaymentTotals totals) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Wrap(
      spacing: 44,
      runSpacing: 16,
      children: [
        _summaryMetric('Collected', _money(totals.collected), prominent: true),
        _summaryMetric('Cash in drawer', _money(totals.cash)),
        _summaryMetric('GCash', _money(totals.gcash)),
        _summaryMetric('Transactions', '${totals.transactions}'),
      ],
    ),
  );

  Widget _summaryMetric(String label, String value, {bool prominent = false}) =>
      SizedBox(
        width: prominent ? 180 : 145,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: _ink,
                fontSize: prominent ? 21 : 16,
                fontWeight: prominent ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      );

  Widget _pagination(int page, int pageCount, int rowCount) {
    final first = rowCount == 0 ? 0 : (page - 1) * _pageSize + 1;
    final last = math.min(page * _pageSize, rowCount);
    final buttonStyle = OutlinedButton.styleFrom(
      foregroundColor: _ink,
      textStyle: const TextStyle(fontSize: 13),
      side: const BorderSide(color: _line),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 10,
        children: [
          Text(
            'Showing $first–$last of $rowCount',
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: page > 1
                    ? () => setState(() => _page = page - 1)
                    : null,
                style: buttonStyle,
                child: const Text('Previous'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Page $page of $pageCount',
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
              ),
              OutlinedButton(
                onPressed: page < pageCount
                    ? () => setState(() => _page = page + 1)
                    : null,
                style: buttonStyle,
                child: const Text('Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _table(List<CustomerOrder> orders, List<Map<String, dynamic>> stock) {
    final headers = switch (_tab) {
      'Payments' => const [
        'Order',
        'Created',
        'Items',
        'Payment',
        'Reference / change',
        'Cashier',
        'Status',
        'Total',
      ],
      'Stock movements' => const [
        'Time',
        'Product',
        'Type',
        'Change',
        'Balance',
        'By',
        'Note',
      ],
      _ => const [
        'Order',
        'Created',
        'Items',
        'Payment',
        'Cashier',
        'Assigned staff',
        'Status',
        'Total',
      ],
    };
    final List<double> baseWidths = switch (_tab) {
      'Payments' => const [190.0, 155, 70, 110, 190, 155, 110, 125],
      'Stock movements' => const [170.0, 270, 135, 95, 95, 160, 280],
      _ => const [190.0, 155, 70, 110, 155, 155, 110, 125],
    };
    final rows = _tab == 'Stock movements' ? stock.length : orders.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return _mobileRecords(orders, stock);
        }
        final baseTotal = baseWidths.fold<double>(
          0,
          (sum, width) => sum + width,
        );
        final tableWidth = math.max(baseTotal, constraints.maxWidth);
        final widths = baseWidths
            .map((width) => width * tableWidth / baseTotal)
            .toList();
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
                children: [
                  Container(
                    height: 44,
                    color: const Color(0xFFFAF9F8),
                    child: Row(
                      children: [
                        for (var i = 0; i < headers.length; i++)
                          _cell(headers[i], widths[i], color: _muted, size: 12),
                      ],
                    ),
                  ),
                  if (rows == 0)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No records match these filters.',
                        style: TextStyle(color: _muted, fontSize: 13),
                      ),
                    ),
                  for (var i = 0; i < rows; i++) ...[
                    const Divider(height: 1, color: _line),
                    _tab == 'Stock movements'
                        ? _stockRow(stock[i], widths)
                        : _orderRow(orders[i], widths),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _mobileRecords(
    List<CustomerOrder> orders,
    List<Map<String, dynamic>> stock,
  ) {
    final count = _tab == 'Stock movements' ? stock.length : orders.length;
    if (count == 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(
          child: Text(
            'No records match these filters.',
            style: TextStyle(color: _muted, fontSize: 13),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _tab == 'Stock movements'
              ? _mobileStockCard(stock[i])
              : _mobileOrderCard(orders[i]),
        ],
      ],
    );
  }

  Widget _mobileOrderCard(CustomerOrder order) {
    final status = _orderStatus(order);
    final statusColor = _statusColor(status);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _line),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openOrderDetails(order),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _shortId(order.id),
                      style: const TextStyle(
                        color: _ink,
                        fontFamily: 'monospace',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _mobileBadge(status, statusColor),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                _date(order.createdAt),
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 13),
                child: Divider(height: 1, color: _line),
              ),
              Row(
                children: [
                  Expanded(
                    child: _mobileField('Items', '${order.items.length}'),
                  ),
                  Expanded(
                    child: _mobileField('Total', _money(order.totalAmount)),
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Row(
                children: [
                  Expanded(
                    child: _mobileField('Payment', order.paymentMode ?? '—'),
                  ),
                  Expanded(
                    child: _mobileField(
                      _tab == 'Payments' ? 'Reference / change' : 'Cashier',
                      _tab == 'Payments'
                          ? _paymentDetail(order)
                          : order.createdByName ?? '—',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mobileStockCard(Map<String, dynamic> row) {
    final product = row['products'] as Map<String, dynamic>?;
    final change = (row['quantity_change'] as num?)?.toDouble() ?? 0;
    final when = DateTime.tryParse(
      row['created_at']?.toString() ?? '',
    )?.toLocal();
    final type = _movement(row['transaction_type']?.toString() ?? '');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  product?['product_name']?.toString() ?? 'Unknown product',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _mobileBadge(type, _movementColor(type)),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            when == null ? '—' : _date(when),
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 13),
            child: Divider(height: 1, color: _line),
          ),
          Row(
            children: [
              Expanded(
                child: _mobileField(
                  'Change',
                  '${change > 0 ? '+' : ''}${_quantity(change)}',
                ),
              ),
              Expanded(
                child: _mobileField(
                  'Balance',
                  _quantity((row['new_quantity'] as num?)?.toDouble() ?? 0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          _mobileField('By', _actor(row).isEmpty ? '—' : _actor(row)),
          if (_stockNote(row) != '—') ...[
            const SizedBox(height: 11),
            _mobileField('Note', _stockNote(row)),
          ],
        ],
      ),
    );
  }

  Widget _mobileField(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _ink, fontSize: 13),
      ),
    ],
  );

  Widget _mobileBadge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      border: Border.all(color: color.withValues(alpha: 0.22)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 12)),
  );

  Widget _orderRow(CustomerOrder order, List<double> widths) {
    final cells = _tab == 'Payments'
        ? <Widget>[
            _cell(_shortId(order.id), widths[0], bold: true, mono: true),
            _cell(_date(order.createdAt), widths[1], color: _muted),
            _cell('${order.items.length}', widths[2]),
            _paymentCell(order.paymentMode, widths[3]),
            _cell(_paymentDetail(order), widths[4], color: _muted, mono: true),
            _cell(order.createdByName ?? '—', widths[5]),
            _statusCell(order, widths[6]),
            _cell(
              _money(order.totalAmount),
              widths[7],
              bold: true,
              right: true,
            ),
          ]
        : <Widget>[
            _cell(_shortId(order.id), widths[0], bold: true, mono: true),
            _cell(_date(order.createdAt), widths[1], color: _muted),
            _cell('${order.items.length}', widths[2]),
            _paymentCell(order.paymentMode, widths[3]),
            _cell(order.createdByName ?? '—', widths[4]),
            _cell(
              orderAssignedStaffLabel(order),
              widths[5],
              color:
                  orderAssignedStaffLabel(order).contains('unassigned') ||
                      orderAssignedStaffLabel(order) == 'Unassigned'
                  ? _orange
                  : _ink,
            ),
            _statusCell(order, widths[6]),
            _cell(
              _money(order.totalAmount),
              widths[7],
              bold: true,
              right: true,
            ),
          ];
    return InkWell(
      onTap: () => _openOrderDetails(order),
      child: SizedBox(height: 58, child: Row(children: cells)),
    );
  }

  void _openOrderDetails(CustomerOrder order) => OrderDetailsDrawer.show(
    context,
    order: order,
    inventory: widget.controller.allItems,
    onOpenQueue: () => widget.onOpenQueue(order.id),
    orderUpdates: widget.controller.orderSnapshots,
    loadLoadingProof: widget.controller.getOrderLoadingProof,
    loadHelpers: _loadHelpers,
    onAssignHelper: (current, helperId) async {
      await widget.controller.assignOrderToHelper(
        orderId: current.id,
        helperId: helperId,
        expectedHelperId: current.assignedHelperId,
      );
      if (mounted) {
        setState(() => _ordersFuture = widget.controller.loadActivityOrders());
      }
    },
    onCancelOrder: (current) async {
      await widget.controller.cancelOrder(current);
      if (mounted) {
        setState(() => _ordersFuture = widget.controller.loadActivityOrders());
      }
    },
  );

  Future<List<({String id, String name})>> _loadHelpers() async {
    final staff = await widget.controller.fetchStaff();
    if (widget.controller.staffConfigurationLoadFailed) {
      throw StateError('Could not load helpers');
    }
    final helpers = staff
        .where((person) => person['role']?.toString().toLowerCase() == 'helper')
        .map(
          (person) => (
            id: person['id']?.toString() ?? '',
            name: person['name']?.toString() ?? 'Helper',
          ),
        )
        .where((person) => person.id.isNotEmpty)
        .toList();
    helpers.sort((a, b) => a.name.compareTo(b.name));
    return helpers;
  }

  Widget _stockRow(Map<String, dynamic> row, List<double> widths) {
    final product = row['products'] as Map<String, dynamic>?;
    final change = (row['quantity_change'] as num?)?.toDouble() ?? 0;
    final when = DateTime.tryParse(
      row['created_at']?.toString() ?? '',
    )?.toLocal();
    return SizedBox(
      height: 68,
      child: Row(
        children: [
          _cell(when == null ? '—' : _date(when), widths[0], color: _muted),
          _stockProductCell(product, widths[1]),
          _movementCell(row['transaction_type']?.toString() ?? '', widths[2]),
          _cell(
            '${change > 0 ? '+' : ''}${_quantity(change)}',
            widths[3],
            color: change > 0
                ? const Color(0xFF15803D)
                : const Color(0xFFDC2626),
            right: true,
          ),
          _cell(
            _quantity((row['new_quantity'] as num?)?.toDouble() ?? 0),
            widths[4],
            right: true,
          ),
          _cell(_actor(row), widths[5]),
          _cell(_stockNote(row), widths[6], color: _muted),
        ],
      ),
    );
  }

  Widget _stockProductCell(Map<String, dynamic>? product, double width) =>
      SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product?['product_name']?.toString() ?? 'Unknown product',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (product?['sku']?.toString().isNotEmpty == true)
                Text(
                  product!['sku'].toString(),
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _movementCell(String rawType, double width) {
    final type = _movement(rawType);
    final color = _movementColor(type);
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              border: Border.all(color: color.withValues(alpha: 0.22)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(type, style: TextStyle(color: color, fontSize: 12)),
          ),
        ),
      ),
    );
  }

  Widget _cell(
    String value,
    double width, {
    Color color = _ink,
    bool bold = false,
    bool mono = false,
    bool right = false,
    double size = 13,
  }) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: right ? TextAlign.right : TextAlign.left,
          style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ),
    ),
  );

  Widget _statusCell(CustomerOrder order, double width) {
    final label = _orderStatus(order);
    final color = _statusColor(label);
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              border: Border.all(color: color.withValues(alpha: 0.22)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label, style: TextStyle(color: color, fontSize: 12)),
          ),
        ),
      ),
    );
  }

  Widget _paymentCell(String? method, double width) {
    final gcash = method?.trim().toLowerCase() == 'gcash';
    final color = gcash ? const Color(0xFF2556DB) : _ink;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: gcash ? const Color(0xFFEEF3FF) : const Color(0xFFF7F6F4),
              border: Border.all(
                color: gcash ? const Color(0xFFC2D2FF) : _line,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              gcash ? 'GCash' : method ?? '—',
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }

  static Color _statusColor(String label) => switch (label) {
    'Waiting' => const Color(0xFFB45309),
    'Assigned' || 'Preparing' => _orange,
    'Ready' => const Color(0xFF15803D),
    'Cancelled' || 'Returned' => const Color(0xFFDC2626),
    _ => _ink,
  };

  static Color _movementColor(String type) => switch (type) {
    'Sale' => _orange,
    'Restock' || 'Return' => const Color(0xFF15803D),
    'Write-off' => const Color(0xFFDC2626),
    _ => _ink,
  };

  Future<void> _export(
    List<CustomerOrder> orders,
    List<Map<String, dynamic>> stock,
  ) async {
    setState(() => _exporting = true);
    try {
      final rows = switch (_tab) {
        'Stock movements' => <List<String>>[
          ['Time', 'Product', 'SKU', 'Type', 'Change', 'Balance', 'By', 'Note'],
          for (final row in stock)
            [
              row['created_at']?.toString() ?? '',
              (row['products'] as Map<String, dynamic>?)?['product_name']
                      ?.toString() ??
                  '',
              (row['products'] as Map<String, dynamic>?)?['sku']?.toString() ??
                  '',
              _movement(row['transaction_type']?.toString() ?? ''),
              row['quantity_change']?.toString() ?? '',
              row['new_quantity']?.toString() ?? '',
              _actor(row),
              _stockNote(row),
            ],
        ],
        'Payments' => <List<String>>[
          [
            'Order',
            'Created',
            'Items',
            'Payment',
            'Reference / change',
            'Cashier',
            'Status',
            'Total',
          ],
          for (final order in orders)
            [
              order.id,
              order.createdAt.toIso8601String(),
              '${order.items.length}',
              order.paymentMode ?? '',
              _paymentDetail(order),
              order.createdByName ?? '',
              _orderStatus(order),
              order.totalAmount.toStringAsFixed(2),
            ],
        ],
        _ => <List<String>>[
          [
            'Order',
            'Created',
            'Items',
            'Payment',
            'Cashier',
            'Assigned staff',
            'Status',
            'Total',
          ],
          for (final order in orders)
            [
              order.id,
              order.createdAt.toIso8601String(),
              '${order.items.length}',
              order.paymentMode ?? '',
              order.createdByName ?? '',
              orderAssignedStaffLabel(order),
              _orderStatus(order),
              order.totalAmount.toStringAsFixed(2),
            ],
        ],
      };
      final csv =
          '\uFEFF${rows.map((row) => row.map(_csvCell).join(',')).join('\r\n')}\r\n';
      final date = DateTime.now();
      final filename =
          '${_tab.toLowerCase().replaceAll(' ', '-')}-${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}.csv';
      final result = await saveCsv(filename, csv);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported $result')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  static String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';
  static String _paymentDetail(CustomerOrder order) {
    if (order.paymentMode?.trim().toLowerCase() == 'gcash') {
      return order.paymentReference?.trim().isNotEmpty == true
          ? order.paymentReference!.trim()
          : '—';
    }
    return 'Change ${_money(order.changeAmount)}';
  }

  static String _orderStatus(CustomerOrder order) =>
      switch (order.status.toLowerCase()) {
        'solo_picking' => 'Preparing',
        'pending'
            when order.assignedHelperId != null &&
                order.items.any((item) => item.picked) =>
          'Preparing',
        'pending' when order.assignedHelperId != null => 'Assigned',
        'pending' => 'Waiting',
        'prepared' => 'Ready',
        'completed' => 'Completed',
        'cancelled' => 'Cancelled',
        'returned' => 'Returned',
        _ => order.status,
      };
  static String _shortId(String id) =>
      id.length > 12 ? id.substring(0, 8).toUpperCase() : id;
  static String _actor(Map<String, dynamic> row) =>
      row['user_name']?.toString() ??
      (row['profiles'] as Map<String, dynamic>?)?['name']?.toString() ??
      '';
  static String _movement(String value) => switch (value) {
    'checkout' || 'stock_out' => 'Sale',
    'stock_in' || 'add' => 'Restock',
    'write_off' => 'Write-off',
    'manual_adjustment' => 'Adjustment',
    'order_cancelled' => 'Return',
    _ => value.replaceAll('_', ' '),
  };
  static String _stockNote(Map<String, dynamic> row) {
    final note = row['note']?.toString().trim();
    if (note != null && note.isNotEmpty) return note;
    return switch (row['transaction_type']?.toString()) {
      'checkout' => 'Checkout',
      'order_cancelled' => 'Order cancelled',
      _ => '—',
    };
  }

  static String _quantity(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
  static String _money(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final digits = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (match) => ',',
    );
    return '₱$digits.${parts[1]}';
  }

  static String _date(DateTime date) {
    final now = DateTime.now();
    final day =
        date.year == now.year && date.month == now.month && date.day == now.day
        ? 'Today'
        : '${_months[date.month - 1]} ${date.day}';
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    return '$day, $hour:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
  }

  static const _months = [
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
}
