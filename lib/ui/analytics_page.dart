import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
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
  late final Future<Map<String, String>> _marketFuture;
  String? _loadedPeriod;
  String? _loadedLocationId;
  bool _stale = true;
  int _loadGeneration = 0;
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  StreamSubscription<HistoryInvalidation>? _historySubscription;
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    _marketFuture = _loadMarketContext();
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
      _loadedPeriod = null;
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
          _loadedPeriod != _period ||
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
    final period = _period;
    final locationId = widget.controller.activeLocationId;
    final start = _periodStart;
    final end = _periodEnd;
    final previousStart = period == 'Last month'
        ? DateTime(start.year, start.month - 1)
        : start.subtract(end.difference(start));
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month - 8);
    setState(() {
      _loading =
          _summary == null ||
          _loadedPeriod != period ||
          _loadedLocationId != locationId;
      _error = null;
    });
    try {
      final summary = await widget.controller.loadAnalyticsSummary(
        periodStart: start,
        periodEnd: end,
        previousStart: previousStart,
        monthStart: monthStart,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _summary = summary;
        _loadedPeriod = period;
        _loadedLocationId = locationId;
        _stale = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = 'Analytics could not be loaded.';
      });
    }
  }


  // Live reference feeds are informational only, not forecasting inputs.
  Future<Map<String, String>> _loadMarketContext() async {
    final results = <String, String>{};

    Future<void> weather() async {
      final key = dotenv.env['WEATHER_API_KEY'];
      if (key == null || key.isEmpty) return;
      try {
        final uri = Uri.https('api.openweathermap.org', '/data/2.5/weather', {
          'q': 'Quezon City,PH',
          'units': 'metric',
          'appid': key,
        });
        final response = await http.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final conditions = data['weather'] as List<dynamic>?;
        final condition = conditions?.isNotEmpty == true
            ? (conditions!.first as Map<String, dynamic>)['description']
                  ?.toString()
            : null;
        if (condition != null) {
          results['Weather'] = '$condition · Quezon City · OpenWeather';
        }
      } catch (_) {}
    }

    Future<void> exchange() async {
      try {
        final response = await http
            .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rate = (data['rates'] as Map<String, dynamic>?)?['PHP'] as num?;
        if (rate != null) {
          results['USD / PHP'] =
              '₱${rate.toStringAsFixed(2)} per USD · ExchangeRate-API';
        }
      } catch (_) {}
    }

    Future<void> news() async {
      final key = dotenv.env['NEWS_API_KEY'];
      if (key == null || key.isEmpty) return;
      try {
        final uri = Uri.https('newsapi.org', '/v2/everything', {
          'q': 'Philippines construction hardware',
          'language': 'en',
          'sortBy': 'publishedAt',
          'pageSize': '1',
          'apiKey': key,
        });
        final response = await http.get(uri).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final articles = data['articles'] as List<dynamic>?;
        if (articles?.isNotEmpty != true) return;
        final article = articles!.first as Map<String, dynamic>;
        final title = article['title']?.toString();
        final source =
            (article['source'] as Map<String, dynamic>?)?['name']?.toString();
        if (title != null && title != '[Removed]') {
          results['Industry news'] =
              '$title${source == null ? '' : ' · $source'}';
        }
      } catch (_) {}
    }

    await Future.wait([weather(), exchange(), news()]);
    return results;
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
      default:
        return DateTime(now.year, now.month);
    }
  }

  DateTime get _periodEnd {
    final now = DateTime.now();
    return _period == 'Last month'
        ? DateTime(now.year, now.month)
        : now.add(const Duration(microseconds: 1));
  }

  double get _revenue => (_summary?['revenue'] as num?)?.toDouble() ?? 0;
  double get _unitsSold => (_summary?['units_sold'] as num?)?.toDouble() ?? 0;
  int get _orderCount => (_summary?['order_count'] as num?)?.toInt() ?? 0;
  double get _previousRevenue =>
      (_summary?['previous_revenue'] as num?)?.toDouble() ?? 0;

  double get _inventoryValue => widget.controller.allItems.fold(
    0,
    (sum, item) => sum + item.price * item.quantity,
  );

  Map<String, double> get _categorySales => (Map<String, dynamic>.from(
    _summary?['categories'] as Map? ?? const {},
  )).map((key, value) => MapEntry(key, (value as num).toDouble()));

  Map<String, dynamic> get _stockSummary =>
      Map<String, dynamic>.from(_summary?['stock'] as Map? ?? const {});

  List<_DeadRow> get _deadStock {
    final now = DateTime.now();
    final stock = _stockSummary;
    return widget.controller.allItems
        .where((item) => item.quantity > 0)
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
              row.lastSale != null &&
              now.difference(row.lastSale!).inDays >= 60,
        )
        .take(8)
        .toList();
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
      final transactions =
          await widget.controller.loadAllTransactionHistory();
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
        return ColoredBox(
          color: _background,
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.all(narrow ? 20 : 40),
              children: [
                _header(narrow),
                const SizedBox(height: 28),
                _kpis(narrow),
                const SizedBox(height: 28),
                narrow
                    ? Column(
                        children: [
                          _categoryCard(),
                          const SizedBox(height: 20),
                          _marketCard(),
                          const SizedBox(height: 20),
                          _deadStockCard(),
                        ],
                      )
                    : Column(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _categoryCard()),
                              const SizedBox(width: 20),
                              Expanded(child: _marketCard()),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _deadStockCard(),
                        ],
                      ),
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
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            color: _ink,
          ),
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
      children: [
        SizedBox(
          width: 180,
          height: 44,
          child: AppStyledDropdown<String>(
            value: _period,
            items:
                const [
                      'Today',
                      'This week',
                      'This month',
                      'Last month',
                      'This year',
                    ]
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
            onChanged: (value) {
              if (value != null && value != _period) {
                setState(() => _period = value);
                unawaited(_load());
              }
            },
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
    return narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, const SizedBox(height: 16), actions],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [heading, actions],
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
    final previous = _previousRevenue;
    final change = previous > 0 ? (_revenue - previous) / previous * 100 : null;
    final items = <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Revenue · ${_period.toLowerCase()}',
            style: const TextStyle(color: _muted),
          ),
          const SizedBox(height: 8),
          Text(
            _money(_revenue),
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          Text(
            change == null
                ? 'No previous period sales'
                : '${change >= 0 ? '↗' : '↘'} ${change.abs().toStringAsFixed(1)}% vs previous period',
            style: TextStyle(
              color: change == null
                  ? _muted
                  : change >= 0
                  ? const Color(0xFF087B3C)
                  : _orange,
            ),
          ),
        ],
      ),
      _metric('Gross margin', '—', 'Unit cost unavailable'),
      _metric(
        'Avg order value',
        _money(_orderCount == 0 ? 0 : _revenue / _orderCount),
      ),
      _metric('Units sold', _number(_unitsSold)),
      _metric(
        'Inventory value',
        _compactMoney(_inventoryValue),
        'At retail price',
      ),
      _metric('Stock turnover', '—', 'Unit cost unavailable'),
    ];
    return _card(
      Padding(
        padding: const EdgeInsets.all(24),
        child: narrow
            ? Wrap(
                spacing: 28,
                runSpacing: 20,
                children: [
                  SizedBox(width: 220, child: items[0]),
                  for (final item in items.skip(1))
                    SizedBox(width: 150, child: item),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(flex: 2, child: items.first),
                  for (final item in items.skip(1)) Expanded(child: item),
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
            Text(_period, style: const TextStyle(color: _muted, fontSize: 14)),
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


  Widget _marketCard() => _card(
    Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Market context',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Live reference information',
            style: TextStyle(color: _muted, fontSize: 13),
          ),
          const SizedBox(height: 18),
          FutureBuilder<Map<String, String>>(
            future: _marketFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Text(
                  'Checking available feeds…',
                  style: TextStyle(color: _muted),
                );
              }
              final values = snapshot.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final label in const [
                    'Weather',
                    'USD / PHP',
                    'Industry news',
                  ]) ...[
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      values[label] ?? 'Live feed unavailable',
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                    if (label != 'Industry news') ...[
                      const SizedBox(height: 14),
                      const Divider(color: _line),
                      const SizedBox(height: 8),
                    ],
                  ],
                ],
              );
            },
          ),
        ],
      ),
    ),
  );

  Widget _deadStockCard() {
    final rows = _deadStock;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tableHeading(
            'Dead stock',
            'Products whose last recorded sale was 60+ days ago',
          ),
          if (rows.isEmpty)
            _emptyRow('No dead stock found.')
          else
            for (final row in rows)
              _tableRow(
                row.item.name,
                '${_number(row.item.quantity)} ${row.item.unit} on hand',
                row.lastSale == null
                    ? 'No sale recorded'
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
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(LucideIcons.package, size: 18, color: _muted),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              middle,
              textAlign: TextAlign.end,
              style: TextStyle(color: middle == 'Out' ? Colors.red : _ink),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              trailing,
              textAlign: TextAlign.end,
              maxLines: 2,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
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
