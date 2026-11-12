import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';

import 'forecasting_test_fixture.dart';

Map<String, dynamic> replenishmentConfigurationFixture() => <String, dynamic>{
  'configured': true,
  'product_id': 'product-1',
  'location_id': 'location-1',
  'inventory_unit': 'pcs',
  'supplier_lead_time_days': 5,
  'review_period_days': 7,
  'safety_stock': 12,
  'minimum_order_quantity': 6,
  'supplier_pack_size': 3,
  'supplier_order_unit': 'box',
  'unit_conversion_factor': 4,
  'confirmed_incoming_quantity': 8,
  'incoming_quantity_verified': true,
  'backorder_quantity': 2,
  'backorder_quantity_verified': true,
  'supplier_availability': 'available',
  'data_source': 'admin_estimate',
  'source_captured_at': '2026-11-04T08:00:00Z',
  'rationale': 'Reviewed supplier estimate',
  'updated_at': '2026-11-04T08:01:00Z',
  'updated_by_profile_id': 'profile-1',
  'manual_estimate': true,
};

void main() {
  test(
    'dart-define URL overrides dotenv and requires an absolute HTTP URL',
    () {
      expect(
        ForecastApiClient.resolveConfiguredBaseUri(
          compileTimeUrl: 'http://10.0.2.2:8000',
          dotenvUrl: 'http://127.0.0.1:9000',
        ).toString(),
        'http://10.0.2.2:8000',
      );
      expect(
        ForecastApiClient.resolveConfiguredBaseUri(
          compileTimeUrl: '',
          dotenvUrl: 'http://127.0.0.1:8000',
        ).toString(),
        'http://127.0.0.1:8000',
      );
      expect(
        () => ForecastApiClient.resolveConfiguredBaseUri(
          compileTimeUrl: 'localhost:8000',
        ),
        throwsA(isA<ForecastApiException>()),
      );
    },
  );

  test(
    'serializes authenticated scoped request and parses response contract',
    () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(forecastingAnalysisFixture(manualEstimate: true)),
          200,
        );
      });
      final service = ForecastApiClient(
        baseUri: Uri.parse('https://forecast.example.test'),
        client: client,
      );

      final result = await service.analyze(
        productId: 'product-1',
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        model: 'calibrated_blend',
        manualDailyDemand: 3,
        manualUnit: 'pcs',
        manualRationale: 'Reviewed estimate',
        manualConfirmed: true,
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/forecasting/products/product-1/analysis');
      expect(captured.headers['authorization'], 'Bearer opaque-session-token');
      final requestBody = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(requestBody['location_id'], 'location-1');
      expect(requestBody['model'], 'calibrated_blend');
      expect(requestBody['manual_daily_demand'], 3);
      expect(requestBody['manual_confirmed'], isTrue);
      expect(requestBody, isNot(contains('service_role_key')));
      expect(requestBody, isNot(contains('create_purchase_order')));
      expect(result.authorizedLocationId, 'location-1');
      expect(result.product.productId, 'product-1');
      expect(result.forecast.model, 'calibrated_blend');
      expect(result.forecast.version, 'stage5b-blend-v1');
      expect(result.preliminaryRestockingInsight.planningHorizonDays, 28);
      expect(result.preliminaryRestockingInsight.predictedDemand, 84);
      expect(result.preliminaryRestockingInsight.availableInventory, 12);
      expect(result.preliminaryRestockingInsight.suggestedRestockQuantity, 72);
      expect(
        result.preliminaryRestockingInsight.usesExperimentalSeasonalForecast,
        isFalse,
      );
      expect(
        result.preliminaryRestockingInsight.incomingAndBackordersTreatedAsZero,
        isFalse,
      );
      expect(result.recommendation.status, 'recommend_order');
      expect(result.recommendation.purchaseOrderCreated, isFalse);
      expect(
        result.recommendation.manualDemandEstimate?.staffConfirmed,
        isTrue,
      );
      expect(
        result.recommendation.manualDemandEstimate?.source,
        'authenticated_admin_manual_input',
      );
      expect(
        result.recommendation.manualDemandEstimate?.createsHistoricalSales,
        isFalse,
      );
    },
  );

  test('parses experimental seasonal context and fallback metadata', () async {
    final payload = forecastingAnalysisFixture();
    final forecast = payload['forecast'] as Map<String, dynamic>;
    forecast.addAll(<String, dynamic>{
      'requested_model': 'seasonal_experimental',
      'experimental': true,
      'fallback': <String, dynamic>{'used': false, 'reason': null},
      'seasonal_context': <String, dynamic>{
        'calendar_version': 'pagasa-type-i-core-seasons-v1',
        'source_name': 'PAGASA Climate of the Philippines',
        'source_url': 'https://www.pagasa.dost.gov.ph/',
        'numerical_multiplier_applied': false,
        'classification': <String, dynamic>{
          'seasonal_relevance': 'summer',
          'match_type': 'frozen_simulation_hypothesis',
          'evidence_level': 'simulation_hypothesis_inherited_industry',
        },
        'next_transition': <String, dynamic>{
          'date': '2027-05-01',
          'transition': 'to_rainy',
        },
      },
    });
    final daily = forecast['daily'] as List<dynamic>;
    (daily.first as Map<String, dynamic>).addAll(<String, dynamic>{
      'season': 'transition',
      'transition': 'to_dry',
    });

    final result = ForecastAnalysis.fromJson(payload).forecast;

    expect(result.requestedModel, 'seasonal_experimental');
    expect(result.isExperimental, isTrue);
    expect(result.seasonalContext?.seasonalRelevance, 'summer');
    expect(result.seasonalContext?.nextTransition, 'to_rainy');
    expect(result.seasonalContext?.numericalMultiplierApplied, isFalse);
    expect(result.daily.first.transition, 'to_dry');
  });

  test(
    'surfaces authorization error without treating it as valid data',
    () async {
      final service = ForecastApiClient(
        baseUri: Uri.parse('https://forecast.example.test'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(<String, String>{'detail': 'Forbidden'}),
            403,
          ),
        ),
      );

      await expectLater(
        service.analyze(
          productId: 'product-1',
          locationId: 'location-2',
          sessionToken: 'opaque-session-token',
          model: 'mean28',
        ),
        throwsA(
          isA<ForecastApiException>()
              .having((error) => error.statusCode, 'statusCode', 403)
              .having((error) => error.message, 'message', 'Forbidden'),
        ),
      );
    },
  );

  test('surfaces timeout explicitly', () async {
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      timeout: const Duration(milliseconds: 1),
      client: MockClient((_) => Completer<http.Response>().future),
    );

    await expectLater(
      service.analyze(
        productId: 'product-1',
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        model: 'mean28',
      ),
      throwsA(
        isA<ForecastApiException>().having(
          (error) => error.isTimeout,
          'isTimeout',
          isTrue,
        ),
      ),
    );
  });

  test('seasonal analysis uses its longer history-retrieval timeout', () async {
    final payload = forecastingAnalysisFixture();
    final forecast = payload['forecast'] as Map<String, dynamic>;
    forecast['requested_model'] = 'seasonal_experimental';
    forecast['experimental'] = true;
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      timeout: const Duration(milliseconds: 1),
      seasonalTimeout: const Duration(milliseconds: 100),
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response(jsonEncode(payload), 200);
      }),
    );

    final result = await service.analyze(
      productId: 'product-1',
      locationId: 'location-1',
      sessionToken: 'opaque-session-token',
      model: 'seasonal_experimental',
    );

    expect(result.forecast.requestedModel, 'seasonal_experimental');
  });

  test('surfaces connection failure explicitly', () async {
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((_) async => throw http.ClientException('offline')),
    );

    await expectLater(
      service.analyze(
        productId: 'product-1',
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        model: 'mean28',
      ),
      throwsA(
        isA<ForecastApiException>().having(
          (error) => error.message,
          'message',
          'Forecast API connection failed.',
        ),
      ),
    );
  });

  test('rejects malformed successful response', () async {
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient(
        (_) async => http.Response('{"unexpected":true}', 200),
      ),
    );

    await expectLater(
      service.analyze(
        productId: 'product-1',
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        model: 'mean28',
      ),
      throwsA(
        isA<ForecastApiException>().having(
          (error) => error.message,
          'message',
          'Forecast API returned invalid data.',
        ),
      ),
    );
  });

  test('reads scoped replenishment configuration', () async {
    late http.Request captured;
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(replenishmentConfigurationFixture()),
          200,
        );
      }),
    );

    final result = await service.getReplenishmentConfiguration(
      productId: 'product-1',
      locationId: 'location-1',
      sessionToken: 'opaque-session-token',
    );

    expect(captured.method, 'GET');
    expect(
      captured.url.path,
      '/v1/forecasting/products/product-1/replenishment-config',
    );
    expect(captured.url.queryParameters['location_id'], 'location-1');
    expect(captured.headers['authorization'], 'Bearer opaque-session-token');
    expect(result.inventoryUnit, 'pcs');
    expect(result.unitConversionFactor, 4);
    expect(result.manualEstimate, isTrue);
  });

  test('saves only forecasting replenishment inputs', () async {
    late http.Request captured;
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(replenishmentConfigurationFixture()),
          200,
        );
      }),
    );

    await service.saveReplenishmentConfiguration(
      productId: 'product-1',
      locationId: 'location-1',
      sessionToken: 'opaque-session-token',
      configuration: ReplenishmentConfigurationInput(
        supplierLeadTimeDays: 5,
        reviewPeriodDays: 7,
        safetyStock: 12,
        minimumOrderQuantity: 6,
        supplierPackSize: 3,
        supplierOrderUnit: 'box',
        unitConversionFactor: 4,
        confirmedIncomingQuantity: 8,
        incomingQuantityVerified: true,
        backorderQuantity: 2,
        backorderQuantityVerified: true,
        supplierAvailability: 'available',
        dataSource: 'admin_estimate',
        sourceCapturedAt: DateTime.utc(2026, 11, 4, 8),
        rationale: 'Reviewed supplier estimate',
      ),
    );

    expect(captured.method, 'PUT');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['location_id'], 'location-1');
    expect(body['confirmed_incoming_quantity'], 8);
    expect(body['incoming_quantity_verified'], isTrue);
    expect(body['data_source'], 'admin_estimate');
    expect(body, isNot(contains('service_role_key')));
    expect(body, isNot(contains('purchase_order')));
    expect(body, isNot(contains('product_quantity')));
  });

  test('loads authenticated read-only seasonal research artifacts', () async {
    late http.Request captured;
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(seasonalLearningLabFixture()), 200);
      }),
    );

    final result = await service.loadSeasonalLearningLab(
      sessionToken: 'opaque-session-token',
      productId: 'sim-product-1',
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, '/v1/forecasting/research/seasonal-learning');
    expect(captured.url.queryParameters['product_id'], 'sim-product-1');
    expect(captured.headers['authorization'], 'Bearer opaque-session-token');
    expect(result.readOnly, isTrue);
    expect(result.products, hasLength(24));
    expect(result.selectedProduct?.sku, 'SIM-SUM-01');
    expect(
      result.classificationModels['refined']?.accuracy,
      closeTo(0.875, 0.00001),
    );
    expect(
      result.products.where(
        (product) => product.refinedDiscovered == 'UNKNOWN',
      ),
      hasLength(3),
    );
    expect(
      result.forecastActual.every(
        (point) => point.forecastDate.isAfter(point.origin),
      ),
      isTrue,
    );
  });

  test(
    'uses trusted recommendation tracking endpoints without secrets',
    () async {
      final requests = <http.Request>[];
      final service = ForecastApiClient(
        baseUri: Uri.parse('https://forecast.example.test'),
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/recommendation-snapshots')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'recommendation_id': 17,
                'request_id': '11111111-1111-4111-8111-111111111111',
                'reused': false,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/receipt-allocations')) {
            return http.Response(
              jsonEncode(<String, dynamic>{'reused': false}),
              200,
            );
          }
          if (request.url.path.endsWith('/reconcile')) {
            return http.Response(
              jsonEncode(<String, dynamic>{'reused': false}),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'items': <Map<String, dynamic>>[
                <String, dynamic>{
                  'recommendation_id': 17,
                  'product_id_snapshot': 'product-1',
                  'product_name_snapshot': 'Claw Hammer',
                  'product_sku_snapshot': 'HAMMER-01',
                  'inventory_unit': 'pcs',
                  'recommendation_date': '2026-11-04T08:00:00Z',
                  'forecast_period_start': '2026-11-05',
                  'forecast_period_end': '2026-12-02',
                  'predicted_demand': 84,
                  'available_inventory': 12,
                  'suggested_quantity': 72,
                  'evaluation_status': 'partially_received',
                  'matched_received_quantity': 20,
                  'signed_quantity_difference': -52,
                  'absolute_difference': 52,
                  'percentage_variance': -72.2222,
                  'first_receipt_date': '2026-11-06T08:00:00Z',
                  'last_receipt_date': '2026-11-06T08:00:00Z',
                  'receipt_count': 1,
                  'reconciled_at': null,
                  'forecast_model': 'lightgbm',
                  'forecast_version': '1',
                  'training_history_days': 365,
                  'assumptions': <String>['Owner review is required.'],
                },
              ],
            }),
            200,
          );
        }),
      );
      final analysis = ForecastAnalysis.fromJson(forecastingAnalysisFixture());

      final saved = await service.saveRecommendationSnapshot(
        productId: 'product-1',
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        requestId: '11111111-1111-4111-8111-111111111111',
        analysis: analysis,
      );
      final history = await service.loadRecommendationTracking(
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        productId: 'product-1',
      );
      await service.matchRecommendationReceipt(
        recommendationId: 17,
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        transactionHistoryId: '22222222-2222-4222-8222-222222222222',
        allocatedInventoryQuantity: 20,
      );
      await service.reconcileRecommendation(
        recommendationId: 17,
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        requestId: '33333333-3333-4333-8333-333333333333',
        confirmNoReceipts: false,
        confirmationNote: 'Delivery complete',
      );

      expect(saved.recommendationId, 17);
      expect(history.single.evaluationStatus, 'partially_received');
      expect(history.single.matchedReceivedQuantity, 20);
      expect(history.single.percentageVariance, closeTo(-72.2222, 0.0001));
      final saveBody = jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(saveBody['forecast_model'], 'lightgbm');
      expect(saveBody['training_history_days'], 365);
      expect(saveBody['experimental_model'], isFalse);
      expect(saveBody, isNot(contains('SUPABASE_SECRET_KEY')));
      expect(saveBody, isNot(contains('service_role_key')));
      expect(
        requests.every(
          (request) =>
              request.headers['authorization'] == 'Bearer opaque-session-token',
        ),
        isTrue,
      );
    },
  );

  test('parses read-only forecast performance monitoring', () async {
    late http.Request captured;
    final service = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'business_timezone': 'Asia/Manila',
            'data_source_available': true,
            'data_source_warning': null,
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'recommendation_id': 17,
                'location_id': 'location-1',
                'product_id': 'product-1',
                'product_name': 'Concrete Hollow Blocks',
                'product_sku': 'SIM-SUM-01',
                'inventory_unit': 'pcs',
                'recommendation_date': '2026-09-01T00:00:00+08:00',
                'forecast_period_start': '2026-09-01',
                'forecast_period_end': '2026-09-28',
                'predicted_demand': 20,
                'forecast_model': 'lightgbm',
                'forecast_version': '1',
                'training_history_days': 365,
                'evaluation_status': 'completed_evaluable',
                'status_explanation': 'Completed sales retrieved.',
                'evaluable': true,
                'actual_completed_sales': 5,
                'signed_forecast_error': 15,
                'absolute_error': 15,
                'percentage_error': 300,
                'error_direction': 'overprediction',
                'synthetic_sales': true,
                'sales_provenance': 'synthetic_simulation_history',
                'stock_availability_known': false,
              },
            ],
            'summaries_by_unit': <Map<String, dynamic>>[
              <String, dynamic>{
                'inventory_unit': 'pcs',
                'evaluation_count': 1,
                'zero_actual_count': 0,
                'predicted_total': 20,
                'actual_total': 5,
                'absolute_error_total': 15,
                'signed_error_total': 15,
                'wape': 300,
                'forecast_bias': 300,
              },
            ],
            'limitations': <String>['Saved forecasts only.'],
          }),
          200,
        );
      }),
    );

    final report = await service.loadForecastPerformance(
      productId: 'product-1',
      locationId: 'location-1',
      sessionToken: 'opaque-session-token',
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, '/v1/forecasting/forecast-performance');
    expect(captured.url.queryParameters['product_id'], 'product-1');
    expect(captured.url.queryParameters['location_id'], 'location-1');
    expect(captured.headers['authorization'], 'Bearer opaque-session-token');
    expect(report.items.single.signedForecastError, 15);
    expect(report.items.single.syntheticSales, isTrue);
    expect(report.summariesByUnit.single.wape, 300);
  });
}
