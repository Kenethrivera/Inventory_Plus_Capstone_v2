import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/seasonal_learning_lab.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';
import 'package:inventory_plus/ui/forecasting_page.dart';
import 'package:inventory_plus/ui/widgets/seasonal_learning_laboratory.dart';

import 'forecasting_test_fixture.dart';

void main() {
  Future<void> useDesktopSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );

  testWidgets('displays model, forecast, policy state and warning', (
    tester,
  ) async {
    final analysis = ForecastAnalysis.fromJson(forecastingAnalysisFixture());
    await useDesktopSurface(tester);

    await tester.pumpWidget(host(ForecastAnalysisPanel(analysis: analysis)));

    expect(
      tester.widget<Text>(find.byKey(const Key('forecast-total'))).data,
      '84 pcs',
    );
    expect(find.text('calibrated_blend vstage5b-blend-v1'), findsOneWidget);
    expect(find.text('RECOMMEND_ORDER'), findsOneWidget);
    expect(find.text('Preliminary 28-day demand insight'), findsOneWidget);
    expect(find.text('72 pcs'), findsOneWidget);
    expect(find.text('40 pcs'), findsOneWidget);
    expect(
      find.textContaining('Missing incoming or backorder'),
      findsOneWidget,
    );
    expect(find.textContaining('Periodic-review policy'), findsOneWidget);
    expect(find.textContaining('supplier capacity review'), findsOneWidget);
    expect(find.text('How this guidance was calculated'), findsOneWidget);
    expect(find.textContaining('Known test calculation'), findsOneWidget);
    expect(find.textContaining('Human approval is required'), findsOneWidget);
    expect(find.text('Live authenticated Supabase-backed API'), findsOneWidget);
    expect(
      find.text('Supabase sales history (may include staging or test records)'),
      findsOneWidget,
    );
    expect(find.text('real'), findsOneWidget);
  });

  testWidgets('shows experimental classification and upcoming transition', (
    tester,
  ) async {
    await useDesktopSurface(tester);
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

    await tester.pumpWidget(
      host(ForecastAnalysisPanel(analysis: ForecastAnalysis.fromJson(payload))),
    );

    expect(find.text('Experimental seasonal context'), findsOneWidget);
    expect(find.text('SUMMER'), findsOneWidget);
    expect(find.textContaining('to rainy on 2027-05-01'), findsOneWidget);
    expect(
      find.textContaining('Replenishment remains calculated'),
      findsOneWidget,
    );
  });

  testWidgets(
    'no-history zero is displayed as unknown demand with manual option',
    (tester) async {
      await useDesktopSurface(tester);
      var manualTapped = false;
      final analysis = ForecastAnalysis.fromJson(
        forecastingAnalysisFixture(
          noHistory: true,
          status: 'needs_review',
          recommendationWarnings: const <String>['no_history_demand_unknown'],
        ),
      );

      await tester.pumpWidget(
        host(
          ForecastAnalysisPanel(
            analysis: analysis,
            onManualEstimate: () => manualTapped = true,
          ),
        ),
      );

      expect(find.textContaining('unknown-demand placeholder'), findsOneWidget);
      expect(find.text('NEEDS_REVIEW'), findsOneWidget);
      expect(
        find.textContaining('No sales history is available'),
        findsOneWidget,
      );
      expect(find.text('Not calculable'), findsOneWidget);
      await tester.tap(find.text('Enter manual estimate'));
      expect(manualTapped, isTrue);
    },
  );

  testWidgets('connection failure remains an explicit forecast-only error', (
    tester,
  ) async {
    await useDesktopSurface(tester);
    await tester.pumpWidget(
      host(
        const ForecastAnalysisPanel(
          analysis: null,
          error: 'Forecast API is unreachable.',
        ),
      ),
    );

    expect(find.text('Forecast unavailable'), findsOneWidget);
    expect(find.text('Forecast API is unreachable.'), findsOneWidget);
  });

  testWidgets('synthetic fixture is visibly separated from real data', (
    tester,
  ) async {
    await useDesktopSurface(tester);
    final analysis = ForecastAnalysis.fromJson(
      forecastingAnalysisFixture(synthetic: true),
    );
    await tester.pumpWidget(host(ForecastAnalysisPanel(analysis: analysis)));

    expect(find.textContaining('Development fixture'), findsWidgets);
    expect(
      find.textContaining('not evidence of real-store accuracy'),
      findsOneWidget,
    );
  });

  testWidgets('manual estimate requires rationale and staff confirmation', (
    tester,
  ) async {
    await useDesktopSurface(tester);
    await tester.pumpWidget(
      const MaterialApp(home: ColdStartManualEstimateDialog(unit: 'pcs')),
    );

    FilledButton submit() => tester.widget<FilledButton>(
      find.byKey(const Key('manual-demand-submit')),
    );

    expect(
      find.text('Source: authenticated Admin manual input'),
      findsOneWidget,
    );
    expect(find.text('Daily demand (pcs)'), findsOneWidget);
    expect(submit().onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('manual-demand-quantity')),
      '3.5',
    );
    await tester.enterText(
      find.byKey(const Key('manual-demand-rationale')),
      'Opening-week shelf plan',
    );
    expect(submit().onPressed, isNull);

    await tester.tap(find.byKey(const Key('manual-demand-confirmation')));
    await tester.pump();
    expect(submit().onPressed, isNotNull);
  });

  testWidgets(
    'confirmed manual input is labeled provisional and non-historical',
    (tester) async {
      await useDesktopSurface(tester);
      final analysis = ForecastAnalysis.fromJson(
        forecastingAnalysisFixture(
          noHistory: true,
          status: 'needs_review',
          manualEstimate: true,
        ),
      );
      await tester.pumpWidget(host(ForecastAnalysisPanel(analysis: analysis)));

      expect(find.text('Confirmed cold-start input'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('manual-demand-summary')),
          matching: find.text('3 pcs'),
        ),
        findsOneWidget,
      );
      expect(find.text('Opening-week shelf plan'), findsOneWidget);
      expect(
        find.textContaining('does not create historical sales records'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'restocking dialog labels estimates and requires verified quantities',
    (tester) async {
      await useDesktopSurface(tester);
      final configuration = ReplenishmentConfiguration(
        configured: false,
        productId: 'product-1',
        locationId: 'location-1',
        inventoryUnit: 'pcs',
        incomingQuantityVerified: false,
        backorderQuantityVerified: false,
        manualEstimate: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ReplenishmentConfigurationDialog(
            configuration: configuration,
            productName: 'Claw Hammer',
          ),
        ),
      );

      expect(find.textContaining('Inventory unit: pcs'), findsOneWidget);
      expect(find.textContaining('Leave unknown values blank'), findsOneWidget);
      expect(find.text('Admin-provided estimate'), findsOneWidget);
      expect(find.text('Save and recalculate'), findsOneWidget);
      final orderUnit = tester.widget<TextField>(
        find.byKey(const Key('config-order-unit')),
      );
      expect(orderUnit.controller?.text, isEmpty);

      await tester.enterText(find.byKey(const Key('config-incoming')), '10');
      await tester.enterText(
        find.byKey(const Key('config-rationale')),
        'Supplier confirmation call',
      );
      await tester.tap(find.byKey(const Key('config-save-confirmation')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('replenishment-config-save')));
      await tester.pump();

      expect(
        find.textContaining('entered and explicitly verified together'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'seasonal laboratory displays exact report metrics and evidence boundaries',
    (tester) async {
      await useDesktopSurface(tester);
      final report = SeasonalLearningLabReport.fromJson(
        seasonalLearningLabFixture(),
      );
      await tester.pumpWidget(
        host(
          SeasonalLearningLaboratory(
            isActive: true,
            initiallyExpanded: true,
            initialReport: report,
            onLoad: (_) async => report,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Seasonal Learning Laboratory'), findsOneWidget);
      expect(
        find.textContaining('Historical forecast accuracy'),
        findsOneWidget,
      );
      expect(find.text('18.42%'), findsNWidgets(2));
      expect(find.text('87.50%'), findsWidgets);
      expect(find.text('100.00%'), findsWidgets);
      expect(find.text('UNKNOWN'), findsWidgets);
      expect(find.textContaining('24 SIMULATION PRODUCTS'), findsOneWidget);
      expect(
        find.textContaining('Six and twelve months', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('Fourth-year confirmation'), findsWidgets);
      expect(find.textContaining('after its origin'), findsOneWidget);
      expect(
        find.textContaining('never used for stock orders'),
        findsOneWidget,
      );
    },
  );

  testWidgets('missing research reports do not replace operational forecast', (
    tester,
  ) async {
    await useDesktopSurface(tester);
    final analysis = ForecastAnalysis.fromJson(forecastingAnalysisFixture());
    await tester.pumpWidget(
      host(
        Column(
          children: [
            ForecastAnalysisPanel(analysis: analysis),
            SeasonalLearningLaboratory(
              isActive: true,
              initiallyExpanded: true,
              liveAnalysis: analysis,
              onLoad: (_) async => throw const ForecastApiException(
                'Research report artifacts are missing.',
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(const Key('forecast-total'))).data,
      '84 pcs',
    );
    expect(find.text('Research dashboard unavailable'), findsOneWidget);
    expect(find.textContaining('artifacts are missing'), findsOneWidget);
    expect(
      find.textContaining('Live forecasting is unaffected'),
      findsOneWidget,
    );
  });

  testWidgets('SIM SKU is labeled as imported synthetic sales', (tester) async {
    await useDesktopSurface(tester);
    final payload = forecastingAnalysisFixture();
    final product = payload['product'] as Map<String, dynamic>;
    product['sku'] = 'SIM-SUM-01';
    await tester.pumpWidget(
      host(ForecastAnalysisPanel(analysis: ForecastAnalysis.fromJson(payload))),
    );

    expect(
      find.text('Imported synthetic simulation sales (SIM SKU)'),
      findsOneWidget,
    );
    expect(find.text('Live authenticated Supabase-backed API'), findsOneWidget);
  });

  testWidgets(
    'recommendation tracking separates pending receipts and variance',
    (tester) async {
      await useDesktopSurface(tester);
      var matched = false;
      var reconciled = false;
      final item = RecommendationTrackingItem(
        recommendationId: 17,
        productId: 'product-1',
        productName: 'Claw Hammer',
        productSku: 'HAMMER-01',
        inventoryUnit: 'pcs',
        recommendationDate: DateTime.utc(2026, 11, 4, 8),
        forecastPeriodStart: '2026-11-05',
        forecastPeriodEnd: '2026-12-02',
        predictedDemand: 84,
        availableInventory: 12,
        suggestedQuantity: 72,
        evaluationStatus: 'pending',
        matchedReceivedQuantity: null,
        receiptCount: 0,
        forecastModel: 'lightgbm',
        forecastVersion: '1',
        trainingHistoryDays: 365,
        assumptions: const <String>['Owner review is required.'],
      );

      await tester.pumpWidget(
        host(
          RecommendationTrackingPanel(
            items: <RecommendationTrackingItem>[item],
            loading: false,
            mutatingRecommendationId: null,
            onMatchReceipt: (_) => matched = true,
            onReconcile: (_) => reconciled = true,
          ),
        ),
      );

      expect(
        find.textContaining('RESTOCK VARIANCE', findRichText: true),
        findsNothing,
      );
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.textContaining('not assumed to be zero'), findsOneWidget);
      expect(
        find.text('Unavailable — no matched receipt evidence'),
        findsNWidgets(3),
      );
      await tester.ensureVisible(find.text('Match stock receipt'));
      await tester.tap(find.text('Match stock receipt'));
      await tester.tap(find.text('Finalize comparison'));
      expect(matched, isTrue);
      expect(reconciled, isTrue);
    },
  );

  testWidgets(
    'reconciled recommendation without receipts does not show zero variance',
    (tester) async {
      await useDesktopSurface(tester);
      final item = RecommendationTrackingItem(
        recommendationId: 18,
        productId: 'product-1',
        productName: 'Claw Hammer',
        productSku: 'HAMMER-01',
        inventoryUnit: 'pcs',
        recommendationDate: DateTime.utc(2026, 9, 1),
        forecastPeriodStart: '2026-09-01',
        forecastPeriodEnd: '2026-09-28',
        predictedDemand: 20,
        availableInventory: 10,
        suggestedQuantity: 10,
        evaluationStatus: 'reconciled',
        matchedReceivedQuantity: 0,
        signedQuantityDifference: -10,
        absoluteDifference: 10,
        percentageVariance: -100,
        receiptCount: 0,
        reconciledAt: DateTime.utc(2026, 10, 1),
        forecastModel: 'lightgbm',
        forecastVersion: '1',
        trainingHistoryDays: 365,
        assumptions: const <String>[],
      );

      await tester.pumpWidget(
        host(
          RecommendationTrackingPanel(
            items: <RecommendationTrackingItem>[item],
            loading: false,
            mutatingRecommendationId: null,
            onMatchReceipt: (_) {},
            onReconcile: (_) {},
          ),
        ),
      );

      expect(
        find.text('Unavailable — no matched receipt evidence'),
        findsNWidgets(3),
      );
      expect(find.text('-100.0%'), findsNothing);
      expect(
        find.textContaining('No restock variance is reported'),
        findsOneWidget,
      );
    },
  );

  testWidgets('forecast performance shows saved prediction and actuals', (
    tester,
  ) async {
    await useDesktopSurface(tester);
    final report = ForecastPerformanceReport(
      businessTimezone: 'Asia/Manila',
      dataSourceAvailable: true,
      items: <ForecastPerformanceItem>[
        ForecastPerformanceItem(
          recommendationId: 17,
          locationId: 'location-1',
          productId: 'product-1',
          productName: 'Concrete Hollow Blocks',
          productSku: 'SIM-SUM-01',
          inventoryUnit: 'pcs',
          recommendationDate: DateTime.utc(2026, 9, 1),
          forecastPeriodStart: '2026-09-01',
          forecastPeriodEnd: '2026-09-28',
          predictedDemand: 20,
          forecastModel: 'lightgbm',
          forecastVersion: '1',
          trainingHistoryDays: 365,
          evaluationStatus: 'completed_evaluable',
          statusExplanation: 'Completed customer sales were retrieved.',
          evaluable: true,
          actualCompletedSales: 5,
          signedForecastError: 15,
          absoluteError: 15,
          percentageError: 300,
          errorDirection: 'overprediction',
          syntheticSales: true,
          salesProvenance: 'synthetic_simulation_history',
          stockAvailabilityKnown: false,
        ),
      ],
      summariesByUnit: const <ForecastPerformanceSummary>[
        ForecastPerformanceSummary(
          inventoryUnit: 'pcs',
          evaluationCount: 1,
          zeroActualCount: 0,
          predictedTotal: 20,
          actualTotal: 5,
          absoluteErrorTotal: 15,
          signedErrorTotal: 15,
          wape: 300,
          forecastBias: 300,
        ),
      ],
      limitations: const <String>['Saved forecasts only.'],
    );

    await tester.pumpWidget(
      host(ForecastPerformancePanel(report: report, loading: false)),
    );

    expect(find.text('Forecast Performance'), findsOneWidget);
    expect(find.text('20 pcs'), findsOneWidget);
    expect(find.text('5 pcs'), findsOneWidget);
    expect(find.textContaining('+15 pcs (overprediction)'), findsOneWidget);
    expect(find.byKey(const Key('forecast-error-trend')), findsOneWidget);
    expect(
      find.byKey(const Key('forecast-performance-synthetic-warning')),
      findsOneWidget,
    );
    expect(
      find.textContaining('not recommendation-versus-restock'),
      findsOneWidget,
    );
  });

  testWidgets('tracking outage does not replace the forecast panel', (
    tester,
  ) async {
    await useDesktopSurface(tester);
    final analysis = ForecastAnalysis.fromJson(forecastingAnalysisFixture());
    await tester.pumpWidget(
      host(
        Column(
          children: [
            ForecastAnalysisPanel(analysis: analysis),
            RecommendationTrackingPanel(
              items: const <RecommendationTrackingItem>[],
              loading: false,
              error:
                  'Recommendation tracking is currently disabled or unavailable. Forecasting remains available.',
              mutatingRecommendationId: null,
              onMatchReceipt: (_) {},
              onReconcile: (_) {},
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const Key('forecast-total')), findsOneWidget);
    expect(
      find.textContaining('Forecasting remains available'),
      findsOneWidget,
    );
  });
}
