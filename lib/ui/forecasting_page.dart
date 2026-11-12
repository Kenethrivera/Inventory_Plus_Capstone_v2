import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/ai_insights_service.dart';
import '../data/inventory.dart';
import '../logic/forecast_portfolio.dart';
import '../logic/inventory_controller.dart';
import '../services/app_logger.dart';
import '../services/forecasting_api_service.dart';
import 'widgets/app_toast.dart';
import 'widgets/seasonal_learning_laboratory.dart';

class ForecastingPage extends StatefulWidget {
  const ForecastingPage({
    super.key,
    required this.controller,
    required this.aiService,
    required this.isActive,
    this.forecastApi,
  });

  final InventoryController controller;

  /// Retained for optional narrative explanations. It never calculates
  /// forecasts or replenishment quantities.
  final AIInsightsService aiService;
  final bool isActive;
  final ForecastingApiService? forecastApi;

  @override
  State<ForecastingPage> createState() => _ForecastingPageState();
}

class _ForecastingPageState extends State<ForecastingPage> {
  static const _models = <String, String>{
    'calibrated_blend': 'Calibrated blend',
    'lightgbm': 'LightGBM',
    'mean28': 'Mean28',
    'seasonal_experimental': 'Seasonal experimental',
  };

  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  ForecastingApiService? _environmentApi;
  List<InventoryItem> _items = const <InventoryItem>[];
  String? _selectedProductId;
  String _selectedModel = 'calibrated_blend';
  ForecastWindow _selectedWindow = ForecastWindow.next7Days;
  PortfolioForecastSnapshot? _overview;
  Map<String, ForecastAnalysis> _overviewAnalyses = const {};
  List<String> _overviewWarnings = const [];
  String? _overviewError;
  bool _overviewLoading = false;
  bool _overviewStale = false;
  ForecastAnalysis? _analysis;
  String? _error;
  bool _loading = false;
  bool _configuring = false;
  bool _stale = false;
  List<RecommendationTrackingItem> _recommendations = const [];
  String? _recommendationTrackingError;
  bool _recommendationTrackingLoading = false;
  ForecastPerformanceReport? _forecastPerformance;
  String? _forecastPerformanceError;
  bool _forecastPerformanceLoading = false;
  int? _mutatingRecommendationId;
  final Map<int, String> _reconciliationRequestIds = <int, String>{};
  int _overviewGeneration = 0;
  int _detailGeneration = 0;

  @override
  void initState() {
    super.initState();
    _bindInventory();
  }

