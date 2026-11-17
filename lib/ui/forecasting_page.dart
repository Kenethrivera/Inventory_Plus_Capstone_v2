import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:crypto/crypto.dart';

import '../data/ai_insights_service.dart';
import '../data/inventory.dart';
import '../logic/forecast_portfolio.dart';
import '../logic/history_pagination.dart';
import '../logic/inventory_controller.dart';
import '../services/app_logger.dart';
import '../services/forecasting_api_service.dart';
import '../services/forecasting_performance_diagnostics.dart';
import 'widgets/app_toast.dart';

const _forecastInk = Color(0xFF1C1917);
const _forecastBody = Color(0xFF44403C);
const _forecastMuted = Color(0xFF78716C);
const _forecastFaint = Color(0xFFA8A29E);
const _forecastLine = Color(0xFFE7E5E4);
const _forecastHairline = Color(0xFFF0EFED);
const _forecastAccent = Color(0xFFEA580C);
const _forecastAccentDark = Color(0xFFC2410C);
const _forecastAccentSoft = Color(0xFFFFF4EC);
const _forecastBackground = Color(0xFFF7F7F6);

const _trackingInk = Color(0xFF1C2230);
const _trackingBody = Color(0xFF3D4555);
const _trackingMuted = Color(0xFF6B7280);
const _trackingFaint = Color(0xFF9AA1AD);
const _trackingLine = Color(0xFFE7E9EE);
const _trackingLineStrong = Color(0xFFD5D9E0);
const _trackingAccent = Color(0xFFEA6A10);
const _trackingAccentStrong = Color(0xFFC2550A);
const _trackingAccentSoft = Color(0xFFFFF3EA);
const _trackingSubtle = Color(0xFFF9FAFB);
const _forecastOverviewTrace = bool.fromEnvironment('FORECAST_OVERVIEW_TRACE');

enum _ForecastingView { overview, product, tracking }

enum _TrackingSection { records, accuracy }

typedef _AnalysisRequestKey = ({
  InventoryController controller,
  ForecastingApiService api,
  String userId,
  String sessionDigest,
  String locationId,
  String productId,
  String inventoryUnit,
  double inventoryQuantity,
  String model,
  int horizonDays,
  double? manualDailyDemand,
  String? manualUnit,
  String? manualRationale,
  bool manualConfirmed,
  int dataGeneration,
});

class _CachedForecastAnalysis {
  _CachedForecastAnalysis(this.analysis) : age = Stopwatch()..start();

  final ForecastAnalysis analysis;
  final Stopwatch age;
}

extension on _ForecastingView {
  String get label => switch (this) {
    _ForecastingView.overview => 'Overview',
    _ForecastingView.product => 'Product Forecast',
    _ForecastingView.tracking => 'Tracking & Accuracy',
  };

