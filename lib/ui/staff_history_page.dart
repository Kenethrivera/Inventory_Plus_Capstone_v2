import 'dart:async';

import 'package:flutter/material.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'widgets/history_period_controls.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _darkText = Color(0xFF0F172A);
const Color _mutedText = Color(0xFF64748B);
const Color _pageBg = Color(0xFFF4F6F8);
const Color _border = Color(0xFFE2E8F0);
const String _fontFam = 'Hellix';

class StaffHistoryPage extends StatefulWidget {
  final InventoryController controller;

  const StaffHistoryPage({super.key, required this.controller});

  @override
  State<StaffHistoryPage> createState() => _StaffHistoryPageState();
}

class _StaffHistoryPageState extends State<StaffHistoryPage> {
  String _searchQuery = '';
  String _selectedFilter = 'All';
  String _historySection = 'Orders';
  HistoryPeriodSelection _periodSelection = HistoryPeriodSelection.current();
  final TextEditingController _searchController = TextEditingController();

  Future<List<Map<String, dynamic>>>? _restockFuture;
  StreamSubscription<void>? _transactionHistorySubscription;
  List<Map<String, dynamic>> _lastRestocks = const <Map<String, dynamic>>[];
  String? _lastRestockScope;

  String get _role =>
      widget.controller.currentUserRole?.toLowerCase() ?? 'staff';

  String? get _currentUserId => widget.controller.currentUserId;

  bool get _isHelper => _role == 'helper';

  bool get _isCashier => _role == 'staff' || _role == 'cashier';

  List<String> get _filters => _isHelper
      ? const ['All', 'Assigned', 'Prepared']
      : const ['All', 'Created', 'Completed', 'Cancelled'];

  @override
  void initState() {
    super.initState();
    if (_isCashier) _bindTransactionHistoryInvalidations();
  }

  @override
  void dispose() {
    _searchController.dispose();
    unawaited(_transactionHistorySubscription?.cancel());
    super.dispose();
  }

  void _bindTransactionHistoryInvalidations() {
    unawaited(_transactionHistorySubscription?.cancel());
    _transactionHistorySubscription = widget
        .controller
        .transactionHistoryInvalidations
        .listen(
          (_) {
            if (_restockFuture != null) _refreshRestockHistory();
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[StaffHistoryPage] History invalidation error: $error');
          },
        );
  }

  Future<List<Map<String, dynamic>>> _loadRestockHistory() async {
    final periodRange = _periodSelection.range;
    final scope = _currentRestockScope;
    try {
      final rows = await widget.controller.loadMyRestockHistory(
        start: periodRange.start,
        endExclusive: periodRange.end,
      );
      if (_currentRestockScope == scope) {
        _lastRestocks = rows;
        _lastRestockScope = scope;
      }
      return rows;
    } catch (error, stackTrace) {
      debugPrint('[StaffHistoryPage] Failed to refresh restocks: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (_lastRestocks.isNotEmpty && _lastRestockScope == scope) {
        return _lastRestocks;
      }
      rethrow;
    }
  }

  String get _currentRestockScope =>
      '${widget.controller.activeLocationId}:'
      '${widget.controller.currentUserNumericId}:'
      '${_periodSelection.stableKey}';

  void _refreshRestockHistory() {
    if (!_isCashier || !mounted) return;
    setState(() => _restockFuture = _loadRestockHistory());
  }

  void _updatePeriodSelection(HistoryPeriodSelection selection) {
    setState(() {
      _periodSelection = selection;
      if (_isCashier) {
        _restockFuture = _historySection == 'Restocks'
            ? _loadRestockHistory()
            : null;
      }
    });
  }

  bool _sameUser(dynamic value) {
    final userId = _currentUserId;
    return userId != null &&
        userId.isNotEmpty &&
        value != null &&
        value.toString() == userId;
  }

  bool _belongsToCurrentUser(CustomerOrder order) {
    if (_isHelper) {
      return _sameUser(order.assignedHelperId) || _sameUser(order.preparedById);
    }
    if (_isCashier) {
      return _sameUser(order.createdById) ||
          _sameUser(order.completedById) ||
          _sameUser(order.cancelledById) ||
          _sameUser(order.returnedById);
    }
    return false;
  }

