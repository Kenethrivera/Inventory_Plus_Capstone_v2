import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/forecast_portfolio.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';
import 'package:inventory_plus/ui/forecasting_page.dart';

import 'forecasting_test_fixture.dart';

InventoryItem product({
  required String id,
  required String name,
  required String category,
  required String unit,
}) => InventoryItem(
  id: id,
  name: name,
  sku: id.toUpperCase(),
  price: 10,
  quantity: 20,
  maxQuantity: 100,
  category: category,
  description: '',
  imageUrl: '',
  unit: unit,
);

ForecastAnalysis analysis({
  required String id,
  required String name,
  required String unit,
  required List<double> daily,
  bool coldStart = false,
  String status = 'recommend_order',
}) {
  final json = forecastingAnalysisFixture(noHistory: coldStart, status: status);
  final productJson = json['product'] as Map<String, dynamic>;
  productJson
    ..['product_id'] = id
    ..['name'] = name
    ..['unit'] = unit;
  final forecast = json['forecast'] as Map<String, dynamic>;
  forecast
    ..['unit'] = unit
    ..['total_quantity'] = daily.fold<double>(0, (sum, value) => sum + value)
    ..['daily'] = List<Map<String, dynamic>>.generate(
      daily.length,
      (index) => <String, dynamic>{
        'date': DateTime.utc(
          2026,
          11,
          5,
        ).add(Duration(days: index)).toIso8601String().split('T').first,
        'quantity': daily[index],
      },
      growable: false,
    );
  final recommendation = json['recommendation'] as Map<String, dynamic>;
  final suggested =
      recommendation['suggested_quantity'] as Map<String, dynamic>;
  suggested
    ..['inventory_unit'] = unit
    ..['order_unit'] = unit;
  return ForecastAnalysis.fromJson(json);
}

PortfolioForecastSnapshot snapshot({
  required List<InventoryItem> products,
  required Map<String, ForecastAnalysis> analyses,
}) => const PortfolioForecastAggregator().aggregate(
  products: products,
  analyses: analyses,
  generatedAt: DateTime.utc(2026, 11, 5),
);