  String get description => switch (this) {
    _ForecastingView.overview =>
      'Store-wide demand outlook and evidence-backed planning priorities.',
    _ForecastingView.product =>
      'Future demand and owner-facing restocking guidance for one product.',
    _ForecastingView.tracking =>
      'Saved restock records and completed forecast performance.',
  };
}

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
  // Page loading always reads saved forecasts. The synchronous API remains
  // available to explicit compatibility clients, never to widget lifecycle.
  bool get _useSavedForecasts => true;

  static const _models = <String, String>{
    'calibrated_blend': 'Calibrated blend',
    'lightgbm': 'LightGBM',
    'mean28': 'Mean28',
    'seasonal_experimental': 'Seasonal experimental',
  };

  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  StreamSubscription<HistoryInvalidation>? _forecastHistorySubscription;
  ForecastingApiService? _environmentApi;
  List<InventoryItem> _items = const <InventoryItem>[];
  _ForecastingView _selectedView = _ForecastingView.overview;
  _TrackingSection _selectedTrackingSection = _TrackingSection.records;
  String? _selectedProductId;
  String _selectedModel = 'calibrated_blend';
  ForecastWindow _selectedWindow = ForecastWindow.next28Days;
  String? _selectedOverviewScopeKey;
  PortfolioForecastSnapshot? _overview;
  Map<String, ForecastAnalysis> _overviewAnalyses = const {};
  List<String> _overviewWarnings = const [];
  String? _overviewError;
  ForecastSnapshotPage? _snapshotOverview;
  ForecastSnapshotItem? _snapshotProduct;
  String? _snapshotError;
  int _snapshotPageNumber = 1;
  String? _snapshotUnit;
  String _snapshotSearch = '';
  String? _snapshotOverviewRequestKey;
  String? _snapshotProductRequestKey;
  String? _trackingLoadedKey;
  String? _performanceLoadedKey;
  bool _overviewLoading = false;
  bool _overviewStale = false;
  ForecastAnalysis? _analysis;
  String? _error;
  bool _loading = false;
  bool _configuring = false;
  bool _preparingForecast = false;
  Timer? _forecastStatusTimer;
  int _forecastStatusPolls = 0;
  DateTime? _snapshotOverviewLoadedAt;
  DateTime? _snapshotProductLoadedAt;

  void _scheduleForecastStatus(ForecastSnapshotItem item) {
    _forecastStatusTimer?.cancel();
    final status = item.job['status'];
    if (_forecastStatusPolls <= 0 || (status != 'queued' && status != 'running')) {
      return;
    }
    final product = _selectedProductId;
    final model = _selectedModel;
    _forecastStatusTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || !widget.isActive || _selectedView != _ForecastingView.product ||
          product != _selectedProductId || model != _selectedModel) {
        return;
      }
      _forecastStatusPolls--;
      unawaited(_loadAnalysis(forceRefresh: true));
    });
  }

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
  int _trackingGeneration = 0;
  int _performanceGeneration = 0;
  Stopwatch? _activationTimer;
  final Map<_AnalysisRequestKey, Future<ForecastAnalysis>> _analysisRequests =
      <_AnalysisRequestKey, Future<ForecastAnalysis>>{};
  final Map<_AnalysisRequestKey, _CachedForecastAnalysis> _analysisResults =
      <_AnalysisRequestKey, _CachedForecastAnalysis>{};
  int _analysisDataGeneration = 0;
  String _inventoryInputSignature = '';
  int _overviewCompletedCount = 0;
  int _overviewReadyCount = 0;
  int _overviewUnavailableCount = 0;
  int _overviewTotalCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isActive && ForecastingPerformanceDiagnostics.enabled) {
      _activationTimer = Stopwatch()..start();
      ForecastingPerformanceDiagnostics.event(
        'page.activation',
        ForecastingPerformanceDiagnostics.newOperationId('page'),
        'active=true source=initial',
      );
    }
    _bindInventory();
  }

  @override
  void didUpdateWidget(covariant ForecastingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _invalidatePendingRequests();
      _invalidateForecastResults(reload: false);
      unawaited(_inventorySubscription?.cancel());
      _bindInventory();
    }
    if (!oldWidget.isActive && widget.isActive) {
      if (ForecastingPerformanceDiagnostics.enabled) {
        _activationTimer = Stopwatch()..start();
        ForecastingPerformanceDiagnostics.event(
          'page.activation',
          ForecastingPerformanceDiagnostics.newOperationId('page'),
          'active=true source=navigation',
        );
      }
      _loadActiveViewData();
    } else if (oldWidget.isActive && !widget.isActive) {
      if (ForecastingPerformanceDiagnostics.enabled) {
        _activationTimer?.stop();
        _activationTimer = null;
        ForecastingPerformanceDiagnostics.event(
          'page.deactivation',
          ForecastingPerformanceDiagnostics.newOperationId('page'),
          'active=false',
        );
      }
      _invalidatePendingRequests();
    }
  }

  /// Invalidates in-flight work while retaining successfully loaded values.
  /// A later activation or explicit refresh can then own fresh loading state.
  void _invalidatePendingRequests() {
    _forecastStatusTimer?.cancel();
    _forecastStatusPolls = 0;
    if (_overviewLoading) _snapshotOverviewRequestKey = null;
    if (_loading) _snapshotProductRequestKey = null;
    if (_recommendationTrackingLoading) _trackingLoadedKey = null;
    if (_forecastPerformanceLoading) _performanceLoadedKey = null;
    _overviewGeneration++;
    _detailGeneration++;
    _trackingGeneration++;
    _performanceGeneration++;
    _overviewLoading = false;
    _loading = false;
    _recommendationTrackingLoading = false;
    _forecastPerformanceLoading = false;
  }

  void _loadActiveViewData() {
    if (!mounted || !widget.isActive) return;
    switch (_selectedView) {
      case _ForecastingView.overview:
        unawaited(_loadOverview());
        break;
      case _ForecastingView.product:
        if (_selectedProductId != null) {
          unawaited(_loadAnalysis());
        }
        break;
      case _ForecastingView.tracking:
        if (_selectedTrackingSection == _TrackingSection.records) {
          unawaited(_loadRecommendationTracking());
        } else {
          unawaited(_loadForecastPerformance());
        }
        break;
    }
  }

  void _bindInventory() {
    unawaited(_forecastHistorySubscription?.cancel());
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
    _forecastHistorySubscription = widget.controller.historyInvalidations
        .listen((invalidation) {
          if (invalidation.locationId != widget.controller.activeLocationId) {
            return;
          }
          _invalidateForecastResults(reload: widget.isActive);
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) _loadActiveViewData();
    });
  }

  void _acceptInventory(List<InventoryItem> items, {required bool autoLoad}) {
    if (!mounted) return;
    final sorted = List<InventoryItem>.from(items)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final previousId = _selectedProductId;
    final stillExists = sorted.any((item) => item.id == previousId);
    final nextId = stillExists ? previousId : null;
    final selectionChanged = nextId != previousId;
    final nextInventorySignature = _forecastInventorySignature(sorted);
    final forecastInputsChanged =
        nextInventorySignature != _inventoryInputSignature;
    if (forecastInputsChanged) {
      _analysisDataGeneration++;
      _analysisResults.clear();
      _overviewGeneration++;
      _detailGeneration++;
      _snapshotOverviewRequestKey = null;
      _snapshotProductRequestKey = null;
      _trackingLoadedKey = null;
      _performanceLoadedKey = null;
    }
    if (selectionChanged) {
      _detailGeneration++;
      _trackingGeneration++;
      _performanceGeneration++;
      _snapshotProductRequestKey = null;
      _trackingLoadedKey = null;
      _performanceLoadedKey = null;
    }
    setState(() {
      _items = List<InventoryItem>.unmodifiable(sorted);
      _inventoryInputSignature = nextInventorySignature;
      _selectedProductId = nextId;
      if (forecastInputsChanged) {
        _overview = null;
        _snapshotOverview = null;
        _snapshotProduct = null;
        _overviewAnalyses = const {};
        _overviewWarnings = const [];
        _overviewError = null;
        _overviewStale = false;
        _overviewLoading = false;
        _loading = false;
        _analysis = null;
        _error = null;
        _stale = false;
        _overviewCompletedCount = 0;
        _overviewReadyCount = 0;
        _overviewUnavailableCount = 0;
        _overviewTotalCount = 0;
      }
      if (selectionChanged) {
        _loading = false;
        _recommendationTrackingLoading = false;
        _forecastPerformanceLoading = false;
        _analysis = null;
        _error = null;
        _stale = false;
        _recommendations = const [];
        _recommendationTrackingError = null;
        _forecastPerformance = null;
        _forecastPerformanceError = null;
      }
    });
    if (autoLoad &&
        forecastInputsChanged &&
        widget.isActive &&
        sorted.isNotEmpty) {
      _loadActiveViewData();
    }
  }

  ForecastingApiService _api() {
    final injected = widget.forecastApi;
    if (injected != null) return injected;
    return _environmentApi ??= ForecastApiClient.fromEnvironment();
  }

  Future<ForecastAnalysis> _requestAnalysis({
    required InventoryItem product,
    required String locationId,
    required String sessionToken,
    required String model,
    int horizonDays = 28,
    ColdStartManualEstimateInput? manualEstimate,
    bool forceRefresh = false,
    void Function(String disposition)? onDisposition,
  }) {
    final userId = widget.controller.currentUserId ?? '';
    final api = _api();
    final key = (
      controller: widget.controller,
      api: api,
      userId: userId,
      sessionDigest: sha256.convert(utf8.encode(sessionToken)).toString(),
      locationId: locationId,
      productId: product.id,
      inventoryUnit: product.unit,
      inventoryQuantity: product.quantity,
      model: model,
      horizonDays: horizonDays,
      manualDailyDemand: manualEstimate?.dailyQuantity,
      manualUnit: manualEstimate == null ? null : product.unit,
      manualRationale: manualEstimate?.rationale,
      manualConfirmed: manualEstimate?.staffConfirmed ?? false,
      dataGeneration: _analysisDataGeneration,
    );

    final cached = forceRefresh ? null : _analysisResults.remove(key);
    if (forceRefresh) _analysisResults.remove(key);
    if (cached != null && _canReuseAnalysis(cached, product, locationId)) {
      _analysisResults[key] = cached;
      onDisposition?.call('completed_cache');
      return Future<ForecastAnalysis>.value(cached.analysis);
    }
    _analysisResults.remove(key);
    final existing = _analysisRequests[key];
    if (existing != null) {
      onDisposition?.call('in_flight_shared');
      return existing;
    }

    onDisposition?.call('network_request');
    late final Future<ForecastAnalysis> request;
    request = api
        .analyze(
          productId: product.id,
          locationId: locationId,
          sessionToken: sessionToken,
          model: model,
          horizonDays: horizonDays,
          manualDailyDemand: manualEstimate?.dailyQuantity,
          manualUnit: manualEstimate == null ? null : product.unit,
          manualRationale: manualEstimate?.rationale,
          manualConfirmed: manualEstimate?.staffConfirmed ?? false,
        )
        .then((analysis) {
          if (analysis.authorizedLocationId != locationId ||
              analysis.product.locationId != locationId ||
              analysis.product.productId != product.id) {
            throw const ForecastApiException(
              'Forecast response scope did not match the requested product.',
            );
          }
          final currentProduct = _findInventoryItem(product.id);
          if (_isCurrentAnalysisKey(key) &&
              currentProduct != null &&
              _canReuseAnalysis(
                _CachedForecastAnalysis(analysis),
                currentProduct,
                locationId,
              )) {
            _analysisResults[key] = _CachedForecastAnalysis(analysis);
            while (_analysisResults.length > 150) {
              _analysisResults.remove(_analysisResults.keys.first);
            }
          }
          return analysis;
        })
        .whenComplete(() {
          if (identical(_analysisRequests[key], request)) {
            _analysisRequests.remove(key);
          }
        });
    _analysisRequests[key] = request;
    return request;
  }

  InventoryItem? _findInventoryItem(String productId) {
    for (final item in _items) {
      if (item.id == productId) return item;
    }
    return null;
  }

  bool _canReuseAnalysis(
    _CachedForecastAnalysis cached,
    InventoryItem product,
    String locationId,
  ) {
    if (cached.age.elapsed > const Duration(seconds: 30)) return false;
    final analysis = cached.analysis;
    final available = analysis.preliminaryRestockingInsight.availableInventory;
    return analysis.authorizedLocationId == locationId &&
        analysis.product.locationId == locationId &&
        analysis.product.productId == product.id &&
        analysis.product.unit == product.unit &&
        available != null &&
        available == product.quantity;
  }

  bool _isCurrentAnalysisKey(_AnalysisRequestKey key) =>
      mounted &&
      identical(key.controller, widget.controller) &&
      identical(key.api, _api()) &&
      key.userId == (widget.controller.currentUserId ?? '') &&
      key.locationId == widget.controller.activeLocationId &&
      _currentSessionDigest() == key.sessionDigest &&
      key.dataGeneration == _analysisDataGeneration;

  String? _currentSessionDigest() {
    try {
      return sha256
          .convert(utf8.encode(widget.controller.currentSessionToken))
          .toString();
    } on StateError {
      return null;
    }
  }

  void _invalidateForecastResults({required bool reload}) {
    _analysisDataGeneration++;
    _analysisResults.clear();
    _overviewGeneration++;
    _detailGeneration++;
    _snapshotOverviewRequestKey = null;
    _snapshotProductRequestKey = null;
    _trackingLoadedKey = null;
    _performanceLoadedKey = null;
    if (!mounted) return;
    setState(() {
      _overview = null;
      _snapshotOverview = null;
      _snapshotProduct = null;
      _overviewAnalyses = const {};
      _overviewWarnings = const [];
      _overviewError = null;
      _overviewLoading = false;
      _loading = false;
      _analysis = null;
      _error = null;
      _stale = false;
      _overviewCompletedCount = 0;
      _overviewReadyCount = 0;
      _overviewUnavailableCount = 0;
      _overviewTotalCount = 0;
    });
    if (reload && widget.isActive) _loadActiveViewData();
  }

  Future<void> _loadOverview({bool forceRefresh = false}) async {
    if (_useSavedForecasts) {
      await _loadSnapshotOverview(forceRefresh: forceRefresh);
      return;
    }
    if (!mounted || !widget.isActive || _overviewLoading) return;
    final diagnosticsEnabled = ForecastingPerformanceDiagnostics.enabled;
    final runId = diagnosticsEnabled
        ? ForecastingPerformanceDiagnostics.newOperationId('overview')
        : '';
    final overviewTimer = diagnosticsEnabled ? (Stopwatch()..start()) : null;
    final cachedAnalysisCount = _overviewAnalyses.length;
    var requestsInitiated = 0;
    var requestCalls = 0;
    var duplicateRequests = 0;
    var activeRequests = 0;
    var maxConcurrentRequests = 0;
    final requestedProducts = <String>{};
    if (diagnosticsEnabled) {
      ForecastingPerformanceDiagnostics.event(
        'overview.start',
        runId,
        'products=${_items.length} local_analyses_available=$cachedAnalysisCount '
            'api_client_cache=none',
      );
    }
    final locationId = widget.controller.activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      setState(() => _overviewError = 'An active store location is required.');
      if (diagnosticsEnabled) {
        overviewTimer!.stop();
        ForecastingPerformanceDiagnostics.event(
          'overview.complete',
          runId,
          'duration_ms=${overviewTimer!.elapsedMilliseconds} outcome=no_location '
              'products=${_items.length} requests=0',
        );
      }
      _activationTimer = null;
      return;
    }
    if (_items.isEmpty) {
      setState(() {
        _overview = null;
        _overviewAnalyses = const {};
        _overviewError = 'No inventory products are available for forecasting.';
        _overviewWarnings = const [];
      });
      if (diagnosticsEnabled) {
        overviewTimer!.stop();
        ForecastingPerformanceDiagnostics.event(
          'overview.complete',
          runId,
          'duration_ms=${overviewTimer!.elapsedMilliseconds} outcome=no_products '
              'products=0 requests=0',
        );
      }
      _activationTimer = null;
      return;
    }

    // Every new filter/page request owns a generation; prior responses are stale.
    final generation = ++_overviewGeneration;
    setState(() {
      _overviewLoading = true;
      _overviewError = null;
      _overviewWarnings = const [];
      _overviewCompletedCount = 0;
      _overviewReadyCount = 0;
      _overviewUnavailableCount = 0;
      _overviewTotalCount = _items.length;
    });
    final analyses = <String, ForecastAnalysis>{};
    final warnings = <String>[];
    final requestedModel = _selectedModel;
    var completedRequests = 0;
    try {
      final token = widget.controller.currentSessionToken;
      Future<
        ({InventoryItem product, ForecastAnalysis? analysis, String? error})
      >
      loadProduct(InventoryItem product) async {
        final requestNumber = diagnosticsEnabled ? ++requestCalls : 0;
        final requestId = '$runId-request-$requestNumber';
        final duplicate =
            diagnosticsEnabled && !requestedProducts.add(product.id);
        var wasNetworkRequest = false;
        var disposition = 'unknown';
        final requestTimer = diagnosticsEnabled ? (Stopwatch()..start()) : null;
        if (diagnosticsEnabled) {
          ForecastingPerformanceDiagnostics.event(
            'overview.request.start',
            requestId,
            'concurrent=$activeRequests duplicate_product_in_run=$duplicate',
          );
        }
        var outcome = 'error';
        try {
          final analysis = await _requestAnalysis(
            product: product,
            locationId: locationId,
            sessionToken: token,
            model: requestedModel,
            forceRefresh: forceRefresh,
            onDisposition: (value) {
              disposition = value;
              if (!diagnosticsEnabled || value != 'network_request') return;
              requestsInitiated++;
              wasNetworkRequest = true;
              if (duplicate) duplicateRequests++;
              activeRequests++;
              if (activeRequests > maxConcurrentRequests) {
                maxConcurrentRequests = activeRequests;
              }
            },
          );
          outcome = 'success';
          analyses[product.id] = analysis;
          return (product: product, analysis: analysis, error: null);
        } on ForecastApiException catch (error) {
          outcome = 'api_error';
          warnings.add('${product.name}: ${error.message}');
          return (product: product, analysis: null, error: error.message);
        } finally {
          completedRequests++;
          if (mounted && generation == _overviewGeneration) {
            setState(() {
              _overviewCompletedCount = completedRequests;
              _overviewReadyCount = analyses.length;
              _overviewUnavailableCount = warnings.length;
              _overviewTotalCount = _items.length;
            });
          }
          if (diagnosticsEnabled) {
            requestTimer!.stop();
            if (wasNetworkRequest) activeRequests--;
            ForecastingPerformanceDiagnostics.event(
              'overview.request.complete',
              requestId,
              'duration_ms=${requestTimer!.elapsedMilliseconds} outcome=$outcome '
                  'disposition=$disposition concurrent_after=$activeRequests',
            );
          }
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
      const maxConcurrentAnalyses = 2;
      final remaining = _items.skip(1).toList(growable: false);
      for (
        var start = 0;
        start < remaining.length;
        start += maxConcurrentAnalyses
      ) {
        final end = (start + maxConcurrentAnalyses).clamp(0, remaining.length);
        final batch = remaining.sublist(start, end);
        await Future.wait(batch.map(loadProduct));
        if (!mounted || generation != _overviewGeneration) return;
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
      if (diagnosticsEnabled) {
        ForecastingPerformanceDiagnostics.event(
          'overview.aggregate.complete',
          runId,
          'products=${_items.length} analyzed=${analyses.length}',
        );
      }
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
      if (diagnosticsEnabled) {
        overviewTimer!.stop();
        final activationMs = _activationTimer?.elapsedMilliseconds;
        ForecastingPerformanceDiagnostics.event(
          'overview.complete',
          runId,
          'duration_ms=${overviewTimer!.elapsedMilliseconds} '
              'products=${_items.length} requests=$requestsInitiated '
              'duplicate_requests=$duplicateRequests '
              'max_concurrent=$maxConcurrentRequests '
              'analyses_returned=${analyses.length} '
              'activation_elapsed_ms=${activationMs ?? 'unavailable'} '
              'generation_current=${generation == _overviewGeneration}',
        );
        if (generation == _overviewGeneration) _activationTimer = null;
      }
      if (mounted && generation == _overviewGeneration) {
        setState(() => _overviewLoading = false);
      }
    }
  }

  Future<void> _loadAnalysis({
    ColdStartManualEstimateInput? manualEstimate,
    bool forceRefresh = false,
  }) async {
    if (!mounted || !widget.isActive || _loading) return;
    final productId = _selectedProductId;
    if (productId == null) {
      setState(
        () => _error = 'No inventory product is available for forecasting.',
      );
      return;
    }
    final locationId = widget.controller.activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      setState(() {
        _error = 'An active store location is required.';
      });
      return;
    }

    final generation = ++_detailGeneration;
    final requestedModel = _selectedModel;
    final token = widget.controller.currentSessionToken;
    if (_useSavedForecasts) {
      final requestKey =
          '$locationId|$productId|$requestedModel|${_currentSessionDigest()}';
      if (!forceRefresh &&
          _snapshotProductRequestKey == requestKey &&
          (_error != null || (_snapshotProductLoadedAt != null &&
            DateTime.now().difference(_snapshotProductLoadedAt!) < const Duration(seconds: 30)))) {
        return;
      }
      _snapshotProductRequestKey = requestKey;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_useSavedForecasts) {
        final result = await _api().loadProductSnapshot(
          productId: productId,
          locationId: locationId,
          sessionToken: token,
          model: requestedModel,
        );
        if (!mounted ||
            generation != _detailGeneration ||
            productId != _selectedProductId)
          return;
        if (result.productId != productId || result.locationId != locationId) {
          throw const ForecastApiException(
            'Snapshot response did not match the selected product and location.',
          );
        }
        setState(() {
          _snapshotProduct = result;
          _snapshotProductLoadedAt = DateTime.now();
          _analysis = result.analysis;
          _error = result.guidanceError;
          _snapshotError = null;
          _stale = result.status == 'stale';
        });
        if (result.status == 'completed') _snapshotOverviewRequestKey = null;
        _scheduleForecastStatus(result);
        return;
      }
      final result = await _requestAnalysis(
        product: _items.firstWhere((item) => item.id == productId),
        locationId: locationId,
        sessionToken: token,
        model: requestedModel,
        manualEstimate: manualEstimate,
        forceRefresh: forceRefresh,
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

  Future<void> _loadSnapshotOverview({bool forceRefresh = false}) async {
    if (!mounted || !widget.isActive) return;
    final locationId = widget.controller.activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      setState(() => _overviewError = 'An active store location is required.');
      return;
    }
    final requestKey =
        '$locationId|${_currentSessionDigest()}|$_selectedModel|'
        '$_snapshotPageNumber|$_snapshotUnit|$_snapshotSearch';
    if (!forceRefresh &&
        _snapshotOverviewRequestKey == requestKey &&
        (_overviewLoading ||
            (_snapshotOverviewLoadedAt != null &&
              DateTime.now().difference(_snapshotOverviewLoadedAt!) < const Duration(seconds: 30)) ||
            _snapshotError != null)) {
      return;
    }
    _snapshotOverviewRequestKey = requestKey;
    // Let the newest filter/page selection supersede any request in flight.
    final generation = ++_overviewGeneration;
    final timer = Stopwatch()..start();
    setState(() {
      _overviewLoading = true;
      _overviewError = null;
      _overviewUnavailableCount = 0;
      _overviewTotalCount = _items.length;
    });
    try {
      final page = await _api().loadSnapshotOverview(
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        model: _selectedModel,
        page: _snapshotPageNumber,
        pageSize: 25,
        unit: _snapshotUnit,
        search: _snapshotSearch,
      );
      if (!mounted || generation != _overviewGeneration) return;
      if (page.items.any((item) => item.locationId != locationId)) {
        throw const ForecastApiException(
          'Snapshot response included data outside the active location.',
        );
      }
      setState(() {
        _snapshotOverview = page;
        _snapshotOverviewLoadedAt = DateTime.now();
        _snapshotError = null;
        _overviewReadyCount = page.items
            .where((item) => item.snapshot != null)
            .length;
        _overviewUnavailableCount = page.items
            .where((item) => item.snapshot == null)
            .length;
        _overviewTotalCount = page.totalCount;
      });
    } on ForecastApiException catch (error) {
      if (!mounted || generation != _overviewGeneration) return;
      setState(() {
        _snapshotError = error.message;
        _overviewError = error.message;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Forecast snapshot overview failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && generation == _overviewGeneration) {
        setState(() {
          _snapshotError = 'Unable to load saved forecast snapshots.';
          _overviewError = _snapshotError;
        });
      }
    } finally {
      timer.stop();
      if (ForecastingPerformanceDiagnostics.enabled) {
        ForecastingPerformanceDiagnostics.event(
          'snapshot.overview.complete',
          ForecastingPerformanceDiagnostics.newOperationId('snapshot-overview'),
          'duration_ms=${timer.elapsedMilliseconds} page=$_snapshotPageNumber '
              'page_size=25 result_count=${_snapshotOverview?.items.length ?? 0}',
        );
      }
      if (mounted && generation == _overviewGeneration) {
        setState(() => _overviewLoading = false);
      }
    }
  }

  Future<void> _loadRecommendationTracking({
    String? productId,
    bool forceRefresh = false,
  }) async {
    final selectedId = productId ?? _selectedProductId;
    final locationId = widget.controller.activeLocationId;
    if (!mounted ||
        !widget.isActive ||
        _recommendationTrackingLoading ||
        selectedId == null ||
        selectedId != _selectedProductId ||
        locationId == null ||
        locationId.isEmpty) {
      return;
    }
    final requestKey = '$locationId|$selectedId|${_currentSessionDigest()}';
    if (!forceRefresh && _trackingLoadedKey == requestKey) return;
    _trackingLoadedKey = requestKey;
    final generation = ++_trackingGeneration;
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
      if (!mounted ||
          generation != _trackingGeneration ||
          selectedId != _selectedProductId) {
        return;
      }
      setState(() => _recommendations = List.unmodifiable(items));
    } on ForecastApiException catch (error) {
      if (!mounted ||
          generation != _trackingGeneration ||
          selectedId != _selectedProductId)
        return;
      setState(() {
        _recommendationTrackingError = error.statusCode == 503
            ? 'Applied restock records are unavailable. Forecasting remains available.'
            : error.message;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Recommendation tracking load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted &&
          generation == _trackingGeneration &&
          selectedId == _selectedProductId) {
        setState(() {
          _recommendationTrackingError =
              'Recommendation history could not be loaded. Forecasting remains available.';
        });
      }
    } finally {
      if (mounted &&
          generation == _trackingGeneration &&
          selectedId == _selectedProductId) {
        setState(() => _recommendationTrackingLoading = false);
      }
    }
  }

  Future<void> _loadForecastPerformance({
    String? productId,
    bool forceRefresh = false,
  }) async {
    final selectedId = productId ?? _selectedProductId;
    final locationId = widget.controller.activeLocationId;
    if (!mounted ||
        !widget.isActive ||
        _forecastPerformanceLoading ||
        selectedId == null ||
        selectedId != _selectedProductId ||
        locationId == null ||
        locationId.isEmpty) {
      return;
    }
    final requestKey = '$locationId|$selectedId|${_currentSessionDigest()}';
    if (!forceRefresh && _performanceLoadedKey == requestKey) return;
    _performanceLoadedKey = requestKey;
    final generation = ++_performanceGeneration;
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
      if (!mounted ||
          generation != _performanceGeneration ||
          selectedId != _selectedProductId)
        return;
      setState(() => _forecastPerformance = report);
    } on ForecastApiException catch (error) {
      if (!mounted ||
          generation != _performanceGeneration ||
          selectedId != _selectedProductId)
        return;
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
      if (mounted &&
          generation == _performanceGeneration &&
          selectedId == _selectedProductId) {
        setState(() {
          _forecastPerformanceError =
              'Forecast performance could not be loaded. Live forecasting remains available.';
        });
      }
    } finally {
      if (mounted &&
          generation == _performanceGeneration &&
          selectedId == _selectedProductId) {
        setState(() => _forecastPerformanceLoading = false);
      }
    }
  }

  Future<void> _matchReceipt(RecommendationTrackingItem recommendation) async {
    if (_mutatingRecommendationId != null || recommendation.isReconciled || recommendation.recommendationId == null) {
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
        recommendationId: recommendation.recommendationId!,
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
      await _loadRecommendationTracking(
        productId: recommendation.productId,
        forceRefresh: true,
      );
    } on ForecastApiException catch (error) {
      if (mounted) AppToast.error(context, error.message);
    } finally {
      if (mounted) setState(() => _mutatingRecommendationId = null);
    }
  }

  Future<void> _reconcile(RecommendationTrackingItem recommendation) async {
    if (_mutatingRecommendationId != null || recommendation.isReconciled || recommendation.recommendationId == null) {
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
      recommendation.recommendationId!,
      _newUuid,
    );
    setState(() => _mutatingRecommendationId = recommendation.recommendationId);
    try {
      final result = await _api().reconcileRecommendation(
        recommendationId: recommendation.recommendationId!,
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
      await _loadRecommendationTracking(
        productId: recommendation.productId,
        forceRefresh: true,
      );
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

  Future<void> _prepareForecast() async {
    final productId = _selectedProductId;
    if (productId == null || _preparingForecast) return;
    setState(() => _preparingForecast = true);
    try {
      final requestedModel = _selectedModel;
      final report = await _api().prepareForecast(productId: productId,
        sessionToken: widget.controller.currentSessionToken, model: requestedModel);
      if (!mounted || productId != _selectedProductId || requestedModel != _selectedModel) return;
      final queued = (report['queued'] as num? ?? 0) + (report['duplicate'] as num? ?? 0);
      final jobs = (report['jobs'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
      final failed = jobs.any((job) => job['status'] == 'failed' || job['status'] == 'superseded');
      if (queued > 0 && !failed) {
        final complete = jobs.any((job) => job['status'] == 'succeeded');
        AppToast.success(context, complete ? 'A saved forecast is available.' : 'Forecast request recorded. A configured worker must process it; status will refresh for one minute.');
        _forecastStatusPolls = complete ? 0 : 12;
        await _loadAnalysis(forceRefresh: true);
      } else {
        AppToast.error(context, failed ? 'The existing forecast job failed or was superseded. Check its worker diagnostics before retrying.' : 'Forecast preparation did not queue a job. Check the preparation diagnostics.');
      }
    } on ForecastApiException catch (error) {
      if (mounted) AppToast.error(context, error.message);
    } catch (_) {
      if (mounted) AppToast.error(context, 'Unable to prepare the forecast.');
    } finally {
      if (mounted) setState(() => _preparingForecast = false);
    }
  }

  Future<void> _enterManualEstimate() async {
    final value = await showDialog<ColdStartManualEstimateInput>(
      context: context,
      builder: (context) =>
          ColdStartManualEstimateDialog(unit: _selectedItem?.unit ?? 'units'),
    );
    if (value == null || !mounted) return;
    if (!_useSavedForecasts) {
      await _loadAnalysis(manualEstimate: value);
      return;
    }
    final product = _selectedItem;
    final locationId = widget.controller.activeLocationId;
    if (product == null || locationId == null || _loading) return;
    final model = _selectedModel;
    final generation = ++_detailGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final analysis = await _api().previewSavedForecastGuidance(
        productId: product.id,
        locationId: locationId,
        sessionToken: widget.controller.currentSessionToken,
        model: model,
        manualDailyDemand: value.dailyQuantity,
        manualUnit: product.unit,
        manualRationale: value.rationale,
        manualConfirmed: value.staffConfirmed,
      );
      if (!mounted ||
          generation != _detailGeneration ||
          product.id != _selectedProductId ||
          model != _selectedModel) {
        return;
      }
      if (analysis.product.productId != product.id ||
          analysis.authorizedLocationId != locationId) {
        throw const ForecastApiException(
          'Saved guidance scope did not match the selected product.',
        );
      }
      setState(() => _analysis = analysis);
    } on ForecastApiException catch (error) {
      if (mounted && generation == _detailGeneration) {
        setState(() => _error = error.message);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Saved manual guidance preview failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && generation == _detailGeneration) {
        setState(() => _error = 'Unable to preview the manual demand estimate.');
      }
    } finally {
      if (mounted && generation == _detailGeneration) {
        setState(() => _loading = false);
      }
    }
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
      _analysisDataGeneration++;
      _analysisResults.clear();
      _overviewGeneration++;
      _detailGeneration++;
      setState(() {
        _analysis = null;
        _snapshotProduct = null;
        _overview = null;
        _overviewAnalyses = const {};
        _overviewLoading = false;
        _loading = false;
        _stale = false;
        _snapshotProductRequestKey = null;
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
    if (saved && mounted) await _loadAnalysis(forceRefresh: true);
  }

  @override
  void dispose() {
    _forecastStatusTimer?.cancel();
    _overviewGeneration++;
    _detailGeneration++;
    _trackingGeneration++;
    _performanceGeneration++;
    unawaited(_inventorySubscription?.cancel());
    unawaited(_forecastHistorySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _forecastBackground,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 16 : 40,
              vertical: compact ? 24 : 32,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1280),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Forecasting & Restocking',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: _forecastInk,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _overview == null
                          ? 'Demand planning and inventory guidance'
                          : 'Updated ${_timestamp(_overview!.generatedAt)}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: _forecastMuted,
                      ),
                    ),
                    const SizedBox(height: 20),
                    _ForecastViewNavigation(
                      selected: _selectedView,
                      onSelected: (value) {
                        if (value == _selectedView) return;
                        setState(() => _selectedView = value);
                        _loadActiveViewData();
                      },
                    ),
                    const SizedBox(height: 24),
                    _buildSelectedView(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedView() => switch (_selectedView) {
    _ForecastingView.overview => _buildOverviewView(),
    _ForecastingView.product => _buildProductForecastView(),
    _ForecastingView.tracking => _buildTrackingView(),
  };

  Widget _buildOverviewView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_useSavedForecasts) ...[
        ForecastOverviewDashboard(
          snapshot: _snapshotOverview == null ? null : _savedPortfolio(_snapshotOverview!),
          savedPage: _snapshotOverview,
          selectedModel: _selectedModel,
          products: _items.where((item) => item.locationId == null ||
              item.locationId == widget.controller.activeLocationId).toList(growable: false),
          selectedScopeKey: _selectedOverviewScopeKey,
          onScopeChanged: (value) {
            _OverviewScope? chosen;
            if (_snapshotOverview case final page?) {
              for (final scope in _savedScopes(page, _items.where((item) =>
                  item.locationId == null ||
                  item.locationId == widget.controller.activeLocationId).toList(growable: false))) {
                if (scope.key == value) { chosen = scope; break; }
              }
            }
            setState(() => _selectedOverviewScopeKey = value);
            if (chosen != null) {
              var search = '';
              if (chosen.kind == _OverviewScopeKind.product) {
                for (final item in _items) {
                  if (item.id == chosen.productIds.first) {
                    search = item.sku.trim().isEmpty ? item.name : item.sku;
                    break;
                  }
                }
              }
              if (_snapshotUnit != chosen.unit || _snapshotSearch != search) {
                _snapshotUnit = chosen.unit;
                _snapshotSearch = search;
                _snapshotPageNumber = 1;
                unawaited(_loadSnapshotOverview());
              }
            }
          },
          controls: _buildOverviewControls(),
          selectedWindow: _selectedWindow,
          onWindowChanged: (value) => setState(() => _selectedWindow = value),
          loading: _overviewLoading,
          error: _snapshotError,
          onRetry: () => _loadSnapshotOverview(forceRefresh: true),
          onSelectProduct: _openProductForecast,
          onViewForecastAccuracy: _showForecastAccuracy,
        ),
        if (_snapshotOverview case final page?)
          Row(children: [
            IconButton(tooltip: 'Previous page',
              onPressed: _overviewLoading || page.page <= 1 ? null : () {
                _snapshotPageNumber--; unawaited(_loadSnapshotOverview());
              }, icon: const Icon(LucideIcons.chevronLeft)),
            Text('Page ${page.page} of ${max(1, page.pageCount)}'),
            IconButton(tooltip: 'Next page',
              onPressed: _overviewLoading || page.page >= page.pageCount ? null : () {
                _snapshotPageNumber++; unawaited(_loadSnapshotOverview());
              }, icon: const Icon(LucideIcons.chevronRight)),
            const Spacer(),
            IconButton(tooltip: 'Refresh saved forecasts',
              onPressed: _overviewLoading ? null : () => _loadSnapshotOverview(forceRefresh: true),
              icon: const Icon(LucideIcons.refreshCw)),
          ]),
      ]
      else ...[
        if (_overviewLoading) ...[
          _OverviewLoadingProgress(
            completed: _overviewCompletedCount,
            total: _overviewTotalCount,
            ready: _overviewReadyCount,
            unavailable: _overviewUnavailableCount,
            hasPreviousSnapshot: _overview != null,
          ),
          const SizedBox(height: 16),
        ],
        ForecastOverviewDashboard(
          snapshot: _overview,
          analyses: _overviewAnalyses,
          products: _items,
          selectedScopeKey: _selectedOverviewScopeKey,
          onScopeChanged: (value) =>
              setState(() => _selectedOverviewScopeKey = value),
          controls: _buildOverviewControls(),
          selectedWindow: _selectedWindow,
          loading: _overviewLoading,
          stale: _overviewStale,
          error: _overviewError,
          requestWarnings: _overviewWarnings,
          onRetry: _overviewLoading
              ? null
              : () => _loadOverview(forceRefresh: true),
          onWindowChanged: (value) => setState(() => _selectedWindow = value),
          onSelectProduct: _openProductForecast,
          onViewForecastAccuracy: _showForecastAccuracy,
        ),
      ],
    ],
  );

  Widget _buildProductForecastView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _buildProductControls(),
      if (_useSavedForecasts) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_analysis == null) _buildCompactModelSelector(),
            Text(_snapshotProduct == null ? 'Select a product' : _snapshotStatusLabel(_snapshotProduct!.status)),
            OutlinedButton.icon(
              onPressed: _loading || _preparingForecast || _selectedProductId == null ? null : _prepareForecast,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: Text(_preparingForecast ? 'Preparing request?' : 'Generate / Refresh forecast'),
            ),
          ]),
      ],
      const SizedBox(height: 24),
        ForecastAnalysisPanel(
          analysis: _analysis,
          emptyTitle: _selectedProductId == null ? 'Select a product' : _snapshotStatusLabel(_snapshotProduct?.status ?? 'missing'),
          emptyMessage: _selectedProductId == null
              ? 'Choose a product and model to view its saved forecast.'
              : 'No usable saved forecast is available for the selected model. Generate a forecast or refresh its status. Queued work requires a configured background worker; it is not proof that a worker is online.',
          forecastControls: _buildCompactModelSelector(),
          selectedWindow: _selectedWindow,
          onWindowChanged: (value) => setState(() => _selectedWindow = value),
          loading: _loading,
          error: _error,
          stale: _stale,
          onRetry: _loading ? null : () => _loadAnalysis(forceRefresh: true),
          onManualEstimate:
              _analysis?.forecast.isColdStart == true && !_loading
              ? _enterManualEstimate
              : null,
          onViewForecastAccuracy: _showForecastAccuracy,
        ),
    ],
  );

  Widget _buildTrackingView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _TrackingSectionSelector(
        value: _selectedTrackingSection,
        onChanged: (value) {
          if (value == _selectedTrackingSection) return;
          setState(() => _selectedTrackingSection = value);
          _loadActiveViewData();
        },
      ),
      const SizedBox(height: 16),
      if (_selectedTrackingSection == _TrackingSection.records)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TrackingRestockRecords(
              key: ValueKey('tracking-records-$_selectedProductId'),
              hasProductSelection: _selectedProductId != null,
              productScope: _buildTrackingProductScope(),
              refreshControl: _buildTrackingRefreshControl(),
              items: _recommendations,
              loading: _recommendationTrackingLoading,
              error: _recommendationTrackingError,
              onRetry: _recommendationTrackingLoading
                  ? null
                  : () => _loadRecommendationTracking(forceRefresh: true),
            ),
            const SizedBox(height: 12),
            const _TrackingRestockTransparency(),
          ],
        )
      else
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTrackingAccuracyControls(),
            const SizedBox(height: 16),
            if (_selectedProductId == null)
              const _MessageCard(
                icon: LucideIcons.history,
                title: 'Select a product to review forecast accuracy',
                message:
                    'Saved forecast performance is shown for the selected product.',
              )
            else
              _TrackingForecastAccuracy(
                report: _forecastPerformance,
                loading: _forecastPerformanceLoading,
                error: _forecastPerformanceError,
                onRetry: _forecastPerformanceLoading
                    ? null
                    : () => _loadForecastPerformance(forceRefresh: true),
              ),
          ],
        ),
    ],
  );

  Widget _buildOverviewControls() {
    return _ForecastMethodMenu(
      selectedModel: _selectedModel,
      enabled: !_overviewLoading && !_loading,
      onSelected: (value) {
        if (value == _selectedModel) return;
        _changeModel(value);
      },
    );
  }

  Widget _buildCompactModelSelector() => _ForecastMethodMenu(
    selectedModel: _selectedModel,
    enabled: !_overviewLoading && !_loading,
    triggerKey: const Key('forecast-product-method-selector'),
    maxMenuWidth: 320,
    triggerFontSize: 14,
    alignMenuEnd: true,
    footerText:
        'The preliminary restock estimate uses LightGBM. Verified guidance uses its saved recommendation forecast.',
    onSelected: (value) {
      if (value == _selectedModel) return;
      _changeModel(value);
    },
  );

  Widget _buildProductControls() {
    final product = _selectedItem;
    final selectedIndex = _items.indexWhere(
      (item) => item.id == _selectedProductId,
    );
    final saleable = _analysis?.product.productId == product?.id
        ? _analysis?.preliminaryRestockingInsight.availableInventory
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ProductPickerMenu(
                items: _items,
                selectedProductId: _selectedProductId,
                enabled: !_loading && _items.isNotEmpty,
                onSelected: (productId) {
                  if (productId == _selectedProductId) return;
                  _selectProduct(productId, loadForecast: true);
                },
              ),
            ),
            if (_items.isNotEmpty) ...[
              const SizedBox(width: 12),
              if (MediaQuery.sizeOf(context).width >= 640) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    selectedIndex < 0
                        ? '${_items.length} products'
                        : '${selectedIndex + 1} of ${_items.length}',
                    style: const TextStyle(fontSize: 12, color: _forecastMuted),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _ProductStepButton(
                tooltip: 'Previous product',
                icon: LucideIcons.chevronLeft,
                onPressed: () => _selectAdjacentProduct(-1),
              ),
              const SizedBox(width: 6),
              _ProductStepButton(
                tooltip: 'Next product',
                icon: LucideIcons.chevronRight,
                onPressed: () => _selectAdjacentProduct(1),
              ),
              const SizedBox(width: 6),
              PopupMenuButton<String>(
                key: const Key('forecast-product-actions'),
                tooltip: 'Product forecast actions',
                enabled: !_loading && _selectedProductId != null,
                icon: const Icon(
                  LucideIcons.ellipsis,
                  size: 18,
                  color: _forecastMuted,
                ),
                onSelected: (value) {
                  if (value == 'inputs') {
                    unawaited(_configureReplenishment());
                  } else if (value == 'refresh') {
                    unawaited(_loadAnalysis(forceRefresh: true));
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'refresh',
                    child: Text('Refresh forecast'),
                  ),
                  PopupMenuItem(
                    value: 'inputs',
                    child: Text('Restocking inputs'),
                  ),
                ],
              ),
            ],
          ],
        ),
        if (product != null) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                product.category,
                style: const TextStyle(fontSize: 14, color: _forecastMuted),
              ),
              const Text('·', style: TextStyle(color: _forecastFaint)),
              Text(
                product.sku,
                style: const TextStyle(fontSize: 14, color: _forecastMuted),
              ),
              const Text('·', style: TextStyle(color: _forecastFaint)),
              Text(
                'Sold in ${product.unit}',
                style: const TextStyle(fontSize: 14, color: _forecastMuted),
              ),
              if (saleable != null) ...[
                const Text('·', style: TextStyle(color: _forecastFaint)),
                Text(
                  '${_quantity(saleable)} ${product.unit} saleable',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _forecastInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildTrackingProductScope() => _TrackingProductScopeMenu(
    items: _items,
    selectedProductId: _selectedProductId,
    enabled:
        _items.isNotEmpty &&
        !_recommendationTrackingLoading &&
        !_forecastPerformanceLoading,
    onSelected: (productId) {
      if (productId == _selectedProductId) return;
      _selectProduct(productId, loadForecast: false);
    },
  );

  Widget _buildTrackingRefreshControl() => SizedBox(
    width: 38,
    height: 36,
    child: Tooltip(
      message: 'Refresh tracking data',
      child: OutlinedButton(
        onPressed:
            _selectedProductId == null ||
                _recommendationTrackingLoading ||
                _forecastPerformanceLoading
            ? null
            : () {
                if (_selectedTrackingSection == _TrackingSection.records) {
                  unawaited(_loadRecommendationTracking(forceRefresh: true));
                } else {
                  unawaited(_loadForecastPerformance(forceRefresh: true));
                }
              },
        style: OutlinedButton.styleFrom(
          foregroundColor: _trackingBody,
          side: const BorderSide(color: _trackingLineStrong),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: const Icon(LucideIcons.refreshCw, size: 15),
      ),
    ),
  );

  Widget _buildTrackingAccuracyControls() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _trackingLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final selector = _buildTrackingProductScope();
        final refresh = _buildTrackingRefreshControl();
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 36, child: selector),
              const SizedBox(height: 10),
              refresh,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 280, height: 36, child: selector),
            const SizedBox(width: 12),
            const Spacer(),
            refresh,
          ],
        );
      },
    ),
  );

  void _changeModel(String value) {
    _forecastStatusTimer?.cancel();
    _forecastStatusPolls = 0;
    _overviewGeneration++;
    _detailGeneration++;
    setState(() {
      _selectedModel = value;
      _overviewLoading = false;
      _loading = false;
      _overview = null;
      _overviewAnalyses = const {};
      _analysis = null;
      _snapshotProduct = null;
      _snapshotOverview = null;
      _snapshotProductRequestKey = null;
      _snapshotOverviewRequestKey = null;
      _overviewError = null;
      _error = null;
    });
    _loadActiveViewData();
  }

  void _selectProduct(String productId, {required bool loadForecast}) {
    _forecastStatusTimer?.cancel();
    _forecastStatusPolls = 0;
    if (productId == _selectedProductId) {
      if (loadForecast &&
          (_useSavedForecasts
              ? _snapshotProduct == null
              : _analysis == null)) {
        unawaited(_loadAnalysis());
      }
      return;
    }
    final localResultAvailable = _analysisResults.keys.any(
      (key) =>
          key.productId == productId &&
          key.locationId == widget.controller.activeLocationId &&
          key.model == _selectedModel &&
          key.dataGeneration == _analysisDataGeneration,
    );
    if (ForecastingPerformanceDiagnostics.enabled) {
      ForecastingPerformanceDiagnostics.event(
        'product_analysis.local_cache',
        ForecastingPerformanceDiagnostics.newOperationId('product-cache'),
        'candidate=$localResultAvailable source=scoped_analysis_cache',
      );
    }
    _detailGeneration++;
    _trackingGeneration++;
    _performanceGeneration++;
    _snapshotProductRequestKey = null;
    _trackingLoadedKey = null;
    _performanceLoadedKey = null;
    setState(() {
      _selectedProductId = productId;
      _loading = false;
      _recommendationTrackingLoading = false;
      _forecastPerformanceLoading = false;
      _analysis = null;
      _snapshotProduct = null;
      _error = null;
      _stale = false;
      _recommendations = const [];
      _recommendationTrackingError = null;
      _forecastPerformance = null;
      _forecastPerformanceError = null;
    });
    if (_selectedView == _ForecastingView.tracking) {
      _loadActiveViewData();
    }
    if (loadForecast) unawaited(_loadAnalysis());
  }

  void _showForecastAccuracy() {
    setState(() {
      _selectedView = _ForecastingView.tracking;
      _selectedTrackingSection = _TrackingSection.accuracy;
    });
    _loadActiveViewData();
  }

  void _openProductForecast(String productId) {
    _selectProduct(productId, loadForecast: true);
    setState(() => _selectedView = _ForecastingView.product);
  }

  Future<void> _showProductPicker() async {
    final productId = await showDialog<String>(
      context: context,
      builder: (context) => _ProductPickerDialog(
        items: _items,
        selectedProductId: _selectedProductId,
      ),
    );
    if (!mounted || productId == null || productId == _selectedProductId) {
      return;
    }
    _selectProduct(productId, loadForecast: true);
  }

  void _selectAdjacentProduct(int offset) {
    if (_items.isEmpty) return;
    final current = _items.indexWhere((item) => item.id == _selectedProductId);
    final next = current < 0
        ? 0
        : (current + offset + _items.length) % _items.length;
    _selectProduct(_items[next].id, loadForecast: true);
  }
}

