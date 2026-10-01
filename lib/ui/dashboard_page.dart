import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import '../data/inventory.dart';
import 'widgets/app_dialog.dart';

class DashboardPage extends StatefulWidget {
  final InventoryController controller;
  final VoidCallback onViewTransactions;  
  final VoidCallback onOpenQueue;
  final VoidCallback onViewActivity;
  const DashboardPage({super.key, required this.controller, required this.onViewTransactions,required this.onOpenQueue,required this.onViewActivity,});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  String _selectedFilter = '30 Days';
  List<Map<String, dynamic>> _recentTransactions = [];
  bool _isLoadingTxs = true;

  @override
  void initState() {
    super.initState();
    _fetchTransactions();
  }

  Future<void> _fetchTransactions() async {
    final txs = await widget.controller.fetchAllTransactionHistory();
    if (mounted) {
      setState(() {
        _recentTransactions = txs;
        _isLoadingTxs = false;
      });
    }
  }

  // --- LOCAL DATA AGGREGATION ---
  Map<String, dynamic> _calculateMetrics(List<CustomerOrder> orders) {
    final now = DateTime.now();
    // Use the actual end of today for accurate comparisons
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final startOfToday = DateTime(now.year, now.month, now.day);
    
    // Determine cutoff based on filter
    DateTime currentPeriodStart;
    DateTime previousPeriodStart;
    
    if (_selectedFilter == 'Today') {
      currentPeriodStart = startOfToday;
      previousPeriodStart = startOfToday.subtract(const Duration(days: 1));
    } else if (_selectedFilter == '7 Days') {
      currentPeriodStart = startOfToday.subtract(const Duration(days: 6)); // Includes today + 6 past days
      previousPeriodStart = currentPeriodStart.subtract(const Duration(days: 7));
    } else {
      currentPeriodStart = startOfToday.subtract(const Duration(days: 29));
      previousPeriodStart = currentPeriodStart.subtract(const Duration(days: 30));
    }

    double currentRevenue = 0;
    double previousRevenue = 0;
    int currentOrders = 0;
    int previousOrders = 0;
    int pendingCount = 0;
    int preparedCount = 0;
    int waitingLongCount = 0;

    // Bar chart data (Last 7 days, ending today)
    List<double> dailyRevenue = List.filled(7, 0.0);
    double totalWeekRevenue = 0;
    int bestDayIndex = 6;
    double maxDailyRevenue = 0;
    final startOfChartWeek = startOfToday.subtract(const Duration(days: 6));

    for (var o in orders) {
      if (o.status == 'pending') {
        pendingCount++;
        if (now.difference(o.createdAt).inMinutes > 60) waitingLongCount++;
      } else if (o.status == 'prepared') {
        preparedCount++;
      }

      if (o.status == 'completed') {
        // Filter Comparison for Top Cards
        if (o.createdAt.isAfter(currentPeriodStart) || o.createdAt.isAtSameMomentAs(currentPeriodStart)) {
          currentRevenue += o.totalAmount;
          currentOrders++;
        } else if (o.createdAt.isAfter(previousPeriodStart) && o.createdAt.isBefore(currentPeriodStart)) {
          previousRevenue += o.totalAmount;
          previousOrders++;
        }

        // Weekly Distribution Chart (Always last 7 days ending today)
        if (o.createdAt.isAfter(startOfChartWeek) || o.createdAt.isAtSameMomentAs(startOfChartWeek)) {
          // Calculate the difference in days from the start of the 7-day window
          int dayIndex = o.createdAt.difference(startOfChartWeek).inDays;
          
          // Failsafe bounds check
          if (dayIndex >= 0 && dayIndex < 7) {
            dailyRevenue[dayIndex] += o.totalAmount;
            totalWeekRevenue += o.totalAmount;
          }
        }
      }
    }

    for (int i = 0; i < 7; i++) {
      if (dailyRevenue[i] > maxDailyRevenue) {
        maxDailyRevenue = dailyRevenue[i];
        bestDayIndex = i;
      }
    }

    double revGrowth = previousRevenue == 0 ? 100.0 : ((currentRevenue - previousRevenue) / previousRevenue) * 100;
    int orderDiff = currentOrders - previousOrders;

    return {
      'currentRevenue': currentRevenue,
      'revGrowth': revGrowth,
      'currentOrders': currentOrders,
      'orderDiff': orderDiff,
      'pendingCount': pendingCount,
      'preparedCount': preparedCount,
      'waitingLongCount': waitingLongCount,
      'dailyRevenue': dailyRevenue,
      'totalWeekRevenue': totalWeekRevenue,
      'avgOrder': currentOrders > 0 ? (currentRevenue / currentOrders) : 0.0,
      'bestDayIndex': bestDayIndex,
      'maxDailyRevenue': maxDailyRevenue == 0 ? 1.0 : maxDailyRevenue, 
    };
  }
  String _formatCurrentDate() {
    final now = DateTime.now();
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return "${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year} - Store overview";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8), 
      body: StreamBuilder<List<CustomerOrder>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && _isLoadingTxs) {
            return const Center(child: CircularProgressIndicator(color: Colors.orange));
          }

          final orders = snapshot.data ?? [];
          final metrics = _calculateMetrics(orders);
          
          final allItems = widget.controller.filterInventory(query: "", category: "All");
          final criticalStockItems = allItems.where((item) => item.quantity >= 0 && item.quantity <= 10).toList()
            ..sort((a, b) => a.quantity.compareTo(b.quantity));
          final deadStockItems = allItems.where((item) => item.quantity <= 0).toList();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ─── DASHBOARD HEADER ──────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Dashboard", style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                        const SizedBox(height: 4),
                        Text(_formatCurrentDate(), style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                      ],
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        children: ['Today', '7 Days', '30 Days'].map((filter) {
                          final isSelected = _selectedFilter == filter;
                          return InkWell(
                            onTap: () => setState(() => _selectedFilter = filter),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected ? const Color(0xFF0F172A) : Colors.transparent,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                filter,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                  color: isSelected ? Colors.white : Colors.grey.shade600,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    )
                  ],
                ),
                const SizedBox(height: 24),

                // ─── TOP METRIC CARDS ──────────────────────────────────────
                LayoutBuilder(
                  builder: (context, constraints) {
                    int crossAxisCount = constraints.maxWidth > 1000 ? 4 : (constraints.maxWidth > 600 ? 2 : 1);
                    return GridView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        mainAxisExtent: 160, 
                      ),
                      children: [
                        _buildMetricCard(
                          title: "Revenue",
                          value: "₱${metrics['currentRevenue'].toStringAsFixed(0)}",
                          icon: LucideIcons.dollarSign,
                          iconBg: Colors.green.shade50,
                          iconColor: Colors.green,
                          trendText: "${metrics['revGrowth'].abs().toStringAsFixed(0)}% ${metrics['revGrowth'] >= 0 ? 'vs last period' : 'vs last period'}",
                          isPositiveTrend: metrics['revGrowth'] >= 0,
                        ),
                        _buildMetricCard(
                          title: "Orders Completed",
                          value: "${metrics['currentOrders']}",
                          icon: LucideIcons.shoppingBag,
                          iconBg: Colors.blue.shade50,
                          iconColor: Colors.blue,
                          trendText: "${metrics['orderDiff'].abs()} ${metrics['orderDiff'] >= 0 ? 'more' : 'fewer'} than last period",
                          isPositiveTrend: metrics['orderDiff'] >= 0,
                        ),
                        _buildMetricCard(
                          title: "Low / Critical Stock",
                          value: "${deadStockItems.length} / ${criticalStockItems.length}",
                          icon: LucideIcons.hexagon,
                          iconBg: Colors.orange.shade50,
                          iconColor: Colors.orange,
                          trendText: "Needs restock",
                          isPositiveTrend: false, 
                        ),
                        _buildMetricCard(
                          title: "Pending Orders",
                          value: "${metrics['pendingCount']}",
                          icon: LucideIcons.clock,
                          iconBg: Colors.red.shade50,
                          iconColor: Colors.red,
                          trendText: "${metrics['waitingLongCount']} waiting 60+ days",
                          isPositiveTrend: false,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),

                // ─── MIDDLE SPLIT LAYOUT (Chart & Restock) ─────────────────
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop = constraints.maxWidth > 900;
                    return Flex(
                      direction: isDesktop ? Axis.horizontal : Axis.vertical,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: isDesktop ? 6 : 0,
                          child: _buildSalesChart(metrics),
                        ),
                        if (isDesktop) const SizedBox(width: 16),
                        if (!isDesktop) const SizedBox(height: 16),
                        Expanded(
                          flex: isDesktop ? 4 : 0,
                          child: _buildRestockPriority(criticalStockItems),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),

                // ─── BOTTOM SPLIT LAYOUT (3 Panels) ────────────────────────
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop = constraints.maxWidth > 900;
                    return Flex(
                      direction: isDesktop ? Axis.horizontal : Axis.vertical,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: isDesktop ? 1 : 0,
                          child: _buildTopSellers(allItems),
                        ),
                        if (isDesktop) const SizedBox(width: 16),
                        if (!isDesktop) const SizedBox(height: 16),
                        Expanded(
                          flex: isDesktop ? 1 : 0,
                          child: _buildOrderPipeline(metrics),
                        ),
                        if (isDesktop) const SizedBox(width: 16),
                        if (!isDesktop) const SizedBox(height: 16),
                        Expanded(
                          flex: isDesktop ? 1 : 0,
                          child: _buildRecentActivity(),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 40),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─── WIDGET BUILDERS ───────────────────────────────────────────────────────

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String trendText,
    required bool isPositiveTrend,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title, 
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.w600)
                ),
                const SizedBox(height: 6),
                Text(
                  value, 
                  maxLines: 1, 
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      isPositiveTrend ? LucideIcons.triangle : LucideIcons.triangle,
                      size: 10,
                      color: isPositiveTrend ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        trendText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isPositiveTrend ? Colors.green : Colors.red,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesChart(Map<String, dynamic> metrics) {
    final List<double> dailyRev = metrics['dailyRevenue'];
    final double maxRev = metrics['maxDailyRevenue'];
    final List<String> days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Today'];
    
    final now = DateTime.now();
    int bestDayIndexOffset = 6 - metrics['bestDayIndex'] as int;
    String bestDayStr = bestDayIndexOffset == 0 ? "Today" : ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][now.subtract(Duration(days: bestDayIndexOffset)).weekday - 1];

    return Container(
      height: 380, 
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.barChart2, size: 18, color: Color(0xFF0F172A)),
                  SizedBox(width: 8),
                  Text("Sales — Last 7 Days", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                ],
              ),
              TextButton(
  onPressed: widget.onViewTransactions, // <-- UPDATE THIS
  child: const Text("View Transactions →", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12)),
)
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildChartHeaderMetric("Total", "₱${(metrics['totalWeekRevenue'] as double).toStringAsFixed(0)}"),
              const SizedBox(width: 40),
              _buildChartHeaderMetric("Avg. order", "₱${(metrics['avgOrder'] as double).isNaN ? '0' : (metrics['avgOrder'] as double).toStringAsFixed(0)}"),
              const SizedBox(width: 40),
              _buildChartHeaderMetric("Best day", bestDayStr),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (index) {
                double val = dailyRev[index];
                double barHeight = maxRev == 0 ? 0 : (val / maxRev) * 120; 
                bool isToday = index == 6;
                String formatVal = val >= 1000 ? "${(val/1000).toStringAsFixed(1)}k" : val.toStringAsFixed(0);

                return Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(val == 0 ? "" : formatVal, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      width: 40,
                      height: barHeight == 0 ? 4 : barHeight,
                      decoration: BoxDecoration(
                        color: isToday ? Colors.orange : Colors.orange.shade200,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(days[index], style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: isToday ? FontWeight.bold : FontWeight.normal)),
                  ],
                );
              }),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildChartHeaderMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
      ],
    );
  }

  // ─── STUNNING DIALOG IMPORTED FROM ITEM_DETAIL_PAGE ─────────────────────
  Future<void> _showRestockDialog(InventoryItem item) async {
    final qtyCtrl = TextEditingController();
    final unit = item.unit;
    final allowDecimals = const {
      'kg',
      'g',
      'l',
      'ml',
    }.contains(unit.toLowerCase());
    bool saving = false;
    bool touched = false;
    String? error;

    String? validate(String text) {
      final t = text.trim();
      if (t.isEmpty) return 'Enter the quantity received';
      final v = double.tryParse(t);
      if (v == null) return 'Enter a valid number';
      if (v <= 0) return 'Must be greater than 0';
      return null;
    }

    String fmt(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final value = double.tryParse(qtyCtrl.text.trim());
          final newQty = (value != null && value > 0)
              ? item.quantity + value
              : null;

          Future<void> submit() async {
            touched = true;
            final err = validate(qtyCtrl.text);
            if (err != null) {
              setDialogState(() => error = err);
              return;
            }
            setDialogState(() {
              error = null;
              saving = true;
            });
            try {
              final qty = double.parse(qtyCtrl.text.trim());
              final updated = item.copyWith(
                quantity: item.quantity + qty,
              );
              
              await widget.controller.updateItem(updated);
              
              if (!mounted) return;
              setState(() {}); // Refresh Dashboard Data
              
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Restocked ${item.name}: +${fmt(qty)} $unit '
                    '(now ${fmt(updated.quantity)})',
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            } catch (e) {
              if (dialogContext.mounted) setDialogState(() => saving = false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Restock failed: $e'), backgroundColor: Colors.red),
              );
            }
          }

          void addChip(int n) {
            final next = (double.tryParse(qtyCtrl.text.trim()) ?? 0) + n;
            final text = fmt(next);
            qtyCtrl.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
            setDialogState(() {
              if (touched) error = validate(text);
            });
          }

          OutlineInputBorder border(Color c, [double w = 1]) =>
              OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c, width: w),
              );

          Widget stockSummary(String label, String value, Color color, {bool alignEnd = false}) {
            return Column(
              crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            );
          }

          return AppDialog(
            icon: LucideIcons.packagePlus,
            color: Colors.orange,
            title: 'Restock',
            subtitle: item.name,
            actions: [
              OutlinedButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.grey.shade300),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: saving ? null : submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Add stock',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: stockSummary(
                          'CURRENT',
                          '${fmt(item.quantity)} $unit',
                          const Color(0xFF0F172A),
                        ),
                      ),
                      Icon(
                        LucideIcons.arrowRight,
                        size: 18,
                        color: Colors.grey.shade400,
                      ),
                      Expanded(
                        child: stockSummary(
                          'NEW',
                          newQty == null ? ' ' : '${fmt(newQty)} $unit',
                          newQty == null ? Colors.grey : Colors.orange.shade700,
                          alignEnd: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Quantity received',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons.alertCircle,
                          size: 13,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            error!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: qtyCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: allowDecimals,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(allowDecimals ? r'[0-9.]' : r'[0-9]'),
                    ),
                  ],
                  onChanged: (text) => setDialogState(() {
                    if (touched) error = validate(text);
                  }),
                  onSubmitted: (_) => saving ? null : submit(),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: InputDecoration(
                    hintText: '0',
                    suffixText: unit,
                    suffixStyle: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    enabledBorder: border(
                      error != null ? Colors.red : Colors.grey.shade300,
                    ),
                    focusedBorder: border(
                      error != null ? Colors.red : Colors.orange,
                      1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [1, 5, 10, 50]
                      .map(
                        (n) => ActionChip(
                          label: Text('+$n'),
                          labelStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          backgroundColor: Colors.orange.withOpacity(0.08),
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          onPressed: saving ? null : () => addChip(n),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
    qtyCtrl.dispose();
  }

  Widget _buildRestockPriority(List<InventoryItem> criticalItems) {
    return Container(
      height: 380, 
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.triangleAlert, size: 18, color: Colors.red.shade600),
                  const SizedBox(width: 8),
                  Text("Restock Priority", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.red.shade700)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (criticalItems.isEmpty)
            const Center(child: Text("All stock levels look good!", style: TextStyle(color: Colors.grey)))
          else
            Expanded(
              child: ListView.builder(
                itemCount: criticalItems.length > 4 ? 4 : criticalItems.length,
                itemBuilder: (context, index) {
                  final item = criticalItems[index];
                  String locStr = "Unassigned";
                  List<String> locParts = [];
                  if (item.shelfLevel != null && item.shelfLevel!.isNotEmpty) locParts.add("Shelf ${item.shelfLevel}");
                  if (item.binNumber != null && item.binNumber!.isNotEmpty) locParts.add("Bin ${item.binNumber}");
                  if (locParts.isNotEmpty) locStr = locParts.join(" - ");

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _showRestockDialog(item), // OPEN THE NEW DIALOG MODAL HERE!
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.red.shade100)
                                ),
                                child: Icon(LucideIcons.arrowDown, size: 14, color: Colors.red.shade600),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A)), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    const SizedBox(height: 4),
                                    Text("$locStr · ${item.quantity.toInt()}% of capacity", style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                                    const SizedBox(height: 8),
                                    Stack(
                                      children: [
                                        Container(height: 4, width: double.infinity, decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(2))),
                                        Container(height: 4, width: 40, decoration: BoxDecoration(color: Colors.red.shade500, borderRadius: BorderRadius.circular(2))), 
                                      ],
                                    )
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text("${item.quantity.toInt()} ${item.unit}", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.red.shade700, fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text("Reorder ~40 ${item.unit}", style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
                                ],
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

  // ─── BOTTOM 3 PANELS ───────────────────────────────────────────────────────

  Widget _buildTopSellers(List<InventoryItem> allItems) {
    Map<String, double> sales = {};
    for (var tx in _recentTransactions) {
      if (tx['transaction_type'] == 'checkout') {
        String pid = tx['product_id']?.toString() ?? '';
        sales[pid] = (sales[pid] ?? 0) + (tx['quantity_change'] as num).abs().toDouble();
      }
    }
    
    var sortedSales = sales.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    var top3 = sortedSales.take(3).toList();

    return Container(
      height: 320, // Increased height
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.award, size: 18, color: Color(0xFF0F172A)),
              SizedBox(width: 8),
              Text("Top Sellers", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
            ],
          ),
          const SizedBox(height: 24),
          if (top3.isEmpty)
            const Text("No recent sales data.", style: TextStyle(color: Colors.grey))
          else
            ...top3.asMap().entries.map((entry) {
              int index = entry.key;
              String pId = entry.value.key;
              double qty = entry.value.value;
              
              InventoryItem? item;
              try { item = allItems.firstWhere((i) => i.id == pId); } catch (_) {}
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: index == 0 ? Colors.orange : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text("${index + 1}", style: TextStyle(color: index == 0 ? Colors.white : Colors.grey.shade700, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(item?.name ?? "Unknown Item", style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF0F172A)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text("${qty.toInt()} ${item?.unit ?? 'pcs'}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                        Text("₱${((item?.price ?? 0) * qty).toStringAsFixed(0)}", style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                      ],
                    )
                  ],
                ),
              );
            })
        ],
      ),
    );
  }

  Widget _buildOrderPipeline(Map<String, dynamic> metrics) {
    return Container(
      height: 320, // Increased height
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.alignLeft, size: 18, color: Color(0xFF0F172A)),
                  SizedBox(width: 8),
                  Text("Order Pipeline", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                ],
              ),
              TextButton(
                onPressed: widget.onOpenQueue, // <-- UPDATE THIS
                child: const Text("Open queue →", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12)),
              )
            ],
          ),
          const SizedBox(height: 24),
          _buildPipelineRow("Pending", metrics['pendingCount'], Colors.orange),
          const SizedBox(height: 20),
          _buildPipelineRow("Being prepared", 0, Colors.blue), // Simulation
          const SizedBox(height: 20),
          _buildPipelineRow("Ready for pickup", metrics['preparedCount'], Colors.green),
        ],
      ),
    );
  }

  Widget _buildPipelineRow(String label, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Color(0xFF0F172A))),
        ),
        Text("$count", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Color(0xFF0F172A))),
      ],
    );
  }

  Widget _buildRecentActivity() {
    return Container(
      height: 320, // Increased height
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.history, size: 18, color: Color(0xFF0F172A)),
                  SizedBox(width: 8),
                  Text("Recent Activity", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                ],
              ),
              TextButton(
                onPressed: widget.onViewActivity, // <-- UPDATE THIS
                child: const Text("All →", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12)),
              )
            ],
          ),
          const SizedBox(height: 20),
          if (_isLoadingTxs)
            const Center(child: CircularProgressIndicator())
          else if (_recentTransactions.isEmpty)
            const Text("No recent activity.", style: TextStyle(color: Colors.grey))
          else
            Expanded(
              child: ListView.builder(
                itemCount: _recentTransactions.length > 3 ? 3 : _recentTransactions.length,
                itemBuilder: (context, index) {
                  final tx = _recentTransactions[index];
                  final isPositive = (tx['quantity_change'] as num) > 0;
                  final type = tx['transaction_type'] as String;
                  
                  String pName = "Unknown Item";
                  if (tx['products'] != null) {
                    pName = tx['products']['product_name'] ?? pName;
                  }

                  String uName = "Admin";
                  if (tx['profiles'] != null) {
                    uName = tx['profiles']['name'] ?? uName;
                  }

                  final date = DateTime.parse(tx['created_at']).toLocal();
                  final timeStr = "${date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour)}:${date.minute.toString().padLeft(2, '0')} ${date.hour >= 12 ? 'PM' : 'AM'}";

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: isPositive ? Colors.green.shade50 : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(isPositive ? LucideIcons.plus : LucideIcons.minus, size: 12, color: isPositive ? Colors.green : Colors.red),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("${type.substring(0,1).toUpperCase()}${type.substring(1)} · $pName", style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF0F172A)), maxLines: 1, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 4),
                              Text("$uName · $timeStr", style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                            ],
                          ),
                        ),
                        Text(
                          "${isPositive ? '+' : ''}${tx['quantity_change']}",
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isPositive ? Colors.green : Colors.red),
                        )
                      ],
                    ),
                  );
                },
              ),
            )
        ],
      ),
    );
  }
}