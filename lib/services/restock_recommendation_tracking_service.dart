import '../logic/inventory_approval.dart';
import 'forecasting_api_service.dart';

class RestockTrackingUnavailableException implements Exception {
  const RestockTrackingUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RestockMutationAfterSnapshotException implements Exception {
  const RestockMutationAfterSnapshotException({
    required this.cause,
    required this.recommendationId,
  });

  final Object cause;
  final int recommendationId;

  @override
  String toString() =>
      'The recommendation was saved, but the inventory restock failed.';
}

class AutomaticRestockTrackingResult {
  const AutomaticRestockTrackingResult({
    required this.approvedRequest,
    required this.recommendationId,
    required this.snapshotReused,
    required this.receiptMatched,
    required this.allocationReused,
    this.receiptTrackingError,
  });

  final InventoryApprovalRequest approvedRequest;
  final int recommendationId;
  final bool snapshotReused;
  final bool receiptMatched;
  final bool allocationReused;
  final String? receiptTrackingError;
}

class RestockRecommendationTrackingCoordinator {
  const RestockRecommendationTrackingCoordinator({required this.api});

  final ForecastingApiService api;

  Future<AutomaticRestockTrackingResult> approveAndTrack({
    required InventoryApprovalRequest request,
    required String locationId,
    required String sessionToken,
    required Future<InventoryApprovalRequest> Function() approveRestock,
  }) async {
    if (request.type != InventoryApprovalType.restock ||
        request.status != InventoryApprovalStatus.pending) {
      throw ArgumentError(
        'Automatic recommendation tracking requires a pending restock request.',
      );
    }
    if (request.locationId != locationId) {
      throw StateError('The restock request is outside the active location.');
    }
    if (!request.quantity.isFinite || request.quantity <= 0) {
      throw ArgumentError.value(
        request.quantity,
        'request.quantity',
        'Restock quantity must be positive.',
      );
    }

    late final ForecastAnalysis analysis;
    late final RecommendationSnapshotSaveResult snapshot;
    try {
      analysis = await api.analyze(
        productId: request.productId,
        locationId: locationId,
        sessionToken: sessionToken,
        model: 'lightgbm',
        horizonDays: 28,
      );
      if (analysis.authorizedLocationId != locationId ||
          analysis.product.locationId != locationId ||
          analysis.product.productId != request.productId) {
        throw const ForecastApiException(
          'The trusted forecast scope did not match the restock request.',
        );
      }
      final preliminary = analysis.preliminaryRestockingInsight;
      if (preliminary.forecastModel != 'lightgbm' ||
          preliminary.usesExperimentalSeasonalForecast ||
          preliminary.planningHorizonDays != 28) {
        throw const ForecastApiException(
          'The approved LightGBM preliminary recommendation is unavailable.',
        );
      }
      snapshot = await api.saveRecommendationSnapshot(
        productId: request.productId,
        locationId: locationId,
        sessionToken: sessionToken,
        // Approval request IDs are UUIDs and remain stable across retries.
        requestId: request.id,
        analysis: analysis,
      );
    } on ForecastApiException catch (error) {
      throw RestockTrackingUnavailableException(error.message);
    } on FormatException catch (error) {
      throw RestockTrackingUnavailableException(error.message);
    }

    late final InventoryApprovalRequest approved;
    try {
      approved = await approveRestock();
    } catch (error) {
      throw RestockMutationAfterSnapshotException(
        cause: error,
        recommendationId: snapshot.recommendationId,
      );
    }

    final transactionId = approved.transactionId?.trim() ?? '';
    if (approved.status != InventoryApprovalStatus.approved ||
        approved.type != InventoryApprovalType.restock ||
        transactionId.isEmpty) {
      return AutomaticRestockTrackingResult(
        approvedRequest: approved,
        recommendationId: snapshot.recommendationId,
        snapshotReused: snapshot.reused,
        receiptMatched: false,
        allocationReused: false,
        receiptTrackingError:
            'The approved restock did not return its stock receipt identifier.',
      );
    }

    try {
      final allocation = await api.matchRecommendationReceipt(
        recommendationId: snapshot.recommendationId,
        locationId: locationId,
        sessionToken: sessionToken,
        transactionHistoryId: transactionId,
        allocatedInventoryQuantity: request.quantity,
      );
      return AutomaticRestockTrackingResult(
        approvedRequest: approved,
        recommendationId: snapshot.recommendationId,
        snapshotReused: snapshot.reused,
        receiptMatched: true,
        allocationReused: allocation.reused,
      );
    } on ForecastApiException catch (error) {
      return AutomaticRestockTrackingResult(
        approvedRequest: approved,
        recommendationId: snapshot.recommendationId,
        snapshotReused: snapshot.reused,
        receiptMatched: false,
        allocationReused: false,
        receiptTrackingError: error.message,
      );
    }
  }
}