class _ProductStepButton extends StatelessWidget {
  const _ProductStepButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _forecastLine),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 17, color: _forecastMuted),
      ),
    ),
  );
}

class _ProductPickerMenu extends StatefulWidget {
  const _ProductPickerMenu({
    required this.items,
    required this.selectedProductId,
    required this.enabled,
    required this.onSelected,
  });

  final List<InventoryItem> items;
  final String? selectedProductId;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  State<_ProductPickerMenu> createState() => _ProductPickerMenuState();
}

class _ProductPickerMenuState extends State<_ProductPickerMenu> {
  final MenuController _menuController = MenuController();
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final matches = widget.items
        .where(
          (item) =>
              query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              item.sku.toLowerCase().contains(query) ||
              item.category.toLowerCase().contains(query),
        )
        .toList(growable: false);
    InventoryItem? selected = null;
    for (final item in widget.items) {
      if (item.id == widget.selectedProductId) selected = item;
    }
    final viewport = MediaQuery.sizeOf(context);
    final menuWidth = min(352.0, viewport.width - 32);
    final menuHeight = min(340.0, max(220.0, viewport.height - 120));

    return MenuAnchor(
      controller: _menuController,
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(
        alignment: AlignmentDirectional.bottomStart,
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(8),
        shadowColor: WidgetStatePropertyAll(Color(0x0D1C1917)),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: _forecastLine),
          ),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: menuWidth,
          height: menuHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: TextField(
                  key: const Key('forecast-product-search'),
                  controller: _search,
                  autofocus: true,
                  onChanged: (value) => setState(() => _query = value),
                  style: const TextStyle(fontSize: 14, color: _forecastInk),
                  decoration: const InputDecoration(
                    hintText: 'Search product, SKU or category',
                    hintStyle: TextStyle(color: _forecastFaint),
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 16,
                      color: _forecastFaint,
                    ),
                    prefixIconConstraints: BoxConstraints(minWidth: 32),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const Divider(height: 1, color: _forecastHairline),
              Expanded(
                child: matches.isEmpty
                    ? const Center(
                        child: Text(
                          'No matching products',
                          style: TextStyle(fontSize: 14, color: _forecastMuted),
                        ),
                      )
                    : ListView.builder(
                        primary: false,
                        padding: const EdgeInsets.all(6),
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final item = matches[index];
                          final active = item.id == widget.selectedProductId;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: InkWell(
                              onTap: () {
                                _menuController.close();
                                widget.onSelected(item.id);
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: active
                                      ? _forecastBackground
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 18,
                                      child: active
                                          ? const Icon(
                                              LucideIcons.check,
                                              color: _forecastAccent,
                                              size: 16,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: _forecastInk,
                                            ),
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            '${item.category} · ${item.sku}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: _forecastMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      item.unit,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: _forecastFaint,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
      builder: (context, controller, child) => InkWell(
        key: const Key('forecast-product-picker-open'),
        onTap: widget.enabled
            ? () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  _search.clear();
                  setState(() => _query = '');
                  controller.open();
                }
              }
            : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  selected?.name ?? 'Select a product',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _forecastInk,
                    fontSize: viewport.width >= 640 ? 24 : 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                controller.isOpen
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
                size: 20,
                color: _forecastMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductPickerDialog extends StatefulWidget {
  const _ProductPickerDialog({
    required this.items,
    required this.selectedProductId,
  });

  final List<InventoryItem> items;
  final String? selectedProductId;

  @override
  State<_ProductPickerDialog> createState() => _ProductPickerDialogState();
}

class _ProductPickerDialogState extends State<_ProductPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final matches = widget.items
        .where(
          (item) =>
              query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              item.sku.toLowerCase().contains(query) ||
              item.category.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
              child: TextField(
                key: const Key('forecast-product-search'),
                controller: _search,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search product, SKU or category',
                  prefixIcon: const Icon(LucideIcons.search, size: 18),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: _forecastHairline),
            Flexible(
              child: matches.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No matching products',
                          style: TextStyle(color: _forecastMuted),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(8),
                      itemCount: matches.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final item = matches[index];
                        final selected = item.id == widget.selectedProductId;
                        return ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          tileColor: selected ? _forecastBackground : null,
                          leading: SizedBox(
                            width: 20,
                            child: selected
                                ? const Icon(
                                    LucideIcons.check,
                                    color: _forecastAccent,
                                    size: 18,
                                  )
                                : null,
                          ),
                          title: Text(item.name),
                          subtitle: Text('${item.category} · ${item.sku}'),
                          trailing: Text(
                            item.unit,
                            style: const TextStyle(
                              fontSize: 12,
                              color: _forecastFaint,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, item.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ForecastViewNavigation extends StatelessWidget {
  const _ForecastViewNavigation({
    required this.selected,
    required this.onSelected,
  });

  final _ForecastingView selected;
  final ValueChanged<_ForecastingView> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _forecastLine)),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _ForecastingView.values
            .map(
              (view) => Padding(
                padding: const EdgeInsets.only(right: 24),
                child: InkWell(
                  key: Key('forecast-view-${view.name}'),
                  onTap: () => onSelected(view),
                  child: Container(
                    padding: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: view == selected
                              ? _forecastAccent
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      view.label,
                      style: TextStyle(
                        color: view == selected ? _forecastInk : _forecastMuted,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(growable: false),
      ),
    ),
  );
}

class _TrackingSectionSelector extends StatelessWidget {
  const _TrackingSectionSelector({
    required this.value,
    required this.onChanged,
  });

  final _TrackingSection value;
  final ValueChanged<_TrackingSection> onChanged;

  @override
  Widget build(BuildContext context) {
    final description = value == _TrackingSection.records
        ? 'What was forecast, what was suggested, and what was actually added to stock.'
        : 'Forecasted customer demand compared with recorded customer sales.';
    final selector = Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: _trackingLine.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TrackingSectionButton(
            label: 'Restock Records',
            selected: value == _TrackingSection.records,
            onPressed: () => onChanged(_TrackingSection.records),
          ),
          _TrackingSectionButton(
            label: 'Forecast Accuracy',
            selected: value == _TrackingSection.accuracy,
            onPressed: () => onChanged(_TrackingSection.accuracy),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: selector,
              ),
              const SizedBox(height: 10),
              Text(
                description,
                style: const TextStyle(fontSize: 12, color: _trackingMuted),
              ),
            ],
          );
        }
        return Row(
          children: [
            selector,
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                description,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: _trackingMuted),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TrackingSectionButton extends StatelessWidget {
  const _TrackingSectionButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? Colors.white : Colors.transparent,
    borderRadius: BorderRadius.circular(6),
    elevation: selected ? 1 : 0,
    shadowColor: Colors.black.withValues(alpha: 0.12),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: selected ? _trackingInk : _trackingMuted,
          ),
        ),
      ),
    ),
  );
}

class _TrackingProductScopeMenu extends StatefulWidget {
  const _TrackingProductScopeMenu({
    required this.items,
    required this.selectedProductId,
    required this.enabled,
    required this.onSelected,
  });

  final List<InventoryItem> items;
  final String? selectedProductId;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  State<_TrackingProductScopeMenu> createState() =>
      _TrackingProductScopeMenuState();
}

class _TrackingProductScopeMenuState extends State<_TrackingProductScopeMenu> {
  final MenuController _menuController = MenuController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    InventoryItem? selected;
    for (final item in widget.items) {
      if (item.id == widget.selectedProductId) {
        selected = item;
        break;
      }
    }
    final query = _query.trim().toLowerCase();
    final matches = widget.items
        .where(
          (item) =>
              query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              item.sku.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final menuWidth = min(340.0, MediaQuery.sizeOf(context).width - 32);
    final menuHeight = min(
      340.0,
      max(190.0, MediaQuery.sizeOf(context).height - 140),
    );

    return MenuAnchor(
      controller: _menuController,
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        elevation: WidgetStatePropertyAll(6),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            side: BorderSide(color: _trackingLine),
          ),
        ),
      ),
      onOpen: () {
        _searchController.clear();
        setState(() => _query = '');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      },
      onClose: _searchFocus.unfocus,
      menuChildren: [
        SizedBox(
          width: menuWidth,
          height: menuHeight,
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: (value) => setState(() => _query = value),
                    style: const TextStyle(fontSize: 13, color: _trackingInk),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(
                        LucideIcons.search,
                        size: 16,
                        color: _trackingFaint,
                      ),
                      prefixIconConstraints: BoxConstraints(minWidth: 34),
                      hintText: 'Search products or SKU',
                      hintStyle: TextStyle(color: _trackingFaint),
                      contentPadding: EdgeInsets.symmetric(vertical: 9),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: _trackingLine),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: _trackingAccent),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: matches.isEmpty
                      ? const Center(
                          child: Text(
                            'No matching products',
                            style: TextStyle(
                              fontSize: 13,
                              color: _trackingMuted,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: matches.length,
                          itemBuilder: (context, index) {
                            final item = matches[index];
                            final selectedItem =
                                item.id == widget.selectedProductId;
                            return InkWell(
                              onTap: () {
                                _menuController.close();
                                widget.onSelected(item.id);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 9,
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 20,
                                      child: selectedItem
                                          ? const Icon(
                                              LucideIcons.check,
                                              size: 16,
                                              color: _trackingAccent,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                              color: _trackingInk,
                                            ),
                                          ),
                                          Text(
                                            item.sku,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: _trackingMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => Semantics(
        button: true,
        label: 'Product Scope',
        enabled: widget.enabled,
        child: InkWell(
          onTap: widget.enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.enabled ? Colors.white : _trackingSubtle,
              border: Border.all(
                color: controller.isOpen
                    ? _trackingAccent
                    : _trackingLineStrong,
              ),
              borderRadius: BorderRadius.circular(8),
              boxShadow: controller.isOpen
                  ? [
                      BoxShadow(
                        color: _trackingAccent.withValues(alpha: 0.10),
                        blurRadius: 0,
                        spreadRadius: 3,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                const Icon(
                  LucideIcons.package,
                  size: 15,
                  color: _trackingAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Product Scope',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 9.5,
                          height: 1,
                          color: _trackingMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        selected?.name ?? 'Select a product',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: _trackingInk,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
                Icon(
                  controller.isOpen
                      ? LucideIcons.chevronUp
                      : LucideIcons.chevronDown,
                  size: 15,
                  color: _trackingMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _forecastInventorySignature(List<InventoryItem> items) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          items
              .map(
                (item) => <Object?>[
                  item.id,
                  item.name,
                  item.sku,
                  item.unit,
                  item.quantity.toString(),
                  item.maxQuantity.toString(),
                  item.price.toString(),
                  item.category,
                  item.locationId,
                ],
              )
              .toList(growable: false),
        ),
      ),
    )
    .toString();

class _OverviewLoadingProgress extends StatelessWidget {
  const _OverviewLoadingProgress({
    required this.completed,
    required this.total,
    required this.ready,
    required this.unavailable,
    required this.hasPreviousSnapshot,
  });

  final int completed;
  final int total;
  final int ready;
  final int unavailable;
  final bool hasPreviousSnapshot;

  @override
  Widget build(BuildContext context) {
    final progress = total > 0
        ? (completed / total).clamp(0.0, 1.0).toDouble()
        : 0.0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Preparing store forecasts - $completed of $total products processed',
                  style: const TextStyle(
                    color: _forecastInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: total == 0 ? null : progress,
            minHeight: 4,
            color: _forecastAccent,
            backgroundColor: _forecastHairline,
          ),
          const SizedBox(height: 8),
          Text(
            '$ready forecasts ready${unavailable > 0 ? ' - $unavailable unavailable' : ''}. ${hasPreviousSnapshot ? 'The previous complete portfolio remains visible while results refresh.' : 'Portfolio totals appear after processing completes.'}',
            style: const TextStyle(color: _forecastMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SnapshotOverviewView extends StatelessWidget {
  const _SnapshotOverviewView({
    required this.page,
    required this.inventory,
    required this.selectedWindow,
    required this.onWindowChanged,
    required this.forecastControls,
    required this.onViewForecastAccuracy,
    required this.loading,
    required this.error,
    required this.selectedUnit,
    required this.search,
    required this.onUnitChanged,
    required this.onSearch,
    required this.onPageChanged,
    required this.onRetry,
    required this.onSelectProduct,
  });

  final ForecastSnapshotPage? page;
  final List<InventoryItem> inventory;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow> onWindowChanged;
  final Widget forecastControls;
  final VoidCallback onViewForecastAccuracy;
  final bool loading;
  final String? error;
  final String? selectedUnit;
  final String search;
  final ValueChanged<String?> onUnitChanged;
  final ValueChanged<String> onSearch;
  final ValueChanged<int> onPageChanged;
  final VoidCallback? onRetry;
  final ValueChanged<String> onSelectProduct;

  @override
  Widget build(BuildContext context) {
    final units =
        inventory
            .map((item) => item.unit.trim())
            .where((unit) => unit.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final rows = page?.items ?? const <ForecastSnapshotItem>[];
    final controls = LayoutBuilder(
      builder: (context, constraints) {
        final searchField = TextFormField(
          key: const Key('snapshot-overview-search'),
          initialValue: search,
          decoration: InputDecoration(
            hintText: 'Search product or SKU',
            prefixIcon: const Icon(LucideIcons.search, size: 17),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
            filled: true,
            fillColor: Colors.white,
          ),
          onFieldSubmitted: onSearch,
        );
        final unitField = DropdownButtonFormField<String>(
          value: selectedUnit != null && units.contains(selectedUnit)
              ? selectedUnit
              : '',
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
            filled: true,
            fillColor: Colors.white,
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('All units')),
            ...units.map(
              (unit) => DropdownMenuItem(value: unit, child: Text(unit)),
            ),
          ],
          onChanged: (value) => onUnitChanged(value == '' ? null : value),
        );
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [searchField, const SizedBox(height: 10), unitField],
          );
        }
        return Row(
          children: [
            Expanded(flex: 3, child: searchField),
            const SizedBox(width: 12),
            Expanded(child: unitField),
          ],
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        controls,
        const SizedBox(height: 16),
        if (error != null)
          _MessageCard(
            icon: LucideIcons.cloudOff,
            title: 'Saved forecast snapshots unavailable',
            message: error!,
            actionLabel: onRetry == null ? null : 'Try again',
            onAction: onRetry,
          )
        else if (loading && page == null)
          const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (page != null && page!.totalCount == 0)
          const _MessageCard(
            icon: LucideIcons.chartNoAxesCombined,
            title: 'No products match this filter',
            message: 'Clear the search or select another inventory unit.',
          )
        else ...[
          if (page != null) ...[
            _SnapshotOverviewDashboard(
              page: page!,
              selectedUnit: selectedUnit,
              selectedWindow: selectedWindow,
              onWindowChanged: onWindowChanged,
              forecastControls: forecastControls,
              onViewForecastAccuracy: onViewForecastAccuracy,
              onSelectProduct: onSelectProduct,
            ),
            const SizedBox(height: 24),
          ],
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _forecastLine),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    runSpacing: 8,
                    children: [
                      const Text(
                        'Browse product forecasts',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        page == null
                            ? 'Loading'
                            : '${page!.totalCount} products · ${page!.items.where((row) => row.snapshot != null).length} snapshots on this page',
                        style: const TextStyle(
                          fontSize: 12,
                          color: _forecastMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (MediaQuery.sizeOf(context).width >= 760)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Text(
                            'Product',
                            style: TextStyle(
                              fontSize: 11,
                              color: _forecastMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'On hand',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: _forecastMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '28-day demand',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: _forecastMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'Last saved suggestion',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: _forecastMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'Status',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: _forecastMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        SizedBox(width: 28),
                      ],
                    ),
                  ),
                if (rows.isEmpty && !loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No forecast snapshots have been prepared yet.',
                      style: TextStyle(color: _forecastMuted),
                    ),
                  )
                else
                  for (final row in rows)
                    _SnapshotOverviewRow(
                      item: row,
                      compact: MediaQuery.sizeOf(context).width < 760,
                      onTap: () => onSelectProduct(row.productId),
                    ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          page == null
                              ? 'Forecast coverage is loading.'
                              : 'Persisted forecast values only; missing or stale products are not included in totals.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: _forecastMuted,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Previous page',
                        onPressed: loading || page == null || page!.page <= 1
                            ? null
                            : () => onPageChanged(page!.page - 1),
                        icon: const Icon(LucideIcons.chevronLeft, size: 18),
                      ),
                      Text(
                        page == null
                            ? '—'
                            : '${page!.page} / ${max(1, page!.pageCount)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      IconButton(
                        tooltip: 'Next page',
                        onPressed:
                            loading ||
                                page == null ||
                                page!.page >= page!.pageCount
                            ? null
                            : () => onPageChanged(page!.page + 1),
                        icon: const Icon(LucideIcons.chevronRight, size: 18),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

List<_OverviewScope> _savedScopes(
  ForecastSnapshotPage page,
  List<InventoryItem> products,
) {
  // Inventory supplies stable choices; the bounded response supplies only the
  // product IDs that may contribute to this page's chart.
  final catalog = <String, ({String name, String category, String unit})>{};
  for (final item in products) {
    final unit = item.unit.trim().toLowerCase();
    if (unit.isEmpty) continue;
    catalog[item.id] = (name: item.name, category: item.category, unit: unit);
  }
  for (final item in page.items) {
    catalog.putIfAbsent(item.productId, () => (
      name: item.productName,
      category: item.product['category']?.toString() ?? 'Uncategorized',
      unit: item.unit.trim().toLowerCase(),
    ));
  }
  final units = <String, List<String>>{};
  final categories = <String, ({String label, String unit, List<String> ids})>{};
  for (final entry in catalog.entries) {
    final product = entry.value;
    units.putIfAbsent(product.unit, () => <String>[]).add(entry.key);
    final category = product.category.trim().isEmpty
        ? 'Uncategorized' : product.category.trim();
    categories.putIfAbsent('$category|${product.unit}', () => (
      label: category, unit: product.unit, ids: <String>[],
    )).ids.add(entry.key);
  }
  final pageIds = page.items.map((item) => item.productId).toSet();
  final scopes = <_OverviewScope>[
    for (final entry in units.entries)
      _OverviewScope(key: 'unit:${entry.key}', kind: _OverviewScopeKind.unit,
        label: 'All ${entry.key}', meta: '${entry.value.length} products',
        unit: entry.key,
        productIds: entry.value.where(pageIds.contains).toList(growable: false)),
    for (final entry in categories.entries)
      _OverviewScope(key: 'category:${entry.key}', kind: _OverviewScopeKind.category,
        label: entry.value.label, meta: entry.value.unit,
        unit: entry.value.unit, productIds: entry.value.ids),
    for (final entry in catalog.entries)
      _OverviewScope(key: 'product:${entry.key}', kind: _OverviewScopeKind.product,
        label: entry.value.name, meta: entry.value.unit,
        unit: entry.value.unit, productIds: [entry.key]),
  ];
  scopes.sort((left, right) {
    final kind = left.kind.index.compareTo(right.kind.index);
    return kind != 0 ? kind : left.label.toLowerCase().compareTo(right.label.toLowerCase());
  });
  return scopes;
}

PortfolioForecastSnapshot _savedPortfolio(ForecastSnapshotPage page) {
  final current = page.items.where((item) => item.snapshot != null && (item.status == 'completed' || item.status == 'stale')).toList();
  final categories = current.map((item) => item.product['category']?.toString() ?? 'Uncategorized').toSet();
  Map<String, UnitDemandForecast> byUnit(List<ForecastSnapshotItem> items) {
    final result = <String, UnitDemandForecast>{};
    for (final unit in items.map((item) => item.unit).toSet()) {
      final matching = items.where((item) => item.unit == unit).toList();
      final usable = _overviewUsableSavedItems(matching);
      final daily = _snapshotDailyPageSeries(usable, 28);
      if (daily.isNotEmpty) {
        result[unit] = UnitDemandForecast(unit: unit, daily: daily, productCount: usable.length);
      }
    }
    return result;
  }
  final dates = current.map((item) => DateTime.tryParse(item.snapshot?['created_at']?.toString() ?? '')).whereType<DateTime>().toList()..sort();
  return PortfolioForecastSnapshot(
    byUnit: byUnit(current),
    categories: [for (final category in categories)
      CategoryDemandForecast(category: category,
        byUnit: byUnit(current.where((item) => (item.product['category']?.toString() ?? 'Uncategorized') == category).toList()),
        productCount: current.where((item) => (item.product['category']?.toString() ?? 'Uncategorized') == category).length,
        coldStartProducts: 0)],
    priorities: const [], totalProducts: page.totalCount,
    forecastedProducts: current.length, coldStartProducts: 0,
    models: const {}, provenance: const {}, reliabilityWarnings: const [],
    generatedAt: dates.isEmpty ? DateTime.now() : dates.last,
  );
}

List<ForecastSnapshotItem> _overviewUsableSavedItems(List<ForecastSnapshotItem> items) {
  final completed = items.where((item) => item.status == 'completed' && item.snapshot != null).toList(growable: false);
  if (completed.isNotEmpty) return completed;
  return items.where((item) => item.status == 'stale' && item.snapshot != null).toList(growable: false);
}

class _SnapshotOverviewDashboard extends StatelessWidget {
  const _SnapshotOverviewDashboard({
    required this.page,
    required this.selectedUnit,
    required this.selectedWindow,
    required this.onWindowChanged,
    required this.forecastControls,
    required this.onViewForecastAccuracy,
    required this.onSelectProduct,
  });

  final ForecastSnapshotPage page;
  final String? selectedUnit;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow> onWindowChanged;
  final Widget forecastControls;
  final VoidCallback onViewForecastAccuracy;
  final ValueChanged<String> onSelectProduct;

  @override
  Widget build(BuildContext context) {
    final current = page.items
        .where(
          (item) => item.status == 'completed' && item.forecastSummary != null,
        )
        .toList(growable: false);
    final units = current.map((item) => item.unit).toSet();
    final unit = selectedUnit ?? (units.length == 1 ? units.first : null);
    final compatible = unit == null
        ? const <ForecastSnapshotItem>[]
        : current.where((item) => item.unit == unit).toList(growable: false);
    final summaryKey = switch (selectedWindow) {
      ForecastWindow.today => 'first_day_demand',
      ForecastWindow.next7Days => 'next_7_day_demand',
      ForecastWindow.next28Days => 'next_28_day_demand',
    };
    final hasCompleteSummary =
        compatible.isNotEmpty &&
        compatible.every((item) => item.forecastSummary?[summaryKey] is num);
    final total = hasCompleteSummary
        ? compatible.fold<double>(
            0,
            (sum, item) =>
                sum + (item.forecastSummary![summaryKey] as num).toDouble(),
          )
        : null;
    final daily = _snapshotDailyPageSeries(compatible, selectedWindow.days);
    final categories = <String, double>{};
    for (final item in compatible) {
      final demand = item.forecastSummary?['next_28_day_demand'];
      if (demand is! num) continue;
      final category = item.product['category']?.toString() ?? 'Uncategorized';
      categories[category] = (categories[category] ?? 0) + demand.toDouble();
    }
    final categoryRows = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final coverage =
        '${current.length} current on this page · '
        '${page.totalCount} matching products · page ${page.page} of ${max(1, page.pageCount)}';
    final outlook = Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Store demand outlook',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: _forecastInk,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    coverage,
                    style: const TextStyle(fontSize: 12, color: _forecastMuted),
                  ),
                ],
              );
              final selector = Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _PeriodSelector(
                    selected: selectedWindow,
                    onChanged: onWindowChanged,
                  ),
                  forecastControls,
                ],
              );
              if (constraints.maxWidth < 730) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [heading, const SizedBox(height: 12), selector],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 12),
                  selector,
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Text(
            'Expected demand · ${selectedWindow.label}',
            style: const TextStyle(fontSize: 13, color: _forecastMuted),
          ),
          const SizedBox(height: 4),
          Text(
            total == null ? 'Unavailable' : '${_quantity(total)} $unit',
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w600,
              color: _forecastInk,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            unit == null
                ? 'Choose one inventory unit to view compatible demand.'
                : 'Partial coverage: only current saved forecasts on this page are included.',
            style: const TextStyle(fontSize: 12, color: _forecastMuted),
          ),
          const SizedBox(height: 20),
          _OverviewForecastChart(
            forecastPoints: daily,
            actualPoints: const <ForecastDailyPoint>[],
            unit: unit,
            includesSimulation: false,
            emptyMessage: compatible.isEmpty
                ? 'No current forecast is available for this inventory unit.'
                : 'Daily chart values are unavailable in the compact saved summaries.',
            onViewForecastAccuracy: onViewForecastAccuracy,
          ),
        ],
      ),
    );
    final priorities = Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Planning priorities',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _forecastInk,
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'Open a product for current-stock restock guidance. Products without a saved forecast are not ranked.',
            style: TextStyle(fontSize: 12, color: _forecastMuted, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final item in page.items.take(5))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                item.productName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_snapshotStatusLabel(item.status)),
              trailing: const Icon(LucideIcons.chevronRight, size: 16),
              onTap: () => onSelectProduct(item.productId),
            ),
        ],
      ),
    );
    final supporting = Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _forecastLine),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Category outlook',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: _forecastInk,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Current forecasts on this page only',
                style: TextStyle(fontSize: 12, color: _forecastMuted),
              ),
              const SizedBox(height: 12),
              if (categoryRows.isEmpty)
                const Text(
                  'No compatible category forecasts are available.',
                  style: TextStyle(fontSize: 13, color: _forecastMuted),
                )
              else
                for (final row in categoryRows.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text('${_quantity(row.value)} $unit'),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _forecastLine),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sales evidence',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: _forecastInk,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Open Product Forecast for saved model and data-quality details. Summary pages do not contain historical sales records.',
                style: TextStyle(
                  fontSize: 12,
                  color: _forecastMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Column(
      children: [
        outlook,
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 900) {
              return Column(
                children: [priorities, const SizedBox(height: 16), supporting],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: priorities),
                const SizedBox(width: 24),
                Expanded(flex: 2, child: supporting),
              ],
            );
          },
        ),
      ],
    );
  }
}

List<ForecastDailyPoint> _snapshotDailyPageSeries(
  List<ForecastSnapshotItem> items,
  int days,
) {
  if (items.isEmpty) return const <ForecastDailyPoint>[];
  final totals = <DateTime, double>{};
  for (final item in items) {
    final values = item.forecastSummary?['daily'];
    if (values is! List || values.length < days) {
      return const <ForecastDailyPoint>[];
    }
    for (final raw in values.take(days)) {
      if (raw is! Map || raw['quantity'] is! num) {
        return const <ForecastDailyPoint>[];
      }
      final date = DateTime.tryParse(raw['date']?.toString() ?? '');
      if (date == null) return const <ForecastDailyPoint>[];
      final day = DateTime.utc(date.year, date.month, date.day);
      totals[day] = (totals[day] ?? 0) + (raw['quantity'] as num).toDouble();
    }
  }
  final dates = totals.keys.toList()..sort();
  if (dates.length != days) return const <ForecastDailyPoint>[];
  return dates
      .map((date) => ForecastDailyPoint(date: date, quantity: totals[date]!))
      .toList(growable: false);
}

class _SnapshotOverviewRow extends StatelessWidget {
  const _SnapshotOverviewRow({
    required this.item,
    required this.onTap,
    required this.compact,
  });
  final ForecastSnapshotItem item;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final points = item.forecastPoints('requested');
    final total = points.fold<double>(
      0,
      (sum, point) => sum + ((point['quantity'] as num?)?.toDouble() ?? 0),
    );
    final demand28 =
        (item.forecastSummary?['next_28_day_demand'] as num?)?.toDouble() ??
        (points.isEmpty ? null : total);
    final jobStatus = item.job['status']?.toString();
    final status =
        item.status == 'stale' &&
            (jobStatus == 'queued' || jobStatus == 'running')
        ? 'Stale · update $jobStatus'
        : _snapshotStatusLabel(item.status);
    final saved = item.lastSavedRecommendation;
    final savedValue = saved == null
        ? 'Unavailable'
        : '${_quantity((saved['suggested_restock'] as num?)?.toDouble() ?? 0)} ${saved['unit'] ?? item.unit}';
    final product = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.productName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          '${item.sku ?? 'No SKU'} · ${item.product['category'] ?? 'Uncategorized'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: _forecastMuted),
        ),
      ],
    );
    final statusValue = Text(
      status,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: item.status == 'completed'
            ? const Color(0xFF166534)
            : _forecastMuted,
      ),
    );
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 66),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _forecastHairline)),
        ),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: product),
                      const SizedBox(width: 8),
                      statusValue,
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'On hand: ${item.onHand == null ? 'Unavailable' : '${_quantity(item.onHand!)} ${item.unit}'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: _forecastBody,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '28-day demand: ${demand28 == null ? 'Unavailable' : '${_quantity(demand28)} ${item.unit}'}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12,
                            color: _forecastBody,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (saved != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        'Last saved suggestion: $savedValue · ${saved['saved_at']}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: _forecastMuted,
                        ),
                      ),
                    ),
                ],
              )
            : Row(
                children: [
                  Expanded(flex: 4, child: product),
                  Expanded(
                    flex: 2,
                    child: Text(
                      item.onHand == null
                          ? '—'
                          : '${_quantity(item.onHand!)} ${item.unit}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      demand28 == null
                          ? '—'
                          : '${_quantity(demand28)} ${item.unit}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          savedValue,
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (saved != null)
                          Text(
                            'saved ${saved['saved_at']}',
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: _forecastMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: statusValue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: _forecastMuted,
                  ),
                ],
              ),
      ),
    );
  }
}

