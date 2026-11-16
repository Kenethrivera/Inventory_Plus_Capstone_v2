import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_plus/data/ai_insights_service.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/history_pagination.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';
import 'package:inventory_plus/ui/forecasting_page.dart';
import 'forecasting_test_fixture.dart';

class RecoveryInventory extends Fake implements InventoryController {
  RecoveryInventory([this.items = const []]);
  final List<InventoryItem> items;
  final updates = StreamController<List<InventoryItem>>.broadcast();
  @override
  String? get activeLocationId => 'location-1';
  @override
  String? get currentUserId => 'admin-1';
  @override
  String get currentSessionToken => 'test-session';
  @override
  List<InventoryItem> get allItems => items;
  @override
  Stream<List<InventoryItem>> streamInventory() => updates.stream;
  @override
  Stream<HistoryInvalidation> get historyInvalidations => const Stream.empty();
}

void main() {
  testWidgets('saved overview keeps all unit scopes after filtered pages and navigation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inventory = RecoveryInventory([
      InventoryItem(id: 'pcs-1', name: 'Phillips Screwdriver', sku: 'SKU-1005', price: 10,
        quantity: 12, maxQuantity: 100, category: 'Tools', description: '', imageUrl: '', unit: 'pcs'),
      InventoryItem(id: 'bag-1', name: 'Cement', sku: 'CEM-1', price: 10,
        quantity: 12, maxQuantity: 100, category: 'Materials', description: '', imageUrl: '', unit: 'bag'),
      InventoryItem(id: 'kl-1', name: 'Adhesive', sku: 'ADH-1', price: 10,
        quantity: 12, maxQuantity: 100, category: 'Supplies', description: '', imageUrl: '', unit: 'kl'),
    ]);
    addTearDown(inventory.updates.close);
    final overviewUrls = <Uri>[];
    final api = ForecastApiClient(baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((request) async {
        expect(request.url.path.endsWith('/analysis'), isFalse);
        if (request.url.path.endsWith('/overview')) {
          overviewUrls.add(request.url);
          final unit = request.url.queryParameters['unit'];
          final pageNumber = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
          final rows = unit == 'bag' ? [
            {'status':'no_forecast','product':{'product_id':'bag-1','location_id':'location-1',
              'name':'Cement','unit':'bag','category':'Materials'},'job':{'status':'missing'}},
          ] : unit == 'kl' ? [
            {'status':'no_forecast','product':{'product_id':'kl-1','location_id':'location-1',
              'name':'Adhesive','unit':'kl','category':'Supplies'},'job':{'status':'missing'}},
          ] : unit == 'pcs' && pageNumber == 2 ? [
            {'status':'no_forecast','product':{'product_id':'pcs-2','location_id':'location-1',
              'name':'Another screwdriver','unit':'pcs','category':'Tools'},'job':{'status':'missing'}},
          ] : [
            {'status':'completed','product':{'product_id':'pcs-1','location_id':'location-1',
              'name':'Phillips Screwdriver','unit':'pcs','category':'Tools'},'job':{'status':'succeeded'},
              'snapshot':{'summary':{'next_7_day_demand':21,'next_28_day_demand':84,
                'daily':List.generate(28,(i)=>{'date':DateTime.utc(2026,11,14)
                  .add(Duration(days:i)).toIso8601String().split('T').first,'quantity':3})}}},
          ];
          return http.Response(jsonEncode({'page':pageNumber,'page_size':25,
            'total_count':unit == 'bag' ? 3 : unit == 'kl' ? 2 : 30,
            'page_count':unit == 'pcs' ? 2 : 1,'items':rows}),200);
        }
        return http.Response(jsonEncode({'status':'no_forecast',
          'product':{'product_id':'pcs-1','location_id':'location-1',
            'name':'Phillips Screwdriver','unit':'pcs'},'job':{'status':'missing'}}),200);
      }));
    await tester.pumpWidget(MaterialApp(home: ForecastingPage(controller: inventory,
      aiService: AIInsightsService(), isActive: true, forecastApi: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('84 pcs'), findsWidgets);
    Future<void> selectScope(String label) async {
      await tester.tap(find.byKey(const Key('forecast-overview-scope-selector')));
      await tester.pumpAndSettle();
      expect(find.text('All pcs'), findsWidgets);
      expect(find.text('All bag'), findsWidgets);
      expect(find.text('All kl'), findsWidgets);
      if (label == 'Phillips Screwdriver') {
        await tester.enterText(find.byKey(const Key('forecast-scope-search')), 'Phillips');
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }
    await selectScope('All bag');
    expect(overviewUrls.last.queryParameters['unit'], 'bag');
    expect(find.textContaining('84 pcs'), findsNothing);
    await selectScope('All kl');
    expect(overviewUrls.last.queryParameters['unit'], 'kl');
    await selectScope('All pcs');
    expect(overviewUrls.last.queryParameters['unit'], 'pcs');
    expect(find.textContaining('84 pcs'), findsWidgets);
    await tester.ensureVisible(find.byTooltip('Next page'));
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(overviewUrls.last.queryParameters['page'], '2');
    await tester.tap(find.byKey(const Key('forecast-overview-scope-selector')));
    await tester.pumpAndSettle();
    expect(find.text('All bag'), findsWidgets);
    expect(find.text('All kl'), findsWidgets);
    await tester.tap(find.text('All pcs').last);
    await tester.pumpAndSettle();
    await selectScope('All bag');
    await selectScope('Tools');
    expect(overviewUrls.last.queryParameters['unit'], 'pcs');
    await selectScope('Phillips Screwdriver');
    expect(overviewUrls.last.queryParameters['search'], 'SKU-1005');
    await selectScope('All bag');
    expect(overviewUrls.last.queryParameters.containsKey('search'), isFalse);
    await tester.tap(find.byKey(const Key('forecast-view-product')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forecast-view-overview')));
    await tester.pumpAndSettle();
    await selectScope('All pcs');
    expect(find.textContaining('84 pcs'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page lifecycle reads snapshots once and never calls analysis', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inventory = RecoveryInventory();
    addTearDown(inventory.updates.close);
    final calls = <Uri>[];
    final api = ForecastApiClient(
      baseUri: Uri.parse('https://forecast.example.test'),
      client: MockClient((request) async {
        calls.add(request.url);
        expect(request.url.path, '/v1/forecasting/snapshots/overview');
        return http.Response(jsonEncode({
          'page': 1, 'page_size': 25, 'total_count': 0, 'page_count': 0, 'items': [],
        }), 200);
      }),
    );
    final ai = AIInsightsService();
    Widget host(bool active) => MaterialApp(home: ForecastingPage(
      controller: inventory, aiService: ai, isActive: active, forecastApi: api,
    ));
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('forecast-overview-dashboard')), findsOneWidget);
    inventory.updates.add(const []);
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(false));
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Generate queues one product then polls saved completion into original chart', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inventory = RecoveryInventory([InventoryItem(id: 'product-1', name: 'Claw Hammer', sku: 'HAMMER-01',
      price: 10, quantity: 12, maxQuantity: 100, category: 'Tools', description: '', imageUrl: '', unit: 'pcs')]);
    addTearDown(inventory.updates.close);
    var requested = false;
    var productReads = 0;
    var postCount = 0;
    var overviewReads = 0;
    final api = ForecastApiClient(baseUri: Uri.parse('https://forecast.example.test'), client: MockClient((request) async {
      expect(request.url.path.endsWith('/analysis'), isFalse);
      if (request.url.path.endsWith('/overview')) {
        overviewReads++;
        final complete = requested && productReads >= 3;
        return http.Response(jsonEncode({'page':1,'page_size':25,'total_count':1,'page_count':1,
          'items': complete ? [{'status':'completed',
            'product':{'product_id':'product-1','location_id':'location-1','name':'Claw Hammer','unit':'pcs'},
            'job':{'status':'succeeded'},
            'snapshot':{'summary':{'next_7_day_demand':21,'next_28_day_demand':84,
              'daily':List.generate(28,(i)=>{'date':DateTime.utc(2026,11,14).add(Duration(days:i)).toIso8601String().split('T').first,'quantity':3})}},
          }] : []}),200);
      }
      if (request.method == 'POST') {
        postCount++;
        requested = true;
        expect(request.url.queryParameters['product_id'], 'product-1');
        return http.Response(jsonEncode({'queued':1,'duplicate':0,'jobs':[{'status':'queued'}]}),200);
      }
      productReads++;
      final complete = requested && productReads >= 3;
      return http.Response(jsonEncode({'status':complete ? 'completed' : requested ? 'queued' : 'not_prepared',
        'product':{'product_id':'product-1','location_id':'location-1','name':'Claw Hammer','unit':'pcs'},
        'job':{'status':complete ? 'succeeded' : requested ? 'queued' : 'missing'},
        if(complete) 'analysis':forecastingAnalysisFixture(),
      }),200);
    }));
    await tester.pumpWidget(MaterialApp(home: ForecastingPage(controller:inventory,
      aiService:AIInsightsService(),isActive:true,forecastApi:api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forecast-view-product')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forecast-product-picker-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claw Hammer').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate / Refresh forecast'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds:5));
    await tester.pumpAndSettle();
    expect(postCount,1);
    expect(productReads,3);
    expect(find.byKey(const Key('product-demand-trend')),findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('forecast-total'))).data,'84 pcs');
    await tester.tap(find.byKey(const Key('forecast-view-overview')));
    await tester.pumpAndSettle();
    expect(overviewReads, 2);
    expect(find.textContaining('84 pcs'), findsWidgets);
    await tester.tap(find.byKey(const Key('forecast-view-product')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forecast-view-overview')));
    await tester.pumpAndSettle();
    expect(overviewReads, 2);
    await tester.pump(const Duration(seconds:15));
    expect(productReads,3);
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });

}
