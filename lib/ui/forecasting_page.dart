import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import '../data/ai_insights_service.dart';

class ForecastingPage extends StatefulWidget {
  final InventoryController controller;
  const ForecastingPage({super.key, required this.controller});

  @override
  State<ForecastingPage> createState() => _ForecastingPageState();
}

class _ForecastingPageState extends State<ForecastingPage> {
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
    _fetchAIRecommendations();
    _fetchForecast();
  }

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
      if (mounted) setState(() => _forecastInsightText = "Network error: $e");
    } finally {
      if (mounted) setState(() => _isFetchingForecast = false);
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
      if (mounted) setState(() => _aiRecommendation = "Network error: $e");
    } finally {
      if (mounted) setState(() => _isLoadingAI = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Forecasting & Recommendations",
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "AI-powered inventory insights",
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            const SizedBox(height: 24),

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
                    if (isDesktop) const SizedBox(width: 16),
                    if (!isDesktop) const SizedBox(height: 16),
                    Expanded(
                      flex: isDesktop ? 4 : 0,
                      child: _buildAIRecommendations(),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForecastingChart() {
    String insightTitle = _forecastingFilter == 'Season'
        ? "Seasonal High-Demand Predictions"
        : "Next Month Demand Predictions";

    return Container(
      height: 600,
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
              Expanded(
                child: Row(
                  children: [
                    const Icon(
                      LucideIcons.trendingUp,
                      color: Colors.blue,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    const Flexible(
                      child: Text(
                        "AI Demand Forecasting",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                        overflow: TextOverflow.ellipsis,
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
                    width: 36,
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _isBulletedFormat
                            ? LucideIcons.alignHorizontalJustifyStart400
                            : LucideIcons.list,
                        color: Colors.blue.shade700,
                        size: 18,
                      ),
                      onPressed: () {
                        setState(() => _isBulletedFormat = !_isBulletedFormat);
                        _fetchForecast();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
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
                                fontSize: 14,
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
                        icon: const Icon(
                          Icons.arrow_drop_down,
                          color: Colors.blue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            "Uses contextual market data to forecast future demand and optimize restocking.",
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    insightTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.blue.shade900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _isFetchingForecast
                        ? const Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Colors.blue,
                            ),
                          )
                        : SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Text(
                              _forecastInsightText,
                              style: const TextStyle(
                                fontSize: 15,
                                color: Color(0xFF334155),
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
      height: 600,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
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
                    const Icon(
                      LucideIcons.sparkles,
                      color: Colors.orange,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    const Flexible(
                      child: Text(
                        "AI Restocking Plan",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(
                  LucideIcons.refreshCw,
                  color: Colors.orange,
                  size: 20,
                ),
                onPressed: _isLoadingAI ? null : _fetchAIRecommendations,
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
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: _isLoadingAI
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.orange),
                    )
                  : SingleChildScrollView(
                      child: Text(
                        _aiRecommendation,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 15,
                          height: 1.6,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