String _snapshotStatusLabel(String status) => switch (status) {
  'completed' => 'Current',
  'stale' => 'Stale snapshot',
  'queued' => 'Queued',
  'running' => 'Running',
  'failed' => 'Failed',
  'superseded' => 'Superseded',
  'cancelled' => 'Cancelled',
  _ => 'Not prepared',
};

class _SnapshotProductPanel extends StatelessWidget {
  const _SnapshotProductPanel({
    required this.item,
    required this.loading,
    required this.error,
    required this.selectedModel,
    required this.forecastControls,
    required this.selectedWindow,
    required this.onWindowChanged,
    required this.onRetry,
  });
  final ForecastSnapshotItem? item;
  final bool loading;
  final String? error;
  final String selectedModel;
  final Widget forecastControls;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow> onWindowChanged;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final value = item;
    if (loading && value == null)
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    if (error != null && value == null)
      return _MessageCard(
        icon: LucideIcons.cloudOff,
        title: 'Forecast snapshot unavailable',
        message: error!,
        actionLabel: onRetry == null ? null : 'Retry',
        onAction: onRetry,
      );
    if (value == null)
      return const _MessageCard(
        icon: LucideIcons.chartNoAxesCombined,
        title: 'Select a product',
        message: 'Choose a product to retrieve its saved forecast snapshot.',
      );
    final requested = value.forecastPoints('requested');
    final recommendation = value.forecastPoints('recommendation');
    final preliminary = value.forecastPoints('preliminary');
    if (value.snapshot == null || requested.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _forecastLine),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final title = Text(
                  value.productName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                );
                if (constraints.maxWidth < 620) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 12), forecastControls],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    forecastControls,
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Forecast status: ${_snapshotStatusLabel(value.status)}',
              style: const TextStyle(color: _forecastMuted),
            ),
            const SizedBox(height: 10),
            Text(switch (value.status) {
              'queued' => 'This forecast is queued for background preparation.',
              'running' => 'A background worker is preparing this forecast.',
              'failed' =>
                'The latest forecast preparation failed. No forecast values are shown.',
              'stale' =>
                'A saved forecast exists, but its source inputs are no longer current.',
              _ =>
                'No saved forecast is available for ${_snapshotModelLabel(selectedModel)}. Opening this screen does not start model fitting.',
            }, style: const TextStyle(height: 1.45)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(LucideIcons.refreshCw, size: 15),
                label: const Text('Refresh status'),
              ),
            ],
          ],
        ),
      );
    }
    final points = requested
        .map(
          (point) => ForecastDailyPoint(
            date: DateTime.parse(point['date'].toString()),
            quantity: (point['quantity'] as num).toDouble(),
          ),
        )
        .toList(growable: false);
    final snapshot = value.snapshot!;
    final requestedForecast = snapshot['requested_forecast'] is Map
        ? Map<String, dynamic>.from(snapshot['requested_forecast'] as Map)
        : const <String, dynamic>{};
    final producer = requestedForecast['producer'] is Map
        ? Map<String, dynamic>.from(requestedForecast['producer'] as Map)
        : const <String, dynamic>{};
    final requestedIdentity = snapshot['requested_model'] is Map
        ? Map<String, dynamic>.from(snapshot['requested_model'] as Map)
        : const <String, dynamic>{};
    final savedRecommendation = value.lastSavedRecommendation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (value.status == 'stale')
          const _Notice(
            color: Colors.orange,
            icon: LucideIcons.refreshCw,
            text:
                'This saved forecast is stale. Its values remain visible with their stale status; do not treat them as current.',
          ),
        if (value.status == 'stale' &&
            (value.job['status'] == 'queued' ||
                value.job['status'] == 'running'))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'A refreshed forecast is ${value.job['status']}.',
              style: const TextStyle(fontSize: 12, color: _forecastMuted),
            ),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final productTitle = Text(
              '${value.productName} · ${value.unit}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            );
            if (constraints.maxWidth < 700) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  productTitle,
                  Align(
                    alignment: Alignment.centerRight,
                    child: forecastControls,
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: productTitle),
                forecastControls,
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final entry in <(String, int)>[
              ('Today', 1),
              ('7-day', 7),
              ('28-day', 28),
            ])
              Expanded(
                child: _SnapshotMetric(
                  label: entry.$1,
                  value: _sumSnapshotPoints(points, entry.$2),
                  unit: value.unit,
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _forecastLine),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Demand forecast',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      '${_snapshotModelLabel(selectedModel)} · ${producer['model_name'] ?? 'producer unavailable'}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 11,
                        color: _forecastMuted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth < 620) {
                      return DropdownButton<ForecastWindow>(
                        value: selectedWindow,
                        items: ForecastWindow.values
                            .map(
                              (window) => DropdownMenuItem(
                                value: window,
                                child: Text(window.label),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (window) {
                          if (window != null) onWindowChanged(window);
                        },
                      );
                    }
                    return _PeriodSelector(
                      selected: selectedWindow,
                      onChanged: onWindowChanged,
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 250,
                child: CustomPaint(
                  painter: _OverviewDemandChartPainter(
                    actualPoints: const [],
                    forecastPoints: points
                        .take(selectedWindow.days)
                        .toList(growable: false),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Forecast dates ${snapshot['forecast_start_date']} – ${snapshot['forecast_end_date']}; saved ${snapshot['created_at']}.',
                style: const TextStyle(fontSize: 12, color: _forecastMuted),
              ),
              const SizedBox(height: 4),
              Text(
                'Requested ${requestedIdentity['key'] ?? _snapshotModelLabel(selectedModel)} v${requestedIdentity['version'] ?? 'unavailable'} · ${snapshot['history_window_days'] ?? 'unavailable'}-day history · source ${snapshot['source_data_as_of'] ?? 'unavailable'}',
                style: const TextStyle(fontSize: 11, color: _forecastMuted),
              ),
              if (requestedForecast['fallback_reason'] != null &&
                  requestedForecast['fallback_reason']
                      .toString()
                      .isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Stored fallback: ${requestedForecast['fallback_reason']}',
                  style: const TextStyle(fontSize: 11, color: _forecastMuted),
                ),
              ],
            ],
          ),
        ),
        if (savedRecommendation != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _forecastLine),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Last saved restock suggestion: ${_quantity((savedRecommendation['suggested_restock'] as num?)?.toDouble() ?? 0)} ${savedRecommendation['unit'] ?? value.unit} · saved ${savedRecommendation['saved_at']}. This is historical recommendation data, not a recalculation against current stock.',
              style: const TextStyle(
                fontSize: 12,
                color: _forecastBody,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SnapshotRoleCard(
                title: 'Recommendation forecast',
                points: recommendation,
                unit: value.unit,
                producer: snapshot['recommendation_forecast'],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SnapshotRoleCard(
                title: 'Preliminary forecast',
                points: preliminary,
                unit: value.unit,
                producer: snapshot['preliminary_forecast'],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _forecastAccentSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            'This immutable result stores demand forecasts. A current-stock restock recommendation must be evaluated against live inventory and policy inputs; the snapshot view does not recompute or substitute one.',
            style: TextStyle(fontSize: 13, height: 1.45, color: _forecastBody),
          ),
        ),
      ],
    );
  }
}

double _sumSnapshotPoints(List<ForecastDailyPoint> points, int days) =>
    points.take(days).fold<double>(0, (sum, point) => sum + point.quantity);
String _snapshotModelLabel(String model) =>
    model == 'calibrated_blend' ? 'Calibrated blend' : model;

class _SnapshotMetric extends StatelessWidget {
  const _SnapshotMetric({
    required this.label,
    required this.value,
    required this.unit,
  });
  final String label;
  final double value;
  final String unit;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _forecastLine),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: _forecastMuted),
        ),
        const SizedBox(height: 4),
        Text(
          '${_quantity(value)} $unit',
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _SnapshotRoleCard extends StatelessWidget {
  const _SnapshotRoleCard({
    required this.title,
    required this.points,
    required this.unit,
    required this.producer,
  });
  final String title;
  final List<Map<String, dynamic>> points;
  final String unit;
  final Object? producer;
  @override
  Widget build(BuildContext context) {
    final total = points.fold<double>(
      0,
      (sum, point) => sum + ((point['quantity'] as num?)?.toDouble() ?? 0),
    );
    final metadata = producer is Map
        ? Map<String, dynamic>.from(producer as Map)
        : const <String, dynamic>{};
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            points.isEmpty
                ? 'Unavailable in this result'
                : '${points.length} saved days · ${_quantity(total)} $unit',
            style: const TextStyle(color: _forecastBody),
          ),
          const SizedBox(height: 6),
          Text(
            'Produced by ${metadata['model_name'] ?? metadata['key'] ?? 'an unavailable model'}',
            style: const TextStyle(fontSize: 11, color: _forecastMuted),
          ),
        ],
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
    this.controls,
    this.savedPage,
    this.selectedModel,
    this.analyses = const <String, ForecastAnalysis>{},
    this.products = const <InventoryItem>[],
    this.selectedScopeKey,
    this.onScopeChanged,
    this.loading = false,
    this.stale = false,
    this.error,
    this.requestWarnings = const [],
    this.onRetry,
    this.onSelectProduct,
    this.onViewForecastAccuracy,
  });

  final PortfolioForecastSnapshot? snapshot;
  final Map<String, ForecastAnalysis> analyses;
  final List<InventoryItem> products;
  final String? selectedScopeKey;
  final ValueChanged<String>? onScopeChanged;
  final Widget? controls;
  final ForecastSnapshotPage? savedPage;
  final String? selectedModel;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow> onWindowChanged;
  final bool loading;
  final bool stale;
  final String? error;
  final List<String> requestWarnings;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onSelectProduct;
  final VoidCallback? onViewForecastAccuracy;

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
        if (savedPage?.items.any((item) => item.status == 'stale') == true)
          const _Notice(color: Colors.orange, icon: LucideIcons.clock,
            text: 'Includes stale saved forecasts. Charts retain their original forecast dates; these are not current store-wide demand estimates.'),
        if (savedPage != null)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(
            'Partial page coverage: ${savedPage!.items.where((item) => item.status == "completed").length} current forecasts on this page; ${savedPage!.totalCount} matching products. Totals below cover this page only.',
            style: const TextStyle(fontSize: 12, color: _forecastMuted))),
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
        _StoreOutlookCard(
          analyses: analyses,
          savedPage: savedPage,
          selectedModel: selectedModel,
          products: products,
          selectedScopeKey: selectedScopeKey,
          onScopeChanged: onScopeChanged,
          selectedWindow: selectedWindow,
          onWindowChanged: onWindowChanged,
          controls: controls,
          onViewForecastAccuracy: onViewForecastAccuracy,
        ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final priorities = _PlanningPriorityCard(
              unavailable: savedPage != null && analyses.isEmpty,
              analyses: analyses,
              onSelectProduct: onSelectProduct,
            );
            final supporting = Column(
              children: [
                _CategoryOutlookCard(snapshot: value, window: selectedWindow),
                const SizedBox(height: 16),
                _SalesEvidenceCard(
                  evidenceAvailable: savedPage == null,
                  analyses: analyses.values.toList(growable: false),
                  products: products,
                ),
              ],
            );
            if (constraints.maxWidth < 900) {
              return Column(
                children: [priorities, const SizedBox(height: 16), supporting],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: priorities),
                const SizedBox(width: 24),
                Expanded(flex: 2, child: supporting),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StoreOutlookCard extends StatelessWidget {
  const _StoreOutlookCard({
    required this.analyses,
    required this.products,
    required this.selectedWindow,
    required this.onWindowChanged,
    this.selectedScopeKey,
    this.onScopeChanged,
    this.controls,
    this.savedPage,
    this.selectedModel,
    this.onViewForecastAccuracy,
  });

  final Map<String, ForecastAnalysis> analyses;
  final List<InventoryItem> products;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow> onWindowChanged;
  final String? selectedScopeKey;
  final ValueChanged<String>? onScopeChanged;
  final Widget? controls;
  final ForecastSnapshotPage? savedPage;
  final String? selectedModel;
  final VoidCallback? onViewForecastAccuracy;

  @override
  Widget build(BuildContext context) {
    final scopes = savedPage == null ? _buildOverviewScopes(products, analyses) : _savedScopes(savedPage!, products);
    final selected = scopes.cast<_OverviewScope?>().firstWhere(
      (scope) => scope?.key == selectedScopeKey,
      orElse: () {
        if (savedPage != null) {
          for (final scope in scopes) {
            if (scope.kind == _OverviewScopeKind.unit &&
                savedPage!.items.any((item) => scope.productIds.contains(item.productId) && item.status == 'completed')) {
              return scope;
            }
          }
        }
        return scopes.isEmpty ? null : scopes.first;
      },
    );
    final scopeRows = savedPage == null || selected == null
        ? const <ForecastSnapshotItem>[]
        : savedPage!.items.where((item) => selected.productIds.contains(item.productId)).toList(growable: false);
    final usableRows = _overviewUsableSavedItems(scopeRows);
    final points = selected == null
        ? const <ForecastDailyPoint>[]
        : savedPage == null
        ? _overviewSeries(selected, analyses, selectedWindow.days)
        : _snapshotDailyPageSeries(usableRows, selectedWindow.days);
    final total = points.fold<double>(0, (sum, point) => sum + point.quantity);
    if (_forecastOverviewTrace && ForecastingPerformanceDiagnostics.enabled && savedPage != null) {
      final itemDetails = scopeRows.map((item) {
        final summary = item.forecastSummary;
        final daily = summary?['daily'];
        final firstDate = daily is List && daily.isNotEmpty && daily.first is Map
            ? (daily.first as Map)['date'] : null;
        final lastDate = daily is List && daily.isNotEmpty && daily.last is Map
            ? (daily.last as Map)['date'] : null;
        return '${item.productId}:${item.status}:summary=${summary != null}:'
            'daily=${daily is List ? daily.length : 0}:'
            'first=$firstDate:last=$lastDate:'
            'seven=${summary?['next_7_day_demand']}:'
            'twenty_eight=${summary?['next_28_day_demand']}';
      }).join(',');
      ForecastingPerformanceDiagnostics.event(
        'snapshot.overview.aggregate',
        ForecastingPerformanceDiagnostics.newOperationId('overview-aggregate'),
        'model=$selectedModel page=${savedPage!.page} unit=${selected?.unit} '
        'requested_scope=$selectedScopeKey selected_scope=${selected?.key} '
        'scope_type=${selected?.kind.name} window=${selectedWindow.days} '
        'page_ids=${savedPage!.items.map((item) => item.productId).join(',')} '
        'scope_ids=${selected?.productIds.join(',')} '
        'retained_ids=${usableRows.map((item) => item.productId).join(',')} '
        'matching=[$itemDetails] points=${points.length} total=$total',
      );
    }
    final selectedAnalyses = selected == null
        ? const <ForecastAnalysis>[]
        : selected.productIds
              .map((id) => analyses[id])
              .whereType<ForecastAnalysis>()
              .toList(growable: false);
    final includesSimulation = selectedAnalyses.any(
      (analysis) =>
          analysis.synthetic ||
          (analysis.product.sku?.startsWith('SIM-') ?? false),
    );
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final horizon = _PeriodSelector(
                selected: selectedWindow,
                onChanged: onWindowChanged,
                includeToday: false,
              );
              final scope = _OverviewScopeSelector(
                scopes: scopes,
                selected: selected,
                onSelected: onScopeChanged,
              );
              final compactScope = SizedBox(
                width: min(220.0, constraints.maxWidth),
                child: scope,
              );
              if (constraints.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [compactScope, const SizedBox(height: 12), SingleChildScrollView(scrollDirection: Axis.horizontal, child: horizon)],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [compactScope, const SizedBox(width: 16), horizon],
              );
            },
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final headline = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Expected demand · ${selectedWindow == ForecastWindow.next7Days ? 'Short-term (7 days)' : 'Planning (28 days)'}',
                    style: const TextStyle(fontSize: 13, color: _forecastMuted),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: selected == null || points.isEmpty ? '—' : _quantity(total),
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -1,
                            color: _forecastInk,
                          ),
                        ),
                        if (selected != null)
                          TextSpan(
                            text: ' ${selected.unit}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: _forecastMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
              if (constraints.maxWidth < 660 || controls == null) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    headline,
                    if (controls != null) ...[
                      const SizedBox(height: 12),
                      controls!,
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: headline),
                  const SizedBox(width: 16),
                  controls!,
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          _OverviewForecastChart(
            key: const Key('forecast-primary-demand-chart'),
            forecastPoints: points,
            actualPoints: const <ForecastDailyPoint>[],
            unit: selected?.unit,
            includesSimulation: includesSimulation,
            onViewForecastAccuracy: onViewForecastAccuracy,
            emptyMessage: selected == null
                ? 'No compatible forecast scope is available.'
                : 'No reliable forecast is available for this scope.',
          ),
        ],
      ),
    );
  }
}

class _SalesEvidenceCard extends StatefulWidget {
  const _SalesEvidenceCard({required this.analyses, required this.products, this.evidenceAvailable = true});

  final bool evidenceAvailable;

  final List<ForecastAnalysis> analyses;
  final List<InventoryItem> products;

  @override
  State<_SalesEvidenceCard> createState() => _SalesEvidenceCardState();
}

