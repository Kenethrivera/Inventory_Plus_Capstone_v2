import 'package:flutter/material.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import 'package:printing/printing.dart';
import 'reports/sales_report_generator.dart';
import '../services/export_period.dart';
import '../services/export_reminder_service.dart'; // add
import 'reports/report_range.dart';
import 'reports/report_period_dialog.dart';
import '../notifications/notification_provider.dart';

String _fmtQty(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

class TransactionHistoryPage extends StatefulWidget {
  final InventoryController controller;
  final String initialTab;
  final bool exportDue;
  final VoidCallback? onExported;
  final void Function(String orderId)? onCompleteOrder;

  const TransactionHistoryPage({
    super.key,
    required this.controller,
    this.initialTab = 'Sales History',
    this.exportDue = false,
    this.onExported,
    this.onCompleteOrder,
  });

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  late Future<List<_OrderGroup>> _groupedFuture;

  // Sales History State
  String _filterStatus = 'All';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Activity Log State
  late String _activeTab;
  List<Map<String, dynamic>> _activityLog = [];
  bool _isLoadingLog = true;
  String _logFilter = 'All';

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _load();
  }

  @override
  void didUpdateWidget(TransactionHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the MainScreen tells us to change tabs, update it!
    if (widget.initialTab != oldWidget.initialTab) {
      setState(() {
        _activeTab = widget.initialTab;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _load() {
    _groupedFuture = _fetchGrouped();
    _fetchLog();
  }

  Future<void> _fetchLog() async {
    setState(() => _isLoadingLog = true);
    final logs = await widget.controller.fetchAllTransactionHistory();
    if (mounted) {
      setState(() {
        _activityLog = logs;
        _isLoadingLog = false;
      });
    }
  }

  Future<List<_OrderGroup>> _fetchGrouped() async {
    final locId = widget.controller.activeLocationId;
    if (locId == null) return [];

    try {
      final orders = await widget.controller.supabase
          .from('orders')
          .select()
          .eq('location_id', locId)
          .order('created_at', ascending: false);

      final allUserIds = orders
          .expand((o) {
            final createdBy = o['created_by'];
            final preparedBy = o['prepared_by'];
            final preparedByInt = preparedBy != null
                ? int.tryParse(preparedBy.toString())
                : null;
            return [createdBy, preparedByInt];
          })
          .where((id) => id != null)
          .toSet()
          .toList();

      Map<dynamic, String> profileNames = {};
      if (allUserIds.isNotEmpty) {
        final profiles = await widget.controller.supabase
            .from('profiles')
            .select('id, name')
            .inFilter('id', allUserIds);
        for (final p in profiles) {
          profileNames[p['id']] = p['name']?.toString() ?? '—';
        }
      }

      final List<_OrderGroup> groups = [];

      for (final order in orders) {
        final status = order['status'] as String? ?? 'pending';
        final createdAt = DateTime.parse(order['created_at']).toLocal();
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
        double changeAmount =
            (order['change_amount'] as num?)?.toDouble() ?? 0.0;
        String paymentMode = order['payment_mode'] as String? ?? 'N/A';

        groups.add(
          _OrderGroup(
            id: order['id'].toString(),
            status: status,
            createdAt: createdAt,
            totalAmount: totalAmount,
            subtotal: calculatedSubtotal,
            discount: discount,
            cashGiven: cashGiven,
            changeAmount: changeAmount,
            paymentMode: paymentMode,
            items: items,
            createdBy: order['created_by'] != null
                ? profileNames[order['created_by']]
                : null,
            preparedBy: order['prepared_by'] != null
                ? profileNames[int.tryParse(order['prepared_by'].toString())]
                : null,
            preparedAt: order['prepared_at'] != null
                ? DateTime.parse(order['prepared_at'].toString()).toLocal()
                : null,
            completedAt: order['completed_at'] != null
                ? DateTime.parse(order['completed_at'].toString()).toLocal()
                : null,
          ),
        );
      }

      groups.sort((a, b) => b.eventAt.compareTo(a.eventAt));
      return groups;
    } catch (e) {
      debugPrint('Error fetching orders: $e');
      return [];
    }
  }

  String _formatLogDateGroup(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final target = DateTime(date.year, date.month, date.day);

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
    final dateString = "${months[date.month - 1]} ${date.day}, ${date.year}";

    if (target == today) return "TODAY — $dateString";
    if (target == yesterday) return "YESTERDAY — $dateString";
    return dateString;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _activeTab == 'Sales History'
                          ? 'Transaction History'
                          : 'Activity Log',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    if (_activeTab == 'Sales History')
                      FutureBuilder<List<_OrderGroup>>(
                        future: _groupedFuture,
                        builder: (context, snapshot) {
                          final count =
                              snapshot.data
                                  ?.where(
                                    (g) =>
                                        g.eventAt.month ==
                                            DateTime.now().month &&
                                        g.eventAt.year == DateTime.now().year,
                                  )
                                  .length ??
                              0;
                          return Text(
                            '$count orders this month',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 13,
                            ),
                          );
                        },
                      )
                    else
                      Text(
                        '${_activityLog.length} inventory changes this month',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
                Row(
                  children: [
                    // Only show Export button on the Sales History tab
                    if (_activeTab == 'Sales History') ...[
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => showReportPeriodDialog(
                              context,
                              title: 'Generate Sales Report',
                              onGenerate: (range) =>
                                  _generateAndPrintSalesReport(context, range),
                            ),
                            icon: const Icon(LucideIcons.download, size: 16),
                            label: const Text(
                              "Export Sales",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.black87,
                              side: BorderSide(
                                color: widget.exportDue
                                    ? Colors.red
                                    : Colors.grey.shade300,
                                width: widget.exportDue ? 1.5 : 1,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          if (widget.exportDue)
                            Positioned(
                              top: -4,
                              right: -4,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 12),
                    ],
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: const Icon(
                          LucideIcons.refreshCw,
                          size: 18,
                          color: Colors.black87,
                        ),
                        onPressed: () => setState(() => _load()),
                        tooltip: 'Refresh',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.grey.shade200),

          Expanded(
            child: FutureBuilder<List<_OrderGroup>>(
              future: _groupedFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    _activeTab == 'Sales History') {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.orange),
                  );
                }

                final all = snapshot.data ?? [];

                // Sales Stats
                final now = DateTime.now();
                final thisMonth = all
                    .where(
                      (g) =>
                          g.eventAt.month == now.month &&
                          g.eventAt.year == now.year,
                    )
                    .toList();
                final totalOrders = thisMonth
                    .where((g) => g.status != 'cancelled')
                    .length;
                final pendingOrders = thisMonth
                    .where(
                      (g) => g.status == 'pending' || g.status == 'prepared',
                    )
                    .length;
                final revenue = thisMonth
                    .where((g) => g.status == 'completed')
                    .fold(0.0, (sum, g) => sum + g.totalAmount);

                var filteredOrders = _filterStatus == 'All'
                    ? all
                    : all
                          .where((g) => g.status == _filterStatus.toLowerCase())
                          .toList();

                if (_searchQuery.isNotEmpty && _activeTab == 'Sales History') {
                  filteredOrders = filteredOrders.where((g) {
                    final query = _searchQuery.toLowerCase();
                    final matchId = g.id.toLowerCase().contains(query);
                    final matchItem = g.items.any(
                      (item) => item.productName.toLowerCase().contains(query),
                    );
                    return matchId || matchItem;
                  }).toList();
                }

                // Activity Log Stats
                // Activity Log Stats
                double stockInTotal = 0;
                double stockOutTotal = 0;
                for (var tx in _activityLog) {
                  num qty = tx['quantity_change'] ?? 0;
                  if (qty > 0) stockInTotal += qty.toDouble();
                  if (qty < 0) stockOutTotal += qty.toDouble().abs();
                }

                return Column(
                  children: [
                    // --- DYNAMIC METRICS CARDS ---
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Row(
                        children: [
                          if (_activeTab == 'Sales History') ...[
                            _buildStatCard(
                              "TOTAL ORDERS",
                              "$totalOrders",
                              Colors.black87,
                            ),
                            const SizedBox(width: 16),
                            _buildStatCard(
                              "PENDING",
                              "$pendingOrders",
                              Colors.orange,
                            ),
                            const SizedBox(width: 16),
                            _buildStatCard(
                              "REVENUE (MONTH)",
                              "₱${revenue.toStringAsFixed(2)}",
                              Colors.green,
                            ),
                          ] else ...[
                            _buildStatCard(
                              "TOTAL CHANGES",
                              "${_activityLog.length}",
                              Colors.black87,
                            ),
                            const SizedBox(width: 16),
                            _buildStatCard(
                              "STOCK IN",
                              "+${_fmtQty(stockInTotal)}",
                              Colors.green,
                            ),
                            const SizedBox(width: 16),
                            _buildStatCard(
                              "STOCK OUT",
                              "-${_fmtQty(stockOutTotal)}",
                              Colors.red,
                            ),
                          ],
                        ],
                      ),
                    ),
                    Divider(height: 1, color: Colors.grey.shade200),

                    // --- TABS & FILTERS ---
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 24.0,
                        right: 24.0,
                        top: 16.0,
                      ),
                      child: _buildTabToggle(),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24.0,
                        vertical: 16.0,
                      ),
                      child: Row(
                        children: [
                          if (_activeTab == 'Sales History')
                            _buildFilterPills()
                          else
                            _buildLogFilterPills(),

                          const Spacer(),
                          SizedBox(
                            width: 280,
                            child: TextField(
                              controller: _searchController,
                              decoration: InputDecoration(
                                hintText: _activeTab == 'Sales History'
                                    ? 'Search order # or item...'
                                    : 'Search item name...',
                                hintStyle: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontSize: 13,
                                ),
                                prefixIcon: Icon(
                                  LucideIcons.search,
                                  size: 16,
                                  color: Colors.grey.shade500,
                                ),
                                filled: true,
                                fillColor: Colors.grey.shade50,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 0,
                                  horizontal: 16,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                              ),
                              onChanged: (val) =>
                                  setState(() => _searchQuery = val),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // --- CONDITIONALLY RENDER THE LIST ---
                    Expanded(
                      child: _activeTab == 'Activity Log'
                          ? _buildActivityLogList()
                          : _buildSalesHistoryList(filteredOrders),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabToggle() {
    return Row(
      children: [
        _buildTabButton('Sales History', LucideIcons.receipt),
        const SizedBox(width: 8),
        _buildTabButton('Activity Log', LucideIcons.history),
      ],
    );
  }

  Widget _buildTabButton(String title, IconData icon) {
    final isSelected = _activeTab == title;
    return InkWell(
      onTap: () => setState(() => _activeTab = title),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0F172A) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFF0F172A) : Colors.grey.shade300,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : Colors.grey.shade700,
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade700,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color valueColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterPills() {
    final filters = ['All', 'Pending', 'Prepared', 'Completed', 'Cancelled'];
    return Row(
      children: filters.map((f) {
        final isSelected = _filterStatus == f;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => setState(() => _filterStatus = f),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? Colors.grey.shade300 : Colors.transparent,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 4,
                        ),
                      ]
                    : [],
              ),
              child: Text(
                f,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.black87 : Colors.grey.shade600,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildLogFilterPills() {
    final filters = ['All', 'Stock In', 'Stock Out'];
    return Row(
      children: filters.map((f) {
        final isSelected = _logFilter == f;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => setState(() => _logFilter = f),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? Colors.grey.shade300 : Colors.transparent,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 4,
                        ),
                      ]
                    : [],
              ),
              child: Text(
                f,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.black87 : Colors.grey.shade600,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSalesHistoryList(List<_OrderGroup> filteredOrders) {
    if (filteredOrders.isEmpty) return _buildEmptyState();

    // Group the orders by Date
    Map<String, List<_OrderGroup>> groupedOrders = {};
    for (var order in filteredOrders) {
      final dateKey = _formatLogDateGroup(order.eventAt);
      if (!groupedOrders.containsKey(dateKey)) {
        groupedOrders[dateKey] = [];
      }
      groupedOrders[dateKey]!.add(order);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: groupedOrders.length,
      itemBuilder: (context, index) {
        final dateKey = groupedOrders.keys.elementAt(index);
        final orders = groupedOrders[dateKey]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8.0, bottom: 12.0),
              child: Text(
                dateKey,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            // Build the cards for this specific date group
            ...orders.map(
              (order) => _OrderCard(
                group: order,
                onCompleteOrder: widget.onCompleteOrder,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActivityLogList() {
    if (_isLoadingLog) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.orange),
      );
    }

    var filteredLogs = _activityLog;

    // Apply Filter Pill
    if (_logFilter != 'All') {
      filteredLogs = filteredLogs.where((tx) {
        final num qty = tx['quantity_change'] ?? 0;
        final type = tx['transaction_type'] as String;
        if (_logFilter == 'Stock In') return qty > 0;
        if (_logFilter == 'Stock Out') return qty < 0;
        if (_logFilter == 'Adjustments') return type == 'manual_adjustment';
        return true;
      }).toList();
    }

    // Apply Search
    if (_searchQuery.isNotEmpty) {
      filteredLogs = filteredLogs.where((tx) {
        final pName = (tx['products']?['product_name'] ?? "")
            .toString()
            .toLowerCase();
        return pName.contains(_searchQuery.toLowerCase());
      }).toList();
    }

    if (filteredLogs.isEmpty) {
      return const Center(
        child: Text("No activity found.", style: TextStyle(color: Colors.grey)),
      );
    }

    // Group by Date
    Map<String, List<Map<String, dynamic>>> groupedLogs = {};
    for (var tx in filteredLogs) {
      final date = DateTime.parse(tx['created_at']).toLocal();
      final dateKey = _formatLogDateGroup(date);
      if (!groupedLogs.containsKey(dateKey)) {
        groupedLogs[dateKey] = [];
      }
      groupedLogs[dateKey]!.add(tx);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: groupedLogs.length,
      itemBuilder: (context, index) {
        final dateKey = groupedLogs.keys.elementAt(index);
        final txs = groupedLogs[dateKey]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
              child: Text(
                dateKey,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            ...txs.map((tx) {
              final isPositive = (tx['quantity_change'] as num) > 0;
              final type = tx['transaction_type'] as String;
              final pName = tx['products']?['product_name'] ?? "Unknown Item";
              final uName = tx['profiles']?['name'] ?? "Admin";

              final date = DateTime.parse(tx['created_at']).toLocal();
              final timeStr =
                  "${date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour)}:${date.minute.toString().padLeft(2, '0')} ${date.hour >= 12 ? 'PM' : 'AM'}";

              Color typeColor = isPositive ? Colors.green : Colors.red;
              if (type == 'manual_adjustment') typeColor = Colors.blue;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: typeColor.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPositive ? LucideIcons.plus : LucideIcons.minus,
                        size: 14,
                        color: typeColor,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  pName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: Color(0xFF0F172A),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: typeColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  type.toUpperCase().replaceAll('_', ' '),
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: typeColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "$uName · $timeStr",
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          "${isPositive ? '+' : ''}${_fmtQty((tx['quantity_change'] as num).toDouble())}",
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: typeColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "New qty: ${_fmtQty((tx['new_quantity'] as num).toDouble())}",
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
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
      final allGroups = await _groupedFuture;
      final periodSales = allGroups
          .where((g) => g.status == 'completed' && range.contains(g.eventAt))
          .toList();

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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.receipt, size: 52, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(
            'No orders found',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Adjust your search or filters to see results.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

Color _statusColor(String status) {
  switch (status) {
    case 'completed':
      return Colors.green;
    case 'prepared':
      return Colors.blue;
    case 'pending':
      return Colors.orange;
    case 'cancelled':
      return Colors.red.shade400;
    case 'solo_picking':
      return Colors.orange;
    default:
      return Colors.grey;
  }
}

IconData _statusIcon(String status) {
  switch (status) {
    case 'completed':
      return LucideIcons.check;
    case 'prepared':
      return LucideIcons.packageCheck;
    case 'pending':
      return LucideIcons.clock;
    case 'cancelled':
      return LucideIcons.x;
    case 'solo_picking':
      return LucideIcons.clock;
    default:
      return LucideIcons.circle;
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
  final double totalAmount;
  final double subtotal;
  final double discount;
  final double cashGiven;
  final double changeAmount;
  final String paymentMode;
  final List<_OrderLineItem> items;
  final String? createdBy;
  final String? preparedBy;
  final DateTime? preparedAt;
  final DateTime? completedAt;

  _OrderGroup({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.totalAmount,
    required this.subtotal,
    required this.discount,
    required this.cashGiven,
    required this.changeAmount,
    required this.paymentMode,
    required this.items,
    this.createdBy,
    this.preparedBy,
    this.preparedAt,
    this.completedAt,
  });

  String get shortId =>
      id.length >= 8 ? id.substring(0, 8).toUpperCase() : id.toUpperCase();

  DateTime get eventAt => completedAt ?? preparedAt ?? createdAt;
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

class _OrderCard extends StatefulWidget {
  final _OrderGroup group;
  final void Function(String orderId)? onCompleteOrder;

  const _OrderCard({required this.group, this.onCompleteOrder});

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  void _showReceiptModal(BuildContext context, _OrderGroup g) {
    if (g.status != 'completed') return;
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: Colors.white,
          child: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'INVENTORY PLUS',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'SPRJ Paint Center - San Pedro, Laguna',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _DashedDivider(),
                    const SizedBox(height: 16),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Order #',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          g.shortId,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Ordered',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          _formatDate(g.createdAt),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    if (g.completedAt != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Completed',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            _formatDate(g.completedAt!),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Cashier',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          g.createdBy ?? "Admin",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const _DashedDivider(),
                    const SizedBox(height: 16),

                    ...g.items.map((item) {
                      double itemTotal = item.price * item.quantity;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.productName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    '${_fmtQty(item.quantity)} qty x ₱${item.price.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '₱${itemTotal.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),

                    const SizedBox(height: 16),
                    const _DashedDivider(),
                    const SizedBox(height: 16),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Subtotal', style: TextStyle(fontSize: 12)),
                        Text(
                          '₱${g.subtotal.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    if (g.discount > 0) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Discount',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            '-₱${g.discount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'TOTAL',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '₱${g.totalAmount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),

                    if (g.status == 'completed') ...[
                      const SizedBox(height: 16),
                      const _DashedDivider(),
                      const SizedBox(height: 16),
                      if (g.cashGiven > 0) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Cash Given',
                              style: TextStyle(fontSize: 12),
                            ),
                            Text(
                              '₱${g.cashGiven.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                      ],
                      if (g.changeAmount > 0) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Change',
                              style: TextStyle(fontSize: 12),
                            ),
                            Text(
                              '₱${g.changeAmount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Mode of Payment',
                            style: TextStyle(fontSize: 12),
                          ),
                          Text(
                            g.paymentMode,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 24),
                    Text(
                      'Thank you for your purchase!',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    Text(
                      'This serves as your official receipt.',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),

                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black87,
                          side: BorderSide(color: Colors.grey.shade300),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          "Close",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final color = _statusColor(g.status);
    final bgColor = color.withOpacity(0.05);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 6, color: color),
            Expanded(
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  onExpansionChanged: (expanded) => _toggle(),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: bgColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(_statusIcon(g.status), color: color, size: 18),
                  ),
                  title: Row(
                    children: [
                      Text(
                        'Order #${g.shortId}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(status: g.status),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: Text(
                      g.completedAt != null
                          ? 'Completed ${_formatDate(g.completedAt!)} - by ${g.createdBy ?? "Admin"}'
                          : g.preparedAt != null
                          ? 'Prepared ${_formatDate(g.preparedAt!)} - by ${g.createdBy ?? "Admin"}'
                          : '${_formatDate(g.createdAt)} - by ${g.createdBy ?? "Admin"}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        "₱${g.totalAmount.toStringAsFixed(2)}",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${g.items.length} item${g.items.length == 1 ? '' : 's'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                  childrenPadding: const EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: 16,
                  ),
                  children: [
                    Divider(height: 1, color: Colors.grey.shade100),
                    const SizedBox(height: 12),
                    _buildTimelineRow('Ordered', g.createdAt),
                    if (g.preparedAt != null)
                      _buildTimelineRow('Prepared', g.preparedAt!),
                    if (g.completedAt != null)
                      _buildTimelineRow('Completed', g.completedAt!),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: Colors.grey.shade100),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "ORDER ITEMS",
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...g.items.map(
                      (item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                LucideIcons.package,
                                size: 16,
                                color: Colors.orange,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.productName,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  if (item.price > 0)
                                    Text(
                                      "₱${item.price.toStringAsFixed(2)} / unit",
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                "x${_fmtQty(item.quantity)}",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),
                    if (g.status == 'completed')
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _showReceiptModal(context, g),
                          icon: const Icon(LucideIcons.receipt, size: 16),
                          label: const Text(
                            "Show Receipt",
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.black87,
                            side: BorderSide(color: Colors.grey.shade300),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      )
                    else if (g.status == 'pending')
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: widget.onCompleteOrder == null
                              ? null
                              : () => widget.onCompleteOrder!(g.id),
                          icon: const Icon(
                            LucideIcons.check,
                            size: 16,
                            color: Colors.white,
                          ),
                          label: const Text(
                            "Complete Order Now",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Text(
                          g.status == 'prepared'
                              ? "Items are picked. Complete the payment from POS → Pending Orders → Complete Transaction."
                              : g.status == 'cancelled'
                              ? "This order was cancelled. Its items were returned to stock, so there is no receipt."
                              : "Order in progress — no receipt yet.",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
        color: color.withOpacity(0.12),
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

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        const dashWidth = 5.0;
        const dashHeight = 1.0;
        final dashCount = (boxWidth / (2 * dashWidth)).floor();
        return Flex(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          direction: Axis.horizontal,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: dashHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.grey.shade300),
              ),
            );
          }),
        );
      },
    );
  }
}

Widget _buildTimelineRow(String label, DateTime date) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2.0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
        Text(
          _formatDate(date),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0F172A),
          ),
        ),
      ],
    ),
  );
}