  @override
  void didUpdateWidget(covariant ForecastingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(_inventorySubscription?.cancel());
      _bindInventory();
    }
    if (!oldWidget.isActive && widget.isActive) {
      _loadOverview();
    } else if (oldWidget.isActive && !widget.isActive) {
      _overviewGeneration++;
      _detailGeneration++;
    }
  }

  void _bindInventory() {
    _acceptInventory(widget.controller.allItems, autoLoad: false);
    _inventorySubscription = widget.controller.streamInventory().listen(
      (_) => _acceptInventory(widget.controller.allItems, autoLoad: true),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          'Forecasting inventory synchronization failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) _loadOverview();
    });
  }

  void _acceptInventory(List<InventoryItem> items, {required bool autoLoad}) {
    if (!mounted) return;
    final sorted = List<InventoryItem>.from(items)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final previousId = _selectedProductId;
    final stillExists = sorted.any((item) => item.id == previousId);
    final nextId = stillExists ? previousId : null;
    setState(() {
      _items = List<InventoryItem>.unmodifiable(sorted);
      _selectedProductId = nextId;
      if (_overview != null) _overviewStale = true;
      if (previousId != null && nextId == previousId && _analysis != null) {
        _stale = true;
      }
      if (nextId != previousId) {
        _analysis = null;
        _error = null;
        _stale = false;
        _recommendations = const [];
        _recommendationTrackingError = null;
        _forecastPerformance = null;
        _forecastPerformanceError = null;
      }
    });
    if (autoLoad && widget.isActive && sorted.isNotEmpty) {
      _loadOverview();
    }
  }

  ForecastingApiService _api() {
    final injected = widget.forecastApi;
    if (injected != null) return injected;
    return _environmentApi ??= ForecastApiClient.fromEnvironment();
  }

  Future<void> _loadOverview() async {
    if (!mounted || !widget.isActive || _overviewLoading) return;
    final locationId = widget.controller.activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      setState(() => _overviewError = 'An active store location is required.');
      return;
    }
    if (_items.isEmpty) {
      setState(() {
        _overview = null;
        _overviewAnalyses = const {};
        _overviewError = 'No inventory products are available for forecasting.';
        _overviewWarnings = const [];
      });
      return;
    }

    final generation = ++_overviewGeneration;
    setState(() {
      _overviewLoading = true;
      _overviewError = null;
      _overviewWarnings = const [];
    });
    final analyses = <String, ForecastAnalysis>{};
    final warnings = <String>[];
    try {
      final token = widget.controller.currentSessionToken;
      Future<
        ({InventoryItem product, ForecastAnalysis? analysis, String? error})
      >
      loadProduct(InventoryItem product) async {
        try {
          final analysis = await _api().analyze(
            productId: product.id,
            locationId: locationId,
            sessionToken: token,
            model: _selectedModel,
          );
          if (analysis.authorizedLocationId != locationId ||
              analysis.product.locationId != locationId ||
              analysis.product.productId != product.id) {
            throw const ForecastApiException(
              'Forecast response scope did not match the inventory product.',
            );
          }
          return (product: product, analysis: analysis, error: null);
        } on ForecastApiException catch (error) {
          return (product: product, analysis: null, error: error.message);
        }
      }

      // Prove one product can retrieve the shared location history and finish
      // forecasting before requesting the rest of the catalog. If the shared
      // data source is unavailable, this prevents 36 additional failing calls.
      final probe = await loadProduct(_items.first);
      if (!mounted || generation != _overviewGeneration) return;
      if (probe.analysis == null) {
        throw ForecastApiException('${probe.product.name}: ${probe.error}');
      }
      analyses[probe.product.id] = probe.analysis!;

      const maxConcurrentAnalyses = 2;
      final remaining = _items.skip(1).toList(growable: false);
      for (
        var start = 0;
        start < remaining.length;
        start += maxConcurrentAnalyses
      ) {
        final end = (start + maxConcurrentAnalyses).clamp(0, remaining.length);
        final batch = remaining.sublist(start, end);
        final results = await Future.wait(batch.map(loadProduct));
        if (!mounted || generation != _overviewGeneration) return;
        for (final result in results) {
          final analysis = result.analysis;
          if (analysis != null) {
            analyses[result.product.id] = analysis;
          } else {
            warnings.add('${result.product.name}: ${result.error}');
          }
        }
      }
      if (!mounted || generation != _overviewGeneration) return;
      if (analyses.isEmpty) {
        throw const ForecastApiException(
          'The Forecast API did not return any product forecasts.',
        );
      }
      setState(() {
        _overview = const PortfolioForecastAggregator().aggregate(
          products: _items,
          analyses: analyses,
          generatedAt: DateTime.now().toUtc(),
        );
        _overviewAnalyses = Map.unmodifiable(analyses);
        final selectedId = _selectedProductId;
        if (selectedId != null && analyses.containsKey(selectedId)) {
          _analysis = analyses[selectedId];
          _stale = false;
        }
        _overviewWarnings = List.unmodifiable(warnings);
        _overviewStale = false;
      });
    } on ForecastApiException catch (error, stackTrace) {
      if (!mounted || generation != _overviewGeneration) return;
      AppLogger.error(
        'Forecast overview request failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _overviewError = error.message);
    } catch (error, stackTrace) {
      if (!mounted || generation != _overviewGeneration) return;
      AppLogger.error(
        'Forecast overview failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(
        () => _overviewError = 'Unable to load the store demand outlook.',
      );
    } finally {
      if (mounted && generation == _overviewGeneration) {
        setState(() => _overviewLoading = false);
      }
    }
  }

  Future<void> _loadAnalysis({
    ColdStartManualEstimateInput? manualEstimate,
  }) async {
    if (!mounted || !widget.isActive || _loading) return;
    final productId = _selectedProductId;
    final locationId = widget.controller.activeLocationId;
    if (productId == null || locationId == null || locationId.isEmpty) {
      setState(() {
        _error = productId == null
            ? 'No inventory product is available for forecasting.'
            : 'An active store location is required.';
      });
      return;
    }

    final generation = ++_detailGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _api().analyze(
        productId: productId,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        model: _selectedModel,
        manualDailyDemand: manualEstimate?.dailyQuantity,
        manualUnit: manualEstimate == null ? null : _selectedItem?.unit,
        manualRationale: manualEstimate?.rationale,
        manualConfirmed: manualEstimate?.staffConfirmed ?? false,
      );
      if (!mounted || generation != _detailGeneration) return;
      if (result.authorizedLocationId != locationId ||
          result.product.locationId != locationId ||
          result.product.productId != productId) {
        throw const ForecastApiException(
          'Forecast response did not match the selected product and location.',
        );
      }
      setState(() {
        _analysis = result;
        _stale = false;
      });
      unawaited(_loadRecommendationTracking(productId: productId));
      unawaited(_loadForecastPerformance(productId: productId));
    } on ForecastApiException catch (error, stackTrace) {
      if (!mounted || generation != _detailGeneration) return;
      AppLogger.error(
        'Forecast API request failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _error = error.message);
    } catch (error, stackTrace) {
      if (!mounted || generation != _detailGeneration) return;
      AppLogger.error(
        'Forecast analysis failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _error = 'Unable to load forecasting data. Try again.');
    } finally {
      if (mounted && generation == _detailGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshDashboard() async {
    await _loadOverview();
  }

  Future<void> _loadRecommendationTracking({String? productId}) async {
    final selectedId = productId ?? _selectedProductId;
    final locationId = widget.controller.activeLocationId;
    if (!mounted ||
        selectedId == null ||
        locationId == null ||
        locationId.isEmpty) {
      return;
    }
    setState(() {
      _recommendationTrackingLoading = true;
      _recommendationTrackingError = null;
    });
    try {
      final items = await _api().loadRecommendationTracking(
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        productId: selectedId,
      );
      if (!mounted || selectedId != _selectedProductId) return;
      setState(() => _recommendations = List.unmodifiable(items));
    } on ForecastApiException catch (error) {
      if (!mounted || selectedId != _selectedProductId) return;
      setState(() {
        _recommendationTrackingError = error.statusCode == 503
            ? 'Recommendation tracking is currently disabled or unavailable. Forecasting remains available.'
            : error.message;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Recommendation tracking load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && selectedId == _selectedProductId) {
        setState(() {
          _recommendationTrackingError =
              'Recommendation history could not be loaded. Forecasting remains available.';
        });
      }
    } finally {
      if (mounted && selectedId == _selectedProductId) {
        setState(() => _recommendationTrackingLoading = false);
      }
    }
  }

  Future<void> _loadForecastPerformance({String? productId}) async {
    final selectedId = productId ?? _selectedProductId;
    final locationId = widget.controller.activeLocationId;
    if (!mounted ||
        selectedId == null ||
        locationId == null ||
        locationId.isEmpty) {
      return;
    }
    setState(() {
      _forecastPerformanceLoading = true;
      _forecastPerformanceError = null;
    });
    try {
      final report = await _api().loadForecastPerformance(
        productId: selectedId,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
      );
      if (!mounted || selectedId != _selectedProductId) return;
      setState(() => _forecastPerformance = report);
    } on ForecastApiException catch (error) {
      if (!mounted || selectedId != _selectedProductId) return;
      setState(() {
        _forecastPerformanceError = error.statusCode == 503
            ? 'Forecast performance monitoring is disabled or unavailable. Live forecasting remains available.'
            : error.message;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Forecast performance load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && selectedId == _selectedProductId) {
        setState(() {
          _forecastPerformanceError =
              'Forecast performance could not be loaded. Live forecasting remains available.';
        });
      }
    } finally {
      if (mounted && selectedId == _selectedProductId) {
        setState(() => _forecastPerformanceLoading = false);
      }
    }
  }

  Future<void> _matchReceipt(RecommendationTrackingItem recommendation) async {
    if (_mutatingRecommendationId != null || recommendation.isReconciled) {
      return;
    }
    final locationId = widget.controller.activeLocationId;
    if (locationId == null || locationId.isEmpty) return;
    List<Map<String, dynamic>> history;
    try {
      history = await widget.controller.loadProductTransactionHistory(
        recommendation.productId,
        force: true,
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'Restock receipt history load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) AppToast.error(context, 'Unable to load restock receipts.');
      return;
    }
    if (!mounted) return;
    final receipts = history
        .where((row) {
          final type = row['transaction_type']?.toString().toLowerCase();
          final quantity = _asDouble(row['quantity_change']);
          final createdAt = DateTime.tryParse(
            row['created_at']?.toString() ?? '',
          );
          return type == 'stock_in' &&
              quantity != null &&
              quantity > 0 &&
              createdAt != null &&
              !createdAt.isBefore(recommendation.recommendationDate);
        })
        .map(RestockReceiptCandidate.fromRow)
        .whereType<RestockReceiptCandidate>()
        .toList(growable: false);
    final selection = await showDialog<ReceiptAllocationSelection>(
      context: context,
      builder: (context) => ReceiptMatchDialog(
        recommendation: recommendation,
        receipts: receipts,
      ),
    );
    if (selection == null || !mounted) return;
    setState(() => _mutatingRecommendationId = recommendation.recommendationId);
    try {
      final result = await _api().matchRecommendationReceipt(
        recommendationId: recommendation.recommendationId,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        transactionHistoryId: selection.receipt.id,
        allocatedInventoryQuantity: selection.quantity,
      );
      if (!mounted) return;
      AppToast.success(
        context,
        result.reused
            ? 'This receipt allocation was already recorded.'
            : 'Restock receipt matched. No inventory movement was created.',
      );
      await _loadRecommendationTracking(productId: recommendation.productId);
    } on ForecastApiException catch (error) {
      if (mounted) AppToast.error(context, error.message);
    } finally {
      if (mounted) setState(() => _mutatingRecommendationId = null);
    }
  }

  Future<void> _reconcile(RecommendationTrackingItem recommendation) async {
    if (_mutatingRecommendationId != null || recommendation.isReconciled) {
      return;
    }
    final note = await showDialog<String>(
      context: context,
      builder: (context) =>
          ReconcileRecommendationDialog(recommendation: recommendation),
    );
    if (note == null || !mounted) return;
    final locationId = widget.controller.activeLocationId;
    if (locationId == null || locationId.isEmpty) return;
    final requestId = _reconciliationRequestIds.putIfAbsent(
      recommendation.recommendationId,
      _newUuid,
    );
    setState(() => _mutatingRecommendationId = recommendation.recommendationId);
    try {
      final result = await _api().reconcileRecommendation(
        recommendationId: recommendation.recommendationId,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        requestId: requestId,
        confirmNoReceipts: recommendation.receiptCount == 0,
        confirmationNote: note.trim().isEmpty ? null : note.trim(),
      );
      if (!mounted) return;
      AppToast.success(
        context,
        result.reused
            ? 'This recommendation was already reconciled.'
            : 'Recommendation comparison finalized.',
      );
      await _loadRecommendationTracking(productId: recommendation.productId);
    } on ForecastApiException catch (error) {
      if (mounted) AppToast.error(context, error.message);
    } finally {
      if (mounted) setState(() => _mutatingRecommendationId = null);
    }
  }

  InventoryItem? get _selectedItem {
    for (final item in _items) {
      if (item.id == _selectedProductId) return item;
    }
    return null;
  }

  Future<void> _enterManualEstimate() async {
    final value = await showDialog<ColdStartManualEstimateInput>(
      context: context,
      builder: (context) =>
          ColdStartManualEstimateDialog(unit: _selectedItem?.unit ?? 'units'),
    );
    if (value != null && mounted) await _loadAnalysis(manualEstimate: value);
  }

  Future<void> _configureReplenishment() async {
    if (!mounted || _configuring) return;
    final productId = _selectedProductId;
    final locationId = widget.controller.activeLocationId;
    if (productId == null || locationId == null || locationId.isEmpty) return;
    setState(() {
      _configuring = true;
      _error = null;
    });
    var saved = false;
    try {
      final current = await _api().getReplenishmentConfiguration(
        productId: productId,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
      );
      if (!mounted) return;
      if (current.productId != productId || current.locationId != locationId) {
        throw const ForecastApiException(
          'Restocking configuration did not match the selected product and location.',
        );
      }
      final input = await showDialog<ReplenishmentConfigurationInput>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ReplenishmentConfigurationDialog(
          configuration: current,
          productName: _selectedItem?.name ?? 'Selected product',
        ),
      );
      if (input == null || !mounted) return;
      final result = await _api().saveReplenishmentConfiguration(
        productId: productId,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        configuration: input,
      );
      if (result.productId != productId || result.locationId != locationId) {
        throw const ForecastApiException(
          'Saved restocking configuration did not match the selected scope.',
        );
      }
      saved = true;
      setState(() {
        _analysis = null;
        _stale = false;
      });
    } on ForecastApiException catch (error, stackTrace) {
      if (!mounted) return;
      AppLogger.error(
        'Restocking configuration failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _error = error.message);
    } catch (error, stackTrace) {
      if (!mounted) return;
      AppLogger.error(
        'Restocking configuration failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() => _error = 'Unable to save restocking inputs. Try again.');
    } finally {
      if (mounted) setState(() => _configuring = false);
    }
    if (saved && mounted) await _refreshDashboard();
  }

  @override
  void dispose() {
    _overviewGeneration++;
    _detailGeneration++;
    unawaited(_inventorySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Demand Outlook',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Store-wide demand trends, category outlook and product replenishment detail',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            const SizedBox(height: 20),
            _buildOverviewControls(),
            const SizedBox(height: 16),
            ForecastOverviewDashboard(
              snapshot: _overview,
              selectedWindow: _selectedWindow,
              loading: _overviewLoading,
              stale: _overviewStale,
              error: _overviewError,
              requestWarnings: _overviewWarnings,
              onRetry: _overviewLoading ? null : _loadOverview,
              onWindowChanged: (value) {
                setState(() => _selectedWindow = value);
              },
            ),
            const SizedBox(height: 24),
            const Text(
              'Product forecast details',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'Select a product only when you need SKU-level demand and replenishment guidance.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            const SizedBox(height: 12),
            _buildProductControls(),
            const SizedBox(height: 16),
            ForecastAnalysisPanel(
              analysis: _analysis,
              loading: _loading,
              error: _error,
              stale: _stale,
              onRetry: _loading ? null : _loadAnalysis,
              onManualEstimate:
                  _analysis?.forecast.isColdStart == true && !_loading
                  ? _enterManualEstimate
                  : null,
            ),
            if (_selectedProductId != null) ...[
              const SizedBox(height: 16),
              RecommendationTrackingPanel(
                items: _recommendations,
                loading: _recommendationTrackingLoading,
                error: _recommendationTrackingError,
                mutatingRecommendationId: _mutatingRecommendationId,
                onRetry: _recommendationTrackingLoading
                    ? null
                    : _loadRecommendationTracking,
                onMatchReceipt: _matchReceipt,
                onReconcile: _reconcile,
              ),
              const SizedBox(height: 16),
              ForecastPerformancePanel(
                report: _forecastPerformance,
                loading: _forecastPerformanceLoading,
                error: _forecastPerformanceError,
                onRetry: _forecastPerformanceLoading
                    ? null
                    : _loadForecastPerformance,
              ),
            ],
            const SizedBox(height: 24),
            SeasonalLearningLaboratory(
              isActive: widget.isActive,
              liveAnalysis: _analysis,
              onLoad: (productId) => _api().loadSeasonalLearningLab(
                sessionToken: widget.controller.currentSessionToken,
                productId: productId,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewControls() {
    return _Card(
      title: 'Store forecast controls',
      icon: LucideIcons.slidersHorizontal,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                key: ValueKey('forecast-model-$_selectedModel'),
                initialValue: _selectedModel,
                decoration: const InputDecoration(
                  labelText: 'Forecast model',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: _models.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(growable: false),
                onChanged: _overviewLoading || _loading
                    ? null
                    : (value) {
                        if (value == null || value == _selectedModel) return;
                        setState(() {
                          _selectedModel = value;
                          _overview = null;
                          _overviewAnalyses = const {};
                          _analysis = null;
                          _overviewError = null;
                          _error = null;
                        });
                        _refreshDashboard();
                      },
              ),
            ),
            FilledButton.icon(
              key: const Key('forecast-overview-refresh'),
              onPressed: _overviewLoading ? null : _refreshDashboard,
              icon: const Icon(LucideIcons.refreshCw, size: 17),
              label: const Text('Refresh outlook'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProductControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          final product = DropdownButtonFormField<String>(
            key: ValueKey('forecast-product-$_selectedProductId'),
            initialValue: _selectedProductId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Product',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: _items
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text('${item.name} (${item.sku})'),
                  ),
                )
                .toList(growable: false),
            onChanged: _loading
                ? null
                : (value) {
                    if (value == null || value == _selectedProductId) return;
                    setState(() {
                      _selectedProductId = value;
                      _analysis = _overviewAnalyses[value];
                      _error = null;
                      _stale = false;
                      _recommendations = const [];
                      _recommendationTrackingError = null;
                      _forecastPerformance = null;
                      _forecastPerformanceError = null;
                    });
                    unawaited(_loadRecommendationTracking(productId: value));
                    unawaited(_loadForecastPerformance(productId: value));
                    if (_analysis == null) _loadAnalysis();
                  },
          );
          final refresh = FilledButton.icon(
            onPressed: _loading || _selectedProductId == null
                ? null
                : _loadAnalysis,
            icon: const Icon(LucideIcons.refreshCw, size: 17),
            label: const Text('Load product detail'),
          );
          final configure = OutlinedButton.icon(
            key: const Key('replenishment-config-open'),
            onPressed: _loading || _configuring || _selectedProductId == null
                ? null
                : _configureReplenishment,
            icon: _configuring
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.settings2, size: 17),
            label: const Text('Restocking inputs'),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                product,
                const SizedBox(height: 12),
                configure,
                const SizedBox(height: 12),
                refresh,
              ],
            );
          }
          return Row(
            children: [
              Expanded(flex: 3, child: product),
              const SizedBox(width: 12),
              configure,
              const SizedBox(width: 12),
              refresh,
            ],
          );
        },
      ),
    );
  }
}

class ForecastOverviewDashboard extends StatelessWidget {
  const ForecastOverviewDashboard({
    super.key,
    required this.snapshot,
    required this.selectedWindow,
    required this.onWindowChanged,
    this.loading = false,
    this.stale = false,
    this.error,
    this.requestWarnings = const [],
    this.onRetry,
  });

  final PortfolioForecastSnapshot? snapshot;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow> onWindowChanged;
  final bool loading;
  final bool stale;
  final String? error;
  final List<String> requestWarnings;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading && snapshot == null) {
      return const SizedBox(
        key: Key('forecast-overview-loading'),
        height: 360,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null && snapshot == null) {
      return _MessageCard(
        icon: LucideIcons.cloudOff,
        title: 'Store demand outlook unavailable',
        message: error!,
        actionLabel: onRetry == null ? null : 'Try again',
        onAction: onRetry,
      );
    }
    final value = snapshot;
    if (value == null) {
      return const _MessageCard(
        icon: LucideIcons.chartNoAxesCombined,
        title: 'Store demand outlook unavailable',
        message: 'No product forecasts are available yet.',
      );
    }

    return Column(
      key: const Key('forecast-overview-dashboard'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale)
          const _Notice(
            color: Colors.orange,
            icon: LucideIcons.refreshCw,
            text:
                'Inventory changed after this outlook was generated. Refresh before planning.',
          ),
        if (error != null)
          _Notice(
            color: Colors.red,
            icon: LucideIcons.triangleAlert,
            text: error!,
          ),
        if (requestWarnings.isNotEmpty)
          _Notice(
            color: Colors.orange,
            icon: LucideIcons.circleAlert,
            text:
                '${requestWarnings.length} product forecast(s) were unavailable. Totals include successful responses only.',
          ),
        _StoreOutlookCard(snapshot: value),
        const SizedBox(height: 16),
        _PeriodSelector(selected: selectedWindow, onChanged: onWindowChanged),
        const SizedBox(height: 16),
        _DemandTrendCard(snapshot: value),
        const SizedBox(height: 16),
        _CategoryOutlookCard(snapshot: value, window: selectedWindow),
        const SizedBox(height: 16),
        _PlanningPriorityCard(snapshot: value),
        const SizedBox(height: 16),
        const IndustryOutlookPanel(),
      ],
    );
  }
}

class _StoreOutlookCard extends StatelessWidget {
  const _StoreOutlookCard({required this.snapshot});

  final PortfolioForecastSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Card(
    title: 'Overall hardware-store demand outlook',
    icon: LucideIcons.store,
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: ForecastWindow.values
            .map(
              (window) => Container(
                key: Key('portfolio-${window.name}'),
                width: 230,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      window.label,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    if (snapshot.byUnit.isEmpty)
                      const Text('No reliable product totals')
                    else
                      ...snapshot.byUnit.values.map(
                        (unit) => Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            '${_quantity(unit.quantityFor(window))} ${unit.unit}',
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1D4ED8),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            )
            .toList(growable: false),
      ),
      const SizedBox(height: 14),
      _Metric('Demand direction', snapshot.overallDirection.label),
      _Metric(
        'Reliable product forecasts',
        '${snapshot.forecastedProducts} of ${snapshot.totalProducts}',
      ),
      _Metric(
        'Cold-start products excluded from totals',
        '${snapshot.coldStartProducts}',
      ),
      _Metric('Model output', snapshot.models.join(', ')),
      _Metric('Data source', snapshot.provenance.join(', ')),
      if (snapshot.reliabilityWarnings.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text(
          'Reliability and policy warnings',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        _WarningList(warnings: snapshot.reliabilityWarnings.take(8).toList()),
      ],
      const SizedBox(height: 8),
      const Text(
        'Quantities are separated by inventory unit. Direction compares days 8–14 with days 1–7 using a ±5% stable band. The 28-day view is a rolling horizon, not an exact calendar month.',
        style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
      ),
    ],
  );
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.selected, required this.onChanged});

  final ForecastWindow selected;
  final ValueChanged<ForecastWindow> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    key: const Key('forecast-period-selector'),
    spacing: 8,
    children: ForecastWindow.values
        .map(
          (window) => ChoiceChip(
            key: Key('forecast-period-${window.name}'),
            label: Text(window.label),
            selected: window == selected,
            onSelected: (_) => onChanged(window),
          ),
        )
        .toList(growable: false),
  );
}

class _DemandTrendCard extends StatelessWidget {
  const _DemandTrendCard({required this.snapshot});

  final PortfolioForecastSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Card(
    title: '28-day demand trend',
    icon: LucideIcons.chartNoAxesCombined,
    children: snapshot.byUnit.isEmpty
        ? const [Text('No reliable daily forecasts are available.')]
        : snapshot.byUnit.values
              .map(
                (unit) => Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${unit.unit} • ${unit.productCount} product(s)',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(unit.direction.label),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 90,
                        child: CustomPaint(
                          key: Key('forecast-trend-${unit.unit}'),
                          painter: _DemandSparklinePainter(unit.daily),
                          size: const Size(double.infinity, 90),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
  );
}

class _DemandSparklinePainter extends CustomPainter {
  const _DemandSparklinePainter(this.points);

  final List<ForecastDailyPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    final axis = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      axis,
    );
    if (points.length < 2) return;
    final maximum = points
        .map((point) => point.quantity)
        .fold<double>(0, (current, value) => value > current ? value : current);
    final scale = maximum <= 0 ? 1.0 : maximum;
    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final x = size.width * index / (points.length - 1);
      final y =
          size.height -
          6 -
          (points[index].quantity / scale) * (size.height - 12);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF2563EB)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _DemandSparklinePainter oldDelegate) =>
      oldDelegate.points != points;
}

