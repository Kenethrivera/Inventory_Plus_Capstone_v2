import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import '../data/ai_insights_service.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

class ForecastingPage extends StatefulWidget {
  final InventoryController controller;
  final AIInsightsService aiService;
  final bool isActive;

  const ForecastingPage({
    super.key,
    required this.controller,
    required this.aiService,
    required this.isActive,
  });

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
  bool _aiRecommendationStale = false;
  bool _forecastInsightStale = false;
  bool _initialAIStarted = false;
  int _inventoryRevision = 0;
  int _recommendationGeneration = 0;
  int _forecastGeneration = 0;
  bool _recommendationRefreshQueued = false;
  bool _forecastRefreshQueued = false;
  Future<void>? _recommendationRequestInFlight;
  Future<void>? _forecastRequestInFlight;
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  List<InventoryItem> _inventoryItems = const <InventoryItem>[];

  @override
  void initState() {
    super.initState();
    _bindInventoryState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isActive) return;
      _startInitialAIRequests();
    });
  }

  @override
  void didUpdateWidget(covariant ForecastingPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      unawaited(_inventorySubscription?.cancel());
      _bindInventoryState();
    }

    if (!oldWidget.isActive && widget.isActive) {
      _startInitialAIRequests();
    } else if (oldWidget.isActive && !widget.isActive) {
      _recommendationGeneration++;
      _forecastGeneration++;
      _recommendationRefreshQueued = false;
      _forecastRefreshQueued = false;
      if (_isLoadingAI) _aiRecommendationStale = true;
      if (_isFetchingForecast) _forecastInsightStale = true;
    }
  }

  void _bindInventoryState() {
    _inventoryItems = widget.controller.allItems;
    _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
      if (!mounted) return;
      _inventoryItems = widget.controller.allItems;
      _inventoryRevision++;
      _recommendationGeneration++;
      _forecastGeneration++;
      if (_initialAIStarted) {
        _aiRecommendationStale = true;
        _forecastInsightStale = true;
      }
      if (widget.isActive) {
        setState(() {});
        _startInitialAIRequests();
      }
    });
  }

  String get _sessionScope =>
      '${widget.controller.activeLocationId ?? ''}:'
      '${widget.controller.currentUserId ?? ''}';

  void _startInitialAIRequests() {
    if (_initialAIStarted || !widget.isActive) return;
    _initialAIStarted = true;
    unawaited(_fetchAIRecommendations());
    unawaited(_fetchForecast());
  }

  Future<void> _fetchForecast({bool forceRefresh = false}) {
    if (!mounted || !widget.isActive) return Future<void>.value();

    _forecastGeneration++;
    final inFlight = _forecastRequestInFlight;
    if (inFlight != null) {
      _forecastRefreshQueued = true;
      return inFlight;
    }

    setState(() => _isFetchingForecast = true);
    late final Future<void> request;
    request = _runForecastRequests(forceRefresh: forceRefresh).whenComplete(() {
      if (identical(_forecastRequestInFlight, request)) {
        _forecastRequestInFlight = null;
        if (mounted) setState(() => _isFetchingForecast = false);
      }
    });
    _forecastRequestInFlight = request;
    return request;
  }

  Future<void> _runForecastRequests({required bool forceRefresh}) async {
    do {
      _forecastRefreshQueued = false;
      final generation = _forecastGeneration;
      final revision = _inventoryRevision;
      final scope = _sessionScope;
      final filter = _forecastingFilter;
      final salesData = _inventoryItems
          .map(
            (item) => {
              'name': item.name,
              'current_quantity': item.quantity,
              'max_capacity': item.maxQuantity,
            },
          )
          .toList(growable: false);

      try {
        final result = await widget.aiService.getDemandForecast(
          filter,
          salesData,
          cacheScope: scope,
          forceRefresh: forceRefresh,
        );
        if (!_canPublishForecast(generation, revision, scope, filter)) {
          continue;
        }
        setState(() {
          _forecastInsightText = result;
          _forecastInsightStale = false;
        });
      } catch (error, stackTrace) {
        AppLogger.error(
          'Forecast request failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (_canPublishForecast(generation, revision, scope, filter)) {
          setState(
            () => _forecastInsightText = _safeAiFailure(
              error,
              'Unable to generate the forecast right now. Please try again.',
            ),
          );
        }
      }
    } while (_forecastRefreshQueued && mounted && widget.isActive);
  }

  bool _canPublishForecast(
    int generation,
    int revision,
    String scope,
    String filter,
  ) {
    return mounted &&
        widget.isActive &&
        generation == _forecastGeneration &&
        revision == _inventoryRevision &&
        scope == _sessionScope &&
        filter == _forecastingFilter;
  }

  Future<void> _fetchAIRecommendations({bool forceRefresh = false}) {
    if (!mounted || !widget.isActive) return Future<void>.value();

    _recommendationGeneration++;
    final inFlight = _recommendationRequestInFlight;
    if (inFlight != null) {
      _recommendationRefreshQueued = true;
      return inFlight;
    }

    setState(() => _isLoadingAI = true);
    late final Future<void> request;
    request = _runRecommendationRequests(forceRefresh: forceRefresh)
        .whenComplete(() {
          if (identical(_recommendationRequestInFlight, request)) {
            _recommendationRequestInFlight = null;
            if (mounted) setState(() => _isLoadingAI = false);
          }
        });
    _recommendationRequestInFlight = request;
    return request;
  }

  Future<void> _runRecommendationRequests({required bool forceRefresh}) async {
    do {
      _recommendationRefreshQueued = false;
      final generation = _recommendationGeneration;
      final revision = _inventoryRevision;
      final scope = _sessionScope;
      final criticalItems = _inventoryItems
          .where((item) => item.quantity > 0 && item.quantity <= 10)
          .map((item) => '${item.name} (Current: ${item.quantity})')
          .join(', ');
      final deadItems = _inventoryItems
          .where((item) => item.quantity <= 0)
          .map((item) => item.name)
          .join(', ');

      if (criticalItems.isEmpty && deadItems.isEmpty) {
        if (_canPublishRecommendation(generation, revision, scope)) {
          setState(() {
            _aiRecommendation =
                'All inventory levels are healthy. No items require '
                'immediate restocking!';
            _aiRecommendationStale = false;
          });
        }
        continue;
      }

      try {
        final result = await widget.aiService.getRestockRecommendations(
          criticalItems,
          deadItems,
          cacheScope: scope,
          forceRefresh: forceRefresh,
        );
        if (!_canPublishRecommendation(generation, revision, scope)) {
          continue;
        }
        setState(() {
          _aiRecommendation = result.replaceAll(RegExp(r'\*+'), '').trim();
          _aiRecommendationStale = false;
        });
      } catch (error, stackTrace) {
        AppLogger.error(
          'Restock recommendation request failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (_canPublishRecommendation(generation, revision, scope)) {
          setState(
            () => _aiRecommendation = _safeAiFailure(
              error,
              'Unable to generate the restocking plan right now. Please try again.',
            ),
          );
        }
      }
    } while (_recommendationRefreshQueued && mounted && widget.isActive);
  }

  bool _canPublishRecommendation(int generation, int revision, String scope) {
    return mounted &&
        widget.isActive &&
        generation == _recommendationGeneration &&
        revision == _inventoryRevision &&
        scope == _sessionScope;
  }

  String _safeAiFailure(Object error, String contextualMessage) {
    return switch (AppErrorMapper.categoryFor(error)) {
      AppErrorCategory.network => AppErrorMapper.network,
      AppErrorCategory.timeout => AppErrorMapper.timeout,
      _ => contextualMessage,
    };
  }

  @override
  void dispose() {
    unawaited(_inventorySubscription?.cancel());
    _recommendationGeneration++;
    _forecastGeneration++;
    super.dispose();
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
                            ? LucideIcons.alignHorizontalJustifyStart
                            : LucideIcons.list,
                        color: Colors.blue.shade700,
                        size: 18,
                      ),
                      onPressed: () {
                        setState(() => _isBulletedFormat = !_isBulletedFormat);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    height: 36,
                    width: 36,
                    decoration: BoxDecoration(
                      color: _forecastInsightStale
                          ? Colors.orange.shade50
                          : Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: IconButton(
                      tooltip: _forecastInsightStale
                          ? 'Inventory changed. Refresh forecast.'
                          : 'Refresh forecast',
                      padding: EdgeInsets.zero,
                      onPressed: _isFetchingForecast
                          ? null
                          : () => _fetchForecast(forceRefresh: true),
                      icon: Icon(
                        LucideIcons.refreshCw,
                        color: _forecastInsightStale
                            ? Colors.orange.shade700
                            : Colors.blue.shade700,
                        size: 18,
                      ),
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
          if (_forecastInsightStale) ...[
            const SizedBox(height: 6),
            Text(
              'Inventory changed — refresh this insight.',
              style: TextStyle(
                color: Colors.orange.shade700,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
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
                tooltip: _aiRecommendationStale
                    ? 'Inventory changed. Refresh recommendations.'
                    : 'Refresh recommendations',
                icon: Icon(
                  LucideIcons.refreshCw,
                  color: _aiRecommendationStale ? Colors.amber : Colors.orange,
                  size: 20,
                ),
                onPressed: _isLoadingAI
                    ? null
                    : () => _fetchAIRecommendations(forceRefresh: true),
              ),
            ],
          ),
          if (_aiRecommendationStale)
            const Text(
              'Inventory changed — refresh this plan.',
              style: TextStyle(
                color: Colors.amber,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
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
