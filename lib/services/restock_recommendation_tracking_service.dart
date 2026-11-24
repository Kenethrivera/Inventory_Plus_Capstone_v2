import 'dart:async';

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
    this.recommendationId,
    required this.snapshotReused,
    required this.receiptMatched,
    required this.allocationReused,
    this.receiptTrackingError,
    this.trackingUnavailableReason,
  });

  final InventoryApprovalRequest approvedRequest;
  final int? recommendationId;
  final bool snapshotReused;
  final bool receiptMatched;
  final bool allocationReused;
  final String? receiptTrackingError;
  final String? trackingUnavailableReason;
}

class RestockRecommendationTrackingCoordinator {
  const RestockRecommendationTrackingCoordinator({required this.api});

  final ForecastingApiService api;

  Future<AutomaticRestockTrackingResult> approveAndTrack({
    required InventoryApprovalRequest request,
    required String locationId,
    required String sessionToken,
    required Future<InventoryApprovalRequest> Function() approveRestock,
    void Function(String stage)? onStage,
    void Function(String stage, int milliseconds)? onStageDuration,
    bool deferReceiptMatch = false,
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

    RecommendationSnapshotSaveResult? snapshot;
    String? trackingUnavailableReason;
    final evidenceTimer = Stopwatch()..start();
    onStage?.call('Preparing forecast evidence');
    try {
      final saved = await api.loadProductSnapshot(
        productId: request.productId,
        locationId: locationId,
        sessionToken: sessionToken,
        model: 'lightgbm',
      ).timeout(const Duration(seconds: 7));
      onStageDuration?.call('saved_lightgbm_read', evidenceTimer.elapsedMilliseconds);
      if (saved.status != 'completed' || saved.analysis == null ||
          saved.snapshot == null) {
        throw const ForecastApiException(
          'Current saved LightGBM evidence is unavailable.');
      }
      final analysis = saved.analysis!;
      final businessDate = DateTime.now().toUtc().add(
        const Duration(hours: 8));
      final today = '${businessDate.year.toString().padLeft(4, '0')}-'
          '${businessDate.month.toString().padLeft(2, '0')}-'
          '${businessDate.day.toString().padLeft(2, '0')}';
      if (analysis.authorizedLocationId != locationId ||
          analysis.product.locationId != locationId ||
          analysis.product.productId != request.productId ||
          analysis.product.unit.toLowerCase() != request.unit.toLowerCase() ||
          saved.snapshot!['as_of_business_date']?.toString() != today ||
          analysis.forecast.requestedModel != 'lightgbm' ||
          analysis.forecast.periodStart != today ||
          analysis.forecast.horizonDays != 28) {
        throw const ForecastApiException(
          'Current LightGBM forecast does not match this restock request.',
        );
      }
      final preliminary = analysis.preliminaryRestockingInsight;
      if (preliminary.forecastModel != 'lightgbm' ||
          preliminary.usesExperimentalSeasonalForecast ||
          preliminary.planningHorizonDays != 28 ||
          preliminary.reliability != PreliminaryReliability.normal) {
        throw const ForecastApiException(
          'The approved LightGBM preliminary recommendation is unavailable.',
        );
      }
      onStage?.call('Saving recommendation snapshot');
      final snapshotTimer = Stopwatch()..start();
      try {
        snapshot = await api.saveRecommendationSnapshot(
          productId: request.productId,
          locationId: locationId,
          sessionToken: sessionToken,
          // Approval request IDs are UUIDs and remain stable across retries.
          requestId: request.id,
          analysis: analysis,
        );
      } finally {
        onStageDuration?.call('snapshot_save', snapshotTimer.elapsedMilliseconds);
      }
    } on ForecastApiException catch (error) {
      trackingUnavailableReason = error.isTimeout
          ? 'Snapshot save or forecast read timed out; tracking outcome is uncertain.'
          : error.message;
    } on FormatException catch (_) {
      trackingUnavailableReason = 'Saved forecast evidence could not be verified.';
    } on TimeoutException catch (_) {
      trackingUnavailableReason = 'Saved forecast read exceeded the 7-second preparation budget.';
    } catch (_) {
      trackingUnavailableReason = 'Forecast tracking could not be prepared.';
    } finally {
      onStageDuration?.call('evidence_total', evidenceTimer.elapsedMilliseconds);
    }

    onStage?.call('Approving restock');
    final approvalTimer = Stopwatch()..start();
    final approved = await approveRestock();
    onStageDuration?.call('approval_rpc_and_controller', approvalTimer.elapsedMilliseconds);

    if (snapshot == null) {
      return AutomaticRestockTrackingResult(
        approvedRequest: approved,
        snapshotReused: false,
        receiptMatched: false,
        allocationReused: false,
        trackingUnavailableReason: trackingUnavailableReason,
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

    if (deferReceiptMatch) {
      return AutomaticRestockTrackingResult(
        approvedRequest: approved,
        recommendationId: snapshot.recommendationId,
        snapshotReused: snapshot.reused,
        receiptMatched: false,
        allocationReused: false,
        receiptTrackingError: 'Receipt matching pending.',
      );
    }

    try {
      onStage?.call('Matching stock-in receipt');
      final matchingTimer = Stopwatch()..start();
      final allocation = await api.matchRecommendationReceipt(
        recommendationId: snapshot.recommendationId,
        locationId: locationId,
        sessionToken: sessionToken,
        transactionHistoryId: transactionId,
        allocatedInventoryQuantity: request.quantity,
      );
      onStageDuration?.call('receipt_matching', matchingTimer.elapsedMilliseconds);
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
    } catch (_) {
      return AutomaticRestockTrackingResult(
        approvedRequest: approved,
        recommendationId: snapshot.recommendationId,
        snapshotReused: snapshot.reused,
        receiptMatched: false,
        allocationReused: false,
        receiptTrackingError: 'Receipt matching is pending. Inventory approval remains complete.',
      );
    }
  }
}
