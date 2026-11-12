class SeasonalLearningLabReport {
  const SeasonalLearningLabReport({
    required this.schemaVersion,
    required this.available,
    required this.complete,
    required this.readOnly,
    required this.warnings,
    required this.artifacts,
    required this.stage26Decision,
    required this.stage26DatabaseVerification,
    required this.historyStart,
    required this.historyEnd,
    required this.accuracyMetrics,
    required this.replay,
    required this.forecastActual,
    required this.stage27Decision,
    required this.stage27bDecision,
    required this.selectedPolicy,
    required this.genuinelyBetterThanBaseline,
    required this.conclusion,
    required this.classificationModels,
    required this.chronology,
    required this.products,
    required this.selectedProductId,
    required this.provenanceGuide,
    required this.leakageCheck,
  });

  final String schemaVersion;
  final bool available;
  final bool complete;
  final bool readOnly;
  final List<String> warnings;
  final List<ResearchArtifactStatus> artifacts;
  final String stage26Decision;
  final String stage26DatabaseVerification;
  final String? historyStart;
  final String? historyEnd;
  final List<HistoricalAccuracyMetric> accuracyMetrics;
  final List<HistoricalReplayPoint> replay;
  final List<ForecastActualPoint> forecastActual;
  final String stage27Decision;
  final String stage27bDecision;
  final String selectedPolicy;
  final bool genuinelyBetterThanBaseline;
  final String conclusion;
  final Map<String, ClassificationModelSummary> classificationModels;
  final List<ChronologicalLearningMetric> chronology;
  final List<SeasonalLearningProduct> products;
  final String? selectedProductId;
  final Map<String, String> provenanceGuide;
  final String leakageCheck;

  SeasonalLearningProduct? get selectedProduct {
    for (final product in products) {
      if (product.productId == selectedProductId) return product;
    }
    return products.isEmpty ? null : products.first;
  }

  factory SeasonalLearningLabReport.fromJson(Map<String, dynamic> json) {
    final stage26 = _objectOrEmpty(json['stage26']);
    final stage27 = _objectOrEmpty(json['stage27']);
    final stage27b = _objectOrEmpty(json['stage27b']);
    final forecastActual = _objectOrEmpty(json['forecast_vs_actual']);
    final replay = _objectOrEmpty(stage26['replay']);
    final comparison = _objectOrEmpty(stage27b['final_comparison']);
    return SeasonalLearningLabReport(
      schemaVersion: _requiredText(json['schema_version'], 'schema_version'),
      available: json['available'] == true,
      complete: json['complete'] == true,
      readOnly: json['read_only'] == true,
      warnings: _strings(json['warnings']),
      artifacts: _objects(
        json['artifacts'],
      ).map(ResearchArtifactStatus.fromJson).toList(growable: false),
      stage26Decision: stage26['decision']?.toString() ?? 'UNAVAILABLE',
      stage26DatabaseVerification:
          stage26['database_verification']?.toString() ?? 'NOT_AVAILABLE',
      historyStart: stage26['history_start']?.toString(),
      historyEnd: stage26['history_end']?.toString(),
      accuracyMetrics: _objects(
        stage26['metrics'],
      ).map(HistoricalAccuracyMetric.fromJson).toList(growable: false),
      replay: _objects(
        replay['rows'],
      ).map(HistoricalReplayPoint.fromJson).toList(growable: false),
      forecastActual: _objects(
        forecastActual['points'],
      ).map(ForecastActualPoint.fromJson).toList(growable: false),
      stage27Decision: stage27['decision']?.toString() ?? 'UNAVAILABLE',
      stage27bDecision: stage27b['decision']?.toString() ?? 'UNAVAILABLE',
      selectedPolicy: stage27b['selected_policy']?.toString() ?? 'unavailable',
      genuinelyBetterThanBaseline:
          stage27b['genuinely_better_than_baseline'] == true,
      conclusion: stage27b['conclusion']?.toString() ?? '',
      classificationModels: comparison.map(
        (key, value) => MapEntry(
          key,
          ClassificationModelSummary.fromJson(_object(value, key)),
        ),
      ),
      chronology: _objects(
        stage27b['chronological_comparison'],
      ).map(ChronologicalLearningMetric.fromJson).toList(growable: false),
      products: _objects(
        json['products'],
      ).map(SeasonalLearningProduct.fromJson).toList(growable: false),
      selectedProductId: json['selected_product_id']?.toString(),
      provenanceGuide: _objectOrEmpty(
        json['provenance_guide'],
      ).map((key, value) => MapEntry(key, value.toString())),
      leakageCheck:
          forecastActual['leakage_check']?.toString() ?? 'NOT_AVAILABLE',
    );
  }
}