class _SalesEvidenceCardState extends State<_SalesEvidenceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final noRecordedSales =
        widget.analyses
            .where(
              (analysis) =>
                  analysis.forecast.isColdStart &&
                  analysis.forecast.coldStartReason == 'no_history',
            )
            .toList(growable: false)
          ..sort(
            (left, right) => left.product.name.compareTo(right.product.name),
          );
    final limitedHistory =
        widget.analyses
            .where(
              (analysis) =>
                  analysis.forecast.isColdStart &&
                  analysis.forecast.coldStartReason != 'no_history',
            )
            .toList(growable: false)
          ..sort(
            (left, right) => left.product.name.compareTo(right.product.name),
          );
    final productsById = {
      for (final product in widget.products) product.id: product,
    };
    final evaluatedIds = widget.analyses
        .map((analysis) => analysis.product.productId)
        .toSet();
    final unavailable = widget.products
        .where((product) => !evaluatedIds.contains(product.id))
        .length;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('forecast-sales-gaps-toggle'),
            onTap: noRecordedSales.isEmpty
                ? null
                : () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    widget.evidenceAvailable ? '${noRecordedSales.length}' : '?',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: _forecastInk,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Products with no recorded sales',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _forecastInk,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          widget.evidenceAvailable ? 'In stock, but no completed sales evidence is available.' : 'Sales evidence is available in the product forecast; this summary does not include it.',
                          style: TextStyle(fontSize: 11, color: _forecastMuted),
                        ),
                      ],
                    ),
                  ),
                  if (noRecordedSales.isNotEmpty)
                    Icon(
                      _expanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 17,
                      color: _forecastMuted,
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: _forecastHairline)),
              ),
              child: Column(
                children: [
                  for (final analysis in noRecordedSales)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 10,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: _forecastHairline),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              analysis.product.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: _forecastInk,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _withUnit(
                              analysis
                                      .preliminaryRestockingInsight
                                      .availableInventory ??
                                  productsById[analysis.product.productId]
                                      ?.quantity,
                              analysis.product.unit,
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: _forecastBody,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (limitedHistory.isNotEmpty || unavailable > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 13),
              child: Text(
                [
                  if (limitedHistory.isNotEmpty)
                    '${limitedHistory.length} with insufficient history',
                  if (unavailable > 0) '$unavailable not evaluated',
                ].join(' · '),
                style: const TextStyle(fontSize: 10, color: _forecastFaint),
              ),
            ),
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({
    required this.selected,
    required this.onChanged,
    this.includeToday = true,
  });

  final ForecastWindow selected;
  final ValueChanged<ForecastWindow> onChanged;
  final bool includeToday;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('forecast-period-selector'),
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: _forecastBackground,
      border: Border.all(color: _forecastLine),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: ForecastWindow.values
          .where((window) => includeToday || window != ForecastWindow.today)
          .map(
            (window) => InkWell(
              key: Key('forecast-period-${window.name}'),
              onTap: () => onChanged(window),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: window == selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: window == selected
                      ? const [
                          BoxShadow(
                            color: Color(0x0D1C1917),
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  window == ForecastWindow.next7Days
                      ? 'Short-term (7 days)'
                      : window == ForecastWindow.next28Days
                      ? 'Planning (28 days)'
                      : 'Today',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: window == selected ? _forecastInk : _forecastMuted,
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false),
    ),
  );
}

enum _OverviewScopeKind { unit, category, product }

class _OverviewScope {
  const _OverviewScope({
    required this.key,
    required this.kind,
    required this.label,
    required this.meta,
    required this.unit,
    required this.productIds,
  });

  final String key;
  final _OverviewScopeKind kind;
  final String label;
  final String meta;
  final String unit;
  final List<String> productIds;
}

List<_OverviewScope> _buildOverviewScopes(
  List<InventoryItem> products,
  Map<String, ForecastAnalysis> analyses,
) {
  final productsById = {for (final product in products) product.id: product};
  final units = <String, List<String>>{};
  final categories =
      <String, ({String label, String unit, List<String> ids})>{};
  final productScopes = <_OverviewScope>[];
  for (final entry in analyses.entries) {
    final analysis = entry.value;
    final unit = analysis.forecast.unit.trim().toLowerCase();
    if (unit.isEmpty) continue;
    units.putIfAbsent(unit, () => <String>[]).add(entry.key);
    final inventoryProduct = productsById[entry.key];
    if (inventoryProduct != null) {
      final category = inventoryProduct.category.trim().isEmpty
          ? 'Uncategorized'
          : inventoryProduct.category.trim();
      final key = '${category.toLowerCase()}::$unit';
      final group = categories.putIfAbsent(
        key,
        () => (label: category, unit: unit, ids: <String>[]),
      );
      group.ids.add(entry.key);
    }
    productScopes.add(
      _OverviewScope(
        key: 'product:${entry.key}',
        kind: _OverviewScopeKind.product,
        label: analysis.product.name,
        meta: unit,
        unit: unit,
        productIds: <String>[entry.key],
      ),
    );
  }
  final unitScopes =
      units.entries
          .map(
            (entry) => _OverviewScope(
              key: 'unit:${entry.key}',
              kind: _OverviewScopeKind.unit,
              label: 'All ${entry.key}',
              meta: '${entry.value.length} product(s)',
              unit: entry.key,
              productIds: List<String>.unmodifiable(entry.value),
            ),
          )
          .toList(growable: false)
        ..sort((left, right) => left.label.compareTo(right.label));
  final categoryScopes =
      categories.entries
          .map(
            (entry) => _OverviewScope(
              key: 'category:${entry.key}',
              kind: _OverviewScopeKind.category,
              label: entry.value.label,
              meta: entry.value.unit,
              unit: entry.value.unit,
              productIds: List<String>.unmodifiable(entry.value.ids),
            ),
          )
          .toList(growable: false)
        ..sort((left, right) => left.label.compareTo(right.label));
  productScopes.sort((left, right) => left.label.compareTo(right.label));
  return <_OverviewScope>[...unitScopes, ...categoryScopes, ...productScopes];
}

List<ForecastDailyPoint> _overviewSeries(
  _OverviewScope scope,
  Map<String, ForecastAnalysis> analyses,
  int days,
) {
  final values = <DateTime, double>{};
  for (final productId in scope.productIds) {
    final analysis = analyses[productId];
    if (analysis == null || analysis.forecast.isColdStart) continue;
    if (analysis.forecast.unit.trim().toLowerCase() != scope.unit) continue;
    for (final point in analysis.forecast.daily.take(days)) {
      final date = DateTime.utc(
        point.date.year,
        point.date.month,
        point.date.day,
      );
      values[date] = (values[date] ?? 0) + point.quantity;
    }
  }
  final dates = values.keys.toList()..sort();
  return dates
      .map((date) => ForecastDailyPoint(date: date, quantity: values[date]!))
      .toList(growable: false);
}

class _OverviewScopeSelector extends StatefulWidget {
  const _OverviewScopeSelector({
    required this.scopes,
    required this.selected,
    required this.onSelected,
  });

  final List<_OverviewScope> scopes;
  final _OverviewScope? selected;
  final ValueChanged<String>? onSelected;

  @override
  State<_OverviewScopeSelector> createState() => _OverviewScopeSelectorState();
}

class _OverviewScopeSelectorState extends State<_OverviewScopeSelector> {
  final MenuController _menuController = MenuController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final menuWidth = min(360.0, MediaQuery.sizeOf(context).width - 32);
    final menuHeight = min(
      360.0,
      max(180.0, MediaQuery.sizeOf(context).height - 120),
    );
    final query = _query.trim().toLowerCase();
    final matches = widget.scopes
        .where(
          (scope) =>
              query.isEmpty ||
              scope.label.toLowerCase().contains(query) ||
              scope.meta.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final grouped = <Widget>[];
    for (final kind in _OverviewScopeKind.values) {
      final values = matches.where((scope) => scope.kind == kind).toList();
      if (values.isEmpty) continue;
      grouped.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text(
            switch (kind) {
              _OverviewScopeKind.unit => 'Inventory unit',
              _OverviewScopeKind.category => 'Product category',
              _OverviewScopeKind.product => 'Individual product',
            },
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _forecastMuted,
            ),
          ),
        ),
      );
      for (final scope in values) {
        final selected = scope.key == widget.selected?.key;
        grouped.add(
          InkWell(
            onTap: () {
              _menuController.close();
              widget.onSelected?.call(scope.key);
            },
            child: Container(
              color: selected ? _forecastBackground : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: selected
                        ? const Icon(
                            LucideIcons.check,
                            size: 16,
                            color: _forecastAccent,
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      scope.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: _forecastInk),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    scope.meta,
                    style: const TextStyle(fontSize: 11, color: _forecastFaint),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return MenuAnchor(
      controller: _menuController,
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(8),
        shadowColor: WidgetStatePropertyAll(Color(0x1A1C1917)),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            side: BorderSide(color: _forecastLine),
          ),
        ),
      ),
      onOpen: () {
        _searchController.clear();
        setState(() => _query = '');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      },
      onClose: _searchFocus.unfocus,
      menuChildren: [
        SizedBox(
          width: menuWidth,
          height: menuHeight,
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                  child: TextField(
                    key: const Key('forecast-scope-search'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.search, size: 17),
                      hintText: 'Search units, categories, products',
                      border: UnderlineInputBorder(
                        borderSide: BorderSide(color: _forecastHairline),
                      ),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: _forecastHairline),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                Expanded(
                  child: grouped.isEmpty
                      ? const Center(
                          child: Text(
                            'No matches',
                            style: TextStyle(color: _forecastMuted),
                          ),
                        )
                      : ListView(primary: false, children: grouped),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => OutlinedButton(
        key: const Key('forecast-overview-scope-selector'),
        onPressed: widget.scopes.isEmpty || widget.onSelected == null
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        style: OutlinedButton.styleFrom(
          foregroundColor: _forecastInk,
          side: const BorderSide(color: _forecastLine),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 290),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(switch (widget.selected?.kind) {
                _OverviewScopeKind.category => 'Category',
                _OverviewScopeKind.product => 'Product',
                _ => 'Unit',
              }, style: const TextStyle(fontSize: 13, color: _forecastMuted)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.selected?.label ?? 'No compatible scope',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                controller.isOpen
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
                size: 15,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForecastMethodOption {
  const _ForecastMethodOption({
    required this.id,
    required this.name,
    required this.description,
    this.tag,
  });

  final String id;
  final String name;
  final String description;
  final String? tag;
}

const _forecastMethodOptions = <_ForecastMethodOption>[
  _ForecastMethodOption(
    id: 'calibrated_blend',
    name: 'Calibrated Blend',
    tag: 'Default',
    description:
        'Primary calibrated demand estimate. Combines several methods and corrects for past over- or under-estimates.',
  ),
  _ForecastMethodOption(
    id: 'lightgbm',
    name: 'LightGBM',
    description:
        'Machine-learning baseline that learns from past sales patterns. Used for preliminary restock suggestions.',
  ),
  _ForecastMethodOption(
    id: 'mean28',
    name: 'Mean28',
    description:
        'Simple recent-demand comparison: average daily sales over the last 28 days.',
  ),
  _ForecastMethodOption(
    id: 'seasonal_experimental',
    name: 'Seasonal Experimental',
    tag: 'Experimental',
    description:
        'Experimental model exploring seasonal behavior. Still being tested.',
  ),
];

class _ForecastMethodMenu extends StatelessWidget {
  const _ForecastMethodMenu({
    required this.selectedModel,
    required this.enabled,
    required this.onSelected,
    this.triggerKey = const Key('forecast-overview-method-selector'),
    this.maxMenuWidth = 380,
    this.triggerFontSize = 12,
    this.alignMenuEnd = false,
    this.footerText =
        'Changes this chart only. Restock suggestions always use LightGBM.',
  });

  final String selectedModel;
  final bool enabled;
  final ValueChanged<String> onSelected;
  final Key triggerKey;
  final double maxMenuWidth;
  final double triggerFontSize;
  final bool alignMenuEnd;
  final String footerText;

  @override
  Widget build(BuildContext context) {
    final selected = _forecastMethodOptions.firstWhere(
      (option) => option.id == selectedModel,
      orElse: () => _forecastMethodOptions.first,
    );
    final menuWidth = min(maxMenuWidth, MediaQuery.sizeOf(context).width - 32);
    final menuHeight = min(
      430.0,
      max(220.0, MediaQuery.sizeOf(context).height - 120),
    );
    final menuController = MenuController();
    return MenuAnchor(
      controller: menuController,
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        alignment: alignMenuEnd
            ? AlignmentDirectional.bottomEnd
            : AlignmentDirectional.bottomStart,
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shadowColor: const WidgetStatePropertyAll(Color(0x1A1C1917)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            side: BorderSide(color: _forecastLine),
          ),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: menuWidth,
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: menuHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in _forecastMethodOptions)
                      Builder(
                        builder: (context) {
                          final active = option.id == selectedModel;
                          return InkWell(
                            onTap: () {
                              menuController.close();
                              onSelected(option.id);
                            },
                            child: Container(
                              width: double.infinity,
                              color: active
                                  ? _forecastBackground
                                  : Colors.transparent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 18,
                                    child: active
                                        ? const Icon(
                                            LucideIcons.check,
                                            size: 16,
                                            color: _forecastAccent,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Wrap(
                                          spacing: 7,
                                          runSpacing: 4,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              option.name,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: _forecastInk,
                                              ),
                                            ),
                                            if (option.tag != null)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      option.tag ==
                                                          'Experimental'
                                                      ? _forecastAccentSoft
                                                      : _forecastBackground,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  option.tag!,
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                    color:
                                                        option.tag ==
                                                            'Experimental'
                                                        ? _forecastAccentDark
                                                        : _forecastMuted,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          option.description,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            height: 1.35,
                                            color: _forecastMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    const Divider(height: 1, color: _forecastHairline),
                    Padding(
                      padding: EdgeInsets.fromLTRB(14, 10, 14, 12),
                      child: Text(
                        footerText,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: _forecastMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => TextButton(
        key: triggerKey,
        onPressed: enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
        style: TextButton.styleFrom(
          foregroundColor: _forecastBody,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Forecast method: ',
              style: TextStyle(
                fontSize: triggerFontSize,
                color: _forecastMuted,
              ),
            ),
            Flexible(
              child: Text(
                selected.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: triggerFontSize,
                  fontWeight: FontWeight.w600,
                  color: _forecastBody,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              controller.isOpen
                  ? LucideIcons.chevronUp
                  : LucideIcons.chevronDown,
              size: 14,
              color: _forecastMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewForecastChart extends StatelessWidget {
  const _OverviewForecastChart({
    super.key,
    required this.forecastPoints,
    required this.actualPoints,
    required this.unit,
    required this.includesSimulation,
    required this.emptyMessage,
    this.onViewForecastAccuracy,
  });

  final List<ForecastDailyPoint> forecastPoints;
  final List<ForecastDailyPoint> actualPoints;
  final String? unit;
  final bool includesSimulation;
  final String emptyMessage;
  final VoidCallback? onViewForecastAccuracy;

  @override
  Widget build(BuildContext context) {
    if (forecastPoints.isEmpty && actualPoints.isEmpty) {
      return Container(
        height: 230,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: _forecastLine),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          emptyMessage,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: _forecastMuted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 252,
          child: CustomPaint(
            painter: _OverviewDemandChartPainter(
              actualPoints: actualPoints,
              forecastPoints: forecastPoints,
            ),
            size: const Size(double.infinity, 252),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ChartLegendItem(
              color: const Color(0xFF57534E),
              label: actualPoints.isEmpty
                  ? 'Actual sales unavailable'
                  : 'Actual sales',
              muted: actualPoints.isEmpty,
            ),
            _ChartLegendItem(
              color: _forecastAccent,
              label: 'Predicted demand${unit == null ? '' : ' ($unit)'}',
              dashed: true,
            ),
          ],
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            if (includesSimulation)
              const Text(
                'Simulation data',
                style: TextStyle(fontSize: 11, color: _forecastFaint),
              ),
            const Spacer(),
            TextButton(
              key: const Key('forecast-view-accuracy'),
              onPressed: onViewForecastAccuracy,
              style: TextButton.styleFrom(
                foregroundColor: _forecastMuted,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                minimumSize: const Size(0, 28),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'View forecast accuracy',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(width: 4),
                  Icon(LucideIcons.arrowRight, size: 13),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChartLegendItem extends StatelessWidget {
  const _ChartLegendItem({
    required this.color,
    required this.label,
    this.dashed = false,
    this.muted = false,
  });

  final Color color;
  final String label;
  final bool dashed;
  final bool muted;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 22,
        height: 4,
        child: CustomPaint(
          painter: _LegendLinePainter(color: color, dashed: dashed),
        ),
      ),
      const SizedBox(width: 7),
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: muted ? _forecastFaint : _forecastMuted,
        ),
      ),
    ],
  );
}

class _LegendLinePainter extends CustomPainter {
  const _LegendLinePainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (!dashed) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(min(x + 4, size.width), size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LegendLinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}

class _OverviewDemandChartPainter extends CustomPainter {
  const _OverviewDemandChartPainter({
    required this.actualPoints,
    required this.forecastPoints,
  });

  final List<ForecastDailyPoint> actualPoints;
  final List<ForecastDailyPoint> forecastPoints;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 42.0;
    const right = 12.0;
    const top = 12.0;
    const bottom = 30.0;
    final chartHeight = size.height - top - bottom;
    final chartRight = size.width - right;
    final hasActual = actualPoints.isNotEmpty;
    final todayX = hasActual ? left + (chartRight - left) * .46 : left + 2;
    final quantities = <double>[
      ...actualPoints.map((point) => point.quantity),
      ...forecastPoints.map((point) => point.quantity),
    ];
    final maximum = quantities.fold<double>(0, max);
    final scale = maximum <= 0 ? 1.0 : maximum;
    double y(double value) => top + chartHeight - (value / scale) * chartHeight;

    final grid = Paint()
      ..color = _forecastHairline
      ..strokeWidth = 1;
    for (var row = 0; row < 5; row++) {
      final value = scale * row / 4;
      final lineY = y(value);
      canvas.drawLine(Offset(left, lineY), Offset(chartRight, lineY), grid);
      final label = TextPainter(
        text: TextSpan(
          text: _quantity(value),
          style: const TextStyle(fontSize: 10, color: _forecastMuted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(left - label.width - 7, lineY - label.height / 2),
      );
    }

    final divider = Paint()
      ..color = _forecastFaint
      ..strokeWidth = 1;
    for (var offset = top; offset < top + chartHeight; offset += 6) {
      canvas.drawLine(
        Offset(todayX, offset),
        Offset(todayX, min(offset + 3, top + chartHeight)),
        divider,
      );
    }

    Path linePath(List<ForecastDailyPoint> points, double startX, double endX) {
      final path = Path();
      for (var index = 0; index < points.length; index++) {
        final x = points.length == 1
            ? startX
            : startX + (endX - startX) * index / (points.length - 1);
        final pointY = y(points[index].quantity);
        if (index == 0) {
          path.moveTo(x, pointY);
        } else {
          path.lineTo(x, pointY);
        }
      }
      return path;
    }

    if (hasActual) {
      canvas.drawPath(
        linePath(actualPoints, left, todayX),
        Paint()
          ..color = const Color(0xFF57534E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    if (forecastPoints.isNotEmpty) {
      final forecastPath = linePath(forecastPoints, todayX, chartRight);
      final paint = Paint()
        ..color = _forecastAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (final metric in forecastPath.computeMetrics()) {
        for (var distance = 0.0; distance < metric.length; distance += 10) {
          canvas.drawPath(
            metric.extractPath(distance, min(distance + 6, metric.length)),
            paint,
          );
        }
      }
    }

    void drawDate(String text, double x, TextAlign align) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 10, color: _forecastMuted),
        ),
        textDirection: TextDirection.ltr,
        textAlign: align,
      )..layout();
      final dx = switch (align) {
        TextAlign.left => x,
        TextAlign.right => x - painter.width,
        _ => x - painter.width / 2,
      };
      painter.paint(canvas, Offset(dx, size.height - painter.height));
    }

    if (hasActual) {
      drawDate(
        _shortForecastDate(actualPoints.first.date),
        left,
        TextAlign.left,
      );
    }
    drawDate('Today', todayX, hasActual ? TextAlign.center : TextAlign.left);
    if (forecastPoints.isNotEmpty) {
      drawDate(
        _shortForecastDate(forecastPoints.last.date),
        chartRight,
        TextAlign.right,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OverviewDemandChartPainter oldDelegate) =>
      oldDelegate.actualPoints != actualPoints ||
      oldDelegate.forecastPoints != forecastPoints;
}

String _shortForecastDate(DateTime date) {
  const months = <String>[
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
  return '${months[date.month - 1]} ${date.day}';
}

class _PrimaryForecastChart extends StatelessWidget {
  const _PrimaryForecastChart({
    super.key,
    required this.points,
    required this.unit,
    required this.historicalAvailable,
    required this.emptyMessage,
  });

  final List<ForecastDailyPoint> points;
  final String? unit;
  final bool historicalAvailable;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return Container(
        constraints: const BoxConstraints(minHeight: 230),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: _forecastLine, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          emptyMessage,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _forecastMuted),
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 260,
          child: CustomPaint(
            painter: _DemandSparklinePainter(points),
            size: const Size(double.infinity, 260),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(width: 22, height: 2, color: _forecastAccent),
            const SizedBox(width: 8),
            Text(
              'Predicted demand${unit == null ? '' : ' ($unit)'}',
              style: const TextStyle(fontSize: 12, color: _forecastMuted),
            ),
            const SizedBox(width: 18),
            Container(width: 22, height: 2, color: _forecastFaint),
            const SizedBox(width: 8),
            Text(
              historicalAvailable ? 'Actual sales' : 'Actual sales unavailable',
              style: const TextStyle(fontSize: 12, color: _forecastFaint),
            ),
            const Spacer(),
            Text(
              points.length == 1 ? 'Today' : '${points.length}-day forecast',
              style: const TextStyle(fontSize: 11, color: _forecastFaint),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProductForecastChart extends StatefulWidget {
  const _ProductForecastChart({
    super.key,
    required this.points,
    required this.unit,
    required this.synthetic,
    required this.emptyMessage,
    this.onViewForecastAccuracy,
  });

  final List<ForecastDailyPoint> points;
  final String unit;
  final bool synthetic;
  final String emptyMessage;
  final VoidCallback? onViewForecastAccuracy;

  @override
  State<_ProductForecastChart> createState() => _ProductForecastChartState();
}

class _ProductForecastChartState extends State<_ProductForecastChart> {
  static const _height = 260.0;
  static const _left = 44.0;
  static const _right = 12.0;
  int? _hoverIndex;

  void _updateHover(double dx, double width) {
    if (widget.points.isEmpty) return;
    final plotWidth = max(1.0, width - _left - _right);
    final relative = ((dx - _left) / plotWidth).clamp(0.0, 1.0);
    final index = widget.points.length == 1
        ? 0
        : (relative * (widget.points.length - 1)).round();
    if (index != _hoverIndex) setState(() => _hoverIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return Container(
        constraints: const BoxConstraints(minHeight: 230),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: _forecastLine),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _forecastMuted),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final hover = _hoverIndex;
              final plotWidth = max(1.0, width - _left - _right);
              final pointX = hover == null
                  ? 0.0
                  : widget.points.length == 1
                  ? _left + plotWidth / 2
                  : _left + hover / (widget.points.length - 1) * plotWidth;
              final tooltipWidth = min(184.0, width);
              final preferredLeft = pointX > width * .6
                  ? pointX - tooltipWidth - 12
                  : pointX + 12;
              final tooltipLeft = preferredLeft
                  .clamp(0.0, max(0.0, width - tooltipWidth))
                  .toDouble();
              return MouseRegion(
                onHover: (event) {
                  final box = context.findRenderObject();
                  if (box is! RenderBox) return;
                  _updateHover(box.globalToLocal(event.position).dx, width);
                },
                onExit: (_) {
                  if (_hoverIndex != null) setState(() => _hoverIndex = null);
                },
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _ProductForecastChartPainter(
                          points: widget.points,
                          hoverIndex: hover,
                        ),
                      ),
                    ),
                    if (hover != null)
                      Positioned(
                        left: tooltipLeft,
                        top: 8,
                        width: tooltipWidth,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: _forecastLine),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x0D1C1917),
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${_forecastTooltipDate(widget.points[hover].date)} · Forecast',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: _forecastMuted,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: _quantity(
                                          widget.points[hover].quantity,
                                        ),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: _forecastInk,
                                        ),
                                      ),
                                      TextSpan(
                                        text: ' ${widget.unit}',
                                        style: const TextStyle(
                                          color: _forecastBody,
                                        ),
                                      ),
                                    ],
                                  ),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 24,
          runSpacing: 10,
          children: [
            const Wrap(
              spacing: 20,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ForecastLegendItem(
                  color: _forecastAccent,
                  label: 'Predicted demand',
                  dashed: true,
                ),
                _ForecastLegendItem(
                  color: _forecastFaint,
                  label: 'Actual sales unavailable',
                ),
              ],
            ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.synthetic)
                  const Text(
                    'Simulation data',
                    style: TextStyle(fontSize: 12, color: _forecastFaint),
                  ),
                if (widget.onViewForecastAccuracy != null)
                  TextButton(
                    onPressed: widget.onViewForecastAccuracy,
                    style: TextButton.styleFrom(
                      foregroundColor: _forecastMuted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('View forecast accuracy'),
                        SizedBox(width: 4),
                        Icon(LucideIcons.arrowRight, size: 14),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Historical daily sales and confidence ranges are not exposed by this response. Only supported future predicted demand is shown.',
          style: TextStyle(fontSize: 11, color: _forecastFaint, height: 1.35),
        ),
      ],
    );
  }
}

class _ForecastLegendItem extends StatelessWidget {
  const _ForecastLegendItem({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 20,
        height: 4,
        child: CustomPaint(
          painter: _ForecastLegendPainter(color: color, dashed: dashed),
        ),
      ),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontSize: 12, color: _forecastMuted)),
    ],
  );
}

class _ForecastLegendPainter extends CustomPainter {
  const _ForecastLegendPainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (!dashed) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(min(x + 5, size.width), size.height / 2),
        paint,
      );
      x += 9;
    }
  }

  @override
  bool shouldRepaint(covariant _ForecastLegendPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}

class _ProductForecastChartPainter extends CustomPainter {
  const _ProductForecastChartPainter({
    required this.points,
    required this.hoverIndex,
  });

  final List<ForecastDailyPoint> points;
  final int? hoverIndex;

  static const _top = 16.0;
  static const _right = 12.0;
  static const _bottom = 28.0;
  static const _left = 44.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final maximum = points.fold<double>(
      1,
      (value, point) => max(value, point.quantity),
    );
    final step = _forecastNiceStep(maximum / 4);
    final yMaximum = max(step, (maximum / step).ceil() * step);
    final innerWidth = max(1.0, size.width - _left - _right);
    final innerHeight = max(1.0, size.height - _top - _bottom);
    double xFor(int index) => points.length == 1
        ? _left + innerWidth / 2
        : _left + index / (points.length - 1) * innerWidth;
    double yFor(double value) =>
        _top + innerHeight - value / yMaximum * innerHeight;

    final gridPaint = Paint()
      ..color = _forecastHairline
      ..strokeWidth = 1;
    final tickCount = (yMaximum / step).round();
    for (var index = 0; index <= tickCount; index++) {
      final value = index * step;
      final y = yFor(value);
      canvas.drawLine(
        Offset(_left, y),
        Offset(size.width - _right, y),
        gridPaint,
      );
      _paintForecastText(
        canvas,
        _quantity(value),
        Offset(_left - 8, y),
        const TextStyle(fontSize: 11, color: _forecastMuted),
        textAlign: TextAlign.right,
        anchorRight: true,
      );
    }

    final labelTarget = size.width < 520 ? 4 : 7;
    final labelEvery = max(1, (points.length / labelTarget).ceil());
    for (var index = 0; index < points.length; index += labelEvery) {
      _paintForecastText(
        canvas,
        _forecastDateLabel(points[index].date),
        Offset(xFor(index), size.height - 8),
        const TextStyle(fontSize: 11, color: _forecastMuted),
        textAlign: TextAlign.center,
      );
    }
    if ((points.length - 1) % labelEvery != 0) {
      _paintForecastText(
        canvas,
        _forecastDateLabel(points.last.date),
        Offset(xFor(points.length - 1), size.height - 8),
        const TextStyle(fontSize: 11, color: _forecastMuted),
        textAlign: TextAlign.center,
      );
    }

    final today = DateTime.now();
    final todayIndex = points.indexWhere(
      (point) =>
          point.date.year == today.year &&
          point.date.month == today.month &&
          point.date.day == today.day,
    );
    if (todayIndex >= 0) {
      final markerPaint = Paint()
        ..color = _forecastFaint
        ..strokeWidth = 1;
      _drawDashedLine(
        canvas,
        Offset(xFor(todayIndex), _top),
        Offset(xFor(todayIndex), _top + innerHeight),
        markerPaint,
        dash: 2,
        gap: 3,
      );
      _paintForecastText(
        canvas,
        'Today',
        Offset(xFor(todayIndex), size.height - 8),
        const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _forecastInk,
        ),
        textAlign: TextAlign.center,
      );
    }

    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final offset = Offset(xFor(index), yFor(points[index].quantity));
      if (index == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    final forecastPaint = Paint()
      ..color = _forecastAccent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = min(distance + 5, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), forecastPaint);
        distance += 9;
      }
    }
    if (points.length == 1) {
      canvas.drawCircle(
        Offset(xFor(0), yFor(points.first.quantity)),
        3.5,
        forecastPaint,
      );
    }

    final hover = hoverIndex;
    if (hover != null && hover >= 0 && hover < points.length) {
      final hoverPaint = Paint()
        ..color = _forecastLine
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(xFor(hover), _top),
        Offset(xFor(hover), _top + innerHeight),
        hoverPaint,
      );
      canvas.drawCircle(
        Offset(xFor(hover), yFor(points[hover].quantity)),
        3.5,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        Offset(xFor(hover), yFor(points[hover].quantity)),
        3.5,
        Paint()
          ..color = _forecastAccent
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ProductForecastChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.hoverIndex != hoverIndex;
}

void _drawDashedLine(
  Canvas canvas,
  Offset start,
  Offset end,
  Paint paint, {
  required double dash,
  required double gap,
}) {
  final distance = (end - start).distance;
  final direction = (end - start) / distance;
  var offset = 0.0;
  while (offset < distance) {
    final dashEnd = min(offset + dash, distance);
    canvas.drawLine(
      start + direction * offset,
      start + direction * dashEnd,
      paint,
    );
    offset += dash + gap;
  }
}

double _forecastNiceStep(double raw) {
  final magnitude = pow(10, (log(max(raw, 1)) / ln10).floor()).toDouble();
  final normalized = raw / magnitude;
  final multiplier = normalized <= 1
      ? 1
      : normalized <= 2
      ? 2
      : normalized <= 5
      ? 5
      : 10;
  return multiplier * magnitude;
}

void _paintForecastText(
  Canvas canvas,
  String text,
  Offset anchor,
  TextStyle style, {
  required TextAlign textAlign,
  bool anchorRight = false,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: textAlign,
  )..layout();
  final dx = anchorRight
      ? anchor.dx - painter.width
      : textAlign == TextAlign.center
      ? anchor.dx - painter.width / 2
      : anchor.dx;
  canvas.save();
  painter.paint(canvas, Offset(dx, anchor.dy - painter.height / 2));
  canvas.restore();
}

String _forecastDateLabel(DateTime date) {
  const months = <String>[
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
  return '${months[date.month - 1]} ${date.day}';
}

String _forecastTooltipDate(DateTime date) {
  const weekdays = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[date.weekday - 1]}, ${_forecastDateLabel(date)}';
}

class _DemandSparklinePainter extends CustomPainter {
  const _DemandSparklinePainter(this.points);

  final List<ForecastDailyPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _forecastHairline
      ..strokeWidth = 1;
    for (var row = 0; row < 4; row++) {
      final y = (size.height - 8) * row / 3 + 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (points.isEmpty) return;
    final maximum = points
        .map((point) => point.quantity)
        .fold<double>(0, (current, value) => value > current ? value : current);
    final scale = maximum <= 0 ? 1.0 : maximum;
    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final x = points.length == 1
          ? size.width / 2
          : size.width * index / (points.length - 1);
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
    final line = Paint()
      ..color = _forecastAccent
      ..strokeWidth = 2.25
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (points.length == 1) {
      final y =
          size.height -
          6 -
          (points.single.quantity / scale) * (size.height - 12);
      canvas.drawCircle(Offset(size.width / 2, y), 3.5, line);
      return;
    }
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = min(distance + 7, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), line);
        distance += 11;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DemandSparklinePainter oldDelegate) =>
      oldDelegate.points != points;
}

class _CategoryOutlookCard extends StatefulWidget {
  const _CategoryOutlookCard({required this.snapshot, required this.window});

  final PortfolioForecastSnapshot snapshot;
  final ForecastWindow window;

  @override
  State<_CategoryOutlookCard> createState() => _CategoryOutlookCardState();
}

class _CategoryOutlookCardState extends State<_CategoryOutlookCard> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final rows = <({String category, UnitDemandForecast unit})>[];
    for (final category in widget.snapshot.categories) {
      for (final unit in category.byUnit.values) {
        rows.add((category: category.category, unit: unit));
      }
    }
    final visible = _showAll ? rows : rows.take(5).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 18, 24, 13),
            child: Text(
              'Category demand',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _forecastInk,
              ),
            ),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Text('No reliable category totals are available.'),
            ),
          if (rows.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              decoration: const BoxDecoration(
                color: _forecastBackground,
                border: Border.symmetric(
                  horizontal: BorderSide(color: _forecastHairline),
                ),
              ),
              child: const Row(
                children: [
                  Expanded(
                    child: Text(
                      'Category',
                      style: TextStyle(fontSize: 11, color: _forecastMuted),
                    ),
                  ),
                  SizedBox(
                    width: 55,
                    child: Text(
                      'Unit',
                      style: TextStyle(fontSize: 11, color: _forecastMuted),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: Text(
                      'Forecast',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, color: _forecastMuted),
                    ),
                  ),
                  SizedBox(
                    width: 68,
                    child: Text(
                      'Trend',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, color: _forecastMuted),
                    ),
                  ),
                ],
              ),
            ),
          for (final row in visible)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _CategoryDemandRow(
                category: row.category,
                unit: row.unit,
                window: widget.window,
              ),
            ),
          if (rows.length > 5)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 5, 18, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('forecast-category-show-all'),
                  onPressed: () => setState(() => _showAll = !_showAll),
                  style: TextButton.styleFrom(
                    foregroundColor: _forecastAccentDark,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 5,
                    ),
                  ),
                  child: Text(
                    _showAll ? 'Show fewer' : 'Show all ${rows.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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

class _CategoryDemandRow extends StatelessWidget {
  const _CategoryDemandRow({
    required this.category,
    required this.unit,
    required this.window,
  });

  final String category;
  final UnitDemandForecast unit;
  final ForecastWindow window;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _forecastHairline)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: _forecastInk),
          ),
        ),
        SizedBox(
          width: 55,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: _forecastLine),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                unit.unit,
                style: const TextStyle(fontSize: 11, color: _forecastBody),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 72,
          child: Text(
            _quantity(unit.quantityFor(window)),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          width: 68,
          child: Text(
            unit.direction.label,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, color: _forecastMuted),
          ),
        ),
      ],
    ),
  );
}