class _CategoryOutlookCard extends StatelessWidget {
  const _CategoryOutlookCard({required this.snapshot, required this.window});

  final PortfolioForecastSnapshot snapshot;
  final ForecastWindow window;

  @override
  Widget build(BuildContext context) {
    final highlights = snapshot.highDemandCategories(window);
    return _Card(
      title: 'Product-category demand trends',
      icon: LucideIcons.layoutGrid,
      children: [
        Text(
          'Potential high-demand categories for ${window.label.toLowerCase()}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          'The highest category total is identified separately within each unit; unlike units are not ranked against each other.',
          style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
        ),
        const SizedBox(height: 8),
        if (highlights.isEmpty)
          const Text('No reliable category totals are available.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: highlights
                .map(
                  (value) => Chip(
                    label: Text(
                      '${value.category}: ${_quantity(value.quantity)} ${value.unit}',
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        const Divider(height: 28),
        ...snapshot.categories.map(
          (category) => ExpansionTile(
            key: Key('forecast-category-${category.category}'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              category.category,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              '${category.productCount} product(s) • ${category.coldStartProducts} cold start',
            ),
            children: [
              for (final unit in category.byUnit.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${_quantity(unit.quantityFor(window))} ${unit.unit}',
                  ),
                  trailing: Text(unit.direction.label),
                ),
              if (category.byUnit.isEmpty)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'No reliable totals; review cold-start products.',
                  ),
                ),
            ],
          ),
        ),
        const Text(
          'Categories with different units are displayed separately and are never added together.',
          style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
        ),
      ],
    );
  }
}

class _PlanningPriorityCard extends StatelessWidget {
  const _PlanningPriorityCard({required this.snapshot});