class ResearchArtifactStatus {
  const ResearchArtifactStatus({
    required this.stage,
    required this.status,
    required this.stale,
    this.modifiedAt,
  });

  final String stage;
  final String status;
  final bool stale;
  final DateTime? modifiedAt;

  factory ResearchArtifactStatus.fromJson(Map<String, dynamic> json) =>
      ResearchArtifactStatus(
        stage: _requiredText(json['stage'], 'artifact stage'),
        status: _requiredText(json['status'], 'artifact status'),
        stale: json['stale'] == true,
        modifiedAt: DateTime.tryParse(json['modified_at']?.toString() ?? ''),
      );
}

class HistoricalAccuracyMetric {
  const HistoricalAccuracyMetric({
    required this.horizonDays,
    required this.model,
    required this.mae,
    required this.wape,
    required this.bias,
    required this.actualTotal,
    required this.predictedTotal,
  });

  final int horizonDays;
  final String model;
  final double mae;
  final double wape;
  final double bias;
  final double actualTotal;
  final double predictedTotal;

  factory HistoricalAccuracyMetric.fromJson(Map<String, dynamic> json) =>
      HistoricalAccuracyMetric(
        horizonDays: _integer(json['horizon_days'], 'horizon_days'),
        model: _requiredText(json['model'], 'model'),
        mae: _number(json['mae'], 'mae'),
        wape: _number(json['wape'], 'wape'),
        bias: _number(json['bias'], 'bias'),
        actualTotal: _number(json['actual_total'], 'actual_total'),
        predictedTotal: _number(json['predicted_total'], 'predicted_total'),
      );
}

class HistoricalReplayPoint {
  const HistoricalReplayPoint({
    required this.sku,
    required this.productName,
    required this.seasonalGroup,
    required this.period,
    required this.origin,
    required this.forecastTotal,
    required this.actualTotal,
    required this.signedError,
    required this.absoluteError,
  });

  final String sku;
  final String productName;
  final String seasonalGroup;
  final int period;
  final DateTime origin;
  final double forecastTotal;
  final double actualTotal;
  final double signedError;
  final double absoluteError;

  factory HistoricalReplayPoint.fromJson(Map<String, dynamic> json) =>
      HistoricalReplayPoint(
        sku: _requiredText(json['sku'], 'replay sku'),
        productName: _requiredText(json['product_name'], 'replay product_name'),
        seasonalGroup: _requiredText(
          json['seasonal_group'],
          'replay seasonal_group',
        ),
        period: _integer(json['period'], 'replay period'),
        origin: DateTime.parse(_requiredText(json['origin'], 'replay origin')),
        forecastTotal: _number(json['forecast_total'], 'forecast_total'),
        actualTotal: _number(json['actual_total'], 'actual_total'),
        signedError: _number(json['signed_error'], 'signed_error'),
        absoluteError: _number(json['absolute_error'], 'absolute_error'),
      );
}

class ForecastActualPoint {
  const ForecastActualPoint({
    required this.origin,
    required this.forecastDate,
    required this.model,
    required this.actual,
    required this.predicted,
    required this.signedError,
    required this.unit,
  });

  final DateTime origin;
  final DateTime forecastDate;
  final String model;
  final double actual;
  final double predicted;
  final double signedError;
  final String unit;

  factory ForecastActualPoint.fromJson(Map<String, dynamic> json) =>
      ForecastActualPoint(
        origin: DateTime.parse(_requiredText(json['origin'], 'origin')),
        forecastDate: DateTime.parse(
          _requiredText(json['forecast_date'], 'forecast_date'),
        ),
        model: _requiredText(json['model'], 'model'),
        actual: _number(json['actual'], 'actual'),
        predicted: _number(json['predicted'], 'predicted'),
        signedError: _number(json['signed_error'], 'signed_error'),
        unit: _requiredText(json['unit'], 'unit'),
      );
}

class ClassificationModelSummary {
  const ClassificationModelSummary({
    required this.accuracy,
    required this.coverage,
    required this.coveredAccuracy,
    required this.unknownRate,
    required this.seasonalPrecision,
    required this.falseSeasonalAssignments,
    required this.holdoutTested,
    required this.holdoutConfirmed,
    required this.holdoutConfirmationRate,
  });

  final double accuracy;
  final double coverage;
  final double? coveredAccuracy;
  final double unknownRate;
  final double? seasonalPrecision;
  final int falseSeasonalAssignments;
  final int holdoutTested;
  final int holdoutConfirmed;
  final double? holdoutConfirmationRate;

