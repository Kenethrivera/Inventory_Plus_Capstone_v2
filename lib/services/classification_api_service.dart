import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'forecasting_api_service.dart';

enum HardwareClassificationEngine {
  existing('existing', 'Existing Classifier'),
  gemini('gemini', 'Gemini AI');

  const HardwareClassificationEngine(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

abstract interface class HardwareClassificationService {
  Future<HardwareClassification> classify({
    required String productName,
    required String category,
    required String description,
    required String sessionToken,
    required HardwareClassificationEngine engine,
  });
}

class HardwareClassificationApiClient implements HardwareClassificationService {
  HardwareClassificationApiClient({
    required Uri baseUri,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _baseUri = baseUri,
       _client = client ?? http.Client();

  factory HardwareClassificationApiClient.fromEnvironment({
    http.Client? client,
  }) {
    return HardwareClassificationApiClient(
      baseUri: ForecastApiClient.resolveConfiguredBaseUri(),
      client: client,
    );
  }

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<HardwareClassification> classify({
    required String productName,
    required String category,
    required String description,
    required String sessionToken,
    required HardwareClassificationEngine engine,
  }) async {
    final uri = _baseUri.resolve('/v1/classification');
    try {
      final response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $sessionToken',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, String>{
              'product_name': productName.trim(),
              'category': category.trim(),
              'description': description.trim(),
              'engine': engine.apiValue,
            }),
          )
          .timeout(timeout);
      final decoded = _decodeObject(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded?['detail']?.toString();
        throw ForecastApiException(
          detail?.isNotEmpty == true
              ? detail!
              : 'Classification request failed (${response.statusCode}).',
          statusCode: response.statusCode,
        );
      }
      final result = decoded?['result'];
      if (result is! Map) {
        throw const ForecastApiException(
          'Classification API returned invalid data.',
        );
      }
      return HardwareClassification.fromJson(Map<String, dynamic>.from(result));
    } on TimeoutException {
      throw const ForecastApiException(
        'Classification API timed out. Try again.',
        isTimeout: true,
      );
    } on SocketException {
      throw const ForecastApiException('Classification API is unreachable.');
    } on http.ClientException {
      throw const ForecastApiException('Classification API connection failed.');
    } on FormatException {
      throw const ForecastApiException(
        'Classification API returned invalid data.',
      );
    }
  }

  static Map<String, dynamic>? _decodeObject(String body) {
    final value = jsonDecode(body);
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }
}

class ClassificationEvidenceSource {
  const ClassificationEvidenceSource({
    required this.title,
    required this.url,
    required this.scope,
  });

  factory ClassificationEvidenceSource.fromJson(Map<String, dynamic> json) {
    return ClassificationEvidenceSource(
      title: json['title']?.toString() ?? 'Untitled source',
      url: json['url']?.toString() ?? '',
      scope: json['scope']?.toString() ?? '',
    );
  }

  final String title;
  final String url;
  final String scope;
}

class HardwareClassification {
  const HardwareClassification({
    required this.productName,
    required this.identifiedProductType,
    required this.suggestedTaxonomyCategory,
    required this.intendedUse,
    required this.seasonalRelevance,
    required this.identificationConfidence,
    required this.seasonalEvidenceLevel,
    required this.seasonalMatchType,
    required this.seasonalHierarchy,
    required this.explanation,
    required this.evidence,
    required this.isUnknown,
    required this.identificationMethod,
    required this.clarificationNeeded,
  });

  factory HardwareClassification.fromJson(Map<String, dynamic> json) {
    final evidence = json['evidence'];
    final seasonalHierarchy = json['seasonal_hierarchy'];
    return HardwareClassification(
      productName: json['product_name']?.toString() ?? '',
      identifiedProductType:
          json['identified_product_type']?.toString() ?? 'unknown',
      suggestedTaxonomyCategory:
          json['suggested_taxonomy_category']?.toString() ?? 'unknown',
      intendedUse: json['intended_use']?.toString() ?? 'Unknown',
      seasonalRelevance: json['seasonal_relevance']?.toString() ?? 'unknown',
      identificationConfidence:
          json['identification_confidence']?.toString() ?? 'unknown',
      seasonalEvidenceLevel:
          json['seasonal_evidence_level']?.toString() ?? 'insufficient',
      seasonalMatchType:
          json['seasonal_match_type']?.toString() ?? 'insufficient',
      seasonalHierarchy: seasonalHierarchy is List
          ? seasonalHierarchy
                .map((value) => value.toString())
                .toList(growable: false)
          : const <String>[],
      explanation: json['explanation']?.toString() ?? '',
      evidence: evidence is List
          ? evidence
                .whereType<Map>()
                .map(
                  (value) => ClassificationEvidenceSource.fromJson(
                    Map<String, dynamic>.from(value),
                  ),
                )
                .toList(growable: false)
          : const <ClassificationEvidenceSource>[],
      isUnknown: json['is_unknown'] == true,
      identificationMethod:
          json['identification_method']?.toString() ?? 'unknown',
      clarificationNeeded: json['clarification_needed'] == true,
    );
  }

  final String productName;
  final String identifiedProductType;
  final String suggestedTaxonomyCategory;
  final String intendedUse;
  final String seasonalRelevance;
  final String identificationConfidence;
  final String seasonalEvidenceLevel;
  final String seasonalMatchType;
  final List<String> seasonalHierarchy;
  final String explanation;
  final List<ClassificationEvidenceSource> evidence;
  final bool isUnknown;
  final String identificationMethod;
  final bool clarificationNeeded;
}