class _PlanningPriorityCard extends StatefulWidget {
  const _PlanningPriorityCard({
    this.unavailable = false,
    this.analyses = const <String, ForecastAnalysis>{},
    this.onSelectProduct,
  });

  final bool unavailable;
  final Map<String, ForecastAnalysis> analyses;
  final ValueChanged<String>? onSelectProduct;

  @override
  State<_PlanningPriorityCard> createState() => _PlanningPriorityCardState();
}

class _PlanningPriorityCardState extends State<_PlanningPriorityCard> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final priorities =
        widget.analyses.values
            .where(
              (analysis) =>
                  (analysis
                          .preliminaryRestockingInsight
                          .suggestedRestockQuantity ??
                      0) >
                  0,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final leftInsight = left.preliminaryRestockingInsight;
            final rightInsight = right.preliminaryRestockingInsight;
            final leftRatio = (leftInsight.predictedDemand ?? 0) <= 0
                ? 0.0
                : (leftInsight.suggestedRestockQuantity ?? 0) /
                      leftInsight.predictedDemand!;
            final rightRatio = (rightInsight.predictedDemand ?? 0) <= 0
                ? 0.0
                : (rightInsight.suggestedRestockQuantity ?? 0) /
                      rightInsight.predictedDemand!;
            final urgency = rightRatio.compareTo(leftRatio);
            return urgency != 0
                ? urgency
                : left.product.name.compareTo(right.product.name);
          });
    final visible = _showAll ? priorities : priorities.take(5).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 18, 13),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Restock priorities',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _forecastInk,
                    ),
                  ),
                ),
                if (priorities.length > 5)
                  TextButton(
                    key: const Key('forecast-restock-show-all'),
                    onPressed: () => setState(() => _showAll = !_showAll),
                    style: TextButton.styleFrom(
                      foregroundColor: _forecastMuted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                    ),
                    child: Text(
                      _showAll ? 'Show top 5' : 'View all recommendations',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (priorities.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Text(
                widget.unavailable ? 'Current restock priorities are unavailable in the summary response. Open a product for current-stock guidance.' : 'No positive preliminary restock suggestions are available.',
                style: TextStyle(color: _forecastMuted),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                const minimumTableWidth = 520.0;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: max(minimumTableWidth, constraints.maxWidth),
                    child: Column(
                      children: [
                        const ColoredBox(
                          color: _forecastBackground,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 39,
                                  child: Text(
                                    'Product',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _forecastMuted,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 17,
                                  child: Text(
                                    'On hand',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _forecastMuted,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 24,
                                  child: Text(
                                    'Suggested restock',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _forecastMuted,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 20,
                                  child: Text(
                                    'Action',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _forecastMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        for (final analysis in visible)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: _RestockPriorityRow(
                              analysis: analysis,
                              onOpen: widget.onSelectProduct == null
                                  ? null
                                  : () => widget.onSelectProduct!(
                                      analysis.product.productId,
                                    ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _RestockPriorityRow extends StatelessWidget {
  const _RestockPriorityRow({required this.analysis, required this.onOpen});

  final ForecastAnalysis analysis;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final insight = analysis.preliminaryRestockingInsight;
    final onHand = insight.availableInventory;
    final suggestion = insight.suggestedRestockQuantity;
    final product = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          analysis.product.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _forecastInk,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '28-day demand exceeds saleable stock',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: _forecastMuted),
        ),
      ],
    );
    final action = OutlinedButton(
      onPressed: onOpen,
      style: OutlinedButton.styleFrom(
        foregroundColor: _forecastBody,
        side: const BorderSide(color: _forecastLine),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: const Text('View details'),
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 68),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _forecastHairline)),
      ),
      child: Row(
        children: [
          Expanded(flex: 39, child: product),
          Expanded(
            flex: 17,
            child: Semantics(
              label: 'On hand',
              child: Text(
                _withUnit(onHand, insight.inventoryUnit),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, color: _forecastBody),
              ),
            ),
          ),
          Expanded(
            flex: 24,
            child: Semantics(
              label: 'Suggested restock',
              child: Text(
                _withUnit(suggestion, insight.inventoryUnit),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _forecastInk,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 20,
            child: Align(alignment: Alignment.centerRight, child: action),
          ),
        ],
      ),
    );
  }
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
    this.emptyTitle = 'Select a product',
    this.emptyMessage = 'Choose a product and model to view its saved forecast.',
    this.onRetry,
    this.onManualEstimate,
    this.forecastControls,
    this.selectedWindow = ForecastWindow.next28Days,
    this.onWindowChanged,
    this.onViewForecastAccuracy,
  });

  final ForecastAnalysis? analysis;
  final bool loading;
  final String? error;
  final bool stale;
  final String emptyTitle;
  final String emptyMessage;
  final VoidCallback? onRetry;
  final VoidCallback? onManualEstimate;
  final Widget? forecastControls;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow>? onWindowChanged;
  final VoidCallback? onViewForecastAccuracy;

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
      return _MessageCard(
        icon: LucideIcons.chartNoAxesCombined,
        title: emptyTitle,
        message: emptyMessage,
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
                'This saved forecast is stale. Its dates and demand values are historical; generate a fresh forecast before using restocking guidance.',
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
                ? 'No sales history is available: zero is an unknown-demand placeholder, not confirmed zero customer demand.'
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
            final forecast = _ForecastCard(
              analysis: value,
              controls: forecastControls,
              selectedWindow: selectedWindow,
              onWindowChanged: onWindowChanged,
              onViewForecastAccuracy: onViewForecastAccuracy,
            );
            final recommendation = _RecommendationCard(analysis: value);
            if (MediaQuery.sizeOf(context).width < 1024) {
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
                Expanded(flex: 2, child: forecast),
                const SizedBox(width: 24),
                Expanded(child: recommendation),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _ProductForecastContext(analysis: value),
      ],
    );
  }
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({
    required this.analysis,
    required this.selectedWindow,
    this.controls,
    this.onWindowChanged,
    this.onViewForecastAccuracy,
  });

  final ForecastAnalysis analysis;
  final Widget? controls;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow>? onWindowChanged;
  final VoidCallback? onViewForecastAccuracy;

  @override
  Widget build(BuildContext context) {
    final forecast = analysis.forecast;
    final chartDays = selectedWindow == ForecastWindow.today
        ? 1
        : selectedWindow.days;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final contentPadding = viewportWidth >= 640 ? 24.0 : 16.0;
    return Container(
      constraints: MediaQuery.sizeOf(context).width >= 1024
          ? const BoxConstraints(minHeight: 560)
          : null,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProductPeriodStrip(
            forecast: forecast,
            selectedWindow: selectedWindow,
            onWindowChanged: onWindowChanged,
          ),
          Padding(
            padding: EdgeInsets.all(contentPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final title = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Daily sales and forecast',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _forecastInk,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${selectedWindow.label} shown • ${forecast.periodStart} onward',
                          style: const TextStyle(
                            fontSize: 12,
                            color: _forecastMuted,
                          ),
                        ),
                      ],
                    );
                    if (MediaQuery.sizeOf(context).width < 640 ||
                        controls == null) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          if (controls != null) ...[
                            const SizedBox(height: 12),
                            controls!,
                          ],
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 16),
                        controls!,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                _ProductForecastChart(
                  key: const Key('product-demand-trend'),
                  points: forecast.daily
                      .take(chartDays)
                      .toList(growable: false),
                  unit: forecast.unit,
                  synthetic:
                      analysis.synthetic ||
                      (analysis.product.sku?.startsWith('SIM-') ?? false),
                  onViewForecastAccuracy: onViewForecastAccuracy,
                  emptyMessage: forecast.isColdStart
                      ? 'No reliable daily forecast is available for this product.'
                      : 'No forecast points were returned.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductPeriodStrip extends StatelessWidget {
  const _ProductPeriodStrip({
    required this.forecast,
    required this.selectedWindow,
    required this.onWindowChanged,
  });

  final ForecastSummary forecast;
  final ForecastWindow selectedWindow;
  final ValueChanged<ForecastWindow>? onWindowChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = MediaQuery.sizeOf(context).width < 640;
      final width = compact ? constraints.maxWidth : constraints.maxWidth / 3;
      final firstPoint = forecast.daily.isEmpty ? null : forecast.daily.first;
      final now = DateTime.now();
      final firstPointIsToday =
          firstPoint != null &&
          firstPoint.date.year == now.year &&
          firstPoint.date.month == now.month &&
          firstPoint.date.day == now.day;
      return Wrap(
        children: [
          _ProductPeriodCell(
            width: width,
            compact: compact,
            label: firstPointIsToday
                ? 'Today'
                : firstPoint == null
                ? 'Next forecast day'
                : _forecastDateLabel(firstPoint.date),
            quantity: forecast.isColdStart ? null : forecast.quantityForDays(1),
            unit: forecast.unit,
            note: forecast.isColdStart
                ? 'Demand unknown'
                : firstPointIsToday
                ? 'Estimated'
                : 'First forecast day',
          ),
          _ProductPeriodCell(
            width: width,
            compact: compact,
            label: 'Short-term (7 days)',
            quantity: forecast.isColdStart ? null : forecast.quantityForDays(7),
            unit: forecast.unit,
            selected: selectedWindow == ForecastWindow.next7Days,
            onTap: onWindowChanged == null
                ? null
                : () => onWindowChanged!(ForecastWindow.next7Days),
          ),
          _ProductPeriodCell(
            width: width,
            compact: compact,
            label: 'Planning (28 days)',
            quantity: forecast.isColdStart
                ? null
                : forecast.quantityForDays(28),
            unit: forecast.unit,
            selected: selectedWindow == ForecastWindow.next28Days,
            onTap: onWindowChanged == null
                ? null
                : () => onWindowChanged!(ForecastWindow.next28Days),
            valueKey: const Key('forecast-total'),
          ),
        ],
      );
    },
  );
}

class _ProductPeriodCell extends StatelessWidget {
  const _ProductPeriodCell({
    required this.width,
    required this.compact,
    required this.label,
    required this.quantity,
    required this.unit,
    this.note,
    this.selected = false,
    this.onTap,
    this.valueKey,
  });

  final double width;
  final bool compact;
  final String label;
  final double? quantity;
  final String unit;
  final String? note;
  final bool selected;
  final VoidCallback? onTap;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: width,
      constraints: const BoxConstraints(minHeight: 104),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 24,
        vertical: compact ? 16 : 20,
      ),
      decoration: BoxDecoration(
        color: selected ? _forecastBackground : Colors.white,
        border: Border(
          right: const BorderSide(color: _forecastHairline),
          bottom: BorderSide(
            color: selected ? _forecastAccent : _forecastHairline,
            width: selected ? 2 : 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 12 : 14,
              color: _forecastMuted,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            key: valueKey,
            quantity == null ? '—' : '${_quantity(quantity!)} $unit',
            style: TextStyle(
              fontSize: compact ? 20 : 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -.3,
              color: _forecastInk,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            note ?? '',
            style: const TextStyle(fontSize: 11, color: _forecastMuted),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

class _ForecastTechnicalDetails extends StatelessWidget {
  const _ForecastTechnicalDetails({required this.analysis});

  final ForecastAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final forecast = analysis.forecast;
    return Container(
      decoration: BoxDecoration(
        color: _forecastBackground,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        key: const Key('forecast-technical-details'),
        title: const Text(
          'Technical model details',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: const Text('Source, provenance and seasonal context'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
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
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Experimental seasonal context',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            _Metric(
              'Seasonal classification',
              _readable(
                forecast.seasonalContext!.seasonalRelevance,
              ).toUpperCase(),
            ),
            _Metric(
              'Evidence',
              _readable(forecast.seasonalContext!.evidenceLevel),
            ),
            _Metric(
              'Upcoming transition',
              forecast.seasonalContext!.nextTransitionDate == null
                  ? 'No configured transition found'
                  : '${_readable(forecast.seasonalContext!.nextTransition ?? 'unknown')} '
                        'on ${forecast.seasonalContext!.nextTransitionDate!.toIso8601String().split('T').first}',
            ),
            Text(
              forecast.experimentalFallbackReason == null
                  ? 'Seasonal calendar features influence this experimental forecast only. No fixed demand multiplier is applied.'
                  : 'The experimental model was not used: ${_readable(forecast.experimentalFallbackReason!)}. The API safely returned the existing forecasting model.',
              style: const TextStyle(color: _forecastMuted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            const Text(
              'Replenishment remains calculated from the existing validated LightGBM model.',
              style: TextStyle(
                color: Color(0xFF9A3412),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.analysis});

  final ForecastAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final preliminary = analysis.preliminaryRestockingInsight;
    final provisional = preliminary.reliability == PreliminaryReliability.provisional;
    final unavailable = preliminary.reliability == PreliminaryReliability.unavailable;
    final suggestion = unavailable ? null : preliminary.suggestedRestockQuantity;
    final predicted = preliminary.predictedDemand;
    final saleable = preliminary.availableInventory;
    final daily = predicted == null || predicted <= 0
        ? null
        : predicted / preliminary.planningHorizonDays;
    final coverDays = daily == null || saleable == null
        ? null
        : (saleable / daily).floor();
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final cardPadding = viewportWidth >= 640 ? 24.0 : 16.0;
    return Container(
      width: double.infinity,
      constraints: MediaQuery.sizeOf(context).width >= 1024
          ? const BoxConstraints(minHeight: 560)
          : null,
      padding: EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: (suggestion ?? 0) > 0
                  ? _forecastAccentSoft
                  : _forecastBackground,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provisional ? 'Provisional estimate' : 'Preliminary suggested restock',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _forecastBody,
                  ),
                ),
                const SizedBox(height: 6),
                if (suggestion == null)
                  const Text(
                    'Unavailable',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: _forecastInk,
                    ),
                  )
                else if (suggestion! > 0)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _quantity(
                            suggestion!,
                          ),
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -1,
                            color: _forecastAccentDark,
                          ),
                        ),
                        TextSpan(
                          text: ' ${preliminary.inventoryUnit}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: _forecastBody,
                          ),
                        ),
                      ],
                    ),
                    key: const Key('preliminary-suggested-quantity'),
                  )
                else
                  const Text(
                    'No restock suggested',
                    key: Key('preliminary-suggested-quantity'),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: _forecastInk,
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  suggestion == null
                      ? (preliminary.limitations.isNotEmpty ? preliminary.limitations.join(' ') : 'A valid supporting forecast and saleable inventory are required.')
                      : suggestion! > 0
                      ? 'About ${_withUnit(predicted, preliminary.inventoryUnit)} are expected over ${preliminary.planningHorizonDays} days. Current saleable stock is ${_withUnit(saleable, preliminary.inventoryUnit)}.'
                      : 'Current saleable stock should cover the expected ${preliminary.planningHorizonDays}-day demand.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: _forecastBody,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          if (provisional) ...[
            const SizedBox(height: 10),
            Text(
              'Needs administrator review. '
              '${preliminary.reliabilityCode == 'provisional' ? 'This quantity is based on limited sales history.' : 'Supporting forecast reliability is not confirmed by this server.'}'
              '${analysis.forecast.isColdStart ? ' This is a separate supporting estimate; the selected forecast remains unavailable or limited.' : ''}',
              style: const TextStyle(fontSize: 13, height: 1.45, color: _forecastBody),
            ),
          ],
          const SizedBox(height: 16),
          _RecommendationMetric(
            'Saleable stock',
            _withUnit(
              preliminary.availableInventory,
              preliminary.inventoryUnit,
            ),
            key: const Key('preliminary-current-stock'),
          ),
          _RecommendationMetric(
            'Expected demand, ${preliminary.planningHorizonDays} days',
            _withUnit(preliminary.predictedDemand, preliminary.inventoryUnit),
            key: const Key('preliminary-predicted-demand'),
          ),
          _RecommendationMetric(
            'Current stock lasts',
            coverDays == null ? 'Unavailable' : 'About $coverDays days',
          ),
          const SizedBox(height: 10),
          Text(
            'Supporting model: ${preliminary.forecastModel} v${preliminary.forecastVersion}. '
            'Uses the saved 28-day forecast and current saleable stock. Guidance only - nothing is ordered. '
            '${preliminary.limitations.join(' ')}',
            style: const TextStyle(fontSize: 12, height: 1.45, color: _forecastMuted),
          ),
        ],
      ),
    );
  }
}

