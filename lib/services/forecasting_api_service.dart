import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../logic/seasonal_learning_lab.dart';

class ForecastApiException implements Exception {
  const ForecastApiException(
    this.message, {
    this.statusCode,
    this.isTimeout = false,
  });

  final String message;
  final int? statusCode;
  final bool isTimeout;

  @override
  String toString() => message;
}

abstract interface class ForecastingApiService {
  Future<ForecastAnalysis> analyze({
    required String productId,
    required String locationId,
    required String sessionToken,
    required String model,
    int horizonDays = 28,
    double? manualDailyDemand,
    String? manualUnit,
    String? manualRationale,
    bool manualConfirmed = false,
  });

  Future<ReplenishmentConfiguration> getReplenishmentConfiguration({
    required String productId,
    required String locationId,
    required String sessionToken,
  });

  Future<ReplenishmentConfiguration> saveReplenishmentConfiguration({
    required String productId,
    required String locationId,
    required String sessionToken,
    required ReplenishmentConfigurationInput configuration,
  });

  Future<SeasonalLearningLabReport> loadSeasonalLearningLab({
    required String sessionToken,
    String? productId,
  });

  Future<RecommendationSnapshotSaveResult> saveRecommendationSnapshot({
    required String productId,
    required String locationId,
    required String sessionToken,
    required String requestId,
    required ForecastAnalysis analysis,
  });

  Future<List<RecommendationTrackingItem>> loadRecommendationTracking({
    required String locationId,
    required String sessionToken,
    String? productId,
  });

  Future<ForecastPerformanceReport> loadForecastPerformance({
    required String productId,
    required String locationId,
    required String sessionToken,
  });

  Future<ReceiptAllocationResult> matchRecommendationReceipt({
    required int recommendationId,
    required String locationId,
    required String sessionToken,
    required String transactionHistoryId,
    required double allocatedInventoryQuantity,
  });

  Future<RecommendationReconciliationResult> reconcileRecommendation({
    required int recommendationId,
    required String locationId,
    required String sessionToken,
    required String requestId,
    required bool confirmNoReceipts,
    String? confirmationNote,
  });
}

class ForecastApiClient implements ForecastingApiService {
  ForecastApiClient({
    required Uri baseUri,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.seasonalTimeout = const Duration(seconds: 90),
  }) : _baseUri = baseUri,
       _client = client ?? http.Client();

  factory ForecastApiClient.fromEnvironment({http.Client? client}) {
    return ForecastApiClient(
      baseUri: resolveConfiguredBaseUri(),
      client: client,
    );
  }

