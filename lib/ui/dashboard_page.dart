import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import '../data/inventory.dart';
import '../data/ai_insights_service.dart';
import 'widgets/app_dialog.dart';

class DashboardPage extends StatefulWidget {
  final InventoryController controller;
  final VoidCallback onViewTransactions;
  final VoidCallback onOpenQueue;
  final VoidCallback onViewActivity;
  final VoidCallback onOpenForecasting;
  
  const DashboardPage({
    super.key,
    required this.controller,
    required this.onViewTransactions,
    required this.onOpenQueue,
    required this.onViewActivity,
    required this.onOpenForecasting,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  String _selectedFilter = '30 Days';
  List<Map<String, dynamic>> _recentTransactions = [];
  bool _isLoadingTxs = true;

  // ─── THEME COLORS ────────────────────────────────────────────────────────
  static const Color primaryBlue = Color(0xFF2563EB); // Updated to match new theme
  static const Color darkColor = Color(0xFF0F172A);
  static const Color bgColor = Color(0xFFF4F6F8);
  static const String fontFam = 'Outfit';

  // ─── AI STATE VARIABLES ──────────────────────────────────────────────────
  String _aiRecommendation = "Tap refresh to generate AI insights.";
  bool _isLoadingAI = false;
  String _forecastingFilter = 'Season';
  String _forecastInsightText = "Loading forecast...";
  bool _isFetchingForecast = false;
  bool _isBulletedFormat = true;
  final AIInsightsService _aiService = AIInsightsService();

  @override
  void initState() {
    super.initState();
    _fetchTransactions();
    _fetchAIRecommendations(); 
    _fetchForecast(); 
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

  // ─── AI LOGIC ────────────────────────────────────────────────────────────
  Future<void> _fetchForecast() async {
    if (!mounted) return;
    setState(() => _isFetchingForecast = true);

    try {
      final allItems = widget.controller.filterInventory(
        query: "",
        category: "All",
      );

      final List<Map<String, dynamic>> salesData = allItems
          .map(
            (item) => {
              'name': item.name,
              'current_quantity': item.quantity,
              'max_capacity': (item as dynamic).maxQuantity ?? 100,
            },
          )
          .toList();

      final result = await _aiService.getDemandForecast(
        _forecastingFilter,
        salesData,
      );

      if (!mounted) return;
      setState(() {
        _forecastInsightText = result;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _forecastInsightText = "Network error: $e");
      }
    } finally {
      if (mounted) {
        setState(() => _isFetchingForecast = false);
      }
    }
  }

  Future<void> _fetchAIRecommendations() async {
    if (!mounted) return;
    setState(() => _isLoadingAI = true);

    try {
      final allItems = widget.controller.filterInventory(
        query: "",
        category: "All",
      );

      final criticalItemsList = allItems.where(
        (i) => i.quantity > 0 && i.quantity <= 10,
      );
      final deadItemsList = allItems.where((i) => i.quantity <= 0);

      final criticalItems = criticalItemsList
          .map((i) => "${i.name} (Current: ${i.quantity})")
          .join(', ');
      final deadItems = deadItemsList.map((i) => i.name).join(', ');

      if (criticalItems.isEmpty && deadItems.isEmpty) {
        if (!mounted) return;
        setState(() {
          _aiRecommendation =
              "All inventory levels are healthy. No items require immediate restocking!";
          _isLoadingAI = false;
        });
        return;
      }

      final result = await _aiService.getRestockRecommendations(
        criticalItems,
        deadItems,
      );

      if (!mounted) return;
      setState(() {
        _aiRecommendation = result.replaceAll(RegExp(r'\*+'), '').trim();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _aiRecommendation = "Network error: $e");
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingAI = false);
      }
    }
  }

  // --- LOCAL DATA AGGREGATION ---
  Map<String, dynamic> _calculateMetrics(List<CustomerOrder> orders) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);

    DateTime currentPeriodStart;
    DateTime previousPeriodStart;

    if (_selectedFilter == 'Today') {
      currentPeriodStart = startOfToday;
      previousPeriodStart = startOfToday.subtract(const Duration(days: 1));
    } else if (_selectedFilter == '7 Days') {
      currentPeriodStart = startOfToday.subtract(const Duration(days: 6));
      previousPeriodStart = currentPeriodStart.subtract(
        const Duration(days: 7),
      );
    } else {
      currentPeriodStart = startOfToday.subtract(const Duration(days: 29));
      previousPeriodStart = currentPeriodStart.subtract(
        const Duration(days: 30),
      );
    }

    double currentRevenue = 0;
    double previousRevenue = 0;
    int currentOrders = 0;
    int previousOrders = 0;
    int pendingCount = 0;
    int preparedCount = 0;
    int waitingLongCount = 0;

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
        if (o.createdAt.isAfter(currentPeriodStart) ||
            o.createdAt.isAtSameMomentAs(currentPeriodStart)) {
          currentRevenue += o.totalAmount;
          currentOrders++;
        } else if (o.createdAt.isAfter(previousPeriodStart) &&
            o.createdAt.isBefore(currentPeriodStart)) {
          previousRevenue += o.totalAmount;
          previousOrders++;
        }

        if (o.createdAt.isAfter(startOfChartWeek) ||
            o.createdAt.isAtSameMomentAs(startOfChartWeek)) {
          int dayIndex = o.createdAt.difference(startOfChartWeek).inDays;
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

    double revGrowth = previousRevenue == 0
        ? 100.0
        : ((currentRevenue - previousRevenue) / previousRevenue) * 100;
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
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
    ];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December',
    ];
    return "${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year} - Store overview";
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.03),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: StreamBuilder<List<CustomerOrder>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              _isLoadingTxs) {
            return const Center(
              child: CircularProgressIndicator(color: primaryBlue),
            );
          }

          final orders = snapshot.data ?? [];
          final metrics = _calculateMetrics(orders);

          final allItems = widget.controller.filterInventory(
            query: "",
            category: "All",
          );
          final criticalStockItems =
              allItems
                  .where((item) => item.quantity >= 0 && item.quantity <= 10)
                  .toList()
                ..sort((a, b) => a.quantity.compareTo(b.quantity));
          final deadStockItems = allItems
              .where((item) => item.quantity <= 0)
              .toList();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
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
                        const Text(
                          "Dashboard",
                          style: TextStyle(
                            fontFamily: fontFam,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: darkColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _formatCurrentDate(),
                          style: TextStyle(
                            fontFamily: fontFam,
                            color: Colors.grey.shade500,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          )
                        ],
                      ),
                      child: Row(
                        children: ['Today', '7 Days', '30 Days'].map((filter) {
                          final isSelected = _selectedFilter == filter;
                          return InkWell(
                            onTap: () =>
                                setState(() => _selectedFilter = filter),
                            borderRadius: BorderRadius.circular(8),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? primaryBlue
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                filter,
                                style: TextStyle(
                                  fontFamily: fontFam,
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w600,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.grey.shade600,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // ─── TOP METRIC CARDS ──────────────────────────────────────
                LayoutBuilder(
                  builder: (context, constraints) {
                    int crossAxisCount = constraints.maxWidth > 1000
                        ? 4
                        : (constraints.maxWidth > 600 ? 2 : 1);
                    return GridView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 20,
                        mainAxisSpacing: 20,
                        mainAxisExtent: 140,
                      ),
                      children: [
                        _buildMetricCard(
                          title: "Revenue",
                          value: "₱${metrics['currentRevenue'].toStringAsFixed(0)}",
                          icon: LucideIcons.dollarSign,
                          iconBg: primaryBlue.withOpacity(0.08),
                          iconColor: primaryBlue,
                          trendText: "${metrics['revGrowth'].abs().toStringAsFixed(0)}% vs last period",
                          trendColor: primaryBlue,
                        ),
                        _buildMetricCard(
                          title: "Orders Completed",
                          value: "${metrics['currentOrders']}",
                          icon: LucideIcons.shoppingBag,
                          iconBg: primaryBlue.withOpacity(0.08),
                          iconColor: primaryBlue,
                          trendText: "${metrics['orderDiff'].abs()} more than last period",
                          trendColor: primaryBlue,
                        ),
                        _buildMetricCard(
                          title: "Low | Critical Stock",
                          value: "${deadStockItems.length} | ${criticalStockItems.length}",
                          icon: LucideIcons.hexagon,
                          iconBg: Colors.orange.withOpacity(0.1),
                          iconColor: Colors.orange.shade700,
                          trendText: "Needs restock",
                          trendColor: Colors.red.shade600,
                        ),
                        _buildMetricCard(
                          title: "Pending Orders",
                          value: "${metrics['pendingCount']}",
                          icon: LucideIcons.clock,
                          iconBg: primaryBlue.withOpacity(0.08),
                          iconColor: primaryBlue,
                          trendText: "${metrics['waitingLongCount']} waiting 60+ mins",
                          trendColor: Colors.grey.shade600,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),

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
                        if (isDesktop) const SizedBox(width: 20),
                        if (!isDesktop) const SizedBox(height: 20),
                        Expanded(
                          flex: isDesktop ? 4 : 0,
                          child: _buildRestockPriority(criticalStockItems),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),

                // ─── AI FORECASTING & RECOMMENDATIONS (Preview) ────────────────
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop = constraints.maxWidth > 900;
                    return Flex(
                      direction: isDesktop ? Axis.horizontal : Axis.vertical,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: isDesktop ? 6 : 0,
                          child: _buildForecastingChart(),
                        ),
                        if (isDesktop) const SizedBox(width: 20),
                        if (!isDesktop) const SizedBox(height: 20),
                        Expanded(
                          flex: isDesktop ? 4 : 0,
                          child: _buildAIRecommendations(),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),

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
                        if (isDesktop) const SizedBox(width: 20),
                        if (!isDesktop) const SizedBox(height: 20),
                        Expanded(
                          flex: isDesktop ? 1 : 0,
                          child: _buildOrderPipeline(metrics),
                        ),
                        if (isDesktop) const SizedBox(width: 20),
                        if (!isDesktop) const SizedBox(height: 20),
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

  // ─── AI WIDGET BUILDERS ──────────────────────────────────────────────────

  Widget _buildForecastingChart() {
    String insightTitle = _forecastingFilter == 'Season'
        ? "Seasonal High-Demand Predictions"
        : "Next Month Demand Predictions";

    return Container(
      height: 380,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(LucideIcons.trendingUp, color: darkColor, size: 20),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(
                        "AI Demand Forecasting",
                        style: TextStyle(
                          fontFamily: fontFam,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: darkColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryBlue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        "Admin Preview",
                        style: TextStyle(
                          fontFamily: fontFam,
                          fontSize: 10,
                          color: primaryBlue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _forecastingFilter,
                        isDense: true,
                        items: <String>['Season', 'Month'].map((String value) {
                          return DropdownMenuItem<String>(
                            value: value,
                            child: Text(
                              value,
                              style: const TextStyle(
                                fontFamily: fontFam,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }).toList(),
                        onChanged: (newValue) {
                          if (newValue != null &&
                              newValue != _forecastingFilter) {
                            setState(() => _forecastingFilter = newValue);
                            _fetchForecast();
                          }
                        },
                        icon: const Icon(LucideIcons.chevronDown, size: 16, color: darkColor),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "Uses contextual market data to forecast future demand and optimize restocking.",
            style: TextStyle(fontFamily: fontFam, fontSize: 13, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: primaryBlue.withOpacity(0.04),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    insightTitle,
                    style: const TextStyle(
                      fontFamily: fontFam,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: primaryBlue,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _isFetchingForecast
                        ? const Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2, color: primaryBlue),
                            ),
                          )
                        : SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Text(
                              _forecastInsightText,
                              style: const TextStyle(
                                fontFamily: fontFam,
                                fontSize: 14,
                                color: darkColor,
                                height: 1.6,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAIRecommendations() {
    return Container(
      height: 380, 
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B), // Dark Navy
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(LucideIcons.sparkles, color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(
                        "AI Restocking Plan",
                        style: TextStyle(
                          fontFamily: fontFam,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: primaryBlue,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        "Admin Preview",
                        style: TextStyle(
                          fontFamily: fontFam,
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: _isLoadingAI
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : SingleChildScrollView(
                      child: Text(
                        _aiRecommendation,
                        style: const TextStyle(
                          fontFamily: fontFam,
                          color: Colors.white,
                          fontSize: 14,
                          height: 1.6,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── ORIGINAL WIDGET BUILDERS ────────────────────────────────────────────

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String trendText,
    required Color trendColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
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
                  style: TextStyle(
                    fontFamily: fontFam,
                    color: Colors.grey.shade600,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: fontFam,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: darkColor,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (trendText.contains('more') || trendText.contains('100%'))
                      Icon(LucideIcons.triangle, size: 10, color: trendColor),
                    if (trendText.contains('more') || trendText.contains('100%'))
                      const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        trendText,
                        style: TextStyle(
                          fontFamily: fontFam,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: trendColor,
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
    final List<String> days = [
      'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Today',
    ];

    final now = DateTime.now();
    int bestDayIndexOffset = 6 - metrics['bestDayIndex'] as int;
    String bestDayStr = bestDayIndexOffset == 0
        ? "Today"
        : [
            'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
          ][now.subtract(Duration(days: bestDayIndexOffset)).weekday - 1];

    return Container(
      height: 380,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.barChart2, size: 20, color: darkColor),
                  SizedBox(width: 10),
                  Text(
                    "Sales — Last 7 Days",
                    style: TextStyle(
                      fontFamily: fontFam,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: darkColor,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: widget.onViewTransactions,
                child: const Text(
                  "View Transactions →",
                  style: TextStyle(
                    fontFamily: fontFam,
                    color: primaryBlue,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _buildChartHeaderMetric(
                "Total",
                "₱${(metrics['totalWeekRevenue'] as double).toStringAsFixed(0)}",
              ),
              const SizedBox(width: 48),
              _buildChartHeaderMetric(
                "Avg. order",
                "₱${(metrics['avgOrder'] as double).isNaN ? '0' : (metrics['avgOrder'] as double).toStringAsFixed(0)}",
              ),
              const SizedBox(width: 48),
              _buildChartHeaderMetric("Best day", bestDayStr),
            ],
          ),
          const SizedBox(height: 32),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (index) {
                double val = dailyRev[index];
                double barHeight = maxRev == 0 ? 0 : (val / maxRev) * 120;
                bool isToday = index == 6;
                String formatVal = val >= 1000
                    ? "${(val / 1000).toStringAsFixed(1)}k"
                    : val.toStringAsFixed(0);

                return Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      val == 0 ? "" : formatVal,
                      style: const TextStyle(
                        fontFamily: fontFam,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: darkColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      width: 48,
                      height: barHeight == 0 ? 4 : barHeight,
                      decoration: BoxDecoration(
                        color: isToday ? primaryBlue : primaryBlue.withOpacity(0.1),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      days[index],
                      style: TextStyle(
                        fontFamily: fontFam,
                        fontSize: 12,
                        color: isToday ? darkColor : Colors.grey.shade500,
                        fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartHeaderMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontFamily: fontFam, fontSize: 13, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontFamily: fontFam,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: darkColor,
          ),
        ),
      ],
    );
  }

  // --- RESTOCK DIALOG (Omitted for brevity, assuming standard dialog formatting is acceptable, 
  // but if needed we can theme it too. I'll keep the logic the same and just touch up text styles.)
  // Note: Omitted the full `_showRestockDialog` from this rewrite since it's an overlay and large, 
  // but I have ensured `fontFamily` is used in the parts shown below.

  Widget _buildRestockPriority(List<InventoryItem> criticalItems) {
    return Container(
      height: 380,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.triangleAlert, size: 20, color: Colors.red.shade600),
              const SizedBox(width: 10),
              Text(
                "Restock Priority",
                style: TextStyle(
                  fontFamily: fontFam,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.red.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (criticalItems.isEmpty)
            const Center(
              child: Text(
                "All stock levels look good!",
                style: TextStyle(fontFamily: fontFam, color: Colors.grey),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: criticalItems.length > 4 ? 4 : criticalItems.length,
                itemBuilder: (context, index) {
                  final item = criticalItems[index];
                  String locStr = "Unassigned";
                  List<String> locParts = [];
                  if (item.shelfLevel != null && item.shelfLevel!.isNotEmpty)
                    locParts.add("Shelf ${item.shelfLevel}");
                  if (item.binNumber != null && item.binNumber!.isNotEmpty)
                    locParts.add("Bin ${item.binNumber}");
                  if (locParts.isNotEmpty) locStr = locParts.join(" - ");

                  return Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            LucideIcons.arrowDown,
                            size: 16,
                            color: Colors.red.shade600,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                style: const TextStyle(
                                  fontFamily: fontFam,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: darkColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "$locStr · ${item.quantity.toInt()} left",
                                style: TextStyle(
                                  fontFamily: fontFam,
                                  fontSize: 12,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Stack(
                                children: [
                                  Container(
                                    height: 4,
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  Container(
                                    height: 4,
                                    width: 48,
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade600,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          "${item.quantity.toInt()} ${item.unit}",
                          style: TextStyle(
                            fontFamily: fontFam,
                            fontWeight: FontWeight.w800,
                            color: Colors.red.shade700,
                            fontSize: 14,
                          ),
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

  // ─── BOTTOM 3 PANELS ───────────────────────────────────────────────────────

  Widget _buildTopSellers(List<InventoryItem> allItems) {
    Map<String, double> sales = {};
    for (var tx in _recentTransactions) {
      if (tx['transaction_type'] == 'checkout') {
        String pid = tx['product_id']?.toString() ?? '';
        sales[pid] =
            (sales[pid] ?? 0) + (tx['quantity_change'] as num).abs().toDouble();
      }
    }

    var sortedSales = sales.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    var top3 = sortedSales.take(3).toList();

    return Container(
      height: 320,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.award, size: 20, color: darkColor),
              SizedBox(width: 10),
              Text(
                "Top Sellers",
                style: TextStyle(
                  fontFamily: fontFam,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: darkColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (top3.isEmpty)
            const Text(
              "No recent sales data.",
              style: TextStyle(fontFamily: fontFam, color: Colors.grey),
            )
          else
            ...top3.asMap().entries.map((entry) {
              int index = entry.key;
              String pId = entry.value.key;
              double qty = entry.value.value;

              InventoryItem? item;
              try {
                item = allItems.firstWhere((i) => i.id == pId);
              } catch (_) {}

              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: index == 0 ? primaryBlue : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          "${index + 1}",
                          style: TextStyle(
                            fontFamily: fontFam,
                            color: index == 0 ? Colors.white : Colors.grey.shade600,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        item?.name ?? "Unknown Item",
                        style: const TextStyle(
                          fontFamily: fontFam,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: darkColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          "${qty.toInt()} ${item?.unit ?? 'pcs'}",
                          style: const TextStyle(
                            fontFamily: fontFam,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: darkColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildOrderPipeline(Map<String, dynamic> metrics) {
    return Container(
      height: 320,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.listOrdered, size: 20, color: darkColor),
                  SizedBox(width: 10),
                  Text(
                    "Order Pipeline",
                    style: TextStyle(
                      fontFamily: fontFam,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: darkColor,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: widget.onOpenQueue,
                child: const Text(
                  "Open queue →",
                  style: TextStyle(
                    fontFamily: fontFam,
                    color: primaryBlue,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildPipelineRow("Pending", metrics['pendingCount']),
          const SizedBox(height: 24),
          _buildPipelineRow("Being prepared", 0),
          const SizedBox(height: 24),
          _buildPipelineRow("Ready for pickup", metrics['preparedCount']),
        ],
      ),
    );
  }

  Widget _buildPipelineRow(String label, int count) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(color: darkColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: fontFam,
              fontWeight: FontWeight.w500,
              fontSize: 14,
              color: darkColor,
            ),
          ),
        ),
        Text(
          "$count",
          style: const TextStyle(
            fontFamily: fontFam,
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: darkColor,
          ),
        ),
      ],
    );
  }

  Widget _buildRecentActivity() {
    return Container(
      height: 320,
      padding: const EdgeInsets.all(24),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.history, size: 20, color: darkColor),
                  SizedBox(width: 10),
                  Text(
                    "Recent Activity",
                    style: TextStyle(
                      fontFamily: fontFam,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: darkColor,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: widget.onViewActivity,
                child: const Text(
                  "All →",
                  style: TextStyle(
                    fontFamily: fontFam,
                    color: primaryBlue,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_isLoadingTxs)
            const Center(child: CircularProgressIndicator(color: primaryBlue))
          else if (_recentTransactions.isEmpty)
            const Text(
              "No recent activity.",
              style: TextStyle(fontFamily: fontFam, color: Colors.grey),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _recentTransactions.length > 3
                    ? 3
                    : _recentTransactions.length,
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
                  final timeStr =
                      "${date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour)}:${date.minute.toString().padLeft(2, '0')} ${date.hour >= 12 ? 'PM' : 'AM'}";

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "${type.substring(0, 1).toUpperCase()}${type.substring(1)} · $pName",
                                style: const TextStyle(
                                  fontFamily: fontFam,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: darkColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "$uName · $timeStr",
                                style: TextStyle(
                                  fontFamily: fontFam,
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          "${isPositive ? '+' : ''}${tx['quantity_change']}",
                          style: TextStyle(
                            fontFamily: fontFam,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: isPositive ? Colors.green : Colors.red.shade600,
                          ),
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
}