  bool _matchesSelectedFilter(CustomerOrder order) {
    if (_selectedFilter == 'All') return true;
    if (_isHelper) {
      return switch (_selectedFilter) {
        'Assigned' => _sameUser(order.assignedHelperId),
        'Prepared' => _sameUser(order.preparedById),
        _ => true,
      };
    }
    return switch (_selectedFilter) {
      'Created' => _sameUser(order.createdById),
      'Completed' => _sameUser(order.completedById),
      'Cancelled' =>
        _sameUser(order.cancelledById) || _sameUser(order.returnedById),
      _ => true,
    };
  }

  bool _matchesOrderSearch(CustomerOrder order) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return order.id.toLowerCase().contains(query) ||
        order.status.toLowerCase().contains(query) ||
        order.items.any(
          (item) => item.productName.toLowerCase().contains(query),
        );
  }

  bool _matchesRestockSearch(Map<String, dynamic> transaction) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    final product = _readProductMap(transaction['products']);
    final productName =
        product?['product_name']?.toString().toLowerCase() ?? '';
    final sku = product?['sku']?.toString().toLowerCase() ?? '';
    return productName.contains(query) || sku.contains(query);
  }

  DateTime _activityDate(CustomerOrder order) {
    if (_isHelper) {
      if (_sameUser(order.preparedById) && order.preparedAt != null) {
        return order.preparedAt!;
      }
      if (_sameUser(order.assignedHelperId) && order.assignedAt != null) {
        return order.assignedAt!;
      }
      return order.createdAt;
    }
    if (_sameUser(order.completedById) && order.completedAt != null) {
      return order.completedAt!;
    }
    if (_sameUser(order.cancelledById) && order.cancelledAt != null) {
      return order.cancelledAt!;
    }
    if (_sameUser(order.returnedById) && order.returnedAt != null) {
      return order.returnedAt!;
    }
    return order.createdAt;
  }

  String _myActionLabel(CustomerOrder order) {
    if (_isHelper) {
      if (_sameUser(order.preparedById)) return 'Prepared by you';
      if (_sameUser(order.assignedHelperId)) return 'Assigned to you';
      return 'Your order task';
    }
    if (_sameUser(order.completedById)) return 'Completed by you';
    if (_sameUser(order.cancelledById)) return 'Cancelled by you';
    if (_sameUser(order.returnedById)) return 'Returned by you';
    if (_sameUser(order.createdById)) return 'Created by you';
    return 'Your transaction';
  }

  ({DateTime start, DateTime end}) _selectedPeriodRange() {
    return _periodSelection.range;
  }

  bool _isInSelectedPeriod(DateTime date) {
    final range = _selectedPeriodRange();
    final local = date.toLocal();
    return !local.isBefore(range.start) && local.isBefore(range.end);
  }

  DateTime? _restockDate(Map<String, dynamic> transaction) =>
      DateTime.tryParse(transaction['created_at']?.toString() ?? '')?.toLocal();

  String _periodLabel() => _periodSelection.mode.label;

  String _periodContext() => 'for ${_periodSelection.displayLabel}';

  String _shortOrderId(String id) =>
      (id.length <= 8 ? id : id.substring(0, 8)).toUpperCase();

  String _money(num value) => '\u20B1${value.toStringAsFixed(2)}';

  String _formatHistoryQty(num value) {
    final number = value.toDouble();
    return number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toStringAsFixed(2);
  }

  String _formatDate(DateTime date) {
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
    final local = date.toLocal();
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
  }

  String _formatTime(DateTime date) {
    final local = date.toLocal();
    final hour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _formatDateTime(DateTime date) =>
      '${_formatDate(date)} at ${_formatTime(date)}';

  String _statusLabel(String status) => switch (status.toLowerCase()) {
    'pending' => 'Pending',
    'prepared' => 'Prepared',
    'completed' => 'Completed',
    'cancelled' => 'Cancelled',
    'returned' => 'Returned',
    _ => status,
  };

  Color _statusColor(String status) => switch (status.toLowerCase()) {
    'pending' => const Color(0xFFD97706),
    'prepared' => _primaryBlue,
    'completed' => const Color(0xFF16A34A),
    'cancelled' => const Color(0xFFDC2626),
    'returned' => const Color(0xFFEA580C),
    _ => _mutedText,
  };

  Map<String, dynamic>? _readProductMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUserId == null || _currentUserId!.isEmpty) {
      return const Scaffold(
        backgroundColor: _pageBg,
        body: Center(child: CircularProgressIndicator(color: _primaryBlue)),
      );
    }

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
            return const _HistoryState(
              icon: Icons.error_outline,
              title: 'Could not load your history',
              message: 'Check your connection and try again.',
            );
          }

          final allOrders = snapshot.data ?? <CustomerOrder>[];
          final myOrders = allOrders.where(_belongsToCurrentUser).toList()
            ..sort((a, b) => _activityDate(b).compareTo(_activityDate(a)));
          final periodOrders = myOrders
              .where((order) => _isInSelectedPeriod(_activityDate(order)))
              .toList(growable: false);
          final displayedOrders = periodOrders
              .where(_matchesSelectedFilter)
              .where(_matchesOrderSearch)
              .toList(growable: false);
          final activeCount = periodOrders.where((order) {
            final status = order.status.toLowerCase();
            return status == 'pending' || status == 'prepared';
          }).length;
          final completedCount = _isHelper
              ? periodOrders
                    .where((order) => _sameUser(order.preparedById))
                    .length
              : periodOrders
                    .where((order) => _sameUser(order.completedById))
                    .length;
          final cancelledCount = _isHelper
              ? 0
              : periodOrders.where((order) {
                  return _sameUser(order.cancelledById) ||
                      _sameUser(order.returnedById);
                }).length;

          return LayoutBuilder(
            builder: (context, constraints) {
              final workspaceWidth = constraints.maxWidth > 1160
                  ? 1160.0
                  : constraints.maxWidth;
              final horizontalPadding = constraints.maxWidth < 700
                  ? 14.0
                  : 24.0;
              return Center(
                child: SizedBox(
                  width: workspaceWidth,
                  height: constraints.maxHeight,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(periodOrders.length),
                        const SizedBox(height: 12),
                        _buildStats(
                          total: periodOrders.length,
                          active: activeCount,
                          completed: completedCount,
                          cancelled: cancelledCount,
                        ),
                        const SizedBox(height: 10),
                        _buildControls(),
                        const SizedBox(height: 10),
                        Expanded(
                          child: !_isHelper && _historySection == 'Restocks'
                              ? _buildMyRestockHistory()
                              : displayedOrders.isEmpty
                              ? _buildOrderEmptyState()
                              : _buildOrderHistory(displayedOrders),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildHeader(int recordCount) {
    final period = _periodContext();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isHelper ? 'My Work History' : 'My Transaction History',
          style: const TextStyle(
            color: _darkText,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          _isHelper
              ? '$recordCount assigned or prepared record${recordCount == 1 ? '' : 's'} $period.'
              : '$recordCount transaction record${recordCount == 1 ? '' : 's'} $period.',
          style: const TextStyle(
            color: _mutedText,
            fontSize: 12,
            fontFamily: _fontFam,
          ),
        ),
      ],
    );
  }

  Widget _buildStats({
    required int total,
    required int active,
    required int completed,
    required int cancelled,
  }) {
    final metrics = <_StaffMetric>[
      _StaffMetric('My Records', '$total', Icons.history, _primaryBlue),
      _StaffMetric(
        'Active',
        '$active',
        Icons.schedule,
        const Color(0xFFD97706),
      ),
      _StaffMetric(
        _isHelper ? 'Prepared' : 'Completed',
        '$completed',
        Icons.check_circle_outline,
        const Color(0xFF16A34A),
      ),
      if (!_isHelper)
        _StaffMetric(
          'Cancelled / Returned',
          '$cancelled',
          Icons.cancel_outlined,
          const Color(0xFFDC2626),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 520
            ? 1
            : constraints.maxWidth < 820
            ? 2
            : metrics.length;
        const gap = 8.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: metrics
              .map(
                (metric) => SizedBox(
                  width: width,
                  child: _CompactMetric(metric: metric),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final groups = <Widget>[
            if (!_isHelper) _buildSectionSelector(),
            _HistorySegments(
              options: const ['Daily', 'Weekly', 'Monthly'],
              selected: _periodLabel(),
              onSelected: (value) {
                final mode = switch (value) {
                  'Daily' => HistoryPeriodMode.daily,
                  'Weekly' => HistoryPeriodMode.weekly,
                  _ => HistoryPeriodMode.monthly,
                };
                _updatePeriodSelection(_periodSelection.withMode(mode));
              },
            ),
            HistoryPeriodControls(
              selection: _periodSelection,
              onChanged: _updatePeriodSelection,
            ),
            if (_historySection == 'Orders' || _isHelper)
              _HistorySegments(
                options: _filters,
                selected: _selectedFilter,
                onSelected: (value) => setState(() => _selectedFilter = value),
              ),
          ];
          final refresh = !_isHelper && _historySection == 'Restocks'
              ? IconButton(
                  tooltip: 'Refresh restocks',
                  onPressed: _refreshRestockHistory,
                  icon: const Icon(Icons.refresh, size: 18),
                  color: _primaryBlue,
                  visualDensity: VisualDensity.compact,
                )
              : null;

          if (constraints.maxWidth >= 1040) {
            return Row(
              children: [
                for (var index = 0; index < groups.length; index++) ...[
                  if (index > 0) const SizedBox(width: 9),
                  groups[index],
                ],
                const SizedBox(width: 9),
                Expanded(child: _buildSearchField()),
                if (refresh != null) ...[const SizedBox(width: 4), refresh],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(spacing: 9, runSpacing: 8, children: groups),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _buildSearchField()),
                  if (refresh != null) ...[const SizedBox(width: 4), refresh],
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionSelector() => _HistorySegments(
    options: const ['Orders', 'Restocks'],
    selected: _historySection,
    darkSelection: true,
    onSelected: (value) {
      setState(() {
        _historySection = value;
        if (value == 'Restocks') {
          _restockFuture ??= _loadRestockHistory();
        }
      });
    },
  );

  Widget _buildSearchField() {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _searchQuery = value),
        style: const TextStyle(
          color: _darkText,
          fontSize: 12,
          fontFamily: _fontFam,
        ),
        decoration: InputDecoration(
          hintText: _historySection == 'Restocks' && !_isHelper
              ? 'Search restocked item or SKU'
              : 'Search order or item',
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          prefixIcon: const Icon(Icons.search, size: 17, color: _mutedText),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  icon: const Icon(Icons.close, size: 16),
                ),
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _primaryBlue),
          ),
        ),
      ),
    );
  }

  Widget _buildOrderHistory(List<CustomerOrder> orders) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 760
          ? _buildOrderTable(orders)
          : _buildOrderCards(orders),
    );
  }

  Widget _buildOrderTable(List<CustomerOrder> orders) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            color: const Color(0xFFF8FAFC),
            child: Row(
              children: [
                const _StaffTableCell('ORDER', flex: 15, header: true),
                const _StaffTableCell('DATE & TIME', flex: 18, header: true),
                _StaffTableCell(
                  _isHelper ? 'WORK STATE' : 'ACTIVITY',
                  flex: 17,
                  header: true,
                ),
                const _StaffTableCell('ITEMS', flex: 7, header: true),
                const _StaffTableCell('STATUS', flex: 11, header: true),
                if (!_isHelper)
                  const _StaffTableCell(
                    'TOTAL',
                    flex: 11,
                    header: true,
                    alignRight: true,
                  ),
                const SizedBox(width: 22),
              ],
            ),
          ),
          const Divider(height: 1, color: _border),
          Expanded(
            child: ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
              itemBuilder: (context, index) {
                final order = orders[index];
                final activityDate = _activityDate(order);
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _showOrderDetails(order),
                      hoverColor: const Color(0xFFF8FAFC),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 58),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            _StaffTableCell(
                              '#${_shortOrderId(order.id)}',
                              flex: 15,
                              strong: true,
                            ),
                            _StaffTableCell(
                              _formatDate(activityDate),
                              flex: 18,
                              secondary: _formatTime(activityDate),
                            ),
                            _StaffTableCell(
                              _myActionLabel(order),
                              flex: 17,
                              color: _primaryBlue,
                            ),
                            _StaffTableCell(
                              order.items.length.toString(),
                              flex: 7,
                            ),
                            Expanded(
                              flex: 11,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: _StaffStatusChip(
                                  label: _statusLabel(order.status),
                                  color: _statusColor(order.status),
                                ),
                              ),
                            ),
                            if (!_isHelper)
                              _StaffTableCell(
                                _money(order.totalAmount),
                                flex: 11,
                                strong: true,
                                alignRight: true,
                              ),
                            const SizedBox(
                              width: 22,
                              child: Icon(
                                Icons.chevron_right,
                                size: 18,
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

  Widget _buildOrderCards(List<CustomerOrder> orders) {
    return ListView.separated(
      itemCount: orders.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final order = orders[index];
        final activityDate = _activityDate(order);
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            onTap: () => _showOrderDetails(order),
            borderRadius: BorderRadius.circular(11),
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: _border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Order #${_shortOrderId(order.id)}',
                          style: const TextStyle(
                            color: _darkText,
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            fontFamily: _fontFam,
                          ),
                        ),
                      ),
                      _StaffStatusChip(
                        label: _statusLabel(order.status),
                        color: _statusColor(order.status),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Color(0xFF94A3B8),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    _myActionLabel(order),
                    style: const TextStyle(
                      color: _primaryBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 14,
                    runSpacing: 6,
                    children: [
                      _Meta(
                        icon: Icons.schedule,
                        text: _formatDateTime(activityDate),
                      ),
                      _Meta(
                        icon: Icons.inventory_2_outlined,
                        text:
                            '${order.items.length} item${order.items.length == 1 ? '' : 's'}',
                      ),
                      if (!_isHelper)
                        _Meta(
                          icon: Icons.payments_outlined,
                          text: _money(order.totalAmount),
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

  void _showOrderDetails(CustomerOrder order) {
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
              maxWidth: 720,
              maxHeight: viewport.height * 0.78,
            ),
            child: _StaffOrderDetail(
              order: order,
              isHelper: _isHelper,
              activityLabel: _myActionLabel(order),
              statusLabel: _statusLabel(order.status),
              statusColor: _statusColor(order.status),
              onClose: () => Navigator.pop(dialogContext),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMyRestockHistory() {
    final future = _restockFuture ??= _loadRestockHistory();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _HistoryState(
            icon: Icons.inventory_2_outlined,
            title: 'Loading restock history',
            loading: true,
          );
        }
        if (snapshot.hasError && _lastRestocks.isEmpty) {
          return _HistoryState(
            icon: Icons.error_outline,
            title: 'Could not load restock history',
            message: 'Check your connection and try again.',
            actionLabel: 'Retry',
            onAction: _refreshRestockHistory,
          );
        }
        final allRestocks = snapshot.data ?? _lastRestocks;
        final restocks = allRestocks
            .where((transaction) {
              final date = _restockDate(transaction);
              return date != null &&
                  _isInSelectedPeriod(date) &&
                  _matchesRestockSearch(transaction);
            })
            .toList(growable: false);
        if (restocks.isEmpty) return _buildRestockEmptyState();
        return LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 700
              ? _buildRestockTable(restocks)
              : _buildRestockCards(restocks),
        );
      },
    );
  }

  Widget _buildRestockTable(List<Map<String, dynamic>> restocks) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
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
                _StaffTableCell('ITEM', flex: 22, header: true),
                _StaffTableCell('DATE & TIME', flex: 18, header: true),
                _StaffTableCell('SKU', flex: 13, header: true),
                _StaffTableCell(
                  'QUANTITY ADDED',
                  flex: 13,
                  header: true,
                  alignRight: true,
                ),
                _StaffTableCell(
                  'NEW STOCK',
                  flex: 12,
                  header: true,
                  alignRight: true,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _border),
          Expanded(
            child: ListView.separated(
              itemCount: restocks.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
              itemBuilder: (context, index) {
                final transaction = restocks[index];
                final product = _readProductMap(transaction['products']);
                final date = _restockDate(transaction)!;
                final quantity = (transaction['quantity_change'] as num?) ?? 0;
                final newQuantity = (transaction['new_quantity'] as num?) ?? 0;
                return Container(
                  constraints: const BoxConstraints(minHeight: 58),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      _StaffTableCell(
                        product?['product_name']?.toString() ?? 'Unknown item',
                        flex: 22,
                        strong: true,
                      ),
                      _StaffTableCell(
                        _formatDate(date),
                        flex: 18,
                        secondary: _formatTime(date),
                      ),
                      _StaffTableCell(
                        product?['sku']?.toString() ?? '—',
                        flex: 13,
                      ),
                      _StaffTableCell(
                        '+${_formatHistoryQty(quantity)}',
                        flex: 13,
                        strong: true,
                        alignRight: true,
                        color: const Color(0xFF16A34A),
                      ),
                      _StaffTableCell(
                        _formatHistoryQty(newQuantity),
                        flex: 12,
                        alignRight: true,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRestockCards(List<Map<String, dynamic>> restocks) {
    return ListView.separated(
      itemCount: restocks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final transaction = restocks[index];
        final product = _readProductMap(transaction['products']);
        final date = _restockDate(transaction)!;
        final quantity = (transaction['quantity_change'] as num?) ?? 0;
        final newQuantity = (transaction['new_quantity'] as num?) ?? 0;
        return Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.add_box_outlined,
                  size: 17,
                  color: Color(0xFF16A34A),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product?['product_name']?.toString() ?? 'Unknown item',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _darkText,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        fontFamily: _fontFam,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatDateTime(date)} • ${product?['sku']?.toString() ?? 'No SKU'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _mutedText,
                        fontSize: 10,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '+${_formatHistoryQty(quantity)}',
                    style: const TextStyle(
                      color: Color(0xFF16A34A),
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      fontFamily: _fontFam,
                    ),
                  ),
                  Text(
                    'Stock ${_formatHistoryQty(newQuantity)}',
                    style: const TextStyle(
                      color: _mutedText,
                      fontSize: 10,
                      fontFamily: _fontFam,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOrderEmptyState() => _HistoryState(
    icon: Icons.history_toggle_off,
    title: _searchQuery.trim().isNotEmpty
        ? 'No matching records'
        : 'No history ${_periodContext()}',
    message: _isHelper
        ? 'Your assigned and prepared orders will appear here.'
        : 'Your cashier transactions will appear here.',
  );

  Widget _buildRestockEmptyState() => _HistoryState(
    icon: Icons.inventory_2_outlined,
    title: _searchQuery.trim().isNotEmpty
        ? 'No matching restocks'
        : 'No restocks ${_periodContext()}',
    message: 'Items you restock will appear here.',
  );
}

class _StaffMetric {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StaffMetric(this.label, this.value, this.icon, this.color);
}

class _CompactMetric extends StatelessWidget {
  final _StaffMetric metric;

  const _CompactMetric({required this.metric});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: metric.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(metric.icon, color: metric.color, size: 16),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metric.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFamily: _fontFam,
                  ),
                ),
                Text(
                  metric.value,
                  style: const TextStyle(
                    color: _darkText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
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
}

class _HistorySegments extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;
  final bool darkSelection;

  const _HistorySegments({
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
        children: options
            .map((option) {
              final active = option == selected;
              return InkWell(
                onTap: () => onSelected(option),
                borderRadius: BorderRadius.circular(7),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? (darkSelection ? _darkText : Colors.white)
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
                          ? _darkText
                          : _mutedText,
                      fontSize: 11,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      fontFamily: _fontFam,
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

class _StaffTableCell extends StatelessWidget {
  final String value;
  final int flex;
  final bool header;
  final bool strong;
  final bool alignRight;
  final String? secondary;
  final Color? color;

  const _StaffTableCell(
    this.value, {
    required this.flex,
    this.header = false,
    this.strong = false,
    this.alignRight = false,
    this.secondary,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
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
              color: color ?? (header ? _mutedText : _darkText),
              fontSize: header ? 9 : 11,
              fontWeight: header || strong ? FontWeight.w900 : FontWeight.w600,
              letterSpacing: header ? 0.35 : 0,
              fontFamily: _fontFam,
            ),
          ),
          if (secondary != null)
            Text(
              secondary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _mutedText,
                fontSize: 9,
                fontFamily: _fontFam,
              ),
            ),
        ],
      ),
    );
  }
}

class _StaffStatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StaffStatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          fontFamily: _fontFam,
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Meta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: _mutedText),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            color: _mutedText,
            fontSize: 10,
            fontFamily: _fontFam,
          ),
        ),
      ],
    );
  }
}

class _StaffOrderDetail extends StatelessWidget {
  final CustomerOrder order;
  final bool isHelper;
  final String activityLabel;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onClose;

  const _StaffOrderDetail({
    required this.order,
    required this.isHelper,
    required this.activityLabel,
    required this.statusLabel,
    required this.statusColor,
    required this.onClose,
  });

  String _shortId() =>
      (order.id.length <= 8 ? order.id : order.id.substring(0, 8))
          .toUpperCase();

  String _qty(num value) {
    final number = value.toDouble();
    return number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toStringAsFixed(2);
  }

  String _money(num value) => '\u20B1${value.toStringAsFixed(2)}';

  String _date(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day}/${local.year} '
        '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x180F172A),
            blurRadius: 22,
            offset: Offset(0, 8),
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
                          color: _mutedText,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                          fontFamily: _fontFam,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Order #${_shortId()}',
                        style: const TextStyle(
                          color: _darkText,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ],
                  ),
                ),
                _StaffStatusChip(label: statusLabel, color: statusColor),
                IconButton(
                  tooltip: 'Close details',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 19, color: _mutedText),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _border),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(16),
              children: [
                _StaffDetailSection(
                  title: 'Work summary',
                  child: _StaffDetailRow(
                    label: isHelper ? 'Work state' : 'Your activity',
                    value: activityLabel,
                    emphasized: true,
                  ),
                ),
                const SizedBox(height: 11),
                _StaffDetailSection(
                  title: 'Timeline',
                  child: Column(
                    children: [
                      if (!isHelper)
                        _StaffDetailRow(
                          label: 'Created',
                          value: _date(order.createdAt),
                        ),
                      if (order.assignedAt != null)
                        _StaffDetailRow(
                          label: 'Assigned',
                          value: _date(order.assignedAt!),
                        ),
                      if (order.preparedAt != null)
                        _StaffDetailRow(
                          label: 'Prepared',
                          value: _date(order.preparedAt!),
                        ),
                      if (!isHelper && order.completedAt != null)
                        _StaffDetailRow(
                          label: 'Completed',
                          value: _date(order.completedAt!),
                        ),
                      if (!isHelper && order.cancelledAt != null)
                        _StaffDetailRow(
                          label: 'Cancelled',
                          value: _date(order.cancelledAt!),
                        ),
                      if (!isHelper && order.returnedAt != null)
                        _StaffDetailRow(
                          label: 'Returned',
                          value: _date(order.returnedAt!),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 11),
                _StaffDetailSection(
                  title: 'Items',
                  child: Column(
                    children: order.items
                        .map(
                          (item) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF7ED),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: const Icon(
                                    Icons.inventory_2_outlined,
                                    size: 14,
                                    color: Color(0xFFEA580C),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    item.productName,
                                    style: const TextStyle(
                                      color: _darkText,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                ),
                                Text(
                                  '× ${_qty(item.quantity)}',
                                  style: const TextStyle(
                                    color: _darkText,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
                if (!isHelper) ...[
                  const SizedBox(height: 11),
                  _StaffDetailSection(
                    title: 'Payment & totals',
                    child: Column(
                      children: [
                        _StaffDetailRow(
                          label: 'Total',
                          value: _money(order.totalAmount),
                          emphasized: true,
                        ),
                      ],
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

class _StaffDetailSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _StaffDetailSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: _mutedText,
            fontSize: 9,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.7,
            fontFamily: _fontFam,
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

class _StaffDetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasized;

  const _StaffDetailRow({
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
              style: const TextStyle(
                color: _mutedText,
                fontSize: 11,
                fontFamily: _fontFam,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: _darkText,
                fontSize: emphasized ? 13 : 11,
                fontWeight: emphasized ? FontWeight.w900 : FontWeight.w700,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool loading;

  const _HistoryState({
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: _primaryBlue,
                  ),
                )
              else
                Icon(icon, size: 38, color: const Color(0xFF94A3B8)),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _darkText,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 4),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