class _RecommendationMetric extends StatelessWidget {
  const _RecommendationMetric(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _forecastHairline)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, color: _forecastMuted),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 14, color: _forecastInk),
          ),
        ),
      ],
    ),
  );
}

class _ProductForecastContext extends StatefulWidget {
  const _ProductForecastContext({required this.analysis});

  final ForecastAnalysis analysis;

  @override
  State<_ProductForecastContext> createState() =>
      _ProductForecastContextState();
}

class _ProductForecastContextState extends State<_ProductForecastContext> {
  bool _showAllLimitations = false;

  @override
  Widget build(BuildContext context) {
    final analysis = widget.analysis;
    final forecast = analysis.forecast;
    final seasonalContext = forecast.seasonalContext;
    final seasonal = forecast.experimentalFallbackReason != null
        ? 'Not applied · ${_readable(forecast.experimentalFallbackReason!)}'
        : seasonalContext == null
        ? 'Not available for this forecast method'
        : '${_readable(seasonalContext.seasonalRelevance)} · ${_readable(seasonalContext.evidenceLevel)}';
    final quality = forecast.isColdStart
        ? forecast.coldStartReason == 'no_history'
              ? 'No recorded sales history'
              : 'Insufficient history'
        : forecast.warnings.isEmpty
        ? 'No forecast warnings reported'
        : '${forecast.warnings.length} warning(s) reported';

    final additionalLimitations = <String>[
      'Promotions, local projects, or price changes may affect future demand.',
      'Forecast reliability depends on available and accurate sales history.',
      ...forecast.warnings.map(_readable),
    ];

    final contextPadding = MediaQuery.sizeOf(context).width >= 640
        ? 20.0
        : 16.0;

    final limitationsCard = _ForecastLimitationsCard(
      additionalLimitations: additionalLimitations,
      expanded: _showAllLimitations,
      onToggle: () =>
          setState(() => _showAllLimitations = !_showAllLimitations),
    );

    final about = Container(
      padding: EdgeInsets.symmetric(horizontal: contextPadding, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'About this forecast',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _forecastInk,
            ),
          ),
          const SizedBox(height: 4),
          const _ForecastContextMetric(
            'Sales history',
            'Not exposed by this response',
          ),
          _ForecastContextMetric('Data quality', quality),
          _ForecastContextMetric('Seasonal pattern', seasonal),
          const SizedBox(height: 6),
          if (analysis.synthetic ||
              (analysis.product.sku?.startsWith('SIM-') ?? false))
            const Text(
              'Simulation/demo data',
              style: TextStyle(fontSize: 11, color: _forecastFaint),
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (MediaQuery.sizeOf(context).width < 768) {
          return Column(
            children: [limitationsCard, const SizedBox(height: 16), about],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: limitationsCard),
            const SizedBox(width: 24),
            Expanded(child: about),
          ],
        );
      },
    );
  }
}

class _ForecastLimitationsCard extends StatelessWidget {
  const _ForecastLimitationsCard({
    required this.additionalLimitations,
    required this.expanded,
    required this.onToggle,
  });

  static const _alwaysVisibleLimitations = <String>[
    'Predictions are estimates, not guaranteed sales.',
    'Stockouts may cause recorded sales to understate true demand.',
  ];

  final List<String> additionalLimitations;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = MediaQuery.sizeOf(context).width >= 640
        ? 20.0
        : 16.0;
    final totalLimitations =
        _alwaysVisibleLimitations.length + additionalLimitations.length;
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        border: Border.all(color: const Color(0xFFFDE68A)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          const Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(color: Color(0xFFD97706)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding + 4,
              16,
              horizontalPadding,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      LucideIcons.triangleAlert,
                      size: 16,
                      color: Color(0xFFD97706),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Important Forecast Limitations',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (final limitation in _alwaysVisibleLimitations)
                  _ForecastLimitationBullet(text: limitation),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: const Cubic(.23, 1, .32, 1),
                  alignment: Alignment.topCenter,
                  child: expanded
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final limitation in additionalLimitations)
                              _ForecastLimitationBullet(text: limitation),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                if (additionalLimitations.isNotEmpty)
                  TextButton(
                    onPressed: onToggle,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF92400E),
                      padding: const EdgeInsets.only(top: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(
                      expanded
                          ? 'Show less'
                          : 'Read all limitations ($totalLimitations)',
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

class _ForecastLimitationBullet extends StatelessWidget {
  const _ForecastLimitationBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 20, bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 7),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0xFFD97706),
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 4, height: 4),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              height: 1.4,
              color: _forecastInk,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ForecastContextMetric extends StatelessWidget {
  const _ForecastContextMetric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _forecastHairline)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: _forecastMuted),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, color: _forecastInk),
          ),
        ),
      ],
    ),
  );
}

class _TrackingForecastAccuracy extends StatefulWidget {
  const _TrackingForecastAccuracy({
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
  State<_TrackingForecastAccuracy> createState() =>
      _TrackingForecastAccuracyState();
}

class _TrackingForecastAccuracyState extends State<_TrackingForecastAccuracy> {
  bool _explanationOpen = false;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    Widget content;
    if (widget.loading && report == null) {
      content = const _TrackingAccuracyStateCard(
        icon: LucideIcons.hourglass,
        title: 'Loading forecast accuracy',
        message: 'Retrieving saved forecasts and completed evaluations.',
        loading: true,
      );
    } else if (widget.error != null && report == null) {
      content = _TrackingAccuracyStateCard(
        icon: LucideIcons.triangleAlert,
        title: 'Forecast accuracy unavailable',
        message: widget.error!,
        actionLabel: widget.onRetry == null ? null : 'Retry',
        onAction: widget.onRetry,
      );
    } else if (report == null) {
      content = const _TrackingAccuracyStateCard(
        icon: LucideIcons.chartNoAxesCombined,
        title: 'Forecast accuracy not loaded',
        message: 'Refresh tracking to load saved forecast performance.',
      );
    } else {
      final evaluated = report.items
          .where((item) => item.evaluable)
          .toList(growable: false);
      final monitored = report.items
          .where((item) => !item.evaluable)
          .toList(growable: false);
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TrackingAccuracyMainCard(
            report: report,
            evaluated: evaluated,
            monitored: monitored,
          ),
          if (report.dataSourceAvailable &&
              report.dataSourceWarning != null) ...[
            const SizedBox(height: 12),
            _TrackingInfoNotice(text: report.dataSourceWarning!),
          ],
          if (widget.error != null) ...[
            const SizedBox(height: 12),
            _TrackingInfoNotice(
              text: widget.error!,
              actionLabel: widget.onRetry == null ? null : 'Retry',
              onAction: widget.onRetry,
            ),
          ],
          const SizedBox(height: 16),
          _TrackingCompletedAccuracy(
            summaries: report.summariesByUnit,
            items: evaluated,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        content,
        const SizedBox(height: 16),
        _TrackingPerformanceDisclosure(
          open: _explanationOpen,
          report: report,
          onToggle: () => setState(() => _explanationOpen = !_explanationOpen),
        ),
      ],
    );
  }
}

class _TrackingAccuracyStateCard extends StatelessWidget {
  const _TrackingAccuracyStateCard({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _trackingLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TrackingStatusIcon(icon: icon),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: _trackingInk,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: _trackingMuted,
                ),
              ),
              if (loading) ...[
                const SizedBox(height: 18),
                const LinearProgressIndicator(
                  minHeight: 3,
                  color: _trackingAccent,
                  backgroundColor: _trackingLine,
                ),
              ],
              if (actionLabel != null) ...[
                const SizedBox(height: 10),
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _TrackingStatusIcon extends StatelessWidget {
  const _TrackingStatusIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: _trackingAccentSoft,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(icon, size: 18, color: _trackingAccent),
  );
}

class _TrackingAccuracyMainCard extends StatelessWidget {
  const _TrackingAccuracyMainCard({
    required this.report,
    required this.evaluated,
    required this.monitored,
  });

  final ForecastPerformanceReport report;
  final List<ForecastPerformanceItem> evaluated;
  final List<ForecastPerformanceItem> monitored;

  @override
  Widget build(BuildContext context) {
    final hasItems = report.items.isNotEmpty;
    final dataUnavailable = !report.dataSourceAvailable;
    final title = !hasItems
        ? 'No saved forecasts yet'
        : dataUnavailable
        ? 'Forecast accuracy unavailable'
        : evaluated.isEmpty
        ? 'Awaiting completed forecasts'
        : 'Forecast performance available';
    final message = !hasItems
        ? 'Accuracy monitoring begins after an immutable 28-day forecast has been saved.'
        : dataUnavailable
        ? (report.dataSourceWarning ??
              'Recorded sales are currently unavailable for evaluation.')
        : evaluated.isEmpty
        ? 'Forecast accuracy will appear after saved forecast periods end and sufficient sales data becomes available for comparison.'
        : 'Completed eligible forecasts are compared with recorded customer sales for the same forecast periods.';
    final status = !hasItems
        ? 'No saved forecasts'
        : dataUnavailable
        ? 'Data unavailable'
        : evaluated.isNotEmpty
        ? 'Results available'
        : _trackingEvaluationStatus(monitored);

    final statusColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _TrackingStatusIcon(icon: LucideIcons.hourglass),
        const SizedBox(height: 12),
        Text(
          title,
          key: !hasItems ? const Key('forecast-performance-empty') : null,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: _trackingInk,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: _trackingBody,
          ),
        ),
        const SizedBox(height: 20),
        _TrackingAccuracySummary(
          monitored: report.items.length,
          evaluated: evaluated.length,
          status: status,
        ),
      ],
    );
    final monitoredColumn = _TrackingMonitoredForecasts(items: monitored);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _trackingLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 900) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  statusColumn,
                  const SizedBox(height: 24),
                  monitoredColumn,
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 10, child: statusColumn),
                const SizedBox(width: 40),
                Expanded(flex: 11, child: monitoredColumn),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TrackingAccuracySummary extends StatelessWidget {
  const _TrackingAccuracySummary({
    required this.monitored,
    required this.evaluated,
    required this.status,
  });

  final int monitored;
  final int evaluated;
  final String status;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final cells = [
        _TrackingAccuracySummaryCell(
          label: 'Saved forecasts monitored',
          value: '$monitored',
        ),
        _TrackingAccuracySummaryCell(
          label: 'Completed eligible evaluations',
          value: '$evaluated',
        ),
        _TrackingAccuracySummaryCell(
          label: 'Current status',
          value: status,
          compact: true,
        ),
      ];
      if (constraints.maxWidth < 360) {
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: _trackingLine),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              cells[0],
              const Divider(height: 1, color: _trackingLine),
              cells[1],
              const Divider(height: 1, color: _trackingLine),
              cells[2],
            ],
          ),
        );
      }
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _trackingLine),
          borderRadius: BorderRadius.circular(8),
        ),
        child: IntrinsicHeight(
          child: Row(
            children: [
              Expanded(child: cells[0]),
              const VerticalDivider(width: 1, color: _trackingLine),
              Expanded(child: cells[1]),
              const VerticalDivider(width: 1, color: _trackingLine),
              Expanded(child: cells[2]),
            ],
          ),
        ),
      );
    },
  );
}

class _TrackingAccuracySummaryCell extends StatelessWidget {
  const _TrackingAccuracySummaryCell({
    required this.label,
    required this.value,
    this.compact = false,
  });

  final String label;
  final String value;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            height: 1.15,
            color: _trackingMuted,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 13 : 20,
            height: compact ? 1.15 : 1,
            fontWeight: FontWeight.w600,
            color: _trackingInk,
          ),
        ),
      ],
    ),
  );
}

class _TrackingMonitoredForecasts extends StatelessWidget {
  const _TrackingMonitoredForecasts({required this.items});

  final List<ForecastPerformanceItem> items;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Monitored 28-day forecasts',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: _trackingMuted,
        ),
      ),
      const SizedBox(height: 8),
      Container(
        decoration: const BoxDecoration(
          border: Border.symmetric(
            horizontal: BorderSide(color: _trackingLine),
          ),
        ),
        child: items.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'No forecasts are currently awaiting evaluation.',
                  style: TextStyle(fontSize: 13, color: _trackingMuted),
                ),
              )
            : Column(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    _TrackingMonitoredForecastRow(item: items[index]),
                    if (index != items.length - 1)
                      const Divider(height: 1, color: _trackingLine),
                  ],
                ],
              ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Each forecast becomes eligible once its period ends and its sales have been recorded.',
        style: TextStyle(fontSize: 12, height: 1.35, color: _trackingMuted),
      ),
    ],
  );
}

class _TrackingMonitoredForecastRow extends StatelessWidget {
  const _TrackingMonitoredForecastRow({required this.item});

  final ForecastPerformanceItem item;

  @override
  Widget build(BuildContext context) {
    final progress = _trackingForecastProgress(
      item.forecastPeriodStart,
      item.forecastPeriodEnd,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _trackingInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _trackingPeriod(
                    item.forecastPeriodStart,
                    item.forecastPeriodEnd,
                  ),
                  style: const TextStyle(fontSize: 12, color: _trackingMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  'Eligibility: ${_trackingTitleCase(_readable(item.evaluationStatus))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: _trackingAccentStrong,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 112,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  progress.label,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, color: _trackingBody),
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: progress.fraction,
                    minHeight: 4,
                    color: _trackingAccent,
                    backgroundColor: _trackingLine,
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

class _TrackingCompletedAccuracy extends StatelessWidget {
  const _TrackingCompletedAccuracy({
    required this.summaries,
    required this.items,
  });

  final List<ForecastPerformanceSummary> summaries;
  final List<ForecastPerformanceItem> items;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Historical Forecast Performance',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: _trackingInk,
        ),
      ),
      const SizedBox(height: 4),
      const Text(
        'Review completed forecasts and compare predicted demand against actual recorded sales.',
        style: TextStyle(fontSize: 13, color: _trackingMuted),
      ),
      const SizedBox(height: 12),
      _TrackingAccuracyTableCard(
        child: items.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 22),
                child: Text(
                  'No completed forecast evaluations available yet.',
                  style: TextStyle(fontSize: 13, color: _trackingMuted),
                ),
              )
            : _TrackingCompletedAccuracyTable(items: items),
      ),
      if (summaries.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text(
          'WAPE and Bias Summary',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _trackingInk,
          ),
        ),
        const SizedBox(height: 8),
        _TrackingAccuracyTableCard(
          child: _TrackingAccuracySummaryTable(summaries: summaries),
        ),
      ],
    ],
  );
}

class _TrackingAccuracyTableCard extends StatelessWidget {
  const _TrackingAccuracyTableCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _trackingLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

class _TrackingAccuracySummaryTable extends StatelessWidget {
  const _TrackingAccuracySummaryTable({required this.summaries});

  final List<ForecastPerformanceSummary> summaries;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: constraints.maxWidth < 690 ? 690 : constraints.maxWidth,
        child: Column(
          children: [
            const _TrackingAccuracySummaryRow(header: true),
            for (final summary in summaries)
              _TrackingAccuracySummaryRow(summary: summary),
          ],
        ),
      ),
    ),
  );
}

class _TrackingAccuracySummaryRow extends StatelessWidget {
  const _TrackingAccuracySummaryRow({this.summary, this.header = false});

  final ForecastPerformanceSummary? summary;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final value = summary;
    return Container(
      key: value == null
          ? null
          : ValueKey('forecast-performance-summary-${value.inventoryUnit}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: header ? _trackingSubtle : Colors.white,
        border: const Border(bottom: BorderSide(color: _trackingLine)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 24,
            child: header
                ? const _TrackingHeaderText('Inventory Unit')
                : Text(value!.inventoryUnit, style: _trackingTableValueStyle),
          ),
          Expanded(
            flex: 26,
            child: header
                ? const _TrackingHeaderText('Eligible Evaluations', right: true)
                : Text(
                    '${value!.evaluationCount}',
                    textAlign: TextAlign.right,
                    style: _trackingTableValueStyle,
                  ),
          ),
          Expanded(
            flex: 24,
            child: header
                ? const _TrackingHeaderText('WAPE', right: true)
                : Text(
                    value!.wape == null
                        ? 'Unavailable'
                        : '${value.wape!.toStringAsFixed(1)}%',
                    textAlign: TextAlign.right,
                    style: _trackingTableValueStyle,
                  ),
          ),
          Expanded(
            flex: 26,
            child: header
                ? const _TrackingHeaderText('Forecast Bias', right: true)
                : Text(
                    value!.forecastBias == null
                        ? 'Unavailable'
                        : '${_signedQuantity(value.forecastBias!)}%',
                    textAlign: TextAlign.right,
                    style: _trackingTableValueStyle,
                  ),
          ),
        ],
      ),
    );
  }
}

const _trackingTableValueStyle = TextStyle(
  fontSize: 12.5,
  fontWeight: FontWeight.w500,
  color: _trackingInk,
);

class _TrackingCompletedAccuracyTable extends StatelessWidget {
  const _TrackingCompletedAccuracyTable({required this.items});

  final List<ForecastPerformanceItem> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: constraints.maxWidth < 900 ? 900 : constraints.maxWidth,
        child: Column(
          children: [
            const _TrackingAccuracyTableRow(header: true),
            for (final item in items) _TrackingAccuracyTableRow(item: item),
          ],
        ),
      ),
    ),
  );
}

class _TrackingAccuracyTableRow extends StatelessWidget {
  const _TrackingAccuracyTableRow({this.item, this.header = false});

  final ForecastPerformanceItem? item;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final value = item;
    final values = Row(
      children: [
        Expanded(
          flex: 24,
          child: header
              ? const _TrackingHeaderText('Date / Product')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _trackingRecordDate(value!.recommendationDate),
                      style: const TextStyle(
                        fontSize: 11,
                        color: _trackingMuted,
                      ),
                    ),
                    Text(
                      _trackingPeriod(
                        value!.forecastPeriodStart,
                        value.forecastPeriodEnd,
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        color: _trackingMuted,
                      ),
                    ),
                    Text(
                      value.productName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _trackingInk,
                      ),
                    ),
                  ],
                ),
        ),
        Expanded(
          flex: 19,
          child: header
              ? const _TrackingHeaderText('Forecast Period', right: true)
              : Text(
                  _trackingPeriod(
                    value!.forecastPeriodStart,
                    value.forecastPeriodEnd,
                  ),
                  textAlign: TextAlign.right,
                  style: _trackingTableValueStyle,
                ),
        ),
        Expanded(
          flex: 16,
          child: header
              ? const _TrackingHeaderText('Forecasted Demand', right: true)
              : _TrackingQuantityText(
                  value: value!.predictedDemand,
                  unit: value.inventoryUnit,
                  alignRight: true,
                ),
        ),
        Expanded(
          flex: 16,
          child: header
              ? const _TrackingHeaderText('Actual sales', right: true)
              : value!.actualCompletedSales == null
              ? const Text(
                  'Unavailable',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: _trackingMuted),
                )
              : _TrackingQuantityText(
                  value: value.actualCompletedSales!,
                  unit: value.inventoryUnit,
                  alignRight: true,
                ),
        ),
        Expanded(
          flex: 13,
          child: header
              ? const _TrackingHeaderText('Status', right: true)
              : Text(
                  _trackingTitleCase(_readable(value!.evaluationStatus)),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _trackingTableValueStyle,
                ),
        ),
      ],
    );
    return Container(
      key: value == null
          ? null
          : ValueKey('forecast-performance-${value.recommendationId}'),
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: header ? 10 : 11),
      decoration: BoxDecoration(
        color: header ? _trackingSubtle : Colors.white,
        border: const Border(bottom: BorderSide(color: _trackingLine)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          values,
          if (!header) ...[
            const SizedBox(height: 6),
            Text(
              value!.statusExplanation,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: _trackingMuted,
              ),
            ),
            if (value!.syntheticSales)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Simulation data; this does not establish real-store accuracy.',
                  key: Key('forecast-performance-synthetic-warning'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _trackingAccentStrong,
                  ),
                ),
              ),
            if (!value!.stockAvailabilityKnown)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Stock availability is not proven; recorded sales may understate demand during stockouts.',
                  style: TextStyle(fontSize: 11.5, color: _trackingMuted),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _TrackingCompletedAccuracyList extends StatelessWidget {
  const _TrackingCompletedAccuracyList({required this.items});

  final List<ForecastPerformanceItem> items;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final item in items)
        Container(
          key: ValueKey('forecast-performance-${item.recommendationId}'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _trackingLine)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _trackingPeriod(
                  item.forecastPeriodStart,
                  item.forecastPeriodEnd,
                ),
                style: const TextStyle(fontSize: 12, color: _trackingMuted),
              ),
              Text(
                item.productName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _trackingInk,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Forecast ${_quantity(item.predictedDemand)} ${item.inventoryUnit} · '
                'Actual ${item.actualCompletedSales == null ? 'unavailable' : '${_quantity(item.actualCompletedSales!)} ${item.inventoryUnit}'} · '
                'Difference ${item.signedForecastError == null ? '—' : '${_signedQuantity(item.signedForecastError!)} ${item.inventoryUnit}'}',
                style: const TextStyle(fontSize: 12, color: _trackingBody),
              ),
              const SizedBox(height: 5),
              Text(
                item.statusExplanation,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: _trackingMuted,
                ),
              ),
              if (item.errorDirection != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    'Error direction: ${_trackingTitleCase(_readable(item.errorDirection!))}',
                    style: const TextStyle(fontSize: 12, color: _trackingMuted),
                  ),
                ),
              if (item.syntheticSales)
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text(
                    'Simulation data; this does not establish real-store accuracy.',
                    key: Key('forecast-performance-synthetic-warning'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _trackingAccentStrong,
                    ),
                  ),
                ),
              if (!item.stockAvailabilityKnown)
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text(
                    'Stock availability is not proven; recorded sales may understate demand during stockouts.',
                    style: TextStyle(fontSize: 12, color: _trackingMuted),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}

class _TrackingPerformanceDisclosure extends StatelessWidget {
  const _TrackingPerformanceDisclosure({
    required this.open,
    required this.report,
    required this.onToggle,
  });

  final bool open;
  final ForecastPerformanceReport? report;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _trackingLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: open,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'How is forecast performance measured?',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _trackingInk,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Data basis, eligibility, WAPE and Bias',
                          style: TextStyle(fontSize: 12, color: _trackingMuted),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: const Cubic(.23, 1, .32, 1),
                    child: const Icon(
                      LucideIcons.chevronDown,
                      size: 16,
                      color: _trackingMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: const Cubic(.23, 1, .32, 1),
          alignment: Alignment.topCenter,
          child: open
              ? Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: _trackingLine)),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const wape = _TrackingPerformanceFormula(
                        title: 'WAPE — Forecast Error',
                        explanation:
                            'Measures total absolute forecast error relative to actual sales. Lower is better.',
                        formula: 'Σ |forecast − actual sales| ÷ Σ actual sales',
                      );
                      const bias = _TrackingPerformanceFormula(
                        title: 'Bias — Forecast Tendency',
                        explanation:
                            'Positive means predicted too much; negative means predicted too little. Near zero means more balanced overall, but does not guarantee small errors.',
                        formula:
                            '(Σ forecast − Σ actual sales) ÷ Σ actual sales',
                      );
                      final formulas = constraints.maxWidth < 680
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                wape,
                                const SizedBox(height: 18),
                                bias,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: wape),
                                const SizedBox(width: 18),
                                Expanded(child: bias),
                              ],
                            );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _TrackingAccuracyTransparency(report: report),
                          const SizedBox(height: 18),
                          const Divider(height: 1, color: _trackingLine),
                          const SizedBox(height: 18),
                          formulas,
                          const SizedBox(height: 18),
                          const Text(
                            'Only forecasts whose full 28-day period has ended, with recorded sales for that period, are evaluated. Restock quantities are not part of these measures.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: _trackingMuted,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

class _TrackingAccuracyTransparency extends StatelessWidget {
  const _TrackingAccuracyTransparency({required this.report});

  final ForecastPerformanceReport? report;

  @override
  Widget build(BuildContext context) {
    final items = report?.items ?? const <ForecastPerformanceItem>[];
    final models = items
        .map(
          (item) =>
              '${item.forecastModel} v${item.forecastVersion} · ${item.trainingHistoryDays}-day history',
        )
        .toSet()
        .toList(growable: false);
    final provenance = items
        .map((item) => _trackingTitleCase(_readable(item.salesProvenance)))
        .toSet()
        .toList(growable: false);
    final eligibleCount = items.where((item) => item.evaluable).length;
    final actualSalesCount = items
        .where((item) => item.actualCompletedSales != null)
        .length;
    final limitations = report?.limitations ?? const <String>[];
    final caveats = limitations.isEmpty
        ? 'No additional report-level caveats were returned. Item-specific stock and simulation warnings still appear with affected results.'
        : limitations.take(2).join(' ') +
              (limitations.length > 2
                  ? ' ${limitations.length - 2} more report-level ${limitations.length == 3 ? 'caveat applies' : 'caveats apply'}.'
                  : '');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _trackingSubtle,
        border: Border.all(color: _trackingLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Forecast accuracy transparency',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: _trackingInk,
            ),
          ),
          const SizedBox(height: 8),
          const _TrackingTransparencyFact(
            label: 'Comparison',
            value:
                'Predicted customer demand versus actual recorded customer sales. Restock quantities are not part of forecast accuracy.',
          ),
          _TrackingTransparencyFact(
            label: 'Model basis',
            value: models.isEmpty
                ? 'Available after a saved forecast is loaded.'
                : models.join(' · '),
          ),
          _TrackingTransparencyFact(
            label: 'Sales source',
            value: provenance.isEmpty
                ? (report?.dataSourceWarning ??
                      'Recorded-sales provenance is unavailable.')
                : '${provenance.join(', ')} · Business timezone ${report?.businessTimezone ?? 'unavailable'}',
          ),
          _TrackingTransparencyFact(
            label: 'Actual sales',
            value: items.isEmpty
                ? 'Availability is shown after saved forecasts load.'
                : '$actualSalesCount of ${items.length} saved forecasts currently include completed actual-sales data.',
          ),
          _TrackingTransparencyFact(
            label: 'Eligibility',
            value: items.isEmpty
                ? 'A full 28-day period must end and recorded sales must be available.'
                : '$eligibleCount of ${items.length} saved forecasts are currently eligible. Period end alone does not guarantee eligibility.',
          ),
          _TrackingTransparencyFact(label: 'Caveats', value: caveats),
        ],
      ),
    );
  }
}