  final PortfolioForecastSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Card(
    title: 'Inventory planning and replenishment priorities',
    icon: LucideIcons.listChecks,
    children: snapshot.priorities.isEmpty
        ? const [Text('No products currently require replenishment review.')]
        : snapshot.priorities
              .take(10)
              .map(
                (priority) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    priority.status == 'recommend_order'
                        ? LucideIcons.packagePlus
                        : LucideIcons.triangleAlert,
                    color: priority.status == 'recommend_order'
                        ? Colors.orange
                        : Colors.red,
                  ),
                  title: Text(priority.productName),
                  subtitle: Text(
                    '${priority.category} • ${priority.status.replaceAll('_', ' ').toUpperCase()}',
                  ),
                  trailing: Text(
                    priority.suggestedQuantity == null
                        ? 'Review'
                        : '${_quantity(priority.suggestedQuantity!)} ${priority.inventoryUnit}',
                  ),
                ),
              )
              .toList(growable: false),
  );
}

class IndustryOutlookPanel extends StatelessWidget {
  const IndustryOutlookPanel({super.key});

  @override
  Widget build(BuildContext context) => const _Card(
    title: 'Hardware and construction industry outlook',
    icon: LucideIcons.landmark,
    children: [
      _Notice(
        color: Colors.blueGrey,
        icon: LucideIcons.databaseZap,
        text:
            'Industry outlook unavailable: no verified external industry feed is configured. No market trend or growth figure is inferred from store SKU forecasts.',
      ),
      SizedBox(height: 12),
      Text(
        'Credible sources identified for a future integration:',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      SizedBox(height: 8),
      Text(
        '• Philippine Statistics Authority Construction Materials Retail Price Index — NCR price indicator, not a demand forecast.\n'
        '• Philippine Statistics Authority approved building-permit statistics — national and regional construction activity, not store-level product demand.',
        style: TextStyle(height: 1.5),
      ),
      SizedBox(height: 8),
      Text(
        'Source attribution, geographic coverage, update date and indicator definitions will be required before any external values are displayed.',
        style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
      ),
    ],
  );
}

class ForecastAnalysisPanel extends StatelessWidget {
  const ForecastAnalysisPanel({
    super.key,
    required this.analysis,
    this.loading = false,
    this.error,
    this.stale = false,
    this.onRetry,
    this.onManualEstimate,
  });

  final ForecastAnalysis? analysis;
  final bool loading;
  final String? error;
  final bool stale;
  final VoidCallback? onRetry;
  final VoidCallback? onManualEstimate;

