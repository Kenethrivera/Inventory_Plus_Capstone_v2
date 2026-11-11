import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_approval.dart';
import 'package:inventory_plus/logic/seasonal_learning_lab.dart';
import 'package:inventory_plus/services/forecasting_api_service.dart';
import 'package:inventory_plus/services/restock_recommendation_tracking_service.dart';

import 'forecasting_test_fixture.dart';

InventoryApprovalRequest restockRequest({
  InventoryApprovalStatus status = InventoryApprovalStatus.pending,
  String? transactionId,
}) => InventoryApprovalRequest(
  id: '11111111-1111-4111-8111-111111111111',
  locationId: 'location-1',
  locationName: 'Main Store',
  type: InventoryApprovalType.restock,
  status: status,
  requestedById: '7',
  requestedByName: 'Cashier',
  requestedByRole: 'cashier',
  requestedAt: DateTime.utc(2026, 11, 11, 1),
  productId: 'product-1',
  productName: 'Claw Hammer',
  productSku: 'HAMMER-01',
  unit: 'pcs',
  quantity: 20,
  stockAtRequest: 12,
  currentStock: status == InventoryApprovalStatus.approved ? 32 : 12,
  transactionId: transactionId,
);

class RecordingForecastApi implements ForecastingApiService {
  RecordingForecastApi({
    ForecastAnalysis? analysis,
    this.analysisError,
    this.matchError,
  }) : analysis =
           analysis ?? ForecastAnalysis.fromJson(forecastingAnalysisFixture());

