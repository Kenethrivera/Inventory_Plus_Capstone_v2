import 'dart:async';

import 'package:flutter/material.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import '../logic/history_pagination.dart';
import 'package:printing/printing.dart';
import 'reports/sales_report_generator.dart';
import '../services/export_period.dart';
import '../services/export_reminder_service.dart'; // add
import 'reports/report_range.dart';
import 'reports/report_period_dialog.dart';
import '../notifications/notification_provider.dart';
import 'widgets/history_period_controls.dart';
import 'widgets/history_pagination_footer.dart';

String _fmtQty(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

class TransactionHistoryPage extends StatefulWidget {
  final InventoryController controller;
  final String initialTab;
  final bool exportDue;
  final VoidCallback? onExported;
  final void Function(String orderId)? onCompleteOrder;
  final bool isActive;

  const TransactionHistoryPage({
    super.key,
    required this.controller,
    this.initialTab = 'Sales History',
    this.exportDue = false,
    this.onExported,
    this.onCompleteOrder,
    required this.isActive,
  });

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  late Future<HistoryPageResult<Map<String, dynamic>>> _historyFuture;
  StreamSubscription<HistoryInvalidation>? _historySubscription;
  Timer? _searchDebounce;
  int _salesPage = 1;
  int _activityPage = 1;
  HistoryQueryFamily? _renderedFamily;
  HistoryPageResult<Map<String, dynamic>>? _lastVisibleResult;
  int _knownTotalCount = 0;
  Map<String, num> _knownMetrics = const <String, num>{};
  String? _openOrderId;
  HistoryQueryFamily? _openOrderFamily;
  ValueNotifier<_OrderGroup>? _openOrderNotifier;

  // Sales History State
  String _filterStatus = 'All';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  HistoryPeriodSelection _periodSelection = HistoryPeriodSelection.current();

  // Activity Log State
  late String _activeTab;
  String _logFilter = 'All';
  bool _salesHistoryDirty = false;
  bool _activityHistoryDirty = false;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _historyFuture = _emptyPage();
    if (widget.isActive) _loadCurrentPage();
    _bindHistoryInvalidations();
  }

  @override
  void didUpdateWidget(TransactionHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the MainScreen tells us to change tabs, update it!
    if (widget.initialTab != oldWidget.initialTab) {
      setState(() {
        _activeTab = widget.initialTab;
        _historyFuture = _loadCurrentPageResult();
      });
    }
    if (oldWidget.controller != widget.controller) {
      _bindHistoryInvalidations();
      if (widget.isActive) {
        _loadCurrentPage();
      } else {
        _salesHistoryDirty = true;
        _activityHistoryDirty = true;
      }
    }
    if (!oldWidget.isActive && widget.isActive) {
      final dirty = _activeTab == 'Sales History'
          ? _salesHistoryDirty
          : _activityHistoryDirty;
      if (dirty) _loadCurrentPage(forceRefresh: true);
    }
  }

  @override
  void dispose() {
    unawaited(_historySubscription?.cancel());
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _bindHistoryInvalidations() {
    unawaited(_historySubscription?.cancel());
    _historySubscription = widget.controller.historyInvalidations.listen(
      (invalidation) {
        switch (invalidation.kind) {
          case HistoryInvalidationKind.orderHistory:
            _salesHistoryDirty = true;
            unawaited(_refreshOpenOrderDetail());
          case HistoryInvalidationKind.transactions:
            _activityHistoryDirty = true;
          case HistoryInvalidationKind.scope:
            _salesHistoryDirty = true;
            _activityHistoryDirty = true;
        }
        if (widget.isActive && invalidation.affects(_currentDomain)) {
          _loadCurrentPage(forceRefresh: true);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
          '[TransactionHistoryPage] Activity invalidation error: $error',
        );
      },
    );
  }

  void _reloadAll() {
    final family = _currentFamily;
    if (family != null) widget.controller.invalidateHistoryFamily(family);
    _loadCurrentPage(forceRefresh: true);
  }

  HistoryDomain get _currentDomain => _activeTab == 'Sales History'
      ? HistoryDomain.adminSales
      : HistoryDomain.adminActivity;

  int get _currentPage =>
      _activeTab == 'Sales History' ? _salesPage : _activityPage;

  HistoryQueryFamily? get _currentFamily {
    final locationId = widget.controller.activeLocationId;
    final accountId = widget.controller.currentUserId;
    final role = widget.controller.currentUserRole;
    if (locationId == null || accountId == null || role == null) return null;
    final range = _periodSelection.range;
    return HistoryQueryFamily(
      accountId: accountId,
      role: role,
      locationId: locationId,
      domain: _currentDomain,
      periodMode: _periodSelection.mode.name,
      periodStart: range.start,
      periodEndExclusive: range.end,
      filter: _activeTab == 'Sales History' ? _filterStatus : _logFilter,
      search: _searchQuery,
      sort: 'event_at_desc_id_desc',
    );
  }

  Future<HistoryPageResult<Map<String, dynamic>>> _emptyPage() async =>
      HistoryPageResult<Map<String, dynamic>>(
        family: null,
        page: 1,
        records: const [],
        totalCount: 0,
        metrics: const {},
        loadedAt: DateTime.now(),
      );

  Future<HistoryPageResult<Map<String, dynamic>>> _loadCurrentPageResult({
    bool forceRefresh = false,
  }) {
    final family = _currentFamily;
    if (family == null) return _emptyPage();
    final cached = widget.controller.cachedHistoryPage(
      family: family,
      page: _currentPage,
    );
    if (cached != null) _lastVisibleResult = cached;
    if (_activeTab == 'Sales History') {
      _salesHistoryDirty = false;
    } else {
      _activityHistoryDirty = false;
    }
    return widget.controller.loadHistoryPage(
      family: family,
      page: _currentPage,
      forceRefresh: forceRefresh,
    );
  }

  void _loadCurrentPage({bool forceRefresh = false}) {
    if (!mounted || !widget.isActive) return;
    setState(() {
      _historyFuture = _loadCurrentPageResult(forceRefresh: forceRefresh);
    });
  }

  void _queryChanged({bool debounce = false}) {
    _searchDebounce?.cancel();
    if (_activeTab == 'Sales History') {
      _salesPage = 1;
    } else {
      _activityPage = 1;
    }
    if (debounce) {
      _searchDebounce = Timer(
        const Duration(milliseconds: 400),
        _loadCurrentPage,
      );
    } else {
      _loadCurrentPage();
    }
  }

  void _selectPage(int page) {
    if (page < 1 || page == _currentPage) return;
    setState(() {
      if (_activeTab == 'Sales History') {
        _salesPage = page;
      } else {
        _activityPage = page;
      }
      _historyFuture = _loadCurrentPageResult();
    });
  }

  List<_OrderGroup> _orderGroupsFromRows(List<Map<String, dynamic>> orders) {
    final groups = <_OrderGroup>[];
    for (final order in orders) {
      final status = order['status'] as String? ?? 'pending';
      final createdAt = DateTime.parse(order['created_at']).toLocal();
      final eventAt =
          DateTime.tryParse(order['event_at']?.toString() ?? '')?.toLocal() ??
          createdAt;
      final rawItems = order['items'] as List<dynamic>? ?? [];

      final items = rawItems.map((i) {
        final parsedItem = _OrderLineItem.fromJson(i as Map<String, dynamic>);

        double itemPrice = parsedItem.price;
        if (itemPrice == 0.0) {
          try {
            final dbItem = widget.controller.allItems.firstWhere(
              (inv) => inv.id == parsedItem.productId,
            );
            itemPrice = dbItem.price;
          } catch (_) {}
        }

        return _OrderLineItem(
          productId: parsedItem.productId,
          productName: parsedItem.productName,
          quantity: parsedItem.quantity,
          price: itemPrice,
        );
      }).toList();

      double calculatedSubtotal = items.fold(
        0.0,
        (sum, item) => sum + (item.price * item.quantity),
      );
      double totalAmount =
          (order['total_amount'] as num?)?.toDouble() ?? calculatedSubtotal;

      double discount =
          (order['discount_amount'] as num?)?.toDouble() ??
          (calculatedSubtotal - totalAmount);
      if (discount < 0) discount = 0.0;

      double cashGiven = (order['cash_given'] as num?)?.toDouble() ?? 0.0;
      double changeAmount = (order['change_amount'] as num?)?.toDouble() ?? 0.0;
      String paymentMode = order['payment_mode'] as String? ?? 'N/A';
      final paymentReference = order['payment_reference']?.toString();

      groups.add(
        _OrderGroup(
          id: order['id'].toString(),
          status: status,
          createdAt: createdAt,
          eventAt: eventAt,
          totalAmount: totalAmount,
          subtotal: calculatedSubtotal,
          discount: discount,
          cashGiven: cashGiven,
          changeAmount: changeAmount,
          paymentMode: paymentMode,
          paymentReference: paymentReference,
          items: items,
          createdBy: order['created_by_name']?.toString(),
          preparedBy: order['prepared_by_name']?.toString(),
          completedBy: order['completed_by_name']?.toString(),
          cancelledBy: order['cancelled_by_name']?.toString(),
          preparedAt: order['prepared_at'] != null
              ? DateTime.parse(order['prepared_at'].toString()).toLocal()
              : null,
          completedAt: order['completed_at'] != null
              ? DateTime.parse(order['completed_at'].toString()).toLocal()
              : null,
          cancelledAt: order['cancelled_at'] != null
              ? DateTime.parse(order['cancelled_at'].toString()).toLocal()
              : null,
        ),
      );
    }
    return List<_OrderGroup>.unmodifiable(groups);
  }

  @override
  Widget build(BuildContext context) => _buildHistoryWorkspace(context);

  Widget _buildHistoryWorkspace(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: FutureBuilder<HistoryPageResult<Map<String, dynamic>>>(
        future: _historyFuture,
        builder: (context, snapshot) {
          final currentFamily = _currentFamily;
          if (_renderedFamily != currentFamily) {
            _renderedFamily = currentFamily;
            _knownTotalCount = 0;
            _knownMetrics = const <String, num>{};
          }
          final rawResult = snapshot.data;
          final scopedResult = rawResult?.family == currentFamily
              ? rawResult
              : null;
          final currentResult = scopedResult?.page == _currentPage
              ? scopedResult
              : null;
          if (currentResult != null) _lastVisibleResult = currentResult;
          final retainedResult = _lastVisibleResult;
          final result =
              currentResult ??
              (retainedResult?.family == currentFamily &&
                      retainedResult?.page == _currentPage
                  ? retainedResult
                  : null);
          if (scopedResult != null) {
            _knownTotalCount = scopedResult.totalCount;
            _knownMetrics = scopedResult.metrics;
          }
          if (scopedResult != null && scopedResult.page != _currentPage) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || scopedResult.page == _currentPage) return;
              setState(() {
                if (_activeTab == 'Sales History') {
                  _salesPage = scopedResult.page;
                } else {
                  _activityPage = scopedResult.page;
                }
              });
            });
          }
          final orders = _activeTab == 'Sales History' && result != null
              ? _orderGroupsFromRows(result.records)
              : const <_OrderGroup>[];
          final logs = _activeTab == 'Activity Log' && result != null
              ? result.records
              : const <Map<String, dynamic>>[];
          final loading = snapshot.connectionState == ConnectionState.waiting;
          return SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontalPadding = constraints.maxWidth < 700
                    ? 14.0
                    : 22.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        14,
                        horizontalPadding,
                        10,
                      ),
                      child: _buildPageHeader(
                        salesCount: _activeTab == 'Sales History'
                            ? ((result?.metrics ?? _knownMetrics)['records'] ??
                                      0)
                                  .toInt()
                            : 0,
                        activityCount: _activeTab == 'Activity Log'
                            ? ((result?.metrics ?? _knownMetrics)['changes'] ??
                                      0)
                                  .toInt()
                            : 0,
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                      ),
                      child: _buildCompactMetrics(
                        metrics: result?.metrics ?? _knownMetrics,
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        10,
                        horizontalPadding,
                        10,
                      ),
                      child: _buildFilterToolbar(),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          14,
                        ),
                        child: _activeTab == 'Sales History'
                            ? _buildSalesWorkspace(
                                loading: loading,
                                error: snapshot.error,
                                orders: orders,
                                result: result,
                                totalItems:
                                    result?.totalCount ?? _knownTotalCount,
                              )
                            : _buildActivityWorkspace(
                                logs,
                                loading: loading,
                                error: snapshot.error,
                                result: result,
                                totalItems:
                                    result?.totalCount ?? _knownTotalCount,
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildPageHeader({
    required int salesCount,
    required int activityCount,
  }) {
    final count = _activeTab == 'Sales History' ? salesCount : activityCount;
    final subject = _activeTab == 'Sales History'
        ? (count == 1 ? 'order' : 'orders')
        : (count == 1 ? 'inventory change' : 'inventory changes');
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _activeTab == 'Sales History'
                  ? 'Transaction History'
                  : 'Activity Log',
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$count $subject ${_periodContextLabel()}',
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_activeTab == 'Sales History') _buildExportButton(),
            OutlinedButton(
              onPressed: _reloadAll,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF334155),
                side: const BorderSide(color: Color(0xFFE2E8F0)),
                minimumSize: const Size(42, 38),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: const Icon(LucideIcons.refreshCw, size: 16),
            ),
          ],
        );
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 10), actions],
          );
        }
        return Row(
          children: [
            Expanded(child: title),
            actions,
          ],
        );
      },
    );
  }

  Widget _buildExportButton() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        OutlinedButton.icon(
          onPressed: () => showReportPeriodDialog(
            context,
            title: 'Generate Sales Report',
            onGenerate: (range) => _generateAndPrintSalesReport(context, range),
          ),
          icon: const Icon(LucideIcons.download, size: 15),
          label: const Text(
            'Export Sales',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF334155),
            side: BorderSide(
              color: widget.exportDue
                  ? const Color(0xFFDC2626)
                  : const Color(0xFFE2E8F0),
              width: widget.exportDue ? 1.5 : 1,
            ),
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
        ),
        if (widget.exportDue)
          const Positioned(
            top: -3,
            right: -3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFFDC2626),
                shape: BoxShape.circle,
              ),
              child: SizedBox(width: 9, height: 9),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactMetrics({required Map<String, num> metrics}) {
    final cards = <_HistoryMetric>[];
    if (_activeTab == 'Sales History') {
      final totalOrders = (metrics['orders'] ?? 0).toInt();
      final pending = (metrics['pending'] ?? 0).toInt();
      final revenue = (metrics['revenue'] ?? 0).toDouble();
      cards.addAll([
        _HistoryMetric(
          'Orders',
          totalOrders.toString(),
          const Color(0xFF0F172A),
        ),
        _HistoryMetric('Pending', pending.toString(), const Color(0xFFD97706)),
        _HistoryMetric('Revenue', _money(revenue), const Color(0xFF15803D)),
      ]);
    } else {
      final changes = (metrics['changes'] ?? 0).toInt();
      final stockIn = (metrics['stock_in'] ?? 0).toDouble();
      final stockOut = (metrics['stock_out'] ?? 0).toDouble();
      cards.addAll([
        _HistoryMetric('Changes', changes.toString(), const Color(0xFF0F172A)),
        _HistoryMetric(
          'Stock in',
          '+${_fmtQty(stockIn)}',
          const Color(0xFF15803D),
        ),
        _HistoryMetric(
          'Stock out',
          '-${_fmtQty(stockOut)}',
          const Color(0xFFDC2626),
        ),
      ]);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final width = compact
            ? constraints.maxWidth
            : (constraints.maxWidth - 16) / 3;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: cards
              .map(
                (metric) => SizedBox(
                  width: width,
                  child: Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            metric.label.toUpperCase(),
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        Text(
                          metric.value,
                          style: TextStyle(
                            color: metric.color,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }

  Widget _buildFilterToolbar() {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final primaryGroups = <Widget>[
            _buildTabSelector(),
            _buildPeriodSelector(),
            HistoryPeriodControls(
              selection: _periodSelection,
              onChanged: (selection) {
                setState(() => _periodSelection = selection);
                _queryChanged();
              },
            ),
          ];
          final resultFilter = _activeTab == 'Sales History'
              ? _buildStatusSelector()
              : _buildActivitySelector();
          final singleRowMinWidth = _activeTab == 'Sales History'
              ? 930.0
              : 850.0;

          if (constraints.maxWidth >= singleRowMinWidth) {
            return Row(
              children: [
                for (var index = 0; index < primaryGroups.length; index++) ...[
                  if (index > 0) const SizedBox(width: 8),
                  primaryGroups[index],
                ],
                const SizedBox(width: 8),
                resultFilter,
                const SizedBox(width: 8),
                Expanded(child: _buildSearchField()),
              ],
            );
          }

          if (constraints.maxWidth >= 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: primaryGroups,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    resultFilter,
                    const SizedBox(width: 10),
                    Expanded(child: _buildSearchField()),
                  ],
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [...primaryGroups, resultFilter],
              ),
              const SizedBox(height: 8),
              _buildSearchField(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabSelector() => _SegmentedControl(
    options: const ['Sales History', 'Activity Log'],
    selected: _activeTab,
    onSelected: (value) {
      if (value == _activeTab) return;
      setState(() {
        _activeTab = value;
        _historyFuture = _loadCurrentPageResult();
      });
    },
    darkSelection: true,
  );

  Widget _buildPeriodSelector() => _SegmentedControl(
    options: const ['Daily', 'Weekly', 'Monthly'],
    selected: _periodLabel(),
    onSelected: (value) {
      setState(() {
        final mode = switch (value) {
          'Daily' => HistoryPeriodMode.daily,
          'Weekly' => HistoryPeriodMode.weekly,
          _ => HistoryPeriodMode.monthly,
        };
        _periodSelection = _periodSelection.withMode(mode);
      });
      _queryChanged();
    },
  );

  Widget _buildStatusSelector() => _SegmentedControl(
    options: const ['All', 'Pending', 'Prepared', 'Completed', 'Cancelled'],
    selected: _filterStatus,
    onSelected: (value) {
      setState(() => _filterStatus = value);
      _queryChanged();
    },
  );

  Widget _buildActivitySelector() => _SegmentedControl(
    options: const ['All', 'Stock In', 'Stock Out', 'Adjustments'],
    selected: _logFilter,
    onSelected: (value) {
      setState(() => _logFilter = value);
      _queryChanged();
    },
  );

  Widget _buildSearchField() {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _searchController,
        onChanged: (value) {
          setState(() => _searchQuery = value);
          _queryChanged(debounce: true);
        },
        style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A)),
        decoration: InputDecoration(
          hintText: _activeTab == 'Sales History'
              ? 'Search order or item'
              : 'Search item name',
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          prefixIcon: const Icon(
            LucideIcons.search,
            size: 15,
            color: Color(0xFF64748B),
          ),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                    _queryChanged();
                  },
                  icon: const Icon(LucideIcons.x, size: 14),
                ),
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2563EB)),
          ),
        ),
      ),
    );
  }

  Widget _buildSalesWorkspace({
    required bool loading,
    required Object? error,
    required List<_OrderGroup> orders,
    required HistoryPageResult<Map<String, dynamic>>? result,
    required int totalItems,
  }) {
    Widget content;
    if (loading && result == null) {
      content = const HistoryLoadingRows();
    } else if (error != null && result == null) {
      content = _BoundedState(
        icon: LucideIcons.circleAlert,
        title: 'Unable to load transaction history',
        message: 'Check your connection and try again.',
        actionLabel: 'Retry',
        onAction: _reloadAll,
      );
    } else if (orders.isEmpty) {
      content = _BoundedState(
        icon: LucideIcons.receipt,
        title: _emptySalesTitle(),
        message: 'Try another period, status, or search term.',
        actionLabel: 'Reset filters',
        onAction: _resetSalesFilters,
      );
    } else {
      content = LayoutBuilder(
        builder: (context, constraints) {
          final useTable = constraints.maxWidth >= 820;
          return useTable
              ? _buildTransactionTable(orders)
              : _buildTransactionCards(orders);
        },
      );
    }
    return _withPagination(
      content,
      totalItems: totalItems,
      loading: loading,
      backgroundRefreshing: loading && result != null,
      refreshError: result == null ? null : error,
    );
  }

  Widget _withPagination(
    Widget content, {
    required int totalItems,
    required bool loading,
    bool backgroundRefreshing = false,
    Object? refreshError,
  }) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        Expanded(
          child: HistoryRefreshLayer(
            refreshing: backgroundRefreshing,
            refreshFailed: refreshError != null,
            onRetry: _reloadAll,
            child: content,
          ),
        ),
        HistoryPaginationFooter(
          currentPage: _currentPage,
          totalItems: totalItems,
          pageSize: historyPageSize,
          loading: loading,
          onPageSelected: _selectPage,
        ),
      ],
    ),
  );

  Widget _buildTransactionTable(List<_OrderGroup> orders) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            color: const Color(0xFFF8FAFC),
            child: const Row(
              children: [
                _TableCell('TRANSACTION', flex: 15, header: true),
                _TableCell('DATE & TIME', flex: 17, header: true),
                _TableCell('HANDLED BY', flex: 13, header: true),
                _TableCell('ITEMS', flex: 7, header: true),
                _TableCell('PAYMENT', flex: 10, header: true),
                _TableCell('STATUS', flex: 11, header: true),
                _TableCell('TOTAL', flex: 11, header: true, alignRight: true),
                SizedBox(width: 22),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Expanded(
            child: ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
              itemBuilder: (context, index) {
                final order = orders[index];
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _openOrder(order),
                      hoverColor: const Color(0xFFF8FAFC),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 58),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            _TableCell(
                              '#${order.shortId}',
                              flex: 15,
                              strong: true,
                            ),
                            _TableCell(
                              _compactDate(order.eventAt),
                              flex: 17,
                              secondary: _compactTime(order.eventAt),
                            ),
                            _TableCell(order.handledBy, flex: 13),
                            _TableCell(order.items.length.toString(), flex: 7),
                            _TableCell(
                              order.paymentMode == 'N/A'
                                  ? '—'
                                  : order.paymentMode,
                              flex: 10,
                            ),
                            Expanded(
                              flex: 11,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: _StatusChip(status: order.status),
                              ),
                            ),
                            _TableCell(
                              _money(order.totalAmount),
                              flex: 11,
                              strong: true,
                              alignRight: true,
                            ),
                            const SizedBox(
                              width: 22,
                              child: Icon(
                                LucideIcons.chevronRight,
                                size: 15,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionCards(List<_OrderGroup> orders) {
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: orders.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final order = orders[index];
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            onTap: () => _openOrder(order),
            borderRadius: BorderRadius.circular(11),
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Order #${order.shortId}',
                          style: const TextStyle(
                            color: Color(0xFF0F172A),
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      _StatusChip(status: order.status),
                      const SizedBox(width: 5),
                      const Icon(
                        LucideIcons.chevronRight,
                        size: 16,
                        color: Color(0xFF94A3B8),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactFact(
                          icon: LucideIcons.calendarDays,
                          value:
                              '${_compactDate(order.eventAt)}, ${_compactTime(order.eventAt)}',
                        ),
                      ),
                      _CompactFact(
                        icon: LucideIcons.package,
                        value:
                            order.items.length.toString() +
                            (order.items.length == 1 ? ' item' : ' items'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactFact(
                          icon: LucideIcons.userRound,
                          value: order.handledBy,
                        ),
                      ),
                      Text(
                        _money(order.totalAmount),
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildActivityWorkspace(
    List<Map<String, dynamic>> logs, {
    required bool loading,
    required Object? error,
    required HistoryPageResult<Map<String, dynamic>>? result,
    required int totalItems,
  }) {
    Widget content;
    if (loading && result == null) {
      content = const HistoryLoadingRows();
    } else if (error != null && result == null) {
      content = _BoundedState(
        icon: LucideIcons.circleAlert,
        title: 'Unable to load activity history',
        message: 'Check your connection and try again.',
        actionLabel: 'Retry',
        onAction: _reloadAll,
      );
    } else if (logs.isEmpty) {
      content = _BoundedState(
        icon: LucideIcons.history,
        title: 'No activity found ${_periodContextLabel()}',
        message: 'Try another period, activity type, or search term.',
        actionLabel: 'Reset filters',
        onAction: _resetActivityFilters,
      );
    } else {
      final entries = <Object>[];
      String? previousGroup;
      for (final log in logs) {
        final group = _activityGroupLabel(_activityDate(log));
        if (group != previousGroup) {
          entries.add(group);
          previousGroup = group;
        }
        entries.add(log);
      }
      content = Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            if (entry is String) {
              return Container(
                height: 32,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                color: const Color(0xFFF8FAFC),
                child: Text(
                  entry,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.7,
                  ),
                ),
              );
            }
            final log = entry as Map<String, dynamic>;
            final quantity =
                (log['quantity_change'] as num?)?.toDouble() ?? 0.0;
            final newQuantity =
                (log['new_quantity'] as num?)?.toDouble() ?? 0.0;
            final type = log['transaction_type']?.toString() ?? 'activity';
            final positive = quantity > 0;
            final color = type == 'manual_adjustment'
                ? const Color(0xFF2563EB)
                : positive
                ? const Color(0xFF15803D)
                : const Color(0xFFDC2626);
            final product = log['products'] is Map
                ? Map<String, dynamic>.from(log['products'] as Map)
                : null;
            final profile = log['profiles'] is Map
                ? Map<String, dynamic>.from(log['profiles'] as Map)
                : null;
            final productName =
                product?['product_name']?.toString() ?? 'Unknown item';
            final userName = profile?['name']?.toString() ?? 'Admin';
            final date = _activityDate(log);
            return Container(
              constraints: const BoxConstraints(minHeight: 62),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      positive ? LucideIcons.plus : LucideIcons.minus,
                      size: 15,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 7,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              productName,
                              style: const TextStyle(
                                color: Color(0xFF0F172A),
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            _ActivityTypeChip(label: type, color: color),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$userName \u2022 ${_compactDate(date)}, ${_compactTime(date)}',
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        (positive ? '+' : '') + _fmtQty(quantity),
                        style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'New qty ${_fmtQty(newQuantity)}',
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      );
    }
    return _withPagination(
      content,
      totalItems: totalItems,
      loading: loading,
      backgroundRefreshing: loading && result != null,
      refreshError: result == null ? null : error,
    );
  }

  void _openOrder(_OrderGroup order) {
    final family = _currentFamily;
    if (family == null) return;
    final notifier = ValueNotifier<_OrderGroup>(order);
    _openOrderId = order.id;
    _openOrderFamily = family;
    _openOrderNotifier = notifier;
    unawaited(_refreshOpenOrderDetail());
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierColor: const Color(0x8A0F172A),
        useSafeArea: true,
        builder: (dialogContext) {
          final viewport = MediaQuery.sizeOf(dialogContext);
          final narrow = viewport.width < 600;
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: EdgeInsets.symmetric(
              horizontal: narrow ? 12 : 32,
              vertical: narrow ? 16 : 28,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 760,
                maxHeight: viewport.height * 0.78,
              ),
              child: ValueListenableBuilder<_OrderGroup>(
                valueListenable: notifier,
                builder: (context, currentOrder, _) => _OrderDetailPanel(
                  group: currentOrder,
                  onClose: () => Navigator.pop(dialogContext),
                  onCompleteOrder: widget.onCompleteOrder,
                ),
              ),
            ),
          );
        },
      ).whenComplete(() {
        if (identical(_openOrderNotifier, notifier)) {
          _openOrderId = null;
          _openOrderFamily = null;
          _openOrderNotifier = null;
        }
        notifier.dispose();
      }),
    );
  }

  Future<void> _refreshOpenOrderDetail() async {
    final orderId = _openOrderId;
    final family = _openOrderFamily;
    final notifier = _openOrderNotifier;
    if (orderId == null || family == null || notifier == null) return;
    try {
      final row = await widget.controller.loadHistoryOrderDetail(
        family: family,
        orderId: orderId,
      );
      if (!mounted ||
          row == null ||
          _openOrderId != orderId ||
          !identical(_openOrderNotifier, notifier)) {
        return;
      }
      notifier.value = _orderGroupsFromRows([row]).single;
    } catch (error) {
      debugPrint(
        '[TransactionHistoryPage] Detail reconciliation failed: $error',
      );
    }
  }

  DateTime _activityDate(Map<String, dynamic> log) {
    final raw = log['created_at']?.toString();
    return raw == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.parse(raw).toLocal();
  }

  String _activityGroupLabel(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(value.year, value.month, value.day);
    if (day == today) return 'TODAY';
    if (day == today.subtract(const Duration(days: 1))) return 'YESTERDAY';
    const months = [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ];
    return '${months[value.month - 1]} ${value.day}, ${value.year}';
  }

  void _resetSalesFilters() {
    _searchController.clear();
    setState(() {
      _periodSelection = HistoryPeriodSelection.current();
      _filterStatus = 'All';
      _searchQuery = '';
    });
    _queryChanged();
  }

  void _resetActivityFilters() {
    _searchController.clear();
    setState(() {
      _periodSelection = HistoryPeriodSelection.current();
      _logFilter = 'All';
      _searchQuery = '';
    });
    _queryChanged();
  }

  String _periodLabel() => _periodSelection.mode.label;

  String _periodContextLabel() => 'for ${_periodSelection.displayLabel}';

  String _emptySalesTitle() {
    final status = _filterStatus == 'All'
        ? 'transactions'
        : '${_filterStatus.toLowerCase()} transactions';
    return 'No $status found ${_periodContextLabel()}';
  }

  String _money(double value) => '\u20B1${value.toStringAsFixed(2)}';

  String _compactDate(DateTime value) {
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
    return '${months[value.month - 1]} ${value.day}';
  }

  String _compactTime(DateTime value) {
    final hour = value.hour == 0
        ? 12
        : value.hour > 12
        ? value.hour - 12
        : value.hour;
    return '$hour:${value.minute.toString().padLeft(2, '0')} '
        '${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  Future<void> _generateAndPrintSalesReport(
    BuildContext context,
    ReportRange range,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          const Center(child: CircularProgressIndicator(color: Colors.orange)),
    );

    try {
      final rows = await widget.controller.loadSalesExport(
        start: range.start,
        endExclusive: range.endExclusive,
      );
      final periodSales = _orderGroupsFromRows(rows);

      if (periodSales.isEmpty) {
        if (context.mounted) {
          Navigator.pop(context);
          AppToast.error(context, 'No completed sales found for this period.');
        }
        return;
      }

      final entries = periodSales
          .map(
            (sale) => SalesReportEntry(
              orderNumber: sale.shortId,
              date: sale.eventAt,
              cashier: sale.createdBy ?? 'Admin',
              paymentMode: sale.paymentMode,
              paymentReference: sale.paymentReference,
              subtotal: sale.subtotal,
              discount: sale.discount,
              total: sale.totalAmount,
            ),
          )
          .toList();

      final now = DateTime.now();
      final bytes = await SalesReportGenerator.generate(
        period: range.period,
        periodStart: range.start,
        periodEnd: range.displayEnd,
        generatedAt: now,
        generatedBy: widget.controller.currentUserName ?? 'Admin',
        sales: entries,
      );

      if (context.mounted) Navigator.pop(context);

      await Printing.sharePdf(
        bytes: bytes,
        filename:
            'Sales_Report_${range.period}_${range.fileTag}_${now.millisecondsSinceEpoch}.pdf',
      );

      // Only the CURRENT period counts toward the export reminder.
      if (range.isCurrent) await _markExported(range.type);
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        AppToast.error(context, 'Error generating PDF: $e');
      }
    }
  }

  Future<void> _markExported(ExportPeriodType type) async {
    final locId = widget.controller.activeLocationId;
    if (locId == null) return;
    final notificationController = NotificationProvider.maybeOf(context);
    final service = ExportReminderService(
      supabase: widget.controller.supabase,
      locationId: locId,
    );
    final period = ExportPeriod.current(type);
    await service.logExport(
      reportType: 'sales',
      period: period,
      exportedBy: widget.controller.currentUserNumericId,
    );
    await notificationController?.resolveExportReminder(
      reportType: 'sales',
      periodType: type.name,
      periodKey: period.key,
    );
    widget.onExported?.call();
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

Color _statusColor(String status) {
  switch (status) {
    case 'completed':
      return const Color(0xFF16A34A);
    case 'prepared':
      return const Color(0xFF2563EB);
    case 'pending':
      return const Color(0xFFF59E0B);
    case 'cancelled':
      return const Color(0xFFDC2626);
    case 'solo_picking':
      return const Color(0xFFF59E0B);
    default:
      return Colors.grey;
  }
}

String _formatDate(DateTime date) {
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
  final month = months[date.month - 1];
  final hour = date.hour > 12
      ? date.hour - 12
      : (date.hour == 0 ? 12 : date.hour);
  final minute = date.minute.toString().padLeft(2, '0');
  final period = date.hour >= 12 ? 'PM' : 'AM';
  return '$month ${date.day}, ${date.year} • $hour:$minute $period';
}

// ─── Data models ──────────────────────────────────────────────────────────────

class _OrderGroup {
  final String id;
  final String status;
  final DateTime createdAt;
  final DateTime eventAt;
  final double totalAmount;
  final double subtotal;
  final double discount;
  final double cashGiven;
  final double changeAmount;
  final String paymentMode;
  final String? paymentReference;
  final List<_OrderLineItem> items;
  final String? createdBy;
  final String? preparedBy;
  final String? completedBy;
  final String? cancelledBy;
  final DateTime? preparedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;

  _OrderGroup({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.eventAt,
    required this.totalAmount,
    required this.subtotal,
    required this.discount,
    required this.cashGiven,
    required this.changeAmount,
    required this.paymentMode,
    this.paymentReference,
    required this.items,
    this.createdBy,
    this.preparedBy,
    this.completedBy,
    this.cancelledBy,
    this.preparedAt,
    this.completedAt,
    this.cancelledAt,
  });

  String get shortId =>
      id.length >= 8 ? id.substring(0, 8).toUpperCase() : id.toUpperCase();

  String get handledBy {
    if (status == 'completed') {
      return completedBy ?? createdBy ?? preparedBy ?? '—';
    }
    if (status == 'prepared') {
      return preparedBy ?? createdBy ?? '—';
    }
    if (status == 'cancelled') {
      return cancelledBy ?? createdBy ?? '—';
    }
    return createdBy ?? preparedBy ?? '—';
  }
}

class _OrderLineItem {
  final String productId;
  final String productName;
  final double quantity;
  final double price;

  _OrderLineItem({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.price,
  });

  factory _OrderLineItem.fromJson(Map<String, dynamic> json) => _OrderLineItem(
    productId: json['product_id']?.toString() ?? '',
    productName: json['product_name']?.toString() ?? 'Unknown Item',
    quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
    price: (json['price'] as num?)?.toDouble() ?? 0.0,
  );
}

// ─── Order Card ───────────────────────────────────────────────────────────────

class _HistoryMetric {
  final String label;
  final String value;
  final Color color;

  const _HistoryMetric(this.label, this.value, this.color);
}

class _SegmentedControl extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;
  final bool darkSelection;

  const _SegmentedControl({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.darkSelection = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Wrap(
        spacing: 0,
        runSpacing: 2,
        children: options
            .map((option) {
              final active = option == selected;
              return InkWell(
                onTap: () => onSelected(option),
                borderRadius: BorderRadius.circular(7),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? (darkSelection
                              ? const Color(0xFF0F172A)
                              : Colors.white)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: active && !darkSelection
                        ? const [
                            BoxShadow(
                              color: Color(0x120F172A),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    option,
                    style: TextStyle(
                      color: active && darkSelection
                          ? Colors.white
                          : active
                          ? const Color(0xFF0F172A)
                          : const Color(0xFF64748B),
                      fontSize: 11,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }
}

class _TableCell extends StatelessWidget {
  final String value;
  final int flex;
  final bool header;
  final bool strong;
  final bool alignRight;
  final String? secondary;

  const _TableCell(
    this.value, {
    required this.flex,
    this.header = false,
    this.strong = false,
    this.alignRight = false,
    this.secondary,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: alignRight
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: alignRight ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                color: header
                    ? const Color(0xFF64748B)
                    : const Color(0xFF0F172A),
                fontSize: header ? 9 : 12,
                fontWeight: header || strong
                    ? FontWeight.w800
                    : FontWeight.w600,
                letterSpacing: header ? 0.4 : 0,
              ),
            ),
            if (secondary != null)
              Text(
                secondary!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CompactFact extends StatelessWidget {
  final IconData icon;
  final String value;

  const _CompactFact({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: const Color(0xFF94A3B8)),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ActivityTypeChip extends StatelessWidget {
  final String label;
  final Color color;

  const _ActivityTypeChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label.replaceAll('_', ' ').toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _BoundedState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _BoundedState({
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: const Color(0xFF94A3B8)),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF334155),
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 4),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 14),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderDetailPanel extends StatelessWidget {
  final _OrderGroup group;
  final VoidCallback onClose;
  final void Function(String orderId)? onCompleteOrder;

  const _OrderDetailPanel({
    required this.group,
    required this.onClose,
    this.onCompleteOrder,
  });

  String _money(double value) => '\u20B1${value.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x100F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 13, 10, 11),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TRANSACTION DETAILS',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Order #${group.shortId}',
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusChip(status: group.status),
                IconButton(
                  tooltip: 'Close details',
                  onPressed: onClose,
                  icon: const Icon(
                    LucideIcons.x,
                    size: 18,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(16),
              children: [
                _DetailSection(
                  title: 'Timeline',
                  child: Column(
                    children: [
                      _DetailRow(
                        label: 'Ordered',
                        value: _formatDate(group.createdAt),
                      ),
                      if (group.preparedAt != null)
                        _DetailRow(
                          label: 'Prepared',
                          value: _formatDate(group.preparedAt!),
                        ),
                      if (group.completedAt != null)
                        _DetailRow(
                          label: 'Completed',
                          value: _formatDate(group.completedAt!),
                        ),
                      if (group.cancelledAt != null)
                        _DetailRow(
                          label: 'Cancelled',
                          value: _formatDate(group.cancelledAt!),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 11),
                _DetailSection(
                  title: 'Staff',
                  child: Column(
                    children: [
                      if (group.createdBy != null)
                        _DetailRow(
                          label: 'Created by',
                          value: group.createdBy!,
                        ),
                      if (group.preparedBy != null)
                        _DetailRow(
                          label: 'Prepared by',
                          value: group.preparedBy!,
                        ),
                      if (group.completedBy != null)
                        _DetailRow(
                          label: 'Completed by',
                          value: group.completedBy!,
                        ),
                      if (group.cancelledBy != null)
                        _DetailRow(
                          label: 'Cancelled by',
                          value: group.cancelledBy!,
                        ),
                      if (group.createdBy == null &&
                          group.preparedBy == null &&
                          group.completedBy == null &&
                          group.cancelledBy == null)
                        const _DetailRow(label: 'Handled by', value: '—'),
                    ],
                  ),
                ),
                const SizedBox(height: 11),
                _DetailSection(
                  title: 'Items',
                  child: Column(
                    children: group.items
                        .map((item) {
                          final subtotal = item.price * item.quantity;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF7ED),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: const Icon(
                                    LucideIcons.package,
                                    size: 14,
                                    color: Color(0xFFEA580C),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.productName,
                                        style: const TextStyle(
                                          color: Color(0xFF0F172A),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        '${_fmtQty(item.quantity)} \u00D7 ${_money(item.price)}',
                                        style: const TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  _money(subtotal),
                                  style: const TextStyle(
                                    color: Color(0xFF0F172A),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
                const SizedBox(height: 11),
                _DetailSection(
                  title: 'Payment & totals',
                  child: Column(
                    children: [
                      _DetailRow(
                        label: 'Subtotal',
                        value: _money(group.subtotal),
                      ),
                      if (group.discount > 0)
                        _DetailRow(
                          label: 'Discount',
                          value: '-${_money(group.discount)}',
                        ),
                      _DetailRow(
                        label: 'Total',
                        value: _money(group.totalAmount),
                        emphasized: true,
                      ),
                      if (group.paymentMode != 'N/A')
                        _DetailRow(
                          label: 'Payment method',
                          value: group.paymentMode,
                        ),
                      if (group.paymentMode.toLowerCase() == 'gcash' &&
                          group.paymentReference?.trim().isNotEmpty == true)
                        _DetailRow(
                          label: 'GCash reference',
                          value: group.paymentReference!.trim(),
                        ),
                      if (group.cashGiven > 0)
                        _DetailRow(
                          label: 'Cash given',
                          value: _money(group.cashGiven),
                        ),
                      if (group.changeAmount > 0)
                        _DetailRow(
                          label: 'Change',
                          value: _money(group.changeAmount),
                        ),
                    ],
                  ),
                ),
                if (group.status == 'pending' && onCompleteOrder != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () {
                      final callback = onCompleteOrder!;
                      onClose();
                      callback(group.id);
                    },
                    icon: const Icon(LucideIcons.arrowRight, size: 16),
                    label: const Text('Open order workflow'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      minimumSize: const Size.fromHeight(42),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _DetailSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 9,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.7,
          ),
        ),
        const SizedBox(height: 7),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFFF1F5F9)),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasized;

  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: const Color(0xFF0F172A),
                fontSize: emphasized ? 13 : 11,
                fontWeight: emphasized ? FontWeight.w900 : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status == 'solo_picking' ? 'Picking' : status._cap(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

extension _StrExt on String {
  String _cap() => isEmpty ? '' : '${this[0].toUpperCase()}${substring(1)}';
}