void main() {
  test('portfolio and categories aggregate compatible units', () {
    final products = <InventoryItem>[
      product(
        id: 'cement',
        name: 'Cement',
        category: 'Construction materials',
        unit: 'bag',
      ),
      product(
        id: 'mortar',
        name: 'Mortar',
        category: 'Building supplies',
        unit: 'bag',
      ),
    ];
    final result = snapshot(
      products: products,
      analyses: <String, ForecastAnalysis>{
        'cement': analysis(
          id: 'cement',
          name: 'Cement',
          unit: 'bag',
          daily: List<double>.filled(28, 2),
        ),
        'mortar': analysis(
          id: 'mortar',
          name: 'Mortar',
          unit: 'bag',
          daily: List<double>.filled(28, 3),
        ),
      },
    );

    expect(result.byUnit.keys, <String>['bag']);
    expect(result.byUnit['bag']!.quantityFor(ForecastWindow.today), 5);
    expect(result.byUnit['bag']!.quantityFor(ForecastWindow.next7Days), 35);
    expect(result.byUnit['bag']!.quantityFor(ForecastWindow.next28Days), 140);
    expect(result.byUnit['bag']!.direction, DemandDirection.stable);
    expect(
      result.categories.map((value) => value.category),
      contains('Building materials'),
    );
  });

  test('mixed measurement units remain separate', () {
    final products = <InventoryItem>[
      product(id: 'pipe', name: 'Pipe', category: 'Plumbing', unit: 'meter'),
      product(
        id: 'fitting',
        name: 'Fitting',
        category: 'Plumbing',
        unit: 'pcs',
      ),
    ];
    final result = snapshot(
      products: products,
      analyses: <String, ForecastAnalysis>{
        'pipe': analysis(
          id: 'pipe',
          name: 'Pipe',
          unit: 'meter',
          daily: List<double>.filled(28, 4),
        ),
        'fitting': analysis(
          id: 'fitting',
          name: 'Fitting',
          unit: 'pcs',
          daily: List<double>.filled(28, 10),
        ),
      },
    );

    expect(result.byUnit.keys.toSet(), <String>{'meter', 'pcs'});
    final plumbing = result.categories.single;
    expect(plumbing.byUnit.keys.toSet(), <String>{'meter', 'pcs'});
    expect(plumbing.byUnit['meter']!.quantityFor(ForecastWindow.today), 4);
    expect(plumbing.byUnit['pcs']!.quantityFor(ForecastWindow.today), 10);
  });

  test('cold-start products remain explicit and are excluded from totals', () {
    final cold = product(
      id: 'new-tool',
      name: 'New Tool',
      category: 'Tools',
      unit: 'pcs',
    );
    final result = snapshot(
      products: <InventoryItem>[cold],
      analyses: <String, ForecastAnalysis>{
        cold.id: analysis(
          id: cold.id,
          name: cold.name,
          unit: cold.unit,
          daily: List<double>.filled(28, 0),
          coldStart: true,
          status: 'needs_review',
        ),
      },
    );

    expect(result.coldStartProducts, 1);
    expect(result.forecastedProducts, 0);
    expect(result.byUnit, isEmpty);
    expect(result.categories.single.coldStartProducts, 1);
  });

  testWidgets('dashboard works without product selection and changes period', (
    tester,
  ) async {
    final item = product(
      id: 'paint',
      name: 'Paint',
      category: 'Paint',
      unit: 'can',
    );
    final value = snapshot(
      products: <InventoryItem>[item],
      analyses: <String, ForecastAnalysis>{
        item.id: analysis(
          id: item.id,
          name: item.name,
          unit: item.unit,
          daily: List<double>.generate(28, (index) => index + 1),
        ),
      },
    );
    var selected = ForecastWindow.next7Days;
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ForecastOverviewDashboard(
              snapshot: value,
              selectedWindow: selected,
              onWindowChanged: (window) => selected = window,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('forecast-overview-dashboard')),
      findsOneWidget,
    );
    expect(find.text('Overall hardware-store demand outlook'), findsOneWidget);
    expect(find.text('Today'), findsWidgets);
    expect(find.text('Next 7 days'), findsWidgets);
    expect(find.text('Next 28 days'), findsWidgets);
    expect(find.textContaining('rolling horizon'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('forecast-period-next28Days')),
      warnIfMissed: false,
    );
    expect(selected, ForecastWindow.next28Days);
  });

  testWidgets('dashboard shows an explicit loading state before forecasts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForecastOverviewDashboard(
            snapshot: null,
            selectedWindow: ForecastWindow.next7Days,
            loading: true,
            onWindowChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('forecast-overview-loading')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('partial product failure keeps the available portfolio visible', (
    tester,
  ) async {
    final item = product(
      id: 'available-product',
      name: 'Available product',
      category: 'Tools',
      unit: 'pcs',
    );
    final value = snapshot(
      products: <InventoryItem>[item],
      analyses: <String, ForecastAnalysis>{
        item.id: analysis(
          id: item.id,
          name: item.name,
          unit: item.unit,
          daily: List<double>.filled(28, 2),
        ),
      },
    );
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ForecastOverviewDashboard(
              snapshot: value,
              selectedWindow: ForecastWindow.next7Days,
              requestWarnings: const <String>[
                'Unavailable product: Forecast API timed out.',
              ],
              onWindowChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('forecast-overview-dashboard')),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 product forecast(s) were unavailable'),
      findsOneWidget,
    );
    expect(find.textContaining('14 pcs'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing industry data is explicit and not fabricated', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: IndustryOutlookPanel()),
        ),
      ),
    );

    expect(find.textContaining('Industry outlook unavailable'), findsOneWidget);
    expect(
      find.textContaining('no verified external industry feed'),
      findsOneWidget,
    );
    expect(find.textContaining('not a demand forecast'), findsOneWidget);
  });
}