  static Uri resolveConfiguredBaseUri({
    String compileTimeUrl = const String.fromEnvironment('FORECAST_API_URL'),
    String? dotenvUrl,
  }) {
    final defined = compileTimeUrl.trim();
    final configured = defined.isNotEmpty
        ? defined
        : (dotenvUrl ?? dotenv.env['FORECAST_API_URL'] ?? '').trim();
    if (configured.isEmpty) {
      throw const ForecastApiException(
        'Forecast API is not configured. Set FORECAST_API_URL with '
        '--dart-define or in lib/.env.',
      );
    }
    final uri = Uri.tryParse(configured);
    if (uri == null ||
        !const <String>{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const ForecastApiException(
        'FORECAST_API_URL must be an absolute HTTP or HTTPS URL.',
      );
    }
    return uri;
  }

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;
  final Duration seasonalTimeout;

  @override
  Future<ForecastAnalysis> analyze({
    required String productId,
    required String locationId,
    required String sessionToken,
    required String model,
    int horizonDays = 28,
    double? manualDailyDemand,
    String? manualUnit,
    String? manualRationale,
    bool manualConfirmed = false,
  }) async {
    final path =
        '/v1/forecasting/products/'
        '${Uri.encodeComponent(productId)}/analysis';
    final uri = _baseUri.resolve(path);
    final body = <String, dynamic>{
      'location_id': locationId,
      'model': model,
      'horizon_days': horizonDays,
    };
    if (manualDailyDemand != null) {
      body['manual_daily_demand'] = manualDailyDemand;
    }
    if (manualUnit != null) body['manual_unit'] = manualUnit;
    if (manualRationale != null) body['manual_rationale'] = manualRationale;
    if (manualDailyDemand != null) {
      body['manual_confirmed'] = manualConfirmed;
    }
    final requestTimeout = model == 'seasonal_experimental'
        ? seasonalTimeout
        : timeout;
    try {
      final response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $sessionToken',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
      final decoded = _decodeObject(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded?['detail']?.toString();
        throw ForecastApiException(
          detail?.isNotEmpty == true
              ? detail!
              : 'Forecast API request failed (${response.statusCode}).',
          statusCode: response.statusCode,
        );
      }
      if (decoded == null) {
        throw const ForecastApiException('Forecast API returned invalid JSON.');
      }
      return ForecastAnalysis.fromJson(decoded);
    } on TimeoutException {
      throw const ForecastApiException(
        'Forecast API timed out. Try again.',
        isTimeout: true,
      );
    } on SocketException {
      throw const ForecastApiException('Forecast API is unreachable.');
    } on http.ClientException {
      throw const ForecastApiException('Forecast API connection failed.');
    } on FormatException {
      throw const ForecastApiException('Forecast API returned invalid data.');
    }
  }

  @override
  Future<ReplenishmentConfiguration> getReplenishmentConfiguration({
    required String productId,
    required String locationId,
    required String sessionToken,
  }) async {
    final path =
        '/v1/forecasting/products/'
        '${Uri.encodeComponent(productId)}/replenishment-config';
    final uri = _baseUri
        .resolve(path)
        .replace(queryParameters: <String, String>{'location_id': locationId});
    final response = await _send(
      () => _client.get(uri, headers: _headers(sessionToken)),
    );
    return ReplenishmentConfiguration.fromJson(response);
  }

  @override
  Future<ReplenishmentConfiguration> saveReplenishmentConfiguration({
    required String productId,
    required String locationId,
    required String sessionToken,
    required ReplenishmentConfigurationInput configuration,
  }) async {
    final path =
        '/v1/forecasting/products/'
        '${Uri.encodeComponent(productId)}/replenishment-config';
    final uri = _baseUri.resolve(path);
    final body = configuration.toJson()..['location_id'] = locationId;
    final response = await _send(
      () => _client.put(
        uri,
        headers: _headers(sessionToken),
        body: jsonEncode(body),
      ),
    );
    return ReplenishmentConfiguration.fromJson(response);
  }

  @override
  Future<SeasonalLearningLabReport> loadSeasonalLearningLab({
    required String sessionToken,
    String? productId,
  }) async {
    final query = productId == null || productId.trim().isEmpty
        ? null
        : <String, String>{'product_id': productId};
    final uri = _baseUri
        .resolve('/v1/forecasting/research/seasonal-learning')
        .replace(queryParameters: query);
    final response = await _send(
      () => _client.get(uri, headers: _headers(sessionToken)),
    );
    return SeasonalLearningLabReport.fromJson(response);
  }

  @override
  Future<RecommendationSnapshotSaveResult> saveRecommendationSnapshot({
    required String productId,
    required String locationId,
    required String sessionToken,
    required String requestId,
    required ForecastAnalysis analysis,
  }) async {
    final preliminary = analysis.preliminaryRestockingInsight;
    if (preliminary.predictedDemand == null ||
        preliminary.availableInventory == null ||
        preliminary.suggestedRestockQuantity == null) {
      throw const ForecastApiException(
        'A complete preliminary recommendation is required before saving.',
      );
    }
    final uri = _baseUri.resolve(
      '/v1/forecasting/products/${Uri.encodeComponent(productId)}/recommendation-snapshots',
    );
    final response = await _send(
      () => _client.post(
        uri,
        headers: _headers(sessionToken),
        body: jsonEncode(<String, dynamic>{
          'request_id': requestId,
          'location_id': locationId,
          'forecast_model': preliminary.forecastModel,
          'forecast_version': preliminary.forecastVersion,
          'training_history_days': 365,
          'experimental_model': false,
          'forecast_generated_at': analysis.forecast.generatedAt
              .toUtc()
              .toIso8601String(),
          'forecast_source_data_as_of': analysis.forecast.sourceDataAsOf
              .toUtc()
              .toIso8601String(),
          'planning_horizon_days': preliminary.planningHorizonDays,
          'forecast_period_start': analysis.forecast.periodStart,
          'forecast_period_end': analysis.forecast.periodEnd,
          'predicted_demand': preliminary.predictedDemand,
          'available_inventory': preliminary.availableInventory,
          'recommended_restock_quantity': preliminary.suggestedRestockQuantity,
          'inventory_unit': preliminary.inventoryUnit,
        }),
      ),
    );
    return RecommendationSnapshotSaveResult.fromJson(response);
  }

  @override
  Future<List<RecommendationTrackingItem>> loadRecommendationTracking({
    required String locationId,
    required String sessionToken,
    String? productId,
  }) async {
    final query = <String, String>{'location_id': locationId};
    if (productId != null && productId.trim().isNotEmpty) {
      query['product_id'] = productId;
    }
    final uri = _baseUri
        .resolve('/v1/forecasting/recommendations')
        .replace(queryParameters: query);
    final response = await _send(
      () => _client.get(uri, headers: _headers(sessionToken)),
    );
    final items = response['items'];
    if (items is! List) {
      throw const ForecastApiException(
        'Recommendation tracking response is invalid.',
      );
    }
    return items
        .map(
          (value) => RecommendationTrackingItem.fromJson(
            _map(value, 'recommendation tracking item'),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ForecastPerformanceReport> loadForecastPerformance({
    required String productId,
    required String locationId,
    required String sessionToken,
  }) async {
    final uri = _baseUri
        .resolve('/v1/forecasting/forecast-performance')
        .replace(
          queryParameters: <String, String>{
            'location_id': locationId,
            'product_id': productId,
          },
        );
    final response = await _send(
      () => _client.get(uri, headers: _headers(sessionToken)),
    );
    return ForecastPerformanceReport.fromJson(response);
  }

  @override
  Future<ReceiptAllocationResult> matchRecommendationReceipt({
    required int recommendationId,
    required String locationId,
    required String sessionToken,
    required String transactionHistoryId,
    required double allocatedInventoryQuantity,
  }) async {
    final uri = _baseUri.resolve(
      '/v1/forecasting/recommendations/$recommendationId/receipt-allocations',
    );
    final response = await _send(
      () => _client.post(
        uri,
        headers: _headers(sessionToken),
        body: jsonEncode(<String, dynamic>{
          'location_id': locationId,
          'transaction_history_id': transactionHistoryId,
          'allocated_inventory_quantity': allocatedInventoryQuantity,
        }),
      ),
    );
    return ReceiptAllocationResult.fromJson(response);
  }

  @override
  Future<RecommendationReconciliationResult> reconcileRecommendation({
    required int recommendationId,
    required String locationId,
    required String sessionToken,
    required String requestId,
    required bool confirmNoReceipts,
    String? confirmationNote,
  }) async {
    final uri = _baseUri.resolve(
      '/v1/forecasting/recommendations/$recommendationId/reconcile',
    );
    final response = await _send(
      () => _client.post(
        uri,
        headers: _headers(sessionToken),
        body: jsonEncode(<String, dynamic>{
          'request_id': requestId,
          'location_id': locationId,
          'confirm_no_receipts': confirmNoReceipts,
          'confirmation_note': confirmationNote,
        }),
      ),
    );
    return RecommendationReconciliationResult.fromJson(response);
  }

  Map<String, String> _headers(String sessionToken) => <String, String>{
    'Authorization': 'Bearer $sessionToken',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    try {
      final response = await request().timeout(timeout);
      final decoded = _decodeObject(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded?['detail']?.toString();
        throw ForecastApiException(
          detail?.isNotEmpty == true
              ? detail!
              : 'Forecast API request failed (${response.statusCode}).',
          statusCode: response.statusCode,
        );
      }
      if (decoded == null) {
        throw const ForecastApiException('Forecast API returned invalid JSON.');
      }
      return decoded;
    } on TimeoutException {
      throw const ForecastApiException(
        'Forecast API timed out. Try again.',
        isTimeout: true,
      );
    } on SocketException {
      throw const ForecastApiException('Forecast API is unreachable.');
    } on http.ClientException {
      throw const ForecastApiException('Forecast API connection failed.');
    } on FormatException {
      throw const ForecastApiException('Forecast API returned invalid data.');
    }
  }

  static Map<String, dynamic>? _decodeObject(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

class ReplenishmentConfigurationInput {
  const ReplenishmentConfigurationInput({
    this.supplierLeadTimeDays,
    this.reviewPeriodDays,
    this.safetyStock,
    this.minimumOrderQuantity,
    this.supplierPackSize,
    this.supplierOrderUnit,
    this.unitConversionFactor,
    this.confirmedIncomingQuantity,
    this.incomingQuantityVerified = false,
    this.backorderQuantity,
    this.backorderQuantityVerified = false,
    this.supplierAvailability,
    required this.dataSource,
    required this.sourceCapturedAt,
    this.rationale,
  });

  final int? supplierLeadTimeDays;
  final int? reviewPeriodDays;
  final double? safetyStock;
  final double? minimumOrderQuantity;
  final double? supplierPackSize;
  final String? supplierOrderUnit;
  final double? unitConversionFactor;
  final double? confirmedIncomingQuantity;
  final bool incomingQuantityVerified;
  final double? backorderQuantity;
  final bool backorderQuantityVerified;
  final String? supplierAvailability;
  final String dataSource;
  final DateTime sourceCapturedAt;
  final String? rationale;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'supplier_lead_time_days': supplierLeadTimeDays,
    'review_period_days': reviewPeriodDays,
    'safety_stock': safetyStock,
    'minimum_order_quantity': minimumOrderQuantity,
    'supplier_pack_size': supplierPackSize,
    'supplier_order_unit': supplierOrderUnit,
    'unit_conversion_factor': unitConversionFactor,
    'confirmed_incoming_quantity': confirmedIncomingQuantity,
    'incoming_quantity_verified': incomingQuantityVerified,
    'backorder_quantity': backorderQuantity,
    'backorder_quantity_verified': backorderQuantityVerified,
    'supplier_availability': supplierAvailability,
    'data_source': dataSource,
    'source_captured_at': sourceCapturedAt.toUtc().toIso8601String(),
    'rationale': rationale,
  };
}

class ReplenishmentConfiguration {
  const ReplenishmentConfiguration({
    required this.configured,
    required this.productId,
    required this.locationId,
    required this.inventoryUnit,
    this.persistenceAvailable = true,
    this.supplierLeadTimeDays,
    this.reviewPeriodDays,
    this.safetyStock,
    this.minimumOrderQuantity,
    this.supplierPackSize,
    this.supplierOrderUnit,
    this.unitConversionFactor,
    this.confirmedIncomingQuantity,
    required this.incomingQuantityVerified,
    this.backorderQuantity,
    required this.backorderQuantityVerified,
    this.supplierAvailability,
    this.dataSource,
    this.sourceCapturedAt,
    this.rationale,
    this.updatedAt,
    this.updatedByProfileId,
    required this.manualEstimate,
  });

  final bool configured;
  final String productId;
  final String locationId;
  final String inventoryUnit;
  final bool persistenceAvailable;
  final int? supplierLeadTimeDays;
  final int? reviewPeriodDays;
  final double? safetyStock;
  final double? minimumOrderQuantity;
  final double? supplierPackSize;
  final String? supplierOrderUnit;
  final double? unitConversionFactor;
  final double? confirmedIncomingQuantity;
  final bool incomingQuantityVerified;
  final double? backorderQuantity;
  final bool backorderQuantityVerified;
  final String? supplierAvailability;
  final String? dataSource;
  final DateTime? sourceCapturedAt;
  final String? rationale;
  final DateTime? updatedAt;
  final String? updatedByProfileId;
  final bool manualEstimate;

  factory ReplenishmentConfiguration.fromJson(Map<String, dynamic> json) =>
      ReplenishmentConfiguration(
        configured: json['configured'] == true,
        productId: _text(json['product_id'], 'configuration product_id'),
        locationId: _text(json['location_id'], 'configuration location_id'),
        inventoryUnit: _text(
          json['inventory_unit'],
          'configuration inventory_unit',
        ),
        persistenceAvailable: json['persistence_available'] != false,
        supplierLeadTimeDays: (json['supplier_lead_time_days'] as num?)
            ?.toInt(),
        reviewPeriodDays: (json['review_period_days'] as num?)?.toInt(),
        safetyStock: _optionalNumber(json['safety_stock']),
        minimumOrderQuantity: _optionalNumber(json['minimum_order_quantity']),
        supplierPackSize: _optionalNumber(json['supplier_pack_size']),
        supplierOrderUnit: json['supplier_order_unit']?.toString(),
        unitConversionFactor: _optionalNumber(json['unit_conversion_factor']),
        confirmedIncomingQuantity: _optionalNumber(
          json['confirmed_incoming_quantity'],
        ),
        incomingQuantityVerified: json['incoming_quantity_verified'] == true,
        backorderQuantity: _optionalNumber(json['backorder_quantity']),
        backorderQuantityVerified: json['backorder_quantity_verified'] == true,
        supplierAvailability: json['supplier_availability']?.toString(),
        dataSource: json['data_source']?.toString(),
        sourceCapturedAt: _optionalTimestamp(json['source_captured_at']),
        rationale: json['rationale']?.toString(),
        updatedAt: _optionalTimestamp(json['updated_at']),
        updatedByProfileId: json['updated_by_profile_id']?.toString(),
        manualEstimate: json['manual_estimate'] == true,
      );
}

class ForecastAnalysis {
  const ForecastAnalysis({
    required this.schemaVersion,
    required this.dataAdapter,
    required this.synthetic,
    required this.authorizedLocationId,
    required this.product,
    required this.forecast,
    required this.preliminaryRestockingInsight,
    required this.recommendation,
  });

  final String schemaVersion;
  final String dataAdapter;
  final bool synthetic;
  final String authorizedLocationId;
  final ForecastProductSummary product;
  final ForecastSummary forecast;
  final PreliminaryRestockingInsight preliminaryRestockingInsight;
  final RecommendationSummary recommendation;

  factory ForecastAnalysis.fromJson(Map<String, dynamic> json) {
    final scope = _map(json['authorized_scope'], 'authorized_scope');
    return ForecastAnalysis(
      schemaVersion: _text(json['schema_version'], 'schema_version'),
      dataAdapter: _text(json['data_adapter'], 'data_adapter'),
      synthetic: json['synthetic'] == true,
      authorizedLocationId: _text(scope['location_id'], 'location_id'),
      product: ForecastProductSummary.fromJson(
        _map(json['product'], 'product'),
      ),
      forecast: ForecastSummary.fromJson(_map(json['forecast'], 'forecast')),
      preliminaryRestockingInsight: PreliminaryRestockingInsight.fromJson(
        _map(
          json['preliminary_restocking_insight'],
          'preliminary_restocking_insight',
        ),
      ),
      recommendation: RecommendationSummary.fromJson(
        _map(json['recommendation'], 'recommendation'),
      ),
    );
  }
}

class PreliminaryRestockingInsight {
  const PreliminaryRestockingInsight({
    required this.status,
    required this.planningHorizonDays,
    required this.inventoryUnit,
    required this.formula,
    required this.forecastModel,
    required this.forecastVersion,
    required this.usesExperimentalSeasonalForecast,
    required this.assumptions,
    required this.limitations,
    required this.requiresOwnerReview,
    required this.incomingAndBackordersTreatedAsZero,
    this.predictedDemand,
    this.availableInventory,
    this.suggestedRestockQuantity,
  });

  final String status;
  final int planningHorizonDays;
  final double? predictedDemand;
  final double? availableInventory;
  final double? suggestedRestockQuantity;
  final String inventoryUnit;
  final String formula;
  final String forecastModel;
  final String forecastVersion;
  final bool usesExperimentalSeasonalForecast;
  final List<String> assumptions;
  final List<String> limitations;
  final bool requiresOwnerReview;
  final bool incomingAndBackordersTreatedAsZero;

  factory PreliminaryRestockingInsight.fromJson(Map<String, dynamic> json) {
    final basis = _map(json['forecast_basis'], 'forecast_basis');
    return PreliminaryRestockingInsight(
      status: _text(json['status'], 'status'),
      planningHorizonDays: _integer(
        json['planning_horizon_days'],
        'planning_horizon_days',
      ),
      predictedDemand: _optionalNumber(json['predicted_demand']),
      availableInventory: _optionalNumber(json['available_inventory']),
      suggestedRestockQuantity: _optionalNumber(
        json['suggested_restock_quantity'],
      ),
      inventoryUnit: _text(json['inventory_unit'], 'inventory_unit'),
      formula: _text(json['formula'], 'formula'),
      forecastModel: _text(basis['model'], 'forecast_basis.model'),
      forecastVersion: _text(basis['version'], 'forecast_basis.version'),
      usesExperimentalSeasonalForecast:
          basis['uses_experimental_seasonal_forecast'] == true,
      assumptions: _strings(json['assumptions']),
      limitations: _strings(json['limitations']),
      requiresOwnerReview: json['requires_owner_review'] == true,
      incomingAndBackordersTreatedAsZero:
          json['incoming_and_backorders_treated_as_zero'] == true,
    );
  }
}

class ForecastProductSummary {
  const ForecastProductSummary({
    required this.productId,
    required this.locationId,
    required this.name,
    required this.unit,
    this.sku,
  });

  final String productId;
  final String locationId;
  final String name;
  final String unit;
  final String? sku;

  factory ForecastProductSummary.fromJson(Map<String, dynamic> json) =>
      ForecastProductSummary(
        productId: _text(json['product_id'], 'product_id'),
        locationId: _text(json['location_id'], 'location_id'),
        name: _text(json['name'], 'name'),
        unit: _text(json['unit'], 'unit'),
        sku: json['sku']?.toString(),
      );
}

class ForecastSummary {
  const ForecastSummary({
    required this.requestedModel,
    required this.model,
    required this.version,
    required this.provenance,
    required this.generatedAt,
    required this.sourceDataAsOf,
    required this.periodStart,
    required this.periodEnd,
    required this.horizonDays,
    required this.unit,
    required this.totalQuantity,
    required this.daily,
    required this.isColdStart,
    required this.zeroIsUnknownDemand,
    required this.warnings,
    required this.isExperimental,
    this.coldStartReason,
    this.coldStartStrategy,
    this.experimentalFallbackReason,
    this.seasonalContext,
  });

  final String requestedModel;
  final String model;
  final String version;
  final String provenance;
  final DateTime generatedAt;
  final DateTime sourceDataAsOf;
  final String periodStart;
  final String periodEnd;
  final int horizonDays;
  final String unit;
  final double totalQuantity;
  final List<ForecastDailyPoint> daily;
  final bool isColdStart;
  final bool zeroIsUnknownDemand;
  final String? coldStartReason;
  final String? coldStartStrategy;
  final List<String> warnings;
  final bool isExperimental;
  final String? experimentalFallbackReason;
  final SeasonalForecastContext? seasonalContext;

  double quantityForDays(int days) => daily
      .take(days)
      .fold<double>(0, (total, point) => total + point.quantity);

  factory ForecastSummary.fromJson(Map<String, dynamic> json) {
    final cold = _map(json['cold_start'], 'cold_start');
    final quality = _map(json['data_quality'], 'data_quality');
    final fallback = json['fallback'] is Map
        ? Map<String, dynamic>.from(json['fallback'] as Map)
        : const <String, dynamic>{};
    return ForecastSummary(
      requestedModel:
          json['requested_model']?.toString() ?? _text(json['model'], 'model'),
      model: _text(json['model'], 'model'),
      version: _text(json['version'], 'version'),
      provenance: _text(json['provenance'], 'provenance'),
      generatedAt: DateTime.parse(_text(json['generated_at'], 'generated_at')),
      sourceDataAsOf: DateTime.parse(
        _text(json['source_data_as_of'], 'source_data_as_of'),
      ),
      periodStart: _text(json['period_start'], 'period_start'),
      periodEnd: _text(json['period_end'], 'period_end'),
      horizonDays: _integer(json['horizon_days'], 'horizon_days'),
      unit: _text(json['unit'], 'unit'),
      totalQuantity: _number(json['total_quantity'], 'total_quantity'),
      daily: (json['daily'] as List? ?? const <Object>[])
          .map(
            (value) => ForecastDailyPoint.fromJson(
              _map(value, 'forecast daily point'),
            ),
          )
          .toList(growable: false),
      isColdStart: cold['is_cold_start'] == true,
      zeroIsUnknownDemand: cold['zero_is_unknown_demand'] == true,
      coldStartReason: cold['reason']?.toString(),
      coldStartStrategy: cold['strategy']?.toString(),
      warnings: _strings(quality['warnings']),
      isExperimental: json['experimental'] == true,
      experimentalFallbackReason: fallback['reason']?.toString(),
      seasonalContext: json['seasonal_context'] is Map
          ? SeasonalForecastContext.fromJson(
              Map<String, dynamic>.from(json['seasonal_context'] as Map),
            )
          : null,
    );
  }
}

class ForecastDailyPoint {
  const ForecastDailyPoint({
    required this.date,
    required this.quantity,
    this.season,
    this.transition,
  });

  final DateTime date;
  final double quantity;
  final String? season;
  final String? transition;

  factory ForecastDailyPoint.fromJson(Map<String, dynamic> json) =>
      ForecastDailyPoint(
        date: DateTime.parse(_text(json['date'], 'forecast date')),
        quantity: _number(json['quantity'], 'forecast quantity'),
        season: json['season']?.toString(),
        transition: json['transition']?.toString(),
      );
}

class SeasonalForecastContext {
  const SeasonalForecastContext({
    required this.calendarVersion,
    required this.sourceName,
    required this.sourceUrl,
    required this.seasonalRelevance,
    required this.matchType,
    required this.evidenceLevel,
    required this.numericalMultiplierApplied,
    this.nextTransitionDate,
    this.nextTransition,
  });

  final String calendarVersion;
  final String sourceName;
  final String sourceUrl;
  final String seasonalRelevance;
  final String matchType;
  final String evidenceLevel;
  final bool numericalMultiplierApplied;
  final DateTime? nextTransitionDate;
  final String? nextTransition;

  factory SeasonalForecastContext.fromJson(Map<String, dynamic> json) {
    final classification = json['classification'] is Map
        ? Map<String, dynamic>.from(json['classification'] as Map)
        : const <String, dynamic>{};
    final transition = json['next_transition'] is Map
        ? Map<String, dynamic>.from(json['next_transition'] as Map)
        : const <String, dynamic>{};
    final transitionDate = transition['date']?.toString();
    return SeasonalForecastContext(
      calendarVersion: json['calendar_version']?.toString() ?? 'unknown',
      sourceName: json['source_name']?.toString() ?? 'unknown',
      sourceUrl: json['source_url']?.toString() ?? '',
      seasonalRelevance:
          classification['seasonal_relevance']?.toString() ?? 'unknown',
      matchType: classification['match_type']?.toString() ?? 'unavailable',
      evidenceLevel:
          classification['evidence_level']?.toString() ?? 'insufficient',
      numericalMultiplierApplied: json['numerical_multiplier_applied'] == true,
      nextTransitionDate: transitionDate == null
          ? null
          : DateTime.tryParse(transitionDate),
      nextTransition: transition['transition']?.toString(),
    );
  }
}

class RecommendationSummary {
  const RecommendationSummary({
    required this.status,
    required this.policyType,
    required this.policyVersion,
    required this.policyMessage,
    required this.humanApprovalRequired,
    required this.approvedPurchaseDecision,
    required this.purchaseOrderCreated,
    required this.warnings,
    required this.explanations,
    this.manualDemandEstimate,
    this.inventoryPosition,
    this.currentInventory,
    this.reorderPoint,
    this.safetyStock,
    this.protectionPeriodDays,
    this.targetInventory,
    this.suggestedInventoryQuantity,
    this.inventoryUnit,
    this.suggestedOrderQuantity,
    this.orderUnit,
  });

  final String status;
  final String policyType;
  final String policyVersion;
  final String policyMessage;
  final double? inventoryPosition;
  final double? currentInventory;
  final double? reorderPoint;
  final double? safetyStock;
  final int? protectionPeriodDays;
  final double? targetInventory;
  final double? suggestedInventoryQuantity;
  final String? inventoryUnit;
  final double? suggestedOrderQuantity;
  final String? orderUnit;
  final bool humanApprovalRequired;
  final bool approvedPurchaseDecision;
  final bool purchaseOrderCreated;
  final List<String> warnings;
  final List<String> explanations;
  final ManualDemandEstimateSummary? manualDemandEstimate;

  factory RecommendationSummary.fromJson(Map<String, dynamic> json) {
    final alert = _map(json['reorder_alert'], 'reorder_alert');
    final quantity = _map(json['suggested_quantity'], 'suggested_quantity');
    final inventory = json['inventory_snapshot'] is Map
        ? Map<String, dynamic>.from(json['inventory_snapshot'] as Map)
        : const <String, dynamic>{};
    return RecommendationSummary(
      status: _text(json['status'], 'status'),
      policyType: _text(json['policy_type'], 'policy_type'),
      policyVersion: _text(json['policy_version'], 'policy_version'),
      policyMessage: _text(alert['message'], 'reorder_alert.message'),
      inventoryPosition: _optionalNumber(json['inventory_position']),
      currentInventory: _optionalNumber(inventory['saleable_on_hand']),
      reorderPoint: _optionalNumber(json['reorder_point']),
      safetyStock: _optionalNumber(json['safety_stock']),
      protectionPeriodDays: (json['protection_period_days'] as num?)?.toInt(),
      targetInventory: _optionalNumber(json['target_inventory']),
      suggestedInventoryQuantity: _optionalNumber(quantity['inventory_units']),
      inventoryUnit: quantity['inventory_unit']?.toString(),
      suggestedOrderQuantity: _optionalNumber(quantity['order_units']),
      orderUnit: quantity['order_unit']?.toString(),
      humanApprovalRequired: json['human_approval_required'] == true,
      approvedPurchaseDecision: json['approved_purchase_decision'] == true,
      purchaseOrderCreated: json['purchase_order_created'] == true,
      warnings: _strings(json['warnings']),
      explanations: _strings(json['explanations']),
      manualDemandEstimate: json['manual_demand_estimate'] == null
          ? null
          : ManualDemandEstimateSummary.fromJson(
              _map(json['manual_demand_estimate'], 'manual_demand_estimate'),
            ),
    );
  }
}

class ManualDemandEstimateSummary {
  const ManualDemandEstimateSummary({
    required this.dailyQuantity,
    required this.unit,
    required this.rationale,
    required this.source,
    required this.staffConfirmed,
    required this.confirmedByProfileId,
    required this.confirmedAt,
    required this.provisional,
    required this.createsHistoricalSales,
  });

  final double dailyQuantity;
  final String unit;
  final String rationale;
  final String source;
  final bool staffConfirmed;
  final String confirmedByProfileId;
  final DateTime confirmedAt;
  final bool provisional;
  final bool createsHistoricalSales;

  factory ManualDemandEstimateSummary.fromJson(Map<String, dynamic> json) =>
      ManualDemandEstimateSummary(
        dailyQuantity: _number(json['daily_quantity'], 'daily_quantity'),
        unit: _text(json['unit'], 'manual unit'),
        rationale: _text(json['rationale'], 'manual rationale'),
        source: _text(json['source'], 'manual source'),
        staffConfirmed: json['staff_confirmed'] == true,
        confirmedByProfileId: _text(
          json['confirmed_by_profile_id'],
          'confirmed_by_profile_id',
        ),
        confirmedAt: DateTime.parse(
          _text(json['confirmed_at'], 'manual confirmed_at'),
        ),
        provisional: json['provisional'] == true,
        createsHistoricalSales: json['creates_historical_sales'] == true,
      );
}

class RecommendationSnapshotSaveResult {
  const RecommendationSnapshotSaveResult({
    required this.recommendationId,
    required this.requestId,
    required this.reused,
  });

  final int recommendationId;
  final String requestId;
  final bool reused;

  factory RecommendationSnapshotSaveResult.fromJson(
    Map<String, dynamic> json,
  ) => RecommendationSnapshotSaveResult(
    recommendationId: _integer(json['recommendation_id'], 'recommendation_id'),
    requestId: _text(json['request_id'], 'request_id'),
    reused: json['reused'] == true,
  );
}

class RecommendationTrackingItem {
  const RecommendationTrackingItem({
    required this.recommendationId,
    required this.productId,
    required this.productName,
    required this.productSku,
    required this.inventoryUnit,
    required this.recommendationDate,
    required this.forecastPeriodStart,
    required this.forecastPeriodEnd,
    required this.predictedDemand,
    required this.availableInventory,
    required this.suggestedQuantity,
    required this.evaluationStatus,
    required this.matchedReceivedQuantity,
    required this.receiptCount,
    required this.forecastModel,
    required this.forecastVersion,
    required this.trainingHistoryDays,
    required this.assumptions,
    this.signedQuantityDifference,
    this.absoluteDifference,
    this.percentageVariance,
    this.firstReceiptDate,
    this.lastReceiptDate,
    this.reconciledAt,
  });

  final int recommendationId;
  final String productId;
  final String productName;
  final String productSku;
  final String inventoryUnit;
  final DateTime recommendationDate;
  final String forecastPeriodStart;
  final String forecastPeriodEnd;
  final double predictedDemand;
  final double availableInventory;
  final double suggestedQuantity;
  final String evaluationStatus;
  final double? matchedReceivedQuantity;
  final double? signedQuantityDifference;
  final double? absoluteDifference;
  final double? percentageVariance;
  final DateTime? firstReceiptDate;
  final DateTime? lastReceiptDate;
  final int receiptCount;
  final DateTime? reconciledAt;
  final String forecastModel;
  final String forecastVersion;
  final int trainingHistoryDays;
  final List<String> assumptions;

  bool get isReconciled => evaluationStatus.toLowerCase() == 'reconciled';

  factory RecommendationTrackingItem.fromJson(
    Map<String, dynamic> json,
  ) => RecommendationTrackingItem(
    recommendationId: _integer(json['recommendation_id'], 'recommendation_id'),
    productId: _text(json['product_id_snapshot'], 'product_id_snapshot'),
    productName: _text(json['product_name_snapshot'], 'product_name_snapshot'),
    productSku: _text(json['product_sku_snapshot'], 'product_sku_snapshot'),
    inventoryUnit: _text(json['inventory_unit'], 'inventory_unit'),
    recommendationDate: DateTime.parse(
      _text(json['recommendation_date'], 'recommendation_date'),
    ),
    forecastPeriodStart: _text(
      json['forecast_period_start'],
      'forecast_period_start',
    ),
    forecastPeriodEnd: _text(
      json['forecast_period_end'],
      'forecast_period_end',
    ),
    predictedDemand: _number(json['predicted_demand'], 'predicted_demand'),
    availableInventory: _number(
      json['available_inventory'],
      'available_inventory',
    ),
    suggestedQuantity: _number(
      json['suggested_quantity'],
      'suggested_quantity',
    ),
    evaluationStatus: _text(json['evaluation_status'], 'evaluation_status'),
    matchedReceivedQuantity: _optionalNumber(json['matched_received_quantity']),
    signedQuantityDifference: _optionalNumber(
      json['signed_quantity_difference'],
    ),
    absoluteDifference: _optionalNumber(json['absolute_difference']),
    percentageVariance: _optionalNumber(json['percentage_variance']),
    firstReceiptDate: _optionalTimestamp(json['first_receipt_date']),
    lastReceiptDate: _optionalTimestamp(json['last_receipt_date']),
    receiptCount: _integer(json['receipt_count'] ?? 0, 'receipt_count'),
    reconciledAt: _optionalTimestamp(json['reconciled_at']),
    forecastModel: _text(json['forecast_model'], 'forecast_model'),
    forecastVersion: _text(json['forecast_version'], 'forecast_version'),
    trainingHistoryDays: _integer(
      json['training_history_days'],
      'training_history_days',
    ),
    assumptions: _strings(json['assumptions']),
  );
}

class ForecastPerformanceReport {
  const ForecastPerformanceReport({
    required this.businessTimezone,
    required this.dataSourceAvailable,
    required this.items,
    required this.summariesByUnit,
    required this.limitations,
    this.dataSourceWarning,
  });

  final String businessTimezone;
  final bool dataSourceAvailable;
  final String? dataSourceWarning;
  final List<ForecastPerformanceItem> items;
  final List<ForecastPerformanceSummary> summariesByUnit;
  final List<String> limitations;

  factory ForecastPerformanceReport.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    final summaries = json['summaries_by_unit'];
    if (items is! List || summaries is! List) {
      throw const FormatException('forecast performance lists are invalid');
    }
    return ForecastPerformanceReport(
      businessTimezone: _text(json['business_timezone'], 'business_timezone'),
      dataSourceAvailable: json['data_source_available'] == true,
      dataSourceWarning: json['data_source_warning']?.toString(),
      items: items
          .map(
            (value) => ForecastPerformanceItem.fromJson(
              _map(value, 'forecast performance item'),
            ),
          )
          .toList(growable: false),
      summariesByUnit: summaries
          .map(
            (value) => ForecastPerformanceSummary.fromJson(
              _map(value, 'forecast performance summary'),
            ),
          )
          .toList(growable: false),
      limitations: _strings(json['limitations']),
    );
  }
}

class ForecastPerformanceItem {
  const ForecastPerformanceItem({
    required this.recommendationId,
    required this.locationId,
    required this.productId,
    required this.productName,
    required this.productSku,
    required this.inventoryUnit,
    required this.recommendationDate,
    required this.forecastPeriodStart,
    required this.forecastPeriodEnd,
    required this.predictedDemand,
    required this.forecastModel,
    required this.forecastVersion,
    required this.trainingHistoryDays,
    required this.evaluationStatus,
    required this.statusExplanation,
    required this.evaluable,
    required this.syntheticSales,
    required this.salesProvenance,
    required this.stockAvailabilityKnown,
    this.actualCompletedSales,
    this.signedForecastError,
    this.absoluteError,
    this.percentageError,
    this.errorDirection,
  });

  final int recommendationId;
  final String locationId;
  final String productId;
  final String productName;
  final String productSku;
  final String inventoryUnit;
  final DateTime recommendationDate;
  final String forecastPeriodStart;
  final String forecastPeriodEnd;
  final double predictedDemand;
  final String forecastModel;
  final String forecastVersion;
  final int trainingHistoryDays;
  final String evaluationStatus;
  final String statusExplanation;
  final bool evaluable;
  final double? actualCompletedSales;
  final double? signedForecastError;
  final double? absoluteError;
  final double? percentageError;
  final String? errorDirection;
  final bool syntheticSales;
  final String salesProvenance;
  final bool stockAvailabilityKnown;

  factory ForecastPerformanceItem.fromJson(
    Map<String, dynamic> json,
  ) => ForecastPerformanceItem(
    recommendationId: _integer(json['recommendation_id'], 'recommendation_id'),
    locationId: _text(json['location_id'], 'location_id'),
    productId: _text(json['product_id'], 'product_id'),
    productName: _text(json['product_name'], 'product_name'),
    productSku: _text(json['product_sku'], 'product_sku'),
    inventoryUnit: _text(json['inventory_unit'], 'inventory_unit'),
    recommendationDate: DateTime.parse(
      _text(json['recommendation_date'], 'recommendation_date'),
    ),
    forecastPeriodStart: _text(
      json['forecast_period_start'],
      'forecast_period_start',
    ),
    forecastPeriodEnd: _text(
      json['forecast_period_end'],
      'forecast_period_end',
    ),
    predictedDemand: _number(json['predicted_demand'], 'predicted_demand'),
    forecastModel: _text(json['forecast_model'], 'forecast_model'),
    forecastVersion: _text(json['forecast_version'], 'forecast_version'),
    trainingHistoryDays: _integer(
      json['training_history_days'],
      'training_history_days',
    ),
    evaluationStatus: _text(json['evaluation_status'], 'evaluation_status'),
    statusExplanation: _text(json['status_explanation'], 'status_explanation'),
    evaluable: json['evaluable'] == true,
    actualCompletedSales: _optionalNumber(json['actual_completed_sales']),
    signedForecastError: _optionalNumber(json['signed_forecast_error']),
    absoluteError: _optionalNumber(json['absolute_error']),
    percentageError: _optionalNumber(json['percentage_error']),
    errorDirection: json['error_direction']?.toString(),
    syntheticSales: json['synthetic_sales'] == true,
    salesProvenance: _text(json['sales_provenance'], 'sales_provenance'),
    stockAvailabilityKnown: json['stock_availability_known'] == true,
  );
}

class ForecastPerformanceSummary {
  const ForecastPerformanceSummary({
    required this.inventoryUnit,
    required this.evaluationCount,
    required this.zeroActualCount,
    required this.predictedTotal,
    required this.actualTotal,
    required this.absoluteErrorTotal,
    required this.signedErrorTotal,
    this.wape,
    this.forecastBias,
  });

  final String inventoryUnit;
  final int evaluationCount;
  final int zeroActualCount;
  final double predictedTotal;
  final double actualTotal;
  final double absoluteErrorTotal;
  final double signedErrorTotal;
  final double? wape;
  final double? forecastBias;

  factory ForecastPerformanceSummary.fromJson(
    Map<String, dynamic> json,
  ) => ForecastPerformanceSummary(
    inventoryUnit: _text(json['inventory_unit'], 'inventory_unit'),
    evaluationCount: _integer(json['evaluation_count'], 'evaluation_count'),
    zeroActualCount: _integer(json['zero_actual_count'], 'zero_actual_count'),
    predictedTotal: _number(json['predicted_total'], 'predicted_total'),
    actualTotal: _number(json['actual_total'], 'actual_total'),
    absoluteErrorTotal: _number(
      json['absolute_error_total'],
      'absolute_error_total',
    ),
    signedErrorTotal: _number(json['signed_error_total'], 'signed_error_total'),
    wape: _optionalNumber(json['wape']),
    forecastBias: _optionalNumber(json['forecast_bias']),
  );
}

class ReceiptAllocationResult {
  const ReceiptAllocationResult({required this.reused});

  final bool reused;

  factory ReceiptAllocationResult.fromJson(Map<String, dynamic> json) =>
      ReceiptAllocationResult(reused: json['reused'] == true);
}

class RecommendationReconciliationResult {
  const RecommendationReconciliationResult({required this.reused});

  final bool reused;

  factory RecommendationReconciliationResult.fromJson(
    Map<String, dynamic> json,
  ) => RecommendationReconciliationResult(reused: json['reused'] == true);
}

Map<String, dynamic> _map(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException('$field must be an object');
}

String _text(Object? value, String field) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException('$field is required');
  return text;
}

double _number(Object? value, String field) {
  final parsed = _optionalNumber(value);
  if (parsed == null || !parsed.isFinite) {
    throw FormatException('$field must be numeric');
  }
  return parsed;
}

double? _optionalNumber(Object? value) {
  if (value == null) return null;
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value.toString());
  if (parsed == null || !parsed.isFinite) {
    throw const FormatException('optional numeric field must be finite');
  }
  return parsed;
}

DateTime? _optionalTimestamp(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : DateTime.parse(text);
}

int _integer(Object? value, String field) {
  final parsed = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  if (parsed == null) throw FormatException('$field must be an integer');
  return parsed;
}

List<String> _strings(Object? value) => value is List
    ? value.map((entry) => entry.toString()).toList(growable: false)
    : const <String>[];
