import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';
import 'package:inventory_plus/ui/forecast_jobs_view.dart';

ForecastJobsPage _page(String status) => ForecastJobsPage.fromJson({
  'page': 1, 'page_size': 25, 'total_count': 1, 'page_count': 1,
  'latest_only': true, 'generated_at': '2026-11-22T01:00:00Z',
  'counts': {'total_jobs': 1, 'queued': status == 'queued' ? 1 : 0,
    'retry_pending': 0, 'running': status == 'running' ? 1 : 0,
    'succeeded': status == 'succeeded' ? 1 : 0,
    'failed': status == 'failed' ? 1 : 0,
    'cancelled': 0, 'superseded': 0},
  'items': [{
    'job_id': 'job-1', 'product_id': 'product-1',
    'product_name': 'Simulation Paint', 'sku': 'SIM-NEU-001',
    'model_key': 'lightgbm', 'model_version': '1',
    'as_of_business_date': '2026-11-22', 'horizon_days': 28,
    'status': status, 'display_status': status,
    'created_at': '2026-11-22T01:00:00Z',
    'attempt_count': status == 'queued' ? 0 : 1, 'max_attempts': 3,
    'safe_error_code': status == 'failed' ? 'forecast_input_unavailable' : null,
    'result_id': status == 'succeeded' ? 'result-1' : null,
    'result_created_at': status == 'succeeded' ? '2026-11-22T01:02:00Z' : null,
  }],
});

class _JobsApi extends ForecastApiClient {
  _JobsApi() : super(baseUri: Uri.parse('https://forecast.example.test'));

  final responses = <ForecastJobsPage>[_page('queued'), _page('running'), _page('succeeded')];
  int reads = 0;
  int preparations = 0;

  @override
  Future<ForecastJobsPage> loadForecastJobs({required String sessionToken,
      required int page, required int pageSize, required bool latestOnly,
      String? search, String? model, String? status, String? fromDate,
      String? toDate}) async {
    final result = responses[reads < responses.length ? reads : responses.length - 1];
    reads++;
    return result;
  }

  @override
  Future<Map<String, dynamic>> prepareForecast({required String productId,
      required String sessionToken, String model = 'blend'}) async {
    preparations++;
    throw StateError('Monitoring must never prepare a forecast');
  }
}

void main() {
  testWidgets('job monitor refreshes authoritative transitions without preparing', (tester) async {
    final api = _JobsApi();
    final key = GlobalKey<ForecastJobsViewState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ForecastJobsView(key: key, api: api, sessionToken: 'session', active: true)))));
    await tester.pump();
    expect(find.text('Queued'), findsWidgets);
    expect(find.byTooltip('Refresh job statuses'), findsNothing);
    key.currentState!.refresh();
    await tester.pump();
    expect(find.text('Running'), findsWidgets);
    key.currentState!.refresh();
    await tester.pump();
    expect(find.text('Succeeded'), findsWidgets);
    expect(api.preparations, 0);
    expect(api.reads, 3);
  });
}