  @override
  Widget build(BuildContext context) {
    if (loading && analysis == null) {
      return const SizedBox(
        height: 360,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null && analysis == null) {
      return _MessageCard(
        icon: LucideIcons.triangleAlert,
        title: 'Forecast unavailable',
        message: error!,
        actionLabel: onRetry == null ? null : 'Try again',
        onAction: onRetry,
      );
    }
    final value = analysis;
    if (value == null) {
      return const _MessageCard(
        icon: LucideIcons.chartNoAxesCombined,
        title: 'Select a product',
        message: 'Choose a product and model to generate a read-only analysis.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (value.synthetic)
          const _Notice(
            color: Colors.purple,
            icon: LucideIcons.flaskConical,
            text:
                'Development fixture: this result is synthetic and is not evidence of real-store accuracy.',
          ),
        if (stale)
          const _Notice(
            color: Colors.orange,
            icon: LucideIcons.refreshCw,
            text:
                'Inventory changed after this analysis was generated. Refresh before review.',
          ),
        if (error != null)
          _Notice(
            color: Colors.red,
            icon: LucideIcons.triangleAlert,
            text: error!,
          ),
        if (value.forecast.isColdStart)
          _Notice(
            color: Colors.orange,
            icon: LucideIcons.info,
            text: value.forecast.coldStartReason == 'no_history'
                ? 'No historical demand: zero is an unknown-demand placeholder, not confirmed zero customer demand.'
                : 'Insufficient history: the forecast uses explicit cold-start behavior and requires review.',
            actionLabel: onManualEstimate == null
                ? null
                : value.recommendation.manualDemandEstimate == null
                ? 'Enter manual estimate'
                : 'Revise manual estimate',
            onAction: onManualEstimate,
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final forecast = _ForecastCard(analysis: value);
            final recommendation = _RecommendationCard(analysis: value);
            if (constraints.maxWidth < 900) {
              return Column(
                children: [
                  forecast,
                  const SizedBox(height: 16),
                  recommendation,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: forecast),
                const SizedBox(width: 16),
                Expanded(flex: 5, child: recommendation),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.analysis});

  final ForecastAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final forecast = analysis.forecast;
    return _Card(
      title: 'Demand forecast',
      icon: LucideIcons.trendingUp,
      children: [
        Text(
          analysis.product.name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(
          '${analysis.product.sku ?? 'No SKU'} • ${analysis.product.locationId}',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
        const SizedBox(height: 20),
        Text(
          '${_quantity(forecast.totalQuantity)} ${forecast.unit}',
          key: const Key('forecast-total'),
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w900,
            color: Color(0xFF1D4ED8),
          ),
        ),
        Text(
          '${forecast.horizonDays}-day estimate • ${forecast.periodStart} to ${forecast.periodEnd}',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 20,
          runSpacing: 10,
          children: [
            _Metric(
              'Today',
              '${_quantity(forecast.quantityForDays(1))} ${forecast.unit}',
            ),
            _Metric(
              'Next 7 days',
              '${_quantity(forecast.quantityForDays(7))} ${forecast.unit}',
            ),
            _Metric(
              'Next 28 days',
              '${_quantity(forecast.quantityForDays(28))} ${forecast.unit}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 90,
          child: CustomPaint(
            key: const Key('product-demand-trend'),
            painter: _DemandSparklinePainter(forecast.daily),
            size: const Size(double.infinity, 90),
          ),
        ),
        const Divider(height: 28),
        _Metric('Model', '${forecast.model} v${forecast.version}'),
        _Metric(
          'Execution source',
          analysis.synthetic
              ? 'Development fixture backend'
              : 'Live authenticated Supabase-backed API',
        ),
        _Metric(
          'Historical sales context',
          analysis.synthetic
              ? 'Synthetic development fixture'
              : (analysis.product.sku?.startsWith('SIM-') ?? false)
              ? 'Imported synthetic simulation sales (SIM SKU)'
              : 'Supabase sales history (may include staging or test records)',
        ),
        _Metric('Forecast provenance code', forecast.provenance),
        _Metric('Generated', _timestamp(forecast.generatedAt)),
        _Metric('Source data as of', _timestamp(forecast.sourceDataAsOf)),
        if (forecast.isExperimental && forecast.seasonalContext != null) ...[
          const Divider(height: 28),
          Text(
            'Experimental seasonal context',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          _Metric(
            'Seasonal classification',
            forecast.seasonalContext!.seasonalRelevance
                .replaceAll('_', ' ')
                .toUpperCase(),
          ),
          _Metric(
            'Evidence',
            forecast.seasonalContext!.evidenceLevel.replaceAll('_', ' '),
          ),
          _Metric(
            'Upcoming transition',
            forecast.seasonalContext!.nextTransitionDate == null
                ? 'No configured transition found'
                : '${forecast.seasonalContext!.nextTransition?.replaceAll('_', ' ')} '
                      'on ${forecast.seasonalContext!.nextTransitionDate!.toIso8601String().split('T').first}',
          ),
          Text(
            forecast.experimentalFallbackReason == null
                ? 'Seasonal calendar features influence this experimental forecast only. '
                      'No fixed demand multiplier is applied.'
                : 'The experimental model was not used: '
                      '${forecast.experimentalFallbackReason!.replaceAll('_', ' ')}. '
                      'The API safely returned the existing forecasting model.',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            'Replenishment remains calculated from the existing validated LightGBM model.',
            style: TextStyle(
              color: Colors.orange.shade900,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (forecast.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          _WarningList(warnings: forecast.warnings),
        ],
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.analysis});

  final ForecastAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final preliminary = analysis.preliminaryRestockingInsight;
    final recommendation = analysis.recommendation;
    final status = recommendation.status.toUpperCase();
    final MaterialColor statusColor = switch (recommendation.status
        .toLowerCase()) {
      'recommend_order' => Colors.orange,
      'sufficient_inventory' => Colors.green,
      _ => Colors.red,
    };
    return _Card(
      title: 'Replenishment guidance',
      icon: LucideIcons.packagePlus,
      children: [
        Text(
          'Preliminary ${preliminary.planningHorizonDays}-day demand insight',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        const Text(
          'Available without supplier-policy inputs',
          style: TextStyle(color: Color(0xFF475569), fontSize: 12),
        ),
        const SizedBox(height: 14),
        _Metric(
          'Predicted demand',
          _withUnit(preliminary.predictedDemand, preliminary.inventoryUnit),
          key: const Key('preliminary-predicted-demand'),
        ),
        _Metric(
          'Current saleable stock',
          _withUnit(preliminary.availableInventory, preliminary.inventoryUnit),
          key: const Key('preliminary-current-stock'),
        ),
        const SizedBox(height: 4),
        const Text(
          'Preliminary suggested restock',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          _withUnit(
            preliminary.suggestedRestockQuantity,
            preliminary.inventoryUnit,
          ),
          key: const Key('preliminary-suggested-quantity'),
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        Text(
          preliminary.suggestedRestockQuantity == null
              ? 'A quantity is not shown because one or more required demand or inventory values are unavailable.'
              : 'Calculation: max(0, ceiling(predicted demand - current saleable stock)).',
          style: const TextStyle(color: Color(0xFF334155), height: 1.35),
        ),
        const SizedBox(height: 6),
        Text(
          'Forecast basis: ${preliminary.forecastModel} v${preliminary.forecastVersion}. Seasonal Experimental is not used for this quantity.',
          style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
        ),
        if (preliminary.limitations.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final limitation in preliminary.limitations)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '• $limitation',
                key: const Key('preliminary-limitation'),
                style: const TextStyle(color: Color(0xFF9A3412), height: 1.35),
              ),
            ),
        ],
        const SizedBox(height: 12),
        const _Notice(
          color: Colors.orange,
          icon: LucideIcons.triangleAlert,
          text:
              'Preliminary estimate only. It excludes supplier timing, confirmed incoming stock, backorders, safety stock, MOQ, and pack-size rules. Missing incoming or backorder data is not treated as zero. Owner review is required.',
        ),
        const Divider(height: 32),
        const Text(
          'Verified-input replenishment policy',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        Container(
          key: const Key('recommendation-status'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: statusColor.shade50,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: statusColor.shade200),
          ),
          child: Text(
            status,
            style: TextStyle(
              color: statusColor.shade800,
              fontWeight: FontWeight.w900,
              letterSpacing: .4,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _Metric(
          'Current inventory',
          _withUnit(
            recommendation.currentInventory,
            recommendation.inventoryUnit,
          ),
        ),
        _Metric(
          'Inventory position',
          _withUnit(
            recommendation.inventoryPosition,
            recommendation.inventoryUnit,
          ),
        ),
        _Metric(
          'Reorder point',
          _withUnit(recommendation.reorderPoint, recommendation.inventoryUnit),
        ),
        _Metric(
          'Safety stock',
          _withUnit(recommendation.safetyStock, recommendation.inventoryUnit),
        ),
        _Metric(
          'Protection period',
          recommendation.protectionPeriodDays == null
              ? 'Unavailable'
              : '${recommendation.protectionPeriodDays} days',
        ),
        _Metric(
          'Order-up-to target',
          _withUnit(
            recommendation.targetInventory,
            recommendation.inventoryUnit,
          ),
        ),
        const Divider(height: 28),
        const Text(
          'Suggested replenishment',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          recommendation.suggestedOrderQuantity == null
              ? 'Not calculable'
              : '${_quantity(recommendation.suggestedOrderQuantity!)} ${recommendation.orderUnit ?? ''}',
          key: const Key('suggested-quantity'),
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        Text(recommendation.policyMessage),
        const SizedBox(height: 8),
        const Text(
          'Periodic-review policy: the reorder point indicates urgency; the order-up-to target determines quantity. A scheduled top-up may be positive even when stock is above the reorder point.',
          style: TextStyle(fontSize: 12, color: Color(0xFF475569), height: 1.4),
        ),
        if (recommendation.manualDemandEstimate case final manual?) ...[
          const Divider(height: 28),
          const Text(
            'Confirmed cold-start input',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          _Metric(
            'Manual daily demand',
            '${_quantity(manual.dailyQuantity)} ${manual.unit}',
            key: const Key('manual-demand-summary'),
          ),
          _Metric('Source', manual.source.replaceAll('_', ' ')),
          _Metric('Rationale', manual.rationale),
          _Metric('Confirmed', manual.staffConfirmed ? 'Yes' : 'No'),
          _Metric('Confirmed at', _timestamp(manual.confirmedAt)),
          const Text(
            'This provisional input does not create historical sales records.',
            style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
          ),
        ],
        if (recommendation.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          _WarningList(warnings: recommendation.warnings),
        ],
        if (recommendation.explanations.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ExplanationList(explanations: recommendation.explanations),
        ],
        const SizedBox(height: 14),
        const _Notice(
          color: Colors.blue,
          icon: LucideIcons.shieldCheck,
          text:
              'Estimate only. Human approval is required; this page cannot create a purchase order or change inventory.',
        ),
      ],
    );
  }
}

class ForecastPerformancePanel extends StatelessWidget {
  const ForecastPerformancePanel({
    super.key,
    required this.report,
    required this.loading,
    this.error,
    this.onRetry,
  });

  final ForecastPerformanceReport? report;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final value = report;
    final evaluated =
        value?.items.where((item) => item.evaluable).toList(growable: false) ??
        const <ForecastPerformanceItem>[];
    final trend = List<ForecastPerformanceItem>.from(evaluated)
      ..sort((a, b) => a.forecastPeriodEnd.compareTo(b.forecastPeriodEnd));
    return _Card(
      title: 'Forecast Performance',
      icon: LucideIcons.chartNoAxesCombined,
      children: [
        const Text(
          'Compares the original saved 28-day LightGBM prediction with completed customer sales for the same Manila business dates. This is forecast accuracy, not recommendation-versus-restock variance.',
          style: TextStyle(color: Color(0xFF475569), height: 1.4),
        ),
        if (loading) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (error != null) ...[
          const SizedBox(height: 14),
          _Notice(
            color: Colors.orange,
            icon: LucideIcons.info,
            text: error!,
            actionLabel: onRetry == null ? null : 'Retry',
            onAction: onRetry,
          ),
        ],
        if (!loading && error == null && value == null) ...[
          const SizedBox(height: 16),
          const Text('Forecast performance has not been loaded.'),
        ],
        if (!loading && error == null && value != null) ...[
          if (value.dataSourceWarning case final warning?) ...[
            const SizedBox(height: 14),
            _Notice(
              color: Colors.orange,
              icon: LucideIcons.databaseZap,
              text: warning,
            ),
          ],
          if (value.items.isEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'No immutable saved forecasts are available for this product yet.',
              key: Key('forecast-performance-empty'),
            ),
          ],
          for (final summary in value.summariesByUnit) ...[
            const SizedBox(height: 16),
            Container(
              key: ValueKey(
                'forecast-performance-summary-${summary.inventoryUnit}',
              ),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  _Metric(
                    '28-day WAPE (${summary.inventoryUnit})',
                    summary.wape == null
                        ? 'Undefined (actual total is zero)'
                        : '${summary.wape!.toStringAsFixed(1)}%',
                  ),
                  _Metric(
                    'Forecast bias',
                    summary.forecastBias == null
                        ? 'Undefined (actual total is zero)'
                        : '${_signedQuantity(summary.forecastBias!)}%',
                  ),
                  _Metric(
                    'Completed evaluations',
                    '${summary.evaluationCount}',
                  ),
                ],
              ),
            ),
          ],
          if (trend.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Historical signed-error trend (predicted − actual)',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Wrap(
              key: const Key('forecast-error-trend'),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in trend)
                  Chip(
                    label: Text(
                      '${item.forecastPeriodEnd}: ${_signedQuantity(item.signedForecastError!)} ${item.inventoryUnit}',
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          for (final item in value.items) ...[
            const SizedBox(height: 14),
            _ForecastPerformanceCard(item: item),
          ],
          if (value.limitations.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              'Interpretation limits',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final limitation in value.limitations)
              Text('• $limitation', style: const TextStyle(fontSize: 12)),
          ],
        ],
      ],
    );
  }
}

class _ForecastPerformanceCard extends StatelessWidget {
  const _ForecastPerformanceCard({required this.item});

  final ForecastPerformanceItem item;

  @override
  Widget build(BuildContext context) {
    final status = item.evaluationStatus.replaceAll('_', ' ').toUpperCase();
    return Container(
      key: ValueKey('forecast-performance-${item.recommendationId}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${item.productName} • ${item.productSku}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              Chip(label: Text(status), visualDensity: VisualDensity.compact),
            ],
          ),
          const SizedBox(height: 10),
          _Metric(
            'Forecast period',
            '${item.forecastPeriodStart} to ${item.forecastPeriodEnd}',
          ),
          _Metric('Location', item.locationId),
          _Metric(
            'Original model',
            '${item.forecastModel} v${item.forecastVersion} (${item.trainingHistoryDays}-day history)',
          ),
          _Metric(
            'Original saved prediction',
            '${_quantity(item.predictedDemand)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Actual completed sales',
            item.actualCompletedSales == null
                ? 'Not available'
                : '${_quantity(item.actualCompletedSales!)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Signed error (predicted − actual)',
            item.signedForecastError == null
                ? 'Not available'
                : '${_signedQuantity(item.signedForecastError!)} ${item.inventoryUnit} (${item.errorDirection})',
          ),
          _Metric(
            'Absolute error',
            item.absoluteError == null
                ? 'Not available'
                : '${_quantity(item.absoluteError!)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Percentage error',
            item.percentageError == null
                ? 'Undefined when actual sales are zero or unavailable'
                : '${_signedQuantity(item.percentageError!)}%',
          ),
          const SizedBox(height: 8),
          Text(
            item.statusExplanation,
            style: const TextStyle(color: Color(0xFF475569), fontSize: 12),
          ),
          if (item.syntheticSales) ...[
            const SizedBox(height: 8),
            const Text(
              'SIMULATION DATA: This product uses synthetic sales history and does not establish real hardware-store demand accuracy.',
              key: Key('forecast-performance-synthetic-warning'),
              style: TextStyle(
                color: Color(0xFF9A3412),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
          if (!item.stockAvailabilityKnown) ...[
            const SizedBox(height: 6),
            const Text(
              'Stock availability during this period is not proven; completed sales may understate unmet demand during stockouts.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class RecommendationTrackingPanel extends StatelessWidget {
  const RecommendationTrackingPanel({
    super.key,
    required this.items,
    required this.loading,
    required this.mutatingRecommendationId,
    required this.onMatchReceipt,
    required this.onReconcile,
    this.error,
    this.onRetry,
  });

  final List<RecommendationTrackingItem> items;
  final bool loading;
  final String? error;
  final int? mutatingRecommendationId;
  final VoidCallback? onRetry;
  final ValueChanged<RecommendationTrackingItem> onMatchReceipt;
  final ValueChanged<RecommendationTrackingItem> onReconcile;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Saved recommendation tracking',
      icon: LucideIcons.clipboardCheck,
      children: [
        const Text(
          'Compare owner-approved recommendation snapshots with genuine later stock receipts. Restock variance measures a purchasing decision; it is not forecast accuracy.',
          style: TextStyle(color: Color(0xFF475569), height: 1.4),
        ),
        if (loading) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (error != null) ...[
          const SizedBox(height: 14),
          _Notice(
            color: Colors.orange,
            icon: LucideIcons.info,
            text: error!,
            actionLabel: onRetry == null ? null : 'Retry',
            onAction: onRetry,
          ),
        ],
        if (!loading && error == null && items.isEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'No saved recommendations for this product yet.',
            key: Key('recommendation-history-empty'),
          ),
        ],
        for (final item in items) ...[
          const SizedBox(height: 14),
          _RecommendationHistoryCard(
            item: item,
            busy: mutatingRecommendationId == item.recommendationId,
            onMatchReceipt: () => onMatchReceipt(item),
            onReconcile: () => onReconcile(item),
          ),
        ],
      ],
    );
  }
}

class _RecommendationHistoryCard extends StatelessWidget {
  const _RecommendationHistoryCard({
    required this.item,
    required this.busy,
    required this.onMatchReceipt,
    required this.onReconcile,
  });

  final RecommendationTrackingItem item;
  final bool busy;
  final VoidCallback onMatchReceipt;
  final VoidCallback onReconcile;

  @override
  Widget build(BuildContext context) {
    final hasReceipts = item.receiptCount > 0;
    final status = item.evaluationStatus.replaceAll('_', ' ').toUpperCase();
    return Container(
      key: ValueKey('recommendation-history-${item.recommendationId}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${item.productName} • ${item.productSku}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              Chip(label: Text(status), visualDensity: VisualDensity.compact),
            ],
          ),
          const SizedBox(height: 10),
          _Metric('Saved', _timestamp(item.recommendationDate)),
          _Metric(
            'Forecast period',
            '${item.forecastPeriodStart} to ${item.forecastPeriodEnd}',
          ),
          _Metric(
            'Predicted demand',
            '${_quantity(item.predictedDemand)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Inventory when saved',
            '${_quantity(item.availableInventory)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Saved recommendation',
            '${_quantity(item.suggestedQuantity)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Forecast model',
            '${item.forecastModel} v${item.forecastVersion} (${item.trainingHistoryDays}-day history)',
          ),
          if (item.assumptions.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Saved calculation assumptions',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            for (final assumption in item.assumptions)
              Text('• $assumption', style: const TextStyle(fontSize: 12)),
          ],
          const Divider(height: 26),
          _Metric(
            'Matched received quantity',
            hasReceipts
                ? '${_quantity(item.matchedReceivedQuantity!)} ${item.inventoryUnit} across ${item.receiptCount} receipt(s)'
                : 'No receipt matched — received quantity is not assumed to be zero',
          ),
          _Metric(
            'Signed difference (received − suggested)',
            !hasReceipts
                ? 'Unavailable — no matched receipt evidence'
                : item.signedQuantityDifference == null
                ? 'Not finalized'
                : '${_signedQuantity(item.signedQuantityDifference!)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Absolute difference',
            !hasReceipts
                ? 'Unavailable — no matched receipt evidence'
                : item.absoluteDifference == null
                ? 'Not finalized'
                : '${_quantity(item.absoluteDifference!)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Percentage variance',
            !hasReceipts
                ? 'Unavailable — no matched receipt evidence'
                : item.percentageVariance == null
                ? 'Not defined or not finalized'
                : '${item.percentageVariance!.toStringAsFixed(1)}%',
          ),
          if (item.lastReceiptDate != null)
            _Metric(
              'Latest matched receipt',
              _timestamp(item.lastReceiptDate!),
            ),
          const SizedBox(height: 8),
          if (!item.isReconciled)
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : onMatchReceipt,
                  icon: const Icon(LucideIcons.link, size: 16),
                  label: const Text('Match stock receipt'),
                ),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onReconcile,
                  icon: const Icon(LucideIcons.checkCheck, size: 16),
                  label: const Text('Finalize comparison'),
                ),
              ],
            )
          else
            Text(
              hasReceipts
                  ? 'Comparison finalized by the owner. Further receipts cannot be attached.'
                  : 'Comparison finalized without matched receipt evidence. No restock variance is reported.',
              style: const TextStyle(color: Color(0xFF166534), fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class RestockReceiptCandidate {
  const RestockReceiptCandidate({
    required this.id,
    required this.quantity,
    required this.createdAt,
    this.note,
  });

  final String id;
  final double quantity;
  final DateTime createdAt;
  final String? note;

  static RestockReceiptCandidate? fromRow(Map<String, dynamic> row) {
    final id = row['id']?.toString().trim() ?? '';
    final quantity = _asDouble(row['quantity_change']);
    final createdAt = DateTime.tryParse(row['created_at']?.toString() ?? '');
    if (id.isEmpty || quantity == null || quantity <= 0 || createdAt == null) {
      return null;
    }
    return RestockReceiptCandidate(
      id: id,
      quantity: quantity,
      createdAt: createdAt,
      note: row['note']?.toString(),
    );
  }
}

class ReceiptAllocationSelection {
  const ReceiptAllocationSelection({
    required this.receipt,
    required this.quantity,
  });

  final RestockReceiptCandidate receipt;
  final double quantity;
}

class ReceiptMatchDialog extends StatefulWidget {
  const ReceiptMatchDialog({
    super.key,
    required this.recommendation,
    required this.receipts,
  });

  final RecommendationTrackingItem recommendation;
  final List<RestockReceiptCandidate> receipts;

  @override
  State<ReceiptMatchDialog> createState() => _ReceiptMatchDialogState();
}

class _ReceiptMatchDialogState extends State<ReceiptMatchDialog> {
  RestockReceiptCandidate? _selected;
  final _quantityController = TextEditingController();

  @override
  void dispose() {
    _quantityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Match genuine stock receipt'),
      content: SizedBox(
        width: 520,
        child: widget.receipts.isEmpty
            ? const Text(
                'No eligible stock_in receipts exist for this product after the recommendation date.',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Matching links an existing receipt for comparison only. It does not change stock or create a new transaction.',
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<RestockReceiptCandidate>(
                    decoration: const InputDecoration(
                      labelText: 'Existing stock receipt',
                      border: OutlineInputBorder(),
                    ),
                    items: widget.receipts
                        .map(
                          (receipt) => DropdownMenuItem(
                            value: receipt,
                            child: Text(
                              '${_timestamp(receipt.createdAt)} • ${_quantity(receipt.quantity)} ${widget.recommendation.inventoryUnit}',
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      setState(() => _selected = value);
                      if (value != null) {
                        _quantityController.text = _quantity(value.quantity);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText:
                          'Quantity to allocate (${widget.recommendation.inventoryUnit})',
                      border: const OutlineInputBorder(),
                      helperText:
                          'May be less than the receipt for a partial allocation. The server prevents over-allocation.',
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.receipts.isNotEmpty)
          FilledButton(
            onPressed: () {
              final quantity = double.tryParse(_quantityController.text.trim());
              final receipt = _selected;
              if (receipt == null ||
                  quantity == null ||
                  !quantity.isFinite ||
                  quantity <= 0 ||
                  quantity > receipt.quantity) {
                AppToast.error(
                  context,
                  'Select a receipt and enter a positive quantity no greater than that receipt.',
                );
                return;
              }
              Navigator.pop(
                context,
                ReceiptAllocationSelection(
                  receipt: receipt,
                  quantity: quantity,
                ),
              );
            },
            child: const Text('Match receipt'),
          ),
      ],
    );
  }
}

class ReconcileRecommendationDialog extends StatefulWidget {
  const ReconcileRecommendationDialog({
    super.key,
    required this.recommendation,
  });

  final RecommendationTrackingItem recommendation;

  @override
  State<ReconcileRecommendationDialog> createState() =>
      _ReconcileRecommendationDialogState();
}

class _ReconcileRecommendationDialogState
    extends State<ReconcileRecommendationDialog> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final noReceipts = widget.recommendation.receiptCount == 0;
    return AlertDialog(
      title: const Text('Finalize recommendation comparison?'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              noReceipts
                  ? 'No receipt is matched. Confirming finalizes the record without interpreting missing receipts as zero received.'
                  : '${widget.recommendation.receiptCount} receipt(s), totaling ${_quantity(widget.recommendation.matchedReceivedQuantity!)} ${widget.recommendation.inventoryUnit}, are matched.',
            ),
            const SizedBox(height: 12),
            const Text(
              'This finalizes restock variance only. It does not measure forecast accuracy and does not change inventory.',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _noteController,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Owner note (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _noteController.text),
          child: const Text('Finalize'),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey.shade200),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Colors.blue.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ...children,
      ],
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: Colors.grey.shade600)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _WarningList extends StatelessWidget {
  const _WarningList({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Data-quality and policy warnings',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
      for (final warning in warnings)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '• ${warning.replaceAll('_', ' ')}',
            style: const TextStyle(color: Color(0xFF9A3412)),
          ),
        ),
    ],
  );
}

class _ExplanationList extends StatelessWidget {
  const _ExplanationList({required this.explanations});

  final List<String> explanations;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('recommendation-explanations'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'How this guidance was calculated',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
      for (final explanation in explanations)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '• $explanation',
            style: const TextStyle(color: Color(0xFF475569), height: 1.35),
          ),
        ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.color,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final MaterialColor color;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.shade50,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.shade200),
    ),
    child: Row(
      children: [
        Icon(icon, color: color.shade700, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(color: color.shade900)),
        ),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => _Card(
    title: title,
    icon: icon,
    children: [
      Text(message),
      if (actionLabel != null) ...[
        const SizedBox(height: 16),
        OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ],
  );
}

String _quantity(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}

String _withUnit(double? value, String? unit) =>
    value == null ? 'Unavailable' : '${_quantity(value)} ${unit ?? ''}'.trim();

String _timestamp(DateTime value) =>
    value.toLocal().toString().split('.').first;

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String _signedQuantity(double value) =>
    value > 0 ? '+${_quantity(value)}' : _quantity(value);

String _newUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class ColdStartManualEstimateInput {
  const ColdStartManualEstimateInput({
    required this.dailyQuantity,
    required this.rationale,
    required this.staffConfirmed,
  });

  final double dailyQuantity;
  final String rationale;
  final bool staffConfirmed;
}

class ColdStartManualEstimateDialog extends StatefulWidget {
  const ColdStartManualEstimateDialog({super.key, required this.unit});

  final String unit;

  @override
  State<ColdStartManualEstimateDialog> createState() =>
      _ColdStartManualEstimateDialogState();
}

class _ColdStartManualEstimateDialogState
    extends State<ColdStartManualEstimateDialog> {
  final _quantityController = TextEditingController();
  final _rationaleController = TextEditingController();
  bool _staffConfirmed = false;

  double? get _quantity => double.tryParse(_quantityController.text.trim());

  bool get _valid {
    final quantity = _quantity;
    return quantity != null &&
        quantity >= 0 &&
        quantity.isFinite &&
        _rationaleController.text.trim().isNotEmpty &&
        _staffConfirmed;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _rationaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Cold-start demand estimate'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter an explicitly reviewed average daily demand. This is '
            'provisional input, not historical sales evidence.',
          ),
          const SizedBox(height: 12),
          Text(
            'Source: authenticated Admin manual input',
            style: TextStyle(
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('manual-demand-quantity'),
            controller: _quantityController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Daily demand (${widget.unit})',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('manual-demand-rationale'),
            controller: _rationaleController,
            maxLength: 240,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Rationale',
              hintText: 'Example: opening-week shelf plan',
              border: OutlineInputBorder(),
            ),
          ),
          CheckboxListTile(
            key: const Key('manual-demand-confirmation'),
            contentPadding: EdgeInsets.zero,
            value: _staffConfirmed,
            onChanged: (checked) =>
                setState(() => _staffConfirmed = checked == true),
            title: const Text(
              'I confirm this estimate and understand it requires human review.',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('manual-demand-submit'),
        onPressed: _valid
            ? () => Navigator.pop(
                context,
                ColdStartManualEstimateInput(
                  dailyQuantity: _quantity!,
                  rationale: _rationaleController.text.trim(),
                  staffConfirmed: true,
                ),
              )
            : null,
        child: const Text('Use provisional estimate'),
      ),
    ],
  );
}

class ReplenishmentConfigurationDialog extends StatefulWidget {
  const ReplenishmentConfigurationDialog({
    super.key,
    required this.configuration,
    required this.productName,
  });

  final ReplenishmentConfiguration configuration;
  final String productName;

  @override
  State<ReplenishmentConfigurationDialog> createState() =>
      _ReplenishmentConfigurationDialogState();
}

class _ReplenishmentConfigurationDialogState
    extends State<ReplenishmentConfigurationDialog> {
  late final TextEditingController _leadTime;
  late final TextEditingController _reviewPeriod;
  late final TextEditingController _safetyStock;
  late final TextEditingController _moq;
  late final TextEditingController _packSize;
  late final TextEditingController _orderUnit;
  late final TextEditingController _conversion;
  late final TextEditingController _incoming;
  late final TextEditingController _backorders;
  late final TextEditingController _rationale;
  late String _availability;
  late String _dataSource;
  late bool _incomingVerified;
  late bool _backordersVerified;
  bool _confirmed = false;
  String? _validationError;

  String _initialNumber(num? value) => value?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    final value = widget.configuration;
    _leadTime = TextEditingController(
      text: _initialNumber(value.supplierLeadTimeDays),
    );
    _reviewPeriod = TextEditingController(
      text: _initialNumber(value.reviewPeriodDays),
    );
    _safetyStock = TextEditingController(
      text: _initialNumber(value.safetyStock),
    );
    _moq = TextEditingController(
      text: _initialNumber(value.minimumOrderQuantity),
    );
    _packSize = TextEditingController(
      text: _initialNumber(value.supplierPackSize),
    );
    _orderUnit = TextEditingController(text: value.supplierOrderUnit ?? '');
    _conversion = TextEditingController(
      text: _initialNumber(value.unitConversionFactor),
    );
    _incoming = TextEditingController(
      text: _initialNumber(value.confirmedIncomingQuantity),
    );
    _backorders = TextEditingController(
      text: _initialNumber(value.backorderQuantity),
    );
    _rationale = TextEditingController(text: value.rationale ?? '');
    _availability = value.supplierAvailability ?? 'unknown';
    _dataSource = value.dataSource ?? 'admin_estimate';
    _incomingVerified = value.incomingQuantityVerified;
    _backordersVerified = value.backorderQuantityVerified;
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _leadTime,
      _reviewPeriod,
      _safetyStock,
      _moq,
      _packSize,
      _orderUnit,
      _conversion,
      _incoming,
      _backorders,
      _rationale,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _optionalInt(TextEditingController controller, String label) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final value = int.tryParse(text);
    if (value == null || value < 0) {
      throw FormatException('$label must be a nonnegative whole number.');
    }
    return value;
  }

  double? _optionalNumber(
    TextEditingController controller,
    String label, {
    bool positive = false,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null ||
        !value.isFinite ||
        (positive ? value <= 0 : value < 0)) {
      throw FormatException(
        '$label must be a ${positive ? 'positive' : 'nonnegative'} number.',
      );
    }
    return value;
  }

  void _submit() {
    try {
      final leadTime = _optionalInt(_leadTime, 'Lead time');
      final reviewPeriod = _optionalInt(_reviewPeriod, 'Review period');
      final safetyStock = _optionalNumber(_safetyStock, 'Safety stock');
      final moq = _optionalNumber(_moq, 'Minimum order quantity');
      final packSize = _optionalNumber(_packSize, 'Pack size', positive: true);
      final conversion = _optionalNumber(
        _conversion,
        'Unit conversion',
        positive: true,
      );
      final incoming = _optionalNumber(_incoming, 'Incoming quantity');
      final backorders = _optionalNumber(_backorders, 'Backorder quantity');
      final orderUnit = _orderUnit.text.trim();
      final rationale = _rationale.text.trim();
      if ((moq != null || packSize != null) && orderUnit.isEmpty) {
        throw const FormatException(
          'Supplier order unit is required for MOQ or pack size.',
        );
      }
      if (conversion != null && orderUnit.isEmpty) {
        throw const FormatException(
          'Supplier order unit is required for the conversion factor.',
        );
      }
      if (orderUnit.isNotEmpty &&
          orderUnit.toLowerCase() !=
              widget.configuration.inventoryUnit.toLowerCase() &&
          conversion == null) {
        throw const FormatException(
          'Enter how many inventory units are in one supplier order unit.',
        );
      }
      if (_incomingVerified != (incoming != null)) {
        throw const FormatException(
          'Incoming quantity must be entered and explicitly verified together.',
        );
      }
      if (_backordersVerified != (backorders != null)) {
        throw const FormatException(
          'Backorder quantity must be entered and explicitly verified together.',
        );
      }
      if (_dataSource == 'admin_estimate' && rationale.isEmpty) {
        throw const FormatException('Admin estimates require a rationale.');
      }
      if (!_confirmed) {
        throw const FormatException(
          'Confirm the data source and values before saving.',
        );
      }
      Navigator.pop(
        context,
        ReplenishmentConfigurationInput(
          supplierLeadTimeDays: leadTime,
          reviewPeriodDays: reviewPeriod,
          safetyStock: safetyStock,
          minimumOrderQuantity: moq,
          supplierPackSize: packSize,
          supplierOrderUnit: orderUnit.isEmpty ? null : orderUnit,
          unitConversionFactor: conversion,
          confirmedIncomingQuantity: incoming,
          incomingQuantityVerified: _incomingVerified,
          backorderQuantity: backorders,
          backorderQuantityVerified: _backordersVerified,
          supplierAvailability: _availability,
          dataSource: _dataSource,
          sourceCapturedAt: DateTime.now().toUtc(),
          rationale: rationale.isEmpty ? null : rationale,
        ),
      );
    } on FormatException catch (error) {
      setState(() => _validationError = error.message);
    }
  }

  Widget _numberField(
    Key key,
    TextEditingController controller,
    String label,
  ) => TextField(
    key: key,
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final inventoryUnit = widget.configuration.inventoryUnit;
    return AlertDialog(
      title: const Text('Restocking inputs'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.productName} • Inventory unit: $inventoryUnit',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                widget.configuration.configured
                    ? 'Saved ${_timestamp(widget.configuration.updatedAt!)} • '
                          '${widget.configuration.manualEstimate ? 'Admin-provided estimate' : 'Verified record'}'
                    : 'No saved configuration. Leave unknown values blank.',
                key: const Key('replenishment-config-status'),
                style: const TextStyle(color: Color(0xFF475569)),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 220,
                    child: _numberField(
                      const Key('config-lead-time'),
                      _leadTime,
                      'Supplier lead time (days)',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _numberField(
                      const Key('config-review-period'),
                      _reviewPeriod,
                      'Inventory review period (days)',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _numberField(
                      const Key('config-safety-stock'),
                      _safetyStock,
                      'Safety stock ($inventoryUnit)',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      key: const Key('config-order-unit'),
                      controller: _orderUnit,
                      decoration: const InputDecoration(
                        labelText: 'Supplier order unit',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _numberField(
                      const Key('config-moq'),
                      _moq,
                      'Minimum order quantity',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _numberField(
                      const Key('config-pack-size'),
                      _packSize,
                      'Supplier pack size',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _numberField(
                      const Key('config-conversion'),
                      _conversion,
                      'Inventory units per order unit',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String>(
                      key: const Key('config-availability'),
                      initialValue: _availability,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Supplier availability',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'unknown',
                          child: Text('Unknown'),
                        ),
                        DropdownMenuItem(
                          value: 'available',
                          child: Text('Available'),
                        ),
                        DropdownMenuItem(
                          value: 'unavailable',
                          child: Text('Unavailable'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _availability = value ?? 'unknown'),
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),
              _numberField(
                const Key('config-incoming'),
                _incoming,
                'Confirmed incoming quantity ($inventoryUnit)',
              ),
              CheckboxListTile(
                key: const Key('config-incoming-verified'),
                contentPadding: EdgeInsets.zero,
                value: _incomingVerified,
                onChanged: (value) =>
                    setState(() => _incomingVerified = value == true),
                title: const Text('Incoming quantity is verified'),
              ),
              _numberField(
                const Key('config-backorders'),
                _backorders,
                'Verified backorder quantity ($inventoryUnit)',
              ),
              CheckboxListTile(
                key: const Key('config-backorders-verified'),
                contentPadding: EdgeInsets.zero,
                value: _backordersVerified,
                onChanged: (value) =>
                    setState(() => _backordersVerified = value == true),
                title: const Text('Backorder quantity is verified'),
              ),
              const Divider(height: 32),
              DropdownButtonFormField<String>(
                key: const Key('config-data-source'),
                initialValue: _dataSource,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Data source',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'admin_estimate',
                    child: Text('Admin-provided estimate'),
                  ),
                  DropdownMenuItem(
                    value: 'verified_record',
                    child: Text('Verified external record'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => _dataSource = value ?? 'admin_estimate'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('config-rationale'),
                controller: _rationale,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'Source or estimate rationale',
                  border: OutlineInputBorder(),
                ),
              ),
              CheckboxListTile(
                key: const Key('config-save-confirmation'),
                contentPadding: EdgeInsets.zero,
                value: _confirmed,
                onChanged: (value) =>
                    setState(() => _confirmed = value == true),
                title: const Text(
                  'I confirm these values and their source. Saving recalculates guidance but does not create a purchase order or change inventory.',
                ),
              ),
              if (_validationError != null)
                Text(
                  _validationError!,
                  key: const Key('config-validation-error'),
                  style: const TextStyle(color: Colors.red),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('replenishment-config-save'),
          onPressed: _submit,
          child: const Text('Save and recalculate'),
        ),
      ],
    );
  }
}
