import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:printing/printing.dart';

import '../data/inventory.dart';
import '../logic/history_pagination.dart';
import '../logic/inventory_controller.dart';
import 'reports/inventory_report_generator.dart';
import 'reports/sales_report_generator.dart';
import 'reports/report_period_dialog.dart';
import 'reports/report_range.dart';
import 'widgets/app_styled_dropdown.dart';

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({
    super.key,
    required this.controller,
    required this.isActive,
    required this.onOpenInventory,
  });

  final InventoryController controller;
  final bool isActive;
  final VoidCallback onOpenInventory;

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  static const _ink = Color(0xFF171717);
  static const _muted = Color(0xFF817A75);
  static const _line = Color(0xFFE7E2DC);
  static const _orange = Color(0xFFC83D08);
  static const _background = Color(0xFFF7F6F4);

  String _period = 'This month';
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  Map<String, dynamic>? _summary;
  final List<CustomerOrder> _periodOrders = <CustomerOrder>[];
  DateTimeRange? _customRange;
  String _chartGrouping = 'Daily';
  String _chartMeasure = 'Revenue';
  String _productRanking = 'Top sellers';
  String? _loadedRangeKey;
  String? _loadedLocationId;
  bool _stale = true;
  int _loadGeneration = 0;
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  StreamSubscription<HistoryInvalidation>? _historySubscription;
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
      if (mounted && widget.isActive) setState(() {});
    });
    _historySubscription = widget.controller.historyInvalidations.listen((
      event,
    ) {
      if (event.locationId != widget.controller.activeLocationId) return;
      _stale = true;
      _loadGeneration++;
      if (widget.isActive) _scheduleReload();
    });
    if (widget.isActive) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AnalyticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      unawaited(_inventorySubscription?.cancel());
      unawaited(_historySubscription?.cancel());
      _summary = null;
      _loadedRangeKey = null;
      _periodOrders.clear();
      _loadedLocationId = null;
      _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
        if (mounted && widget.isActive) setState(() {});
      });
      _historySubscription = widget.controller.historyInvalidations.listen((
        event,
      ) {
        if (event.locationId != widget.controller.activeLocationId) return;
        _stale = true;
        _loadGeneration++;
        if (widget.isActive) _scheduleReload();
      });
      _stale = true;
      if (widget.isActive) unawaited(_load());
    } else if (widget.isActive && !oldWidget.isActive) {
      if (_stale ||
          _loadedRangeKey != _rangeKey ||
          _loadedLocationId != widget.controller.activeLocationId) {
        unawaited(_load());
      }
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    unawaited(_inventorySubscription?.cancel());
    unawaited(_historySubscription?.cancel());
    super.dispose();
  }

  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted && widget.isActive) unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final rangeKey = _rangeKey;
    final locationId = widget.controller.activeLocationId;
    final start = _periodStart;
    final end = _periodEnd;
    final previousStart = _comparisonStart(start, end);
    final monthStart = DateTime(start.year, start.month);
    setState(() {
      _loading =
          _summary == null ||
          _loadedRangeKey != rangeKey ||
          _loadedLocationId != locationId;
      _error = null;
    });
    try {
      // Both datasets use the same store and the same local date boundaries.
      // These non-cancelled order statuses match analytics_summary_v1.
      final responses = await Future.wait<dynamic>([
        widget.controller.loadAnalyticsSummary(
          periodStart: start,
          periodEnd: end,
          previousStart: previousStart,
          monthStart: monthStart,
        ),
        widget.controller.loadAnalyticsSalesExport(
          start: start,
          endExclusive: end,
        ),
      ]);
      if (!mounted ||
          generation != _loadGeneration ||
          locationId != widget.controller.activeLocationId)
        return;
      final summary = Map<String, dynamic>.from(responses[0] as Map);
      final orders = (responses[1] as List<CustomerOrder>)
          .where(
            (order) =>
                !order.createdAt.toLocal().isBefore(start) &&
                order.createdAt.toLocal().isBefore(end),
          )
          .toList(growable: false);
      setState(() {
        _summary = summary;
        _periodOrders
          ..clear()
          ..addAll(orders);
        _loadedRangeKey = rangeKey;
        _loadedLocationId = locationId;
        _stale = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = 'Analytics could not be loaded: $error';
      });
    }
  }

  DateTime get _periodStart {
    final now = DateTime.now();
    switch (_period) {
      case 'Today':
        return DateTime(now.year, now.month, now.day);
      case 'This week':
        return DateTime(now.year, now.month, now.day - now.weekday + 1);
      case 'Last month':
        return DateTime(now.year, now.month - 1);
      case 'This year':
        return DateTime(now.year);
      case 'Custom range':
        final range = _customRange;
        if (range == null) return DateTime(now.year, now.month);
        return DateTime(range.start.year, range.start.month, range.start.day);
      default:
        return DateTime(now.year, now.month);
    }
  }

  DateTime get _periodEnd {
    final now = DateTime.now();
    if (_period == 'Last month') return DateTime(now.year, now.month);
    if (_period == 'Custom range' && _customRange != null) {
      final day = _customRange!.end;
      return DateTime(day.year, day.month, day.day + 1);
    }
    return now.add(const Duration(microseconds: 1));
  }

  String get _rangeKey {
    final start = _periodStart;
    final end = _periodEnd;
    return '${_period}_${start.year}-${start.month}-${start.day}_'
        '${end.year}-${end.month}-${end.day}';
  }

  String get _periodLabel {
    if (_period != 'Custom range' || _customRange == null) return _period;
    final range = _customRange!;
    return '${_shortDate(range.start)} – ${_shortDate(range.end)}';
  }

  Future<void> _selectCustomRange() async {
    final now = DateTime.now();
    final chosen = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _customRange,
      helpText: 'SELECT ANALYTICS DATE RANGE',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(primary: _orange),
        ),
        child: child!,
      ),
    );
    if (!mounted || chosen == null) return;
    setState(() {
      _customRange = chosen;
      _period = 'Custom range';
    });
    unawaited(_load());
  }

  static String _shortDate(DateTime value) =>
      '${value.month}/${value.day}/${value.year}';

  // analytics_summary_v1 uses this preceding window for previous_revenue.
  // Only 'Last month' compares two full calendar months; the other choices
  // compare the selected duration with the immediately preceding duration.
  DateTime _comparisonStart(DateTime start, DateTime end) =>
      _period == 'Last month'
          ? DateTime(start.year, start.month - 1)
          : start.subtract(end.difference(start));

  double get _revenue => (_summary?['revenue'] as num?)?.toDouble() ?? 0;
  double get _unitsSold => (_summary?['units_sold'] as num?)?.toDouble() ?? 0;
  int get _orderCount => (_summary?['order_count'] as num?)?.toInt() ?? 0;
  double get _previousRevenue =>
      (_summary?['previous_revenue'] as num?)?.toDouble() ?? 0;

  Map<String, double> get _categorySales => (Map<String, dynamic>.from(
    _summary?['categories'] as Map? ?? const {},
  )).map((key, value) => MapEntry(key, (value as num).toDouble()));

  Map<String, dynamic> get _stockSummary =>
      Map<String, dynamic>.from(_summary?['stock'] as Map? ?? const {});

  // This is an *unsold stocked-items* watch list for the chosen date range.
  // Inventory quantities are the current snapshot, not historical balances.
  List<_DeadRow> get _deadStock {
    final sold = <String>{};
    for (final order in _periodOrders) {
      for (final item in order.items) {
        if (item.quantity > 0) sold.add(item.productId);
      }
    }
    final stock = _stockSummary;
    final now = DateTime.now();
    final rows = widget.controller.allItems
        .where((item) => item.quantity > 0 && !sold.contains(item.id))
        .map(
          (item) => _DeadRow(
            item,
            DateTime.tryParse(
              (stock[item.id] as Map?)?['last_sale']?.toString() ?? '',
            )?.toLocal(),
          ),
        )
        .where(
          (row) =>
              row.lastSale == null ||
              now.difference(row.lastSale!).inDays >= 60,
        )
        .toList();
    rows.sort((a, b) {
      if (a.lastSale == null) return b.lastSale == null ? 0 : -1;
      if (b.lastSale == null) return 1;
      return a.lastSale!.compareTo(b.lastSale!);
    });
    return rows.take(8).toList(growable: false);
  }

  DateTime _bucketStart(DateTime time, String grouping) {
    final day = time.toLocal();
    if (grouping == 'Hourly') {
      return DateTime(day.year, day.month, day.day, day.hour);
    }
    if (grouping == 'Weekly') {
      return DateTime(day.year, day.month, day.day - day.weekday + 1);
    }
    if (grouping == 'Monthly') return DateTime(day.year, day.month);
    return DateTime(day.year, day.month, day.day);
  }

  DateTime _nextBucket(DateTime date, String grouping) {
    if (grouping == 'Hourly') {
      return DateTime(date.year, date.month, date.day, date.hour + 1);
    }
    if (grouping == 'Weekly') {
      return DateTime(date.year, date.month, date.day + 7);
    }
    if (grouping == 'Monthly') return DateTime(date.year, date.month + 1);
    return DateTime(date.year, date.month, date.day + 1);
  }

  String _bucketLabel(DateTime date, String grouping) {
    if (grouping == 'Hourly') {
      final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
      return '$hour ${date.hour < 12 ? 'AM' : 'PM'}';
    }
    if (grouping == 'Monthly') {
      const months = [
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
      return '${months[date.month - 1]} ${date.year}';
    }
    return '${date.month}/${date.day}';
  }

  List<_AnalyticsBucket> _salesBuckets() {
    final grouping = _period == 'Today' ? 'Hourly' : _chartGrouping;
    final start = _bucketStart(_periodStart, grouping);
    final end = _periodEnd;
    final now = DateTime.now();
    final effectiveEnd = end.isAfter(now) ? now : end;
    final buckets = <_AnalyticsBucket>[];
    final byStart = <int, _AnalyticsBucket>{};
    for (
      var at = start;
      at.isBefore(effectiveEnd) && buckets.length < 400;
      at = _nextBucket(at, grouping)
    ) {
      final bucket = _AnalyticsBucket(_bucketLabel(at, grouping));
      buckets.add(bucket);
      byStart[at.millisecondsSinceEpoch] = bucket;
    }
    for (final order in _periodOrders) {
      final at = _bucketStart(order.createdAt.toLocal(), grouping);
      final bucket = byStart[at.millisecondsSinceEpoch];
      if (bucket == null) continue;
      bucket.revenue += order.totalAmount;
      for (final item in order.items) {
        bucket.units += item.quantity;
      }
    }
    return buckets;
  }

  List<_ProductSalesRow> _productRows() {
    final catalog = <String, InventoryItem>{
      for (final item in widget.controller.allItems) item.id: item,
    };
    final rows = <String, _ProductSalesRow>{};
    for (final item in catalog.values) {
      rows[item.id] = _ProductSalesRow(
        id: item.id,
        name: item.name,
        category: item.category,
        inStock: item.quantity,
      );
    }
    for (final order in _periodOrders) {
      final items = order.items.where((item) => item.quantity > 0).toList();
      if (items.isEmpty) continue;
      final weights = <double>[];
      for (final item in items) {
        final historical =
            item.lineTotal ??
            (item.unitPrice == null ? null : item.unitPrice! * item.quantity);
        final fallback = (catalog[item.productId]?.price ?? 0) * item.quantity;
        weights.add(math.max(0.0, historical ?? fallback));
      }
      final totalWeight = weights.fold<double>(0, (a, b) => a + b);
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final catalogItem = catalog[item.productId];
        final key = item.productId.isEmpty ? item.productName : item.productId;
        if (key.isEmpty) continue;
        final entry = rows.putIfAbsent(
          key,
          () => _ProductSalesRow(
            id: key,
            name: catalogItem?.name ?? item.productName,
            category: catalogItem?.category ?? 'Uncategorized',
            inStock: catalogItem?.quantity ?? 0,
          ),
        );
        entry.units += item.quantity;
        // Allocate the paid order total across lines, including discounts.
        // If old line prices are missing, current prices are only weighting
        // proxies; this is attributed revenue, not a historical unit price.
        entry.revenue +=
            order.totalAmount *
            (totalWeight > 0 ? weights[i] / totalWeight : 1 / items.length);
      }
    }
    return rows.values.toList();
  }

  List<double> _weekdayAverages() {
    final totals = List<double>.filled(7, 0);
    final counts = List<int>.filled(7, 0);
    final now = DateTime.now();
    final end = _periodEnd.isBefore(now) ? _periodEnd : now;
    for (
      var day = DateTime(
        _periodStart.year,
        _periodStart.month,
        _periodStart.day,
      );
      day.isBefore(end);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      counts[day.weekday - 1]++;
    }
    for (final order in _periodOrders) {
      totals[order.createdAt.toLocal().weekday - 1] += order.totalAmount;
    }
    return List<double>.generate(
      7,
      (index) => counts[index] == 0 ? 0 : totals[index] / counts[index],
    );
  }

  void _openSalesReportDialog() {
    if (_exporting) return;

    unawaited(
      showReportPeriodDialog(
        context,
        title: 'Generate Sales Report',
        onGenerate: (range) {
          unawaited(_exportSales(range));
        },
      ),
    );
  }

  void _openInventoryReportDialog() {
    if (_exporting) return;

    unawaited(
      showReportPeriodDialog(
        context,
        title: 'Generate Inventory Report',
        note: 'Past reports use current inventory prices.',
        onGenerate: (range) {
          unawaited(_exportInventory(range));
        },
      ),
    );
  }

  Future<void> _exportSales(ReportRange range) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final orders = await widget.controller.loadAnalyticsSalesExport(
        start: range.start,
        endExclusive: range.endExclusive,
      );
      final entries = orders
          .where((order) => range.contains(order.createdAt))
          .map(
            (order) => SalesReportEntry(
              orderNumber: order.id
                  .substring(0, math.min(order.id.length, 8))
                  .toUpperCase(),
              date: order.createdAt,
              cashier: order.createdByName ?? 'Unknown',
              paymentMode: order.paymentMode ?? 'Unknown',
              paymentReference: order.paymentReference,
              subtotal: order.totalAmount + order.discountAmount,
              discount: order.discountAmount,
              total: order.totalAmount,
            ),
          )
          .toList();
      if (entries.isEmpty) throw StateError('No sales in this period.');
      final bytes = await SalesReportGenerator.generate(
        period: range.period,
        periodStart: range.start,
        periodEnd: range.displayEnd,
        generatedAt: DateTime.now(),
        generatedBy: widget.controller.currentUserName ?? 'Administrator',
        sales: entries,
        businessName: 'Inventory Plus',
      );
      await Printing.sharePdf(
        bytes: bytes,
        filename:
            'Sales_report_${range.period}_${range.fileTag}_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is StateError ? error.message : 'Sales report failed.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportInventory(ReportRange range) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final transactions = await widget.controller.loadAllTransactionHistory();
      final start = range.start;
      final end = range.endExclusive;
      final net = <String, double>{};
      final after = <String, double>{};
      final received = <String, double>{};
      final issued = <String, double>{};
      for (final tx in transactions) {
        final id = tx['product_id']?.toString();
        final date = DateTime.tryParse(
          tx['created_at']?.toString() ?? '',
        )?.toLocal();
        if (id == null || date == null) continue;
        final change = (tx['quantity_change'] as num?)?.toDouble() ?? 0;
        if (!date.isBefore(end)) {
          after[id] = (after[id] ?? 0) + change;
        } else if (!date.isBefore(start)) {
          net[id] = (net[id] ?? 0) + change;
          if (change > 0) received[id] = (received[id] ?? 0) + change;
          if (change < 0) issued[id] = (issued[id] ?? 0) - change;
        }
      }
      final entries = widget.controller.allItems.map((item) {
        final ending = item.quantity - (after[item.id] ?? 0);
        return InventoryReportEntry(
          sku: item.sku,
          name: item.name,
          unit: item.unit,
          beginningQty: ending - (net[item.id] ?? 0),
          received: received[item.id] ?? 0,
          issued: issued[item.id] ?? 0,
          endingQty: ending,
          unitCost: item.price,
        );
      }).toList();
      if (entries.isEmpty) throw StateError('No inventory items found.');
      final bytes = await InventoryReportGenerator.generate(
        period: range.period,
        periodStart: range.start,
        periodEnd: range.displayEnd,
        generatedAt: DateTime.now(),
        generatedBy: widget.controller.currentUserName ?? 'Administrator',
        items: entries,
        businessName: 'Inventory Plus',
      );
      await Printing.sharePdf(
        bytes: bytes,
        filename:
            'Inventory_report_${range.period}_${range.fileTag}_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is StateError ? error.message : 'Inventory report failed.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 1050;
        final sideBySide = constraints.maxWidth >= 900;
        return ColoredBox(
          color: _background,
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.all(
                constraints.maxWidth < 480
                    ? 12
                    : constraints.maxWidth < 1050
                    ? 20
                    : 40,
              ),
              children: [
                _header(narrow),
                const SizedBox(height: 24),
                _kpis(narrow),
                const SizedBox(height: 20),
                _salesPerformanceCard(),
                const SizedBox(height: 20),
                _productPerformanceCard(),
                const SizedBox(height: 20),
                sideBySide
                    ? IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _categoryCard()),
                            const SizedBox(width: 20),
                            Expanded(child: _weekdayCard(matchCategoryHeight: true)),
                          ],
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _categoryCard(),
                          const SizedBox(height: 20),
                          _weekdayCard(),
                        ],
                      ),
                const SizedBox(height: 20),
                _comparisonCard(),
                const SizedBox(height: 20),
                _deadStockCard(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(bool narrow) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Analytics',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: _ink),
        ),
        const SizedBox(height: 5),
        const Text(
          'Historical sales and inventory performance.',
          style: TextStyle(fontSize: 16, color: _muted),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 180,
          height: 44,
          child: AppStyledDropdown<String>(
            value: _period,
            items: const [
              'Today',
              'This week',
              'This month',
              'Last month',
              'This year',
              'Custom range',
            ].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
            onChanged: (value) {
              if (value == 'Custom range') {
                unawaited(_selectCustomRange());
              } else if (value != null && value != _period) {
                setState(() => _period = value);
                unawaited(_load());
              }
            },
          ),
        ),
        if (_period == 'Custom range' && _customRange != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              _periodLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ),
        _outlineButton(
          'Sales report',
          LucideIcons.download,
          _exporting ? null : _openSalesReportDialog,
        ),
        _outlineButton(
          'Inventory report',
          LucideIcons.download,
          _exporting ? null : _openInventoryReportDialog,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, limits) {
        // A side-by-side header is only safe when both the heading and
        // all actions fit; at intermediate desktop widths use two rows.
        if (narrow || limits.maxWidth < 1200) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 16),
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 18),
            Flexible(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: actions,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _outlineButton(String label, IconData icon, VoidCallback? action) =>
      SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          onPressed: action,
          icon: Icon(icon, size: 17),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            backgroundColor: Colors.white,
            side: const BorderSide(color: _line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      );

  Widget _card(Widget child) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );

  Widget _kpis(bool narrow) {
    final change = _previousRevenue > 0
        ? (_revenue - _previousRevenue) / _previousRevenue * 100
        : null;
    final metrics = <Widget>[
      _metric(
        'Revenue',
        _money(_revenue),
        change == null
            ? 'Previous period: ${_money(_previousRevenue)}'
            : '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}% vs previous period',
      ),
      _metric('Total orders', _orderCount.toString()),
      _metric('Units sold', _number(_unitsSold)),
      _metric(
        'Average order value',
        _money(_orderCount == 0 ? 0 : _revenue / _orderCount),
      ),
    ];
    return _card(
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Overview · $_periodLabel',
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, limits) {
                final availableWidth = limits.maxWidth;

                if (!narrow && availableWidth >= 760) {
                  return Row(
                    children: [
                      for (final item in metrics) Expanded(child: item),
                    ],
                  );
                }

                final columns = availableWidth >= 440 ? 2 : 1;
                const gap = 12.0;

                final itemWidth =
                    (availableWidth - (columns - 1) * gap) / columns;

                return Wrap(
                  spacing: gap,
                  runSpacing: 20,
                  children: [
                    for (final item in metrics)
                      SizedBox(width: itemWidth, child: item),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, [String? hint]) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 14)),
        const SizedBox(height: 8),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
          style: const TextStyle(
            color: _ink,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (hint != null)
          Text(hint, style: const TextStyle(color: _muted, fontSize: 11)),
      ],
    ),
  );

  Widget _categoryCard() {
    final categories = _categorySales.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = categories.fold<double>(0, (sum, item) => sum + item.value);
    return _card(
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sales by category',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _periodLabel,
              style: const TextStyle(color: _muted, fontSize: 14),
            ),
            const SizedBox(height: 25),
            if (categories.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'No category sales for this period.',
                  style: TextStyle(color: _muted),
                ),
              )
            else
              for (final entry in categories.take(8)) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(entry.key, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${total > 0 ? (entry.value / total * 100).round() : 0}%',
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: total > 0 ? entry.value / total : 0,
                    minHeight: 7,
                    backgroundColor: _line,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 18),
              ],
          ],
        ),
      ),
    );
  }

  Widget _salesPerformanceCard() {
    final grouping = _period == 'Today' ? 'Hourly' : _chartGrouping;
    final buckets = _salesBuckets();
    final showRevenue = _chartMeasure == 'Revenue';
    final total = showRevenue ? _revenue : _unitsSold;
    return _card(
      Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sales performance',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              'Historical order sales · $_periodLabel',
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  showRevenue ? _money(total) : _number(total),
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: AppStyledDropdown<String>(
                    value: _chartMeasure,
                    items: const ['Revenue', 'Units sold']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _chartMeasure = value);
                    },
                  ),
                ),
                if (_period != 'Today')
                  SizedBox(
                    width: 150,
                    child: AppStyledDropdown<String>(
                      value: _chartGrouping,
                      items: const ['Daily', 'Weekly', 'Monthly']
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null)
                          setState(() => _chartGrouping = value);
                      },
                    ),
                  )
                else
                  const Text('Hourly', style: TextStyle(color: _muted)),
              ],
            ),
            const SizedBox(height: 18),
            if (buckets.length >= 400)
              const Text(
                'Too many time buckets. Select weekly or monthly grouping to see the full trend.',
                style: TextStyle(color: _muted),
              )
            else if (buckets.isEmpty || _periodOrders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'No recorded sales for this period.',
                  style: TextStyle(color: _muted),
                ),
              )
            else
              _AnalyticsTrendChart(buckets: buckets, showRevenue: showRevenue),
            const SizedBox(height: 12),
            const Text(
              'Hover, tap, or drag across the chart to inspect values.',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _productPerformanceCard() {
    final rows = _productRows();
    if (_productRanking == 'Top sellers') {
      rows.removeWhere((item) => item.units <= 0);
      rows.sort((a, b) => b.units.compareTo(a.units));
    } else {
      rows.removeWhere((item) => item.inStock <= 0);
      rows.sort((a, b) {
        final byUnits = a.units.compareTo(b.units);
        return byUnits != 0 ? byUnits : a.revenue.compareTo(b.revenue);
      });
    }
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Product performance',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Ranked by units sold in selected period',
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
                SizedBox(
                  width: 170,
                  child: AppStyledDropdown<String>(
                    value: _productRanking,
                    items: const ['Top sellers', 'Bottom sellers']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null)
                        setState(() => _productRanking = value);
                    },
                  ),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            _emptyRow('No products found for this selection.')
          else
            for (final row in rows.take(8))
              _tableRow(
                row.name,
                '${row.category} · ${_number(row.inStock)} on hand',
                '${_number(row.units)} sold',
                _money(row.revenue),
                onTap: widget.onOpenInventory,
              ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Text(
              'Revenue is allocated from order totals, including discounts. '
              'Older orders without recorded line prices may use current prices as allocation weights.',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _weekdayCard({bool matchCategoryHeight = false}) {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final averages = _weekdayAverages();
    final maxValue = averages.reduce(math.max);
    // The parent IntrinsicHeight matches the actual outer card heights.
    // This also lets the bars use the extra desktop height productively,
    // while leaving a compact 140 px chart for stacked mobile cards.
    final categoryCount = math.min(8, _categorySales.length);
    final chartHeight = matchCategoryHeight
        ? 140.0 + 42.0 * math.max(0, categoryCount - 2)
        : 140.0;
    final barSpace = math.max(0.0, chartHeight - 31.0);
    return _card(
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sales by day of week',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Average recorded sales per weekday · $_periodLabel',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: chartHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Tooltip(
                          message: '${labels[i]}: ${_money(averages[i])}',
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // Zero averages must not create fake 2 px bars.
                              if (averages[i] > 0 && maxValue > 0)
                                Container(
                                  height: barSpace * averages[i] / maxValue,
                                  decoration: BoxDecoration(
                                    color: _orange.withValues(alpha: 0.8),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(5),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Text(
                                labels[i],
                                maxLines: 1,
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 11,
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
            if (_periodOrders.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'No recorded sales in this period.',
                  style: TextStyle(color: _muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _comparisonCard() {
    final previous = _previousRevenue;
    final current = _revenue;
    final highest = math.max(current, previous);
    final change = previous > 0 ? (current - previous) / previous * 100 : null;
    final start = _periodStart;
    final end = _periodEnd;
    final previousStart = _comparisonStart(start, end);
    final currentDateLabel =
        '${_shortDate(start)} – ${_shortDate(end.subtract(const Duration(microseconds: 1)))}';
    final previousDateLabel =
        '${_shortDate(previousStart)} – ${_shortDate(start.subtract(const Duration(microseconds: 1)))}';
    return _card(
      Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Period comparison',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _period == 'Last month'
                  ? 'Last month compared with the preceding calendar month'
                  : 'Selected period versus the immediately preceding equal-duration period',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 22),
            for (final row in <(String, String, double)>[
              ('Selected period', currentDateLabel, current),
              ('Previous period', previousDateLabel, previous),
            ]) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.$1, style: const TextStyle(color: _muted)),
                        const SizedBox(height: 3),
                        Text(
                          row.$2,
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _money(row.$3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: highest <= 0
                      ? 0.0
                      : math.max(0.0, math.min(1.0, row.$3 / highest)),
                  minHeight: 10,
                  backgroundColor: _line,
                  color: row.$1 == 'Selected period' ? _orange : _ink,
                ),
              ),
              const SizedBox(height: 14),
            ],
            Text(
              change == null
                  ? (current == 0
                        ? 'No revenue in either period.'
                        : 'No previous-period revenue for comparison.')
                  : '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}% revenue change',
              style: TextStyle(
                color: change == null
                    ? _muted
                    : change >= 0
                    ? const Color(0xFF087B3C)
                    : _orange,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deadStockCard() {
    final rows = _deadStock;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tableHeading(
            'Dead stock watch',
            'Current stock: 60+ days since checkout, without sales in $_periodLabel',
          ),
          if (rows.isEmpty)
            _emptyRow('No dead-stock candidates for this selection.')
          else
            for (final row in rows)
              _tableRow(
                row.item.name,
                '${_number(row.item.quantity)} ${row.item.unit} currently on hand',
                row.lastSale == null
                    ? 'No recorded sale'
                    : '${DateTime.now().difference(row.lastSale!).inDays} days',
                _money(row.item.quantity * row.item.price),
                onTap: widget.onOpenInventory,
              ),
        ],
      ),
    );
  }

  Widget _tableHeading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: _muted, fontSize: 13)),
      ],
    ),
  );

  Widget _emptyRow(String text) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(text, style: const TextStyle(color: _muted)),
  );

  Widget _tableRow(
    String name,
    String detail,
    String middle,
    String trailing, {
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _line)),
      ),
      child: LayoutBuilder(
        builder: (context, limits) {
          final compact = limits.maxWidth < 520;
          final symbol = Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(LucideIcons.package, size: 18, color: _muted),
          );
          final identity = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: compact ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    symbol,
                    const SizedBox(width: 12),
                    Expanded(child: identity),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        middle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        trailing,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              symbol,
              const SizedBox(width: 12),
              Expanded(flex: 3, child: identity),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  middle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: middle == 'Out' ? Colors.red : _ink),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  trailing,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  static String _number(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
  static String _money(double value) {
    final parts = value.toStringAsFixed(2).split('.');
    final digits = parts.first.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (match) => ',',
    );
    return '₱$digits.${parts.last}';
  }

  static String _compactMoney(double value) => value >= 1000000
      ? '₱${(value / 1000000).toStringAsFixed(2)}M'
      : value >= 1000
      ? '₱${(value / 1000).toStringAsFixed(1)}k'
      : _money(value);
}

class _DeadRow {
  const _DeadRow(this.item, this.lastSale);
  final InventoryItem item;
  final DateTime? lastSale;
}

/// Aggregated historical sales for one selected time bucket.
class _AnalyticsBucket {
  _AnalyticsBucket(this.label);
  final String label;
  double revenue = 0;
  double units = 0;
}

class _ProductSalesRow {
  _ProductSalesRow({
    required this.id,
    required this.name,
    required this.category,
    required this.inStock,
  });
  final String id;
  final String name;
  final String category;
  final double inStock;
  double units = 0;
  double revenue = 0;
}

class _AnalyticsTrendChart extends StatefulWidget {
  const _AnalyticsTrendChart({
    required this.buckets,
    required this.showRevenue,
  });

  final List<_AnalyticsBucket> buckets;
  final bool showRevenue;

  @override
  State<_AnalyticsTrendChart> createState() => _AnalyticsTrendChartState();
}

class _AnalyticsTrendChartState extends State<_AnalyticsTrendChart> {
  int? _selected;

  void _updateSelection(double dx, double width) {
    if (width <= 0 || widget.buckets.isEmpty) return;
    final index = widget.buckets.length == 1
        ? 0
        : ((dx / width).clamp(0.0, 1.0) * (widget.buckets.length - 1)).round();
    if (_selected != index) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final values = [
      for (final bucket in widget.buckets)
        widget.showRevenue ? bucket.revenue : bucket.units,
    ];
    final selected = _selected == null
        ? null
        : _selected!.clamp(0, widget.buckets.length - 1);
    return Column(
      children: [
        SizedBox(
          height: 182,
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return MouseRegion(
                onHover: (event) => _updateSelection(
                  event.localPosition.dx,
                  constraints.maxWidth,
                ),
                onExit: (_) => setState(() => _selected = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (event) => _updateSelection(
                    event.localPosition.dx,
                    constraints.maxWidth,
                  ),
                  onHorizontalDragUpdate: (event) => _updateSelection(
                    event.localPosition.dx,
                    constraints.maxWidth,
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _AnalyticsTrendPainter(
                            values: values,
                            selected: selected,
                          ),
                        ),
                      ),
                      if (selected != null)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.max(0.0, constraints.maxWidth - 16),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _AnalyticsPageState._line,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                child: Text(
                                  '${widget.buckets[selected].label}: '
                                  '${widget.showRevenue ? _AnalyticsPageState._money(values[selected]) : _AnalyticsPageState._number(values[selected])}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _AnalyticsPageState._ink,
                                    fontSize: 12,
                                  ),
                                ),
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
        const SizedBox(height: 7),
        LayoutBuilder(
          builder: (context, limits) {
            final lastIndex = widget.buckets.length - 1;
            final indexes = limits.maxWidth < 460
                ? <int>{0, lastIndex ~/ 2, lastIndex}
                : <int>{
                    0,
                    lastIndex ~/ 4,
                    lastIndex ~/ 2,
                    3 * lastIndex ~/ 4,
                    lastIndex,
                  };
            return Row(
              children: [
                for (final i in indexes)
                  Expanded(
                    child: Text(
                      widget.buckets[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: i == 0
                          ? TextAlign.left
                          : i == lastIndex
                          ? TextAlign.right
                          : TextAlign.center,
                      style: const TextStyle(
                        color: _AnalyticsPageState._muted,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _AnalyticsTrendPainter extends CustomPainter {
  const _AnalyticsTrendPainter({required this.values, required this.selected});
  final List<double> values;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFFFBF1EC);
    canvas.drawRect(Offset.zero & size, background);
    if (values.isEmpty) return;
    final maxValue = values.reduce(math.max);
    final yMax = maxValue <= 0 ? 1.0 : maxValue;
    double xFor(int i) => values.length == 1
        ? size.width / 2
        : size.width * i / (values.length - 1);
    double yFor(double v) => size.height * (0.86 - 0.72 * v / yMax);

    final outline = Path()..moveTo(xFor(0), yFor(values.first));
    final fillArea = Path()
      ..moveTo(0, size.height)
      ..lineTo(xFor(0), yFor(values.first));
    for (var i = 1; i < values.length; i++) {
      outline.lineTo(xFor(i), yFor(values[i]));
      fillArea.lineTo(xFor(i), yFor(values[i]));
    }
    fillArea
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
      fillArea,
      Paint()..color = _AnalyticsPageState._orange.withValues(alpha: 0.12),
    );
    canvas.drawPath(
      outline,
      Paint()
        ..color = _AnalyticsPageState._orange
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
    if (selected != null && selected! >= 0 && selected! < values.length) {
      final point = Offset(xFor(selected!), yFor(values[selected!]));
      canvas.drawLine(
        Offset(point.dx, 0),
        Offset(point.dx, size.height),
        Paint()
          ..color = const Color(0xFFC9C1BB)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(point, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        point,
        3.5,
        Paint()..color = _AnalyticsPageState._orange,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AnalyticsTrendPainter old) =>
      old.values != values || old.selected != selected;
}
