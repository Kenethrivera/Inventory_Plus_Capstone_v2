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
  testWidgets('current saved pcs forecast survives local inventory scope and period changes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final local = [
      product(id: 'bag-only', name: 'Bag product', category: 'Materials', unit: 'bag'),
      product(id: 'phillips', name: 'Phillips Screwdriver', category: 'Tools', unit: 'pcs'),
      product(id: 'adjustable', name: 'Adjustable wrench', category: 'Tools', unit: 'pcs'),
    ];
    final daily = List.generate(28, (index) => <String, dynamic>{
      'date': DateTime.utc(2026, 11, 14).add(Duration(days: index)).toIso8601String().split('T').first,
      'quantity': index == 0 ? 6.630432856884228 :
          index < 7 ? (42.77728192770286 - 6.630432856884228) / 6 :
          (161.24066866231423 - 42.77728192770286) / 21,
    });
    final page = ForecastSnapshotPage.fromJson({
      'page': 1, 'page_size': 25, 'total_count': 21, 'page_count': 1,
      'items': [{
        'status': 'completed',
        'product': {'product_id': 'phillips', 'location_id': 'location-1',
          'name': 'Phillips Screwdriver', 'unit': 'pcs', 'category': 'Tools'},
        'job': {'status': 'succeeded'},
        'snapshot': {'result_id': 'saved-result', 'summary': {
          'first_day_demand': 6.630432856884228,
          'next_7_day_demand': 42.77728192770286,
          'next_28_day_demand': 161.24066866231423,
          'daily': daily,
        }},
      }, {
        'status': 'stale',
        'product': {'product_id': 'adjustable', 'location_id': 'location-1',
          'name': 'Adjustable wrench', 'unit': 'pcs', 'category': 'Tools'},
        'job': {'status': 'succeeded'},
        'snapshot': {'result_id': 'older-result', 'summary': {
          'next_7_day_demand': 14, 'next_28_day_demand': 56,
          'daily': List.generate(28, (index) => {
            'date': DateTime.utc(2026, 11, 13).add(Duration(days: index)).toIso8601String().split('T').first,
            'quantity': 2,
          }),
        }},
      }],
    });
    final bagPage = ForecastSnapshotPage.fromJson({
      'page': 1, 'page_size': 25, 'total_count': 3, 'page_count': 1,
      'items': [{
        'status': 'completed',
        'product': {'product_id': 'bag-only', 'location_id': 'location-1',
          'name': 'Bag product', 'unit': 'bag', 'category': 'Materials'},
        'job': {'status': 'succeeded'},
        'snapshot': {'summary': {'next_7_day_demand': 7, 'next_28_day_demand': 28,
          'daily': List.generate(28, (index) => {
            'date': DateTime.utc(2026, 11, 14).add(Duration(days: index)).toIso8601String().split('T').first,
            'quantity': 1,
          }),
        }},
      }],
    });
    final seasonalPage = ForecastSnapshotPage.fromJson({
      'page': 1, 'page_size': 25, 'total_count': 21, 'page_count': 1,
      'items': [{
        'status': 'no_forecast',
        'product': {'product_id': 'phillips', 'location_id': 'location-1',
          'name': 'Phillips Screwdriver', 'unit': 'pcs', 'category': 'Tools'},
        'job': {'status': 'missing'},
      }],
    });
    Widget view(ForecastWindow window, {ForecastSnapshotPage? shownPage,
        String? scopeKey, String model = 'calibrated_blend'}) => MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: ForecastOverviewDashboard(
        snapshot: snapshot(products: local, analyses: {}), savedPage: shownPage ?? page,
        products: local, selectedWindow: window, onWindowChanged: (_) {},
        onScopeChanged: (_) {}, selectedScopeKey: scopeKey, selectedModel: model,
      )),
    ));
    await tester.pumpWidget(view(ForecastWindow.next7Days));
    expect(find.textContaining('42.78'), findsWidgets);
    expect(find.textContaining('All pcs'), findsOneWidget);
    await tester.pumpWidget(view(ForecastWindow.next28Days));
    expect(find.textContaining('161.24'), findsWidgets);
    expect(find.textContaining('Includes stale saved forecasts'), findsOneWidget);
    await tester.pumpWidget(view(ForecastWindow.next28Days,
      shownPage: bagPage, scopeKey: 'unit:bag'));
    expect(find.textContaining('28 bag'), findsWidgets);
    await tester.pumpWidget(view(ForecastWindow.next28Days,
      shownPage: seasonalPage, model: 'seasonal_experimental'));
    expect(find.textContaining('161.24'), findsNothing);
    await tester.pumpWidget(view(ForecastWindow.next28Days, scopeKey: 'unit:pcs'));
    expect(find.textContaining('161.24'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved snapshots use the original dashboard chart and partial coverage', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final item = product(id: 'saved', name: 'Saved product', category: 'Tools', unit: 'pcs');
    final page = ForecastSnapshotPage(page: 1, pageSize: 25, totalCount: 38, pageCount: 2, items: [
      ForecastSnapshotItem(status: 'stale', product: {'product_id': 'saved', 'location_id': 'location-1', 'name': 'Saved product', 'unit': 'pcs'}, job: const {},
        snapshot: {'summary': {'daily': List.generate(28, (i) => {'date': DateTime.utc(2026, 11, 13).add(Duration(days: i)).toIso8601String(), 'quantity': 2})}}),
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child:
      ForecastOverviewDashboard(snapshot: snapshot(products: [item], analyses: {}), savedPage: page,
        products: [item], selectedWindow: ForecastWindow.next7Days, onWindowChanged: (_) {}, onScopeChanged: (_) {}),
    ))));
    expect(find.byKey(const Key('forecast-overview-dashboard')), findsOneWidget);
    expect(find.byKey(const Key('forecast-primary-demand-chart')), findsOneWidget);
    expect(find.textContaining('14 pcs'), findsWidgets);
    expect(find.textContaining('Totals below cover this page only'), findsOneWidget);
    expect(find.textContaining('Includes stale saved forecasts'), findsOneWidget);
    expect(find.text('Saved product forecasts'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing saved summaries do not display zero demand', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final item = product(id: 'missing', name: 'Missing product', category: 'Tools', unit: 'pcs');
    final page = ForecastSnapshotPage(page: 1, pageSize: 25, totalCount: 1, pageCount: 1, items: [
      ForecastSnapshotItem(status: 'not_prepared', product: {'product_id': 'missing', 'location_id': 'location-1', 'name': 'Missing product', 'unit': 'pcs'}, job: const {}),
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child:
      ForecastOverviewDashboard(snapshot: snapshot(products: [item], analyses: {}), savedPage: page,
        products: [item], selectedWindow: ForecastWindow.next7Days, onWindowChanged: (_) {}),
    ))));
    expect(find.textContaining('0 pcs'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
    final analyses = <String, ForecastAnalysis>{
      item.id: analysis(
        id: item.id,
        name: item.name,
        unit: item.unit,
        daily: List<double>.generate(28, (index) => index + 1),
      ),
    };
    var selected = ForecastWindow.next7Days;
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ForecastOverviewDashboard(
              snapshot: value,
              analyses: analyses,
              products: <InventoryItem>[item],
              selectedWindow: selected,
              onScopeChanged: (_) {},
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
    expect(
      find.byKey(const Key('forecast-overview-scope-selector')),
      findsOneWidget,
    );
    expect(find.text('Today'), findsNothing);
    expect(find.text('Short-term (7 days)'), findsOneWidget);
    expect(find.text('Planning (28 days)'), findsOneWidget);
    expect(
      find.byKey(const Key('forecast-primary-demand-chart')),
      findsOneWidget,
    );
    expect(find.text('Actual sales unavailable'), findsOneWidget);

    await tester.tap(find.byKey(const Key('forecast-overview-scope-selector')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const Key('forecast-scope-search')), findsOneWidget);
    expect(find.text('Inventory unit'), findsOneWidget);
    await tester.tap(find.text('Paint').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('forecast-scope-search')), findsNothing);

    await tester.tap(
      find.byKey(const Key('forecast-period-next28Days')),
      warnIfMissed: false,
    );
    expect(selected, ForecastWindow.next28Days);
  });

  testWidgets(
    'overview tables and sales gaps expand and collapse without modal UI',
    (tester) async {
      final products = List<InventoryItem>.generate(
        9,
        (index) => product(
          id: 'product-$index',
          name: 'Product $index',
          category: 'Category $index',
          unit: 'pcs',
        ),
      );
      final analyses = <String, ForecastAnalysis>{
        for (var index = 0; index < products.length; index++)
          products[index].id: analysis(
            id: products[index].id,
            name: products[index].name,
            unit: products[index].unit,
            daily: List<double>.filled(28, index < 7 ? 2 : 0),
            coldStart: index >= 7,
            status: index >= 7 ? 'needs_review' : 'recommend_order',
          ),
      };
      final value = snapshot(products: products, analyses: analyses);
      await tester.binding.setSurfaceSize(const Size(1300, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ForecastOverviewDashboard(
                snapshot: value,
                analyses: analyses,
                products: products,
                selectedWindow: ForecastWindow.next28Days,
                onWindowChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('View all recommendations'), findsOneWidget);
      expect(find.text('Product'), findsOneWidget);
      expect(find.text('On hand'), findsOneWidget);
      expect(find.text('Suggested restock'), findsOneWidget);
      expect(find.text('Show all 7'), findsOneWidget);

      await tester.tap(find.byKey(const Key('forecast-category-show-all')));
      await tester.pump();
      expect(find.text('Show fewer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('forecast-category-show-all')));
      await tester.pump();
      expect(find.text('Show all 7'), findsOneWidget);

      expect(find.text('Product 7'), findsNothing);
      await tester.tap(find.byKey(const Key('forecast-sales-gaps-toggle')));
      await tester.pump();
      expect(find.text('Product 7'), findsOneWidget);
      expect(find.text('Product 8'), findsOneWidget);
      await tester.tap(find.byKey(const Key('forecast-sales-gaps-toggle')));
      await tester.pump();
      expect(find.text('Product 7'), findsNothing);
    },
  );

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
    final analyses = <String, ForecastAnalysis>{
      item.id: analysis(
        id: item.id,
        name: item.name,
        unit: item.unit,
        daily: List<double>.filled(28, 2),
      ),
    };
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ForecastOverviewDashboard(
              snapshot: value,
              analyses: analyses,
              products: <InventoryItem>[item],
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