class _TrackingTransparencyFact extends StatelessWidget {
  const _TrackingTransparencyFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: _trackingMuted,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: _trackingBody,
            ),
          ),
        ),
      ],
    ),
  );
}

class _TrackingPerformanceFormula extends StatelessWidget {
  const _TrackingPerformanceFormula({
    required this.title,
    required this.explanation,
    required this.formula,
  });

  final String title;
  final String explanation;
  final String formula;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: _trackingInk,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        explanation,
        style: const TextStyle(
          fontSize: 13,
          height: 1.45,
          color: _trackingBody,
        ),
      ),
      const SizedBox(height: 9),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: _trackingSubtle,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          formula,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: _trackingBody,
          ),
        ),
      ),
    ],
  );
}

class _TrackingInfoNotice extends StatelessWidget {
  const _TrackingInfoNotice({
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: _trackingAccentSoft,
      border: Border.all(color: const Color(0xFFF6D4BD)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        const Icon(LucideIcons.info, size: 16, color: _trackingAccent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: _trackingBody,
            ),
          ),
        ),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ),
  );
}

class _TrackingQuantityText extends StatelessWidget {
  const _TrackingQuantityText({
    required this.value,
    required this.unit,
    this.alignRight = false,
    this.signed = false,
  });

  final double? value;
  final String unit;
  final bool alignRight;
  final bool signed;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: value == null ? 'Not recorded' : signed ? _signedQuantity(value!) : _quantity(value),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: _trackingInk,
          ),
        ),
        TextSpan(
          text: value == null ? '' : ' $unit',
          style: const TextStyle(fontSize: 13, color: _trackingMuted),
        ),
      ],
    ),
    textAlign: alignRight ? TextAlign.right : TextAlign.left,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

class _TrackingHeaderText extends StatelessWidget {
  const _TrackingHeaderText(this.text, {this.right = false});

  final String text;
  final bool right;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: right ? TextAlign.right : TextAlign.left,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: _trackingMuted,
    ),
  );
}

class _TrackingForecastProgress {
  const _TrackingForecastProgress({
    required this.label,
    required this.fraction,
  });

  final String label;
  final double fraction;
}

_TrackingForecastProgress _trackingForecastProgress(
  String startValue,
  String endValue,
) {
  final start = _trackingDateOnly(startValue);
  final end = _trackingDateOnly(endValue);
  if (start == null || end == null || end.isBefore(start)) {
    return const _TrackingForecastProgress(
      label: 'Schedule unavailable',
      fraction: 0,
    );
  }
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final totalDays = end.difference(start).inDays + 1;
  if (today.isBefore(start)) {
    final startsIn = start.difference(today).inDays;
    return _TrackingForecastProgress(
      label: 'Starts in $startsIn ${startsIn == 1 ? 'day' : 'days'}',
      fraction: 0,
    );
  }
  if (today.isAfter(end)) {
    return const _TrackingForecastProgress(label: 'Period ended', fraction: 1);
  }
  final elapsed = today.difference(start).inDays + 1;
  final daysLeft = end.difference(today).inDays + 1;
  return _TrackingForecastProgress(
    label: '$daysLeft ${daysLeft == 1 ? 'day' : 'days'} left',
    fraction: (elapsed / totalDays).clamp(0.0, 1.0).toDouble(),
  );
}

String _trackingEvaluationStatus(List<ForecastPerformanceItem> items) {
  if (items.isEmpty) return 'Awaiting saved forecast';
  final statuses = items
      .map((item) => _readable(item.evaluationStatus))
      .toSet();
  if (statuses.length == 1) return _trackingTitleCase(statuses.first);
  return 'Awaiting completion';
}

String _trackingTitleCase(String value) => value
    .split(' ')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

DateTime? _trackingDateOnly(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

String _trackingPeriod(String? startValue, String? endValue) {
  if (startValue == null || endValue == null) return 'Not recorded';
  final start = _trackingDateOnly(startValue);
  final end = _trackingDateOnly(endValue);
  if (start == null || end == null) return '$startValue – $endValue';
  return '${_trackingMonth(start.month)} ${start.day} – '
      '${_trackingMonth(end.month)} ${end.day}, ${end.year}';
}

String _trackingMonth(int month) => const [
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
][month - 1];

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

enum _TrackingMatchFilter { all, matched, unmatched }

class _TrackingRestockRecords extends StatefulWidget {
  const _TrackingRestockRecords({
    super.key,
    required this.hasProductSelection,
    required this.productScope,
    required this.refreshControl,
    required this.items,
    required this.loading,
    this.error,
    this.onRetry,
  });

  final bool hasProductSelection;
  final Widget productScope;
  final Widget refreshControl;
  final List<RecommendationTrackingItem> items;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  State<_TrackingRestockRecords> createState() =>
      _TrackingRestockRecordsState();
}

class _TrackingRestockRecordsState extends State<_TrackingRestockRecords> {
  static const _pageSize = 5;

  final TextEditingController _searchController = TextEditingController();
  _TrackingMatchFilter _filter = _TrackingMatchFilter.all;
  bool _showAll = false;
  String? _expandedId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = widget.items
        .where((item) {
          if (query.isNotEmpty &&
              !'${item.productName} ${item.productSku}'.toLowerCase().contains(
                query,
              )) {
            return false;
          }
          return switch (_filter) {
            _TrackingMatchFilter.all => true,
            _TrackingMatchFilter.matched => item.receiptCount > 0,
            _TrackingMatchFilter.unmatched => item.receiptCount == 0,
          };
        })
        .toList(growable: false);
    final visible = _showAll
        ? filtered
        : filtered.take(_pageSize).toList(growable: false);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _trackingLine),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TrackingRecordsToolbar(
            controller: _searchController,
            filter: _filter,
            recordCount: filtered.length,
            productScope: widget.productScope,
            refreshControl: widget.refreshControl,
            onSearchChanged: (_) => setState(() {
              _showAll = false;
              _expandedId = null;
            }),
            onClearSearch: () {
              _searchController.clear();
              setState(() {
                _showAll = false;
                _expandedId = null;
              });
            },
            onFilterChanged: (value) => setState(() {
              _filter = value;
              _showAll = false;
              _expandedId = null;
            }),
          ),
          if (widget.loading)
            const LinearProgressIndicator(
              minHeight: 3,
              color: _trackingAccent,
              backgroundColor: _trackingLine,
            ),
          if (widget.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: _TrackingInfoNotice(
                text: widget.error!,
                actionLabel: widget.onRetry == null ? null : 'Retry',
                onAction: widget.onRetry,
              ),
            ),
          if (!widget.loading && widget.error == null && widget.items.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 48),
              child: Column(
                children: [
                  Text(
                    widget.hasProductSelection
                        ? 'No saved recommendations for this product yet.'
                        : 'Select a product to review restock records.',
                    key: Key('recommendation-history-empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _trackingInk,
                    ),
                  ),
                  SizedBox(height: 5),
                ],
              ),
            )
          else if (widget.items.isNotEmpty && filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
              child: Column(
                children: [
                  Text(
                    query.isEmpty
                        ? 'No records match this filter'
                        : 'No records match “${_searchController.text.trim()}”',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _trackingInk,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Try a different product name or clear the filter.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: _trackingMuted),
                  ),
                ],
              ),
            )
          else if (filtered.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth >= 768
                  ? _TrackingRecordsDesktop(
                      items: visible,
                      expandedId: _expandedId,
                      onToggle: _toggleRecord,
                    )
                  : _TrackingRecordsMobile(
                      items: visible,
                      expandedId: _expandedId,
                      onToggle: _toggleRecord,
                    ),
            ),
          _TrackingRecordsFooter(
            count: filtered.length,
            showAll: _showAll,
            canToggle: filtered.length > _pageSize,
            onToggle: () => setState(() {
              _showAll = !_showAll;
              _expandedId = null;
            }),
          ),
        ],
      ),
    );
  }

  void _toggleRecord(String id) =>
      setState(() => _expandedId = _expandedId == id ? null : id);
}

class _TrackingRecordsToolbar extends StatelessWidget {
  const _TrackingRecordsToolbar({
    required this.controller,
    required this.filter,
    required this.recordCount,
    required this.productScope,
    required this.refreshControl,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onFilterChanged,
  });

  final TextEditingController controller;
  final _TrackingMatchFilter filter;
  final int recordCount;
  final Widget productScope;
  final Widget refreshControl;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<_TrackingMatchFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _trackingLine)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final search = SizedBox(
          height: 36,
          child: TextField(
            controller: controller,
            onChanged: onSearchChanged,
            style: const TextStyle(fontSize: 13, color: _trackingInk),
            decoration: InputDecoration(
              hintText: 'Search product or SKU',
              hintStyle: const TextStyle(color: _trackingFaint),
              prefixIcon: const Icon(
                LucideIcons.search,
                size: 15,
                color: _trackingFaint,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: onClearSearch,
                      tooltip: 'Clear search',
                      icon: const Icon(LucideIcons.x, size: 14),
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 34),
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
              filled: true,
              fillColor: Colors.white,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _trackingLineStrong),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _trackingAccent),
              ),
            ),
          ),
        );
        final filterControl = Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _trackingLineStrong),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<_TrackingMatchFilter>(
              value: filter,
              isExpanded: true,
              icon: const Icon(LucideIcons.chevronDown, size: 15),
              style: const TextStyle(fontSize: 13, color: _trackingBody),
              items: const [
                DropdownMenuItem(
                  value: _TrackingMatchFilter.all,
                  child: Text(
                    'All records',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: _TrackingMatchFilter.matched,
                  child: Text(
                    'With detected stock entry',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: _TrackingMatchFilter.unmatched,
                  child: Text(
                    'No detected stock entry',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (value) {
                if (value != null) onFilterChanged(value);
              },
            ),
          ),
        );
        final count = Text(
          '$recordCount ${recordCount == 1 ? 'record' : 'records'}',
          style: const TextStyle(fontSize: 12, color: _trackingMuted),
        );
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: 10),
              if (constraints.maxWidth < 600) ...[
                SizedBox(height: 36, child: productScope),
                const SizedBox(height: 10),
                filterControl,
              ] else
                Row(
                  children: [
                    Expanded(child: SizedBox(height: 36, child: productScope)),
                    const SizedBox(width: 10),
                    Expanded(child: filterControl),
                  ],
                ),
              const SizedBox(height: 9),
              Row(children: [count, const Spacer(), refreshControl]),
            ],
          );
        }
        return Row(
          children: [
            Expanded(flex: 30, child: search),
            const SizedBox(width: 10),
            Expanded(
              flex: 25,
              child: SizedBox(height: 36, child: productScope),
            ),
            const SizedBox(width: 10),
            SizedBox(width: 170, child: filterControl),
            const SizedBox(width: 10),
            count,
            const SizedBox(width: 12),
            refreshControl,
          ],
        );
      },
    ),
  );
}

class _TrackingRecordsDesktop extends StatelessWidget {
  const _TrackingRecordsDesktop({
    required this.items,
    required this.expandedId,
    required this.onToggle,
  });

  final List<RecommendationTrackingItem> items;
  final String? expandedId;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const _TrackingRecordsHeader(),
      for (final item in items) ...[
        _TrackingDesktopRecordRow(
          item: item,
          open: expandedId == item.recordKey,
          onTap: () => onToggle(item.recordKey),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: const Cubic(.23, 1, .32, 1),
          alignment: Alignment.topCenter,
          child: expandedId == item.recordKey
              ? _TrackingRecordDetails(item: item)
              : const SizedBox.shrink(),
        ),
      ],
    ],
  );
}

class _TrackingRecordsHeader extends StatelessWidget {
  const _TrackingRecordsHeader();

  @override
  Widget build(BuildContext context) => Container(
    color: _trackingSubtle,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: const Row(
      children: [
        Expanded(flex: 30, child: _TrackingHeaderText('Date / Product')),
        Expanded(
          flex: 18,
          child: _TrackingHeaderText('Forecasted Demand', right: true),
        ),
        Expanded(
          flex: 18,
          child: _TrackingHeaderText('Suggested Restock', right: true),
        ),
        Expanded(
          flex: 17,
          child: _TrackingHeaderText('Actual Restock', right: true),
        ),
        Expanded(
          flex: 13,
          child: _TrackingHeaderText('Difference', right: true),
        ),
        SizedBox(width: 32),
      ],
    ),
  );
}

class _TrackingDesktopRecordRow extends StatelessWidget {
  const _TrackingDesktopRecordRow({
    required this.item,
    required this.open,
    required this.onTap,
  });

  final RecommendationTrackingItem item;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: open ? _trackingAccentSoft.withValues(alpha: 0.6) : Colors.white,
    child: InkWell(
      onTap: onTap,
      hoverColor: _trackingSubtle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _trackingLine)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 30,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _trackingRecordDate(item.recommendationDate),
                    style: const TextStyle(fontSize: 12, color: _trackingMuted),
                  ),
                  Text(
                    item.productName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _trackingInk,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 18,
              child: _TrackingQuantityText(
                value: item.predictedDemand,
                unit: item.inventoryUnit,
                alignRight: true,
              ),
            ),
            Expanded(
              flex: 18,
              child: _TrackingQuantityText(
                value: item.suggestedQuantity,
                unit: item.inventoryUnit,
                alignRight: true,
              ),
            ),
            Expanded(flex: 17, child: _TrackingActualRestock(item: item)),
            Expanded(flex: 13, child: _TrackingRestockDifference(item: item)),
            SizedBox(
              width: 32,
              child: AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  LucideIcons.chevronDown,
                  size: 15,
                  color: _trackingFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TrackingRecordsMobile extends StatelessWidget {
  const _TrackingRecordsMobile({
    required this.items,
    required this.expandedId,
    required this.onToggle,
  });

  final List<RecommendationTrackingItem> items;
  final String? expandedId;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final item in items) ...[
        Material(
          color: expandedId == item.recordKey
              ? _trackingAccentSoft.withValues(alpha: 0.5)
              : Colors.white,
          child: InkWell(
            onTap: () => onToggle(item.recordKey),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _trackingLine)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _trackingRecordDate(item.recommendationDate),
                              style: const TextStyle(
                                fontSize: 12,
                                color: _trackingMuted,
                              ),
                            ),
                            Text(
                              item.productName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: _trackingInk,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: expandedId == item.recordKey ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(
                          LucideIcons.chevronDown,
                          size: 15,
                          color: _trackingFaint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _TrackingMobileValue(
                          label: 'Forecasted',
                          child: _TrackingQuantityText(
                            value: item.predictedDemand,
                            unit: item.inventoryUnit,
                            alignRight: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _TrackingMobileValue(
                          label: 'Suggested',
                          child: _TrackingQuantityText(
                            value: item.suggestedQuantity,
                            unit: item.inventoryUnit,
                            alignRight: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _TrackingMobileValue(
                          label: 'Actual',
                          child: _TrackingActualRestock(item: item),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _TrackingMobileValue(
                          label: 'Difference',
                          child: _TrackingRestockDifference(item: item),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: const Cubic(.23, 1, .32, 1),
          alignment: Alignment.topCenter,
          child: expandedId == item.recordKey
              ? _TrackingRecordDetails(item: item)
              : const SizedBox.shrink(),
        ),
      ],
    ],
  );
}

class _TrackingMobileValue extends StatelessWidget {
  const _TrackingMobileValue({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: _trackingMuted)),
      const SizedBox(width: 8),
      Expanded(child: child),
    ],
  );
}

class _TrackingActualRestock extends StatelessWidget {
  const _TrackingActualRestock({required this.item});

  final RecommendationTrackingItem item;

  @override
  Widget build(BuildContext context) {
    if (item.receiptCount == 0) {
      return const Text(
        'No detected stock entry',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: _trackingMuted,
        ),
      );
    }
    final quantity = item.matchedReceivedQuantity;
    if (quantity == null) {
      return const Text(
        'Unavailable',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 12, color: _trackingMuted),
      );
    }
    return _TrackingQuantityText(
      value: quantity,
      unit: item.inventoryUnit,
      alignRight: true,
    );
  }
}

class _TrackingRestockDifference extends StatelessWidget {
  const _TrackingRestockDifference({required this.item});

  final RecommendationTrackingItem item;

  @override
  Widget build(BuildContext context) {
    if (item.receiptCount == 0) {
      return const Text(
        'Unavailable',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 12, color: _trackingMuted),
      );
    }
    final difference = item.signedQuantityDifference;
    if (difference == null) {
      return const Text(
        'Not recorded',
        textAlign: TextAlign.right,
        style: TextStyle(fontSize: 12, color: _trackingMuted),
      );
    }
    return _TrackingQuantityText(
      value: difference,
      unit: item.inventoryUnit,
      alignRight: true,
      signed: true,
    );
  }
}

class _TrackingRecordDetails extends StatelessWidget {
  const _TrackingRecordDetails({required this.item});

  final RecommendationTrackingItem item;

  @override
  Widget build(BuildContext context) {
    final fields = <(String, String)>[
      (item.transactionId != null ? 'Restock applied' : 'Forecast saved', _trackingRecordDate(item.recommendationDate)),
      (
        'Forecast period',
        item.forecastPeriodStart == null || item.forecastPeriodEnd == null ? 'Not recorded' : '${_trackingPeriod(item.forecastPeriodStart, item.forecastPeriodEnd)} (28 days)',
      ),
      ('Inventory unit', item.inventoryUnit),
      (
        item.isReconstructed ? 'Stock before restock' : 'On hand when forecast was saved',
        item.availableInventory == null ? 'Not recorded' : '${_quantity(item.availableInventory)} ${item.inventoryUnit}',
      ),
      ('SKU', item.productSku),
      ('Forecast model', item.forecastLabel),
      if (item.assumptions.isNotEmpty)
        ('Historical evidence', '${item.evidenceLabel}. ${item.assumptions.join(' ')}'),
    ];
    final details = Wrap(
      spacing: 24,
      runSpacing: 10,
      children: [
        for (final field in fields)
          SizedBox(
            width: 210,
            child: _TrackingDetailField(label: field.$1, value: field.$2),
          ),
      ],
    );
    final evidence = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Detected stock evidence',
          style: TextStyle(fontSize: 12, color: _trackingMuted),
        ),
        const SizedBox(height: 5),
        if (item.receiptCount > 0) ...[
          Text(
            '${item.receiptCount} detected ${item.receiptCount == 1 ? 'stock entry' : 'stock entries'}',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: _trackingInk,
            ),
          ),
          if (item.matchedReceivedQuantity != null)
            Text(
              '${_quantity(item.matchedReceivedQuantity!)} ${item.inventoryUnit} added to stock',
              style: const TextStyle(fontSize: 12.5, color: _trackingBody),
            ),
          if (item.lastReceiptDate != null)
            Text(
              'Latest detected entry ${_trackingRecordDate(item.lastReceiptDate!)}',
              style: const TextStyle(fontSize: 12.5, color: _trackingBody),
            ),
          const SizedBox(height: 8),
          Text(
            item.signedQuantityDifference == null
                ? 'Historical suggestion not recorded; the actual stock addition is shown above.'
                : 'Suggested restock can be compared with the detected stock addition.',
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: _trackingMuted,
            ),
          ),
        ] else
          const Text(
            'No stock-entry evidence has been detected for this recommendation. Actual restock remains unavailable and is not treated as zero.',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: _trackingBody),
          ),
      ],
    );
    return Container(
      key: ValueKey('recommendation-history-${item.recordKey}'),
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: _trackingSubtle,
        border: Border(bottom: BorderSide(color: _trackingLine)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 18),
                const Divider(height: 1, color: _trackingLine),
                const SizedBox(height: 14),
                evidence,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 14, child: details),
              const SizedBox(width: 20),
              Container(width: 1, height: 150, color: _trackingLine),
              const SizedBox(width: 20),
              Expanded(flex: 10, child: evidence),
            ],
          );
        },
      ),
    );
  }
}

class _TrackingDetailField extends StatelessWidget {
  const _TrackingDetailField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: _trackingMuted)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontSize: 12.5, color: _trackingInk)),
    ],
  );
}

class _TrackingRecordsFooter extends StatelessWidget {
  const _TrackingRecordsFooter({
    required this.count,
    required this.showAll,
    required this.canToggle,
    required this.onToggle,
  });

  final int count;
  final bool showAll;
  final bool canToggle;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _trackingLine)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const definition = Text(
          'Difference = Actual Restock − Suggested Restock. Positive means more was restocked than suggested.',
          style: TextStyle(fontSize: 12, color: _trackingMuted),
        );
        final toggle = canToggle
            ? TextButton(
                onPressed: onToggle,
                style: TextButton.styleFrom(
                  foregroundColor: _trackingAccent,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                child: Text(
                  showAll ? 'Show 5 most recent' : 'View all records ($count)',
                ),
              )
            : const SizedBox.shrink();
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              definition,
              if (canToggle) ...[const SizedBox(height: 8), toggle],
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: definition),
            if (canToggle) ...[const SizedBox(width: 16), toggle],
          ],
        );
      },
    ),
  );
}

class _TrackingRestockTransparency extends StatelessWidget {
  const _TrackingRestockTransparency();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: _trackingSubtle,
      border: Border.all(color: _trackingLine),
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.info, size: 16, color: _trackingAccent),
        SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Restock tracking transparency',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _trackingInk,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Suggested restock is compared with actual stock additions detected from recorded stock-entry evidence. Missing evidence is shown as unavailable, never zero. This does not measure customer-demand forecast accuracy.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: _trackingMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String _trackingRecordDate(DateTime value) {
  final local = value.toLocal();
  return '${_trackingMonth(local.month)} ${local.day}, ${local.year}';
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
          'Compare saved recommendation snapshots with later stock additions detected from inventory records. Restock variance is separate from customer-demand forecast accuracy.',
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
            _trackingPeriod(item.forecastPeriodStart, item.forecastPeriodEnd),
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
            item.forecastLabel == 'Not recorded' ? 'Not recorded' : '${item.forecastLabel} (${item.trainingHistoryDays == null ? 'History not recorded' : '${item.trainingHistoryDays}-day history'})',
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
            'Detected received quantity',
            hasReceipts
                ? '${_quantity(item.matchedReceivedQuantity!)} ${item.inventoryUnit} across ${item.receiptCount} detected stock entry or entries'
                : 'No stock entry detected — received quantity is unavailable, not zero',
          ),
          _Metric(
            'Signed difference (received − suggested)',
            !hasReceipts
                ? 'Unavailable — no detected stock evidence'
                : item.signedQuantityDifference == null
                ? 'Unavailable'
                : '${_signedQuantity(item.signedQuantityDifference!)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Absolute difference',
            !hasReceipts
                ? 'Unavailable — no detected stock evidence'
                : item.absoluteDifference == null
                ? 'Unavailable'
                : '${_quantity(item.absoluteDifference!)} ${item.inventoryUnit}',
          ),
          _Metric(
            'Percentage variance',
            !hasReceipts
                ? 'Unavailable — no detected stock evidence'
                : item.percentageVariance == null
                ? 'Unavailable or not defined'
                : '${item.percentageVariance!.toStringAsFixed(1)}%',
          ),
          if (item.lastReceiptDate != null)
            _Metric(
              'Latest detected stock entry',
              _timestamp(item.lastReceiptDate!),
            ),
          const SizedBox(height: 8),
          const Text(
            'Stock evidence is detected automatically. This view is informational only.',
            style: TextStyle(color: Color(0xFF475569), fontSize: 12),
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
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _forecastLine),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(width: 2),
            Icon(icon, color: _forecastMuted, size: 18),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _forecastInk,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
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
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: _forecastMuted),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _forecastInk,
            ),
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

String _quantity(double? value) {
  if (value == null) return 'Not recorded';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}

String _withUnit(double? value, String? unit) =>
    value == null ? 'Unavailable' : '${_quantity(value)} ${unit ?? ''}'.trim();

String _readable(String value) {
  final words = value.trim().replaceAll('_', ' ').replaceAll('-', ' ');
  return words.isEmpty ? 'Unknown' : words;
}

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