  final ForecastAnalysis analysis;
  final ForecastApiException? analysisError;
  final ForecastApiException? matchError;
  final List<String> events = <String>[];
  final List<String> requestIds = <String>[];
  String? analyzedModel;
  String? matchedTransactionId;
  double? matchedQuantity;
  int saveCalls = 0;

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
    events.add('analyze');
    analyzedModel = model;
    if (analysisError case final error?) throw error;
    return analysis;
  }

  @override
  Future<RecommendationSnapshotSaveResult> saveRecommendationSnapshot({
    required String productId,
    required String locationId,
    required String sessionToken,
    required String requestId,
    required ForecastAnalysis analysis,
  }) async {
    events.add('save');
    requestIds.add(requestId);
    saveCalls++;
    return RecommendationSnapshotSaveResult(
      recommendationId: 41,
      requestId: requestId,
      reused: saveCalls > 1,
    );
  }

  @override
  Future<ReceiptAllocationResult> matchRecommendationReceipt({
    required int recommendationId,
    required String locationId,
    required String sessionToken,
    required String transactionHistoryId,
    required double allocatedInventoryQuantity,
  }) async {
    events.add('match');
    matchedTransactionId = transactionHistoryId;
    matchedQuantity = allocatedInventoryQuantity;
    if (matchError case final error?) throw error;
    return const ReceiptAllocationResult(reused: false);
  }

  @override
  Future<ReplenishmentConfiguration> getReplenishmentConfiguration({
    required String productId,
    required String locationId,
    required String sessionToken,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<RecommendationTrackingItem>> loadRecommendationTracking({
    required String locationId,
    required String sessionToken,
    String? productId,
  }) => throw UnsupportedError('not used');

  @override
  Future<ForecastPerformanceReport> loadForecastPerformance({
    required String productId,
    required String locationId,
    required String sessionToken,
  }) => throw UnsupportedError('not used');

  @override
  Future<SeasonalLearningLabReport> loadSeasonalLearningLab({
    required String sessionToken,
    String? productId,
  }) => throw UnsupportedError('not used');

  @override
  Future<RecommendationReconciliationResult> reconcileRecommendation({
    required int recommendationId,
    required String locationId,
    required String sessionToken,
    required String requestId,
    required bool confirmNoReceipts,
    String? confirmationNote,
  }) => throw UnsupportedError('not used');

  @override
  Future<ReplenishmentConfiguration> saveReplenishmentConfiguration({
    required String productId,
    required String locationId,
    required String sessionToken,
    required ReplenishmentConfigurationInput configuration,
  }) => throw UnsupportedError('not used');
}

void main() {
  test(
    'saves trusted LightGBM snapshot before mutation and matches exact receipt',
    () async {
      final api = RecordingForecastApi();
      final coordinator = RestockRecommendationTrackingCoordinator(api: api);
      final request = restockRequest();

      final result = await coordinator.approveAndTrack(
        request: request,
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        approveRestock: () async {
          api.events.add('mutate');
          return restockRequest(
            status: InventoryApprovalStatus.approved,
            transactionId: '22222222-2222-4222-8222-222222222222',
          );
        },
      );

      expect(api.events, <String>['analyze', 'save', 'mutate', 'match']);
      expect(api.analyzedModel, 'lightgbm');
      expect(api.requestIds.single, request.id);
      expect(api.matchedTransactionId, '22222222-2222-4222-8222-222222222222');
      expect(api.matchedQuantity, 20);
      expect(result.receiptMatched, isTrue);
    },
  );

  test(
    'tracking failure occurs before mutation and can be explicitly handled',
    () async {
      final api = RecordingForecastApi(
        analysisError: const ForecastApiException(
          'Tracking disabled',
          statusCode: 503,
        ),
      );
      final coordinator = RestockRecommendationTrackingCoordinator(api: api);
      var mutated = false;

      await expectLater(
        coordinator.approveAndTrack(
          request: restockRequest(),
          locationId: 'location-1',
          sessionToken: 'opaque-session-token',
          approveRestock: () async {
            mutated = true;
            return restockRequest(status: InventoryApprovalStatus.approved);
          },
        ),
        throwsA(isA<RestockTrackingUnavailableException>()),
      );

      expect(mutated, isFalse);
      expect(api.events, <String>['analyze']);
    },
  );

  test(
    'failed restock leaves saved snapshot pending and never allocates receipt',
    () async {
      final api = RecordingForecastApi();
      final coordinator = RestockRecommendationTrackingCoordinator(api: api);

      await expectLater(
        coordinator.approveAndTrack(
          request: restockRequest(),
          locationId: 'location-1',
          sessionToken: 'opaque-session-token',
          approveRestock: () async {
            api.events.add('mutate');
            throw StateError('Database rejected restock');
          },
        ),
        throwsA(isA<RestockMutationAfterSnapshotException>()),
      );

      expect(api.events, <String>['analyze', 'save', 'mutate']);
      expect(api.matchedTransactionId, isNull);
    },
  );

  test(
    'successful restock with allocation failure is reported as tracking pending',
    () async {
      final api = RecordingForecastApi(
        matchError: const ForecastApiException(
          'Receipt allocation unavailable',
          statusCode: 503,
        ),
      );
      final coordinator = RestockRecommendationTrackingCoordinator(api: api);

      final result = await coordinator.approveAndTrack(
        request: restockRequest(),
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        approveRestock: () async => restockRequest(
          status: InventoryApprovalStatus.approved,
          transactionId: '22222222-2222-4222-8222-222222222222',
        ),
      );

      expect(result.approvedRequest.status, InventoryApprovalStatus.approved);
      expect(result.receiptMatched, isFalse);
      expect(result.receiptTrackingError, 'Receipt allocation unavailable');
    },
  );

  test(
    'retry reuses approval request UUID and does not invent another key',
    () async {
      final api = RecordingForecastApi();
      final coordinator = RestockRecommendationTrackingCoordinator(api: api);
      final request = restockRequest();

      await expectLater(
        coordinator.approveAndTrack(
          request: request,
          locationId: 'location-1',
          sessionToken: 'opaque-session-token',
          approveRestock: () async => throw StateError('Temporary failure'),
        ),
        throwsA(isA<RestockMutationAfterSnapshotException>()),
      );
      final result = await coordinator.approveAndTrack(
        request: request,
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        approveRestock: () async => restockRequest(
          status: InventoryApprovalStatus.approved,
          transactionId: '22222222-2222-4222-8222-222222222222',
        ),
      );

      expect(api.requestIds, <String>[request.id, request.id]);
      expect(result.snapshotReused, isTrue);
    },
  );

  test(
    'zero recommendation remains valid and seasonal model is never requested',
    () async {
      final payload = forecastingAnalysisFixture();
      final insight =
          payload['preliminary_restocking_insight'] as Map<String, dynamic>;
      insight['predicted_demand'] = 5;
      insight['available_inventory'] = 12;
      insight['suggested_restock_quantity'] = 0;
      final api = RecordingForecastApi(
        analysis: ForecastAnalysis.fromJson(payload),
      );
      final coordinator = RestockRecommendationTrackingCoordinator(api: api);

      final result = await coordinator.approveAndTrack(
        request: restockRequest(),
        locationId: 'location-1',
        sessionToken: 'opaque-session-token',
        approveRestock: () async => restockRequest(
          status: InventoryApprovalStatus.approved,
          transactionId: '22222222-2222-4222-8222-222222222222',
        ),
      );

      expect(api.analyzedModel, 'lightgbm');
      expect(result.receiptMatched, isTrue);
    },
  );

  test('final confirmation gates tracking and manual save UI is removed', () {
    final approvalSource = File(
      'lib/ui/approval_center_page.dart',
    ).readAsStringSync();
    final forecastSource = File(
      'lib/ui/forecasting_page.dart',
    ).readAsStringSync();

    expect(
      approvalSource.indexOf('if (confirmed != true || !mounted) return;'),
      lessThan(approvalSource.indexOf('_approveRestockWithTracking(')),
    );
    expect(forecastSource, isNot(contains('Save recommendation')));
    expect(forecastSource, isNot(contains('save-preliminary-recommendation')));
  });
}