  factory ClassificationModelSummary.fromJson(Map<String, dynamic> json) {
    final metrics = _object(json['classification_metrics'], 'metrics');
    final holdout = _object(json['fourth_year_confirmation'], 'holdout');
    return ClassificationModelSummary(
      accuracy: _number(metrics['accuracy'], 'accuracy'),
      coverage: _number(metrics['coverage'], 'coverage'),
      coveredAccuracy: _optionalNumber(metrics['covered_accuracy']),
      unknownRate: _number(metrics['unknown_rate'], 'unknown_rate'),
      seasonalPrecision: _optionalNumber(metrics['seasonal_precision']),
      falseSeasonalAssignments: _integer(
        metrics['false_seasonal_assignments'],
        'false_seasonal_assignments',
      ),
      holdoutTested: _integer(
        holdout['tested_seasonal_classifications'],
        'holdout tested',
      ),
      holdoutConfirmed: _integer(holdout['confirmed'], 'holdout confirmed'),
      holdoutConfirmationRate: _optionalNumber(holdout['confirmation_rate']),
    );
  }
}

class ChronologicalLearningMetric {
  const ChronologicalLearningMetric({
    required this.windowMonths,
    required this.model,
    required this.accuracy,
    required this.coverage,
    required this.coveredAccuracy,
    required this.unknownRate,
    required this.seasonalPrecision,
    required this.falseSeasonalAssignments,
  });

  final int windowMonths;
  final String model;
  final double accuracy;
  final double coverage;
  final double? coveredAccuracy;
  final double unknownRate;
  final double? seasonalPrecision;
  final int falseSeasonalAssignments;

  factory ChronologicalLearningMetric.fromJson(Map<String, dynamic> json) =>
      ChronologicalLearningMetric(
        windowMonths: _integer(json['window_months'], 'window_months'),
        model: _requiredText(json['model'], 'chronology model'),
        accuracy: _number(json['accuracy'], 'chronology accuracy'),
        coverage: _number(json['coverage'], 'chronology coverage'),
        coveredAccuracy: _optionalNumber(json['covered_accuracy']),
        unknownRate: _number(json['unknown_rate'], 'unknown_rate'),
        seasonalPrecision: _optionalNumber(json['seasonal_precision']),
        falseSeasonalAssignments: _integer(
          json['false_seasonal_assignments'],
          'false_seasonal_assignments',
        ),
      );
}

class SeasonalLearningProduct {
  const SeasonalLearningProduct({
    required this.productId,
    required this.sku,
    required this.productName,
    required this.isSimulation,
    required this.frozenSimulationLabel,
    required this.originalDiscovered,
    required this.baselineDiscovered,
    required this.refinedDiscovered,
  });

  final String productId;
  final String sku;
  final String productName;
  final bool isSimulation;
  final String frozenSimulationLabel;
  final String originalDiscovered;
  final String baselineDiscovered;
  final String refinedDiscovered;

  factory SeasonalLearningProduct.fromJson(Map<String, dynamic> json) =>
      SeasonalLearningProduct(
        productId: _requiredText(json['product_id'], 'product_id'),
        sku: _requiredText(json['sku'], 'sku'),
        productName: _requiredText(json['product_name'], 'product_name'),
        isSimulation: json['is_simulation'] == true,
        frozenSimulationLabel: _requiredText(
          json['frozen_simulation_label'],
          'frozen_simulation_label',
        ),
        originalDiscovered: _requiredText(
          json['original_discovered'],
          'original_discovered',
        ),
        baselineDiscovered: _requiredText(
          json['baseline_discovered'],
          'baseline_discovered',
        ),
        refinedDiscovered: _requiredText(
          json['refined_discovered'],
          'refined_discovered',
        ),
      );
}

Map<String, dynamic> _object(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException('$field must be an object');
}

Map<String, dynamic> _objectOrEmpty(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<Map<String, dynamic>> _objects(Object? value) => value is List
    ? value.map((item) => _object(item, 'list item')).toList(growable: false)
    : const <Map<String, dynamic>>[];

String _requiredText(Object? value, String field) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException('$field is required');
  return text;
}

double _number(Object? value, String field) {
  final result = _optionalNumber(value);
  if (result == null || !result.isFinite) {
    throw FormatException('$field must be numeric');
  }
  return result;
}

double? _optionalNumber(Object? value) {
  if (value == null || value.toString().trim().isEmpty) return null;
  final result = value is num
      ? value.toDouble()
      : double.tryParse(value.toString());
  if (result == null || !result.isFinite) {
    throw const FormatException('optional value must be numeric');
  }
  return result;
}

int _integer(Object? value, String field) {
  final result = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  if (result == null) throw FormatException('$field must be an integer');
  return result;
}

List<String> _strings(Object? value) => value is List
    ? value.map((item) => item.toString()).toList(growable: false)
    : const <String>[];
