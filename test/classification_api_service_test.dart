import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_plus/services/classification_api_service.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';

void main() {
  test(
    'classification client sends authenticated read-only text request',
    () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object>{
            'schema_version': 'classification-v3',
            'classifier_version': 'hardware-seasonal-knowledge-v1',
            'read_only': true,
            'result': <String, Object>{
              'product_name': 'Roofing Sealant',
              'identified_product_type': 'roofing_sealant',
              'suggested_taxonomy_category': 'Roof repair sealant',
              'intended_use': 'Repairing and sealing roof leak points.',
              'seasonal_relevance': 'rainy',
              'identification_confidence': 'high',
              'seasonal_evidence_level': 'provisional_domain_assumption',
              'seasonal_match_type': 'product_specific',
              'seasonal_hierarchy': <String>[
                'Roof repair sealant',
                'Product-specific seasonal relationship',
                'Potential rainy-season relevance',
              ],
              'explanation': 'Identification is separate from demand evidence.',
              'evidence': <Object>[
                <String, String>{
                  'title': 'PAGASA Climate of the Philippines',
                  'url':
                      'https://www.pagasa.dost.gov.ph/information/climate-philippines',
                  'scope': 'Climate context only.',
                },
              ],
              'is_unknown': false,
              'identification_method': 'semantic_taxonomy',
              'clarification_needed': false,
            },
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final service = HardwareClassificationApiClient(
        baseUri: Uri.parse('http://127.0.0.1:8000'),
        client: client,
      );

      final result = await service.classify(
        productName: 'Roofing Sealant',
        category: 'Roofing Repair',
        description: 'Sealant for roof leak points',
        sessionToken: 'admin-session',
        engine: HardwareClassificationEngine.gemini,
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/classification');
      expect(captured.headers['Authorization'], 'Bearer admin-session');
      expect(jsonDecode(captured.body)['product_name'], 'Roofing Sealant');
      expect(jsonDecode(captured.body)['engine'], 'gemini');
      expect(result.identifiedProductType, 'roofing_sealant');
      expect(result.suggestedTaxonomyCategory, 'Roof repair sealant');
      expect(result.seasonalRelevance, 'rainy');
      expect(result.identificationMethod, 'semantic_taxonomy');
      expect(result.seasonalMatchType, 'product_specific');
      expect(result.seasonalHierarchy, hasLength(3));
      expect(result.clarificationNeeded, isFalse);
      expect(result.evidence.single.title, contains('PAGASA'));
    },
  );

  test('classification client surfaces API authorization errors', () async {
    final service = HardwareClassificationApiClient(
      baseUri: Uri.parse('http://127.0.0.1:8000'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, String>{'detail': 'Admin users only'}),
          403,
        ),
      ),
    );

    expect(
      () => service.classify(
        productName: 'Claw Hammer',
        category: 'Hand Tools',
        description: '',
        sessionToken: 'helper-session',
        engine: HardwareClassificationEngine.existing,
      ),
      throwsA(
        isA<ForecastApiException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having((error) => error.message, 'message', 'Admin users only'),
      ),
    );
  });
}
