import 'package:flutter/foundation.dart';

enum StaffPerformanceRole { helpers, cashiers }

extension StaffPerformanceRoleLabel on StaffPerformanceRole {
  String get label =>
      this == StaffPerformanceRole.helpers ? 'Helpers' : 'Cashiers';

  String get rpcValue =>
      this == StaffPerformanceRole.helpers ? 'helper' : 'cashier';
}

/// Reviewable V1 constants. The reporting RPC mirrors these values in one
/// constants CTE so neither layer scatters scoring magic numbers.
abstract final class StaffPerformanceV1 {
  static const int helperDelayMinutes = 30;
  static const int cashierDelayMinutes = 15;
  static const int minimumScoredSample = 5;

  static const double onTimeWeight = 0.40;
  static const double throughputWeight = 0.30;
  static const double efficiencyWeight = 0.20;
  static const double reliabilityWeight = 0.10;

  static const double baseComplexity = 1;
  static const double lineComplexity = 1;
  static const double locationStep = 0.50;
  static const double gcashComplexity = 0.50;
  static const double discountedComplexity = 0.50;
  static const double approvedDiscountComplexity = 1;

  static double quantityBurden(double quantity) {
    if (quantity <= 1) return 0;
    if (quantity <= 5) return 0.25;
    if (quantity <= 10) return 0.50;
    if (quantity <= 20) return 0.75;
    return 1;
  }

  static double percentageShare(num numerator, num denominator) {
    if (denominator <= 0) return 0;
    return numerator * 100 / denominator;
  }

  static double? contributionIndex({
    required double workloadShare,
    required double? activeTimeShare,
  }) {
    if (activeTimeShare == null || activeTimeShare <= 0) return null;
    return workloadShare / activeTimeShare;
  }

  static double weightedScore({
    required double onTime,
    required double adjustedThroughput,
    required double adjustedEfficiency,
    required double reliability,
  }) =>
      onTime * onTimeWeight +
      adjustedThroughput * throughputWeight +
      adjustedEfficiency * efficiencyWeight +
      reliability * reliabilityWeight;

  /// Matches PostgreSQL `percent_rank` for an ascending same-cohort value.
  /// A one-person or no-spread cohort uses the V1 neutral score explicitly.
  static double normalizedPeerScore({
    required double value,
    required Iterable<double> eligiblePeerValues,
  }) {
    final peers = eligiblePeerValues.toList()..sort();
    if (peers.length <= 1 || peers.first == peers.last) return 50;
    final lowerCount = peers.where((peer) => peer < value).length;
    return lowerCount * 100 / (peers.length - 1);
  }

  static bool isValidDuration(DateTime? startedAt, DateTime? finishedAt) =>
      startedAt != null &&
      finishedAt != null &&
      !finishedAt.isBefore(startedAt);

  static String bandFor(double? score) {
    if (score == null) return 'Insufficient data';
    if (score >= 90) return 'Excellent';
    if (score >= 80) return 'Strong';
    if (score >= 70) return 'Good';
    if (score >= 60) return 'Developing';
    return 'Needs Review';
  }
}

@immutable
class StaffPerformanceRecord {
  const StaffPerformanceRecord({
    required this.employeeId,
    required this.employeeName,
    required this.role,
    required this.isActive,
    required this.completedCount,
    required this.orderShare,
    required this.validTimingCount,
    required this.excludedTimingCount,
    required this.workloadPoints,
    required this.workloadShare,
    required this.onTimeCount,
    required this.totalServiceMinutes,
    required this.timedWorkloadPoints,
    required this.averageMinutes,
    required this.medianMinutes,
    required this.fastestMinutes,
    required this.onTimeRate,
    required this.delayedCount,
    required this.delayRate,
    required this.reliability,
    required this.efficiency,
    required this.adjustedThroughput,
    required this.adjustedEfficiency,
    required this.activeHours,
    required this.activeTimeShare,
    required this.contributionIndex,
    required this.currentWorkload,
    required this.salesHandled,
    required this.discountedTransactions,
    required this.discountUsageRate,
    required this.discountApprovalRequests,
    required this.discountApprovalsApproved,
    required this.discountApprovalsRejected,
    required this.discountApprovalsPending,
    required this.score,
    required this.peerCount,
  });

  final String employeeId;
  final String employeeName;
  final StaffPerformanceRole role;
  final bool isActive;
  final int completedCount;
  final double orderShare;
  final int validTimingCount;
  final int excludedTimingCount;
  final double workloadPoints;
  final double workloadShare;
  final int onTimeCount;
  final double totalServiceMinutes;
  final double timedWorkloadPoints;
  final double? averageMinutes;
  final double? medianMinutes;
  final double? fastestMinutes;
  final double onTimeRate;
  final int delayedCount;
  final double delayRate;
  final double reliability;

  /// Raw complexity points completed per valid service minute.
  final double? efficiency;

  /// Same-role/location/period peer-normalized score used by the final score.
  final double? adjustedThroughput;

  /// Same-role/location/period peer-normalized score used by the final score.
  final double? adjustedEfficiency;
  final double? activeHours;
  final double? activeTimeShare;
  final double? contributionIndex;
  final int currentWorkload;
  final double salesHandled;
  final int discountedTransactions;
  final double discountUsageRate;
  final int discountApprovalRequests;
  final int discountApprovalsApproved;
  final int discountApprovalsRejected;
  final int discountApprovalsPending;
  final double? score;
  final int peerCount;

  String get scoreBand => StaffPerformanceV1.bandFor(score);
  bool get hasScoredSample => score != null;
  double get onTimeScoreContribution =>
      onTimeRate * StaffPerformanceV1.onTimeWeight;
  double? get throughputScoreContribution => adjustedThroughput == null
      ? null
      : adjustedThroughput! * StaffPerformanceV1.throughputWeight;
  double? get efficiencyScoreContribution => adjustedEfficiency == null
      ? null
      : adjustedEfficiency! * StaffPerformanceV1.efficiencyWeight;
  double get reliabilityScoreContribution =>
      reliability * StaffPerformanceV1.reliabilityWeight;

  factory StaffPerformanceRecord.fromJson(
    Map<String, dynamic> json,
    StaffPerformanceRole role,
  ) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    double? optionalNumber(String key) => (json[key] as num?)?.toDouble();
    int integer(String key) => (json[key] as num?)?.toInt() ?? 0;

    return StaffPerformanceRecord(
      employeeId: json['employee_id']?.toString() ?? '',
      employeeName: json['employee_name']?.toString().trim().isNotEmpty == true
          ? json['employee_name'].toString().trim()
          : 'Former staff member',
      role: role,
      isActive: json['is_active'] == true,
      completedCount: integer('completed_count'),
      orderShare: number('order_share'),
      validTimingCount: integer('valid_timing_count'),
      excludedTimingCount: integer('excluded_timing_count'),
      workloadPoints: number('workload_points'),
      workloadShare: number('workload_share'),
      onTimeCount: integer('on_time_count'),
      totalServiceMinutes: number('total_service_minutes'),
      timedWorkloadPoints: number('timed_workload_points'),
      averageMinutes: optionalNumber('average_minutes'),
      medianMinutes: optionalNumber('median_minutes'),
      fastestMinutes: optionalNumber('fastest_minutes'),
      onTimeRate: number('on_time_rate'),
      delayedCount: integer('delayed_count'),
      delayRate: number('delay_rate'),
      reliability: number('reliability'),
      efficiency: optionalNumber('efficiency'),
      adjustedThroughput: optionalNumber('adjusted_throughput'),
      adjustedEfficiency: optionalNumber('adjusted_efficiency'),
      activeHours: optionalNumber('active_hours'),
      activeTimeShare: optionalNumber('active_time_share'),
      contributionIndex: optionalNumber('contribution_index'),
      currentWorkload: integer('current_workload'),
      salesHandled: number('sales_handled'),
      discountedTransactions: integer('discounted_transactions'),
      discountUsageRate: number('discount_usage_rate'),
      discountApprovalRequests: integer('discount_approval_requests'),
      discountApprovalsApproved: integer('discount_approvals_approved'),
      discountApprovalsRejected: integer('discount_approvals_rejected'),
      discountApprovalsPending: integer('discount_approvals_pending'),
      score: optionalNumber('score'),
      peerCount: integer('peer_count'),
    );
  }
}

@immutable
class StaffPerformanceSnapshot {
  const StaffPerformanceSnapshot({
    required this.role,
    required this.periodStart,
    required this.periodEnd,
    required this.records,
    required this.loadedAt,
    required this.totalStoreOrders,
    required this.totalRoleHandledOrders,
    required this.totalRoleWorkloadPoints,
    required this.unattributedOrderCount,
    required this.totalValidTimingCount,
    required this.totalExcludedTimingCount,
    required this.activeHoursAvailable,
    required this.totalRoleActiveHours,
    required this.locationComplexityCoverage,
  });

  final StaffPerformanceRole role;
  final DateTime periodStart;
  final DateTime periodEnd;
  final List<StaffPerformanceRecord> records;
  final DateTime loadedAt;
  final int totalStoreOrders;
  final int totalRoleHandledOrders;
  final double totalRoleWorkloadPoints;
  final int unattributedOrderCount;
  final int totalValidTimingCount;
  final int totalExcludedTimingCount;
  final bool activeHoursAvailable;
  final double? totalRoleActiveHours;
  final String locationComplexityCoverage;

  factory StaffPerformanceSnapshot.fromJson(
    Map<String, dynamic> json, {
    required StaffPerformanceRole role,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    double? optionalNumber(String key) => (json[key] as num?)?.toDouble();
    int integer(String key) => (json[key] as num?)?.toInt() ?? 0;
    final rawRecords = json['records'] as List<dynamic>? ?? const [];
    return StaffPerformanceSnapshot(
      role: role,
      periodStart: periodStart,
      periodEnd: periodEnd,
      records: List<StaffPerformanceRecord>.unmodifiable(
        rawRecords.map(
          (row) => StaffPerformanceRecord.fromJson(
            Map<String, dynamic>.from(row as Map),
            role,
          ),
        ),
      ),
      loadedAt: DateTime.now(),
      totalStoreOrders: integer('total_store_orders'),
      totalRoleHandledOrders: integer('total_role_handled_orders'),
      totalRoleWorkloadPoints: number('total_role_workload_points'),
      unattributedOrderCount: integer('unattributed_order_count'),
      totalValidTimingCount: integer('total_valid_timing_count'),
      totalExcludedTimingCount: integer('total_excluded_timing_count'),
      activeHoursAvailable: json['active_hours_available'] == true,
      totalRoleActiveHours: optionalNumber('total_role_active_hours'),
      locationComplexityCoverage:
          json['location_complexity_coverage']?.toString() ??
          'Current product map locations when available',
    );
  }
}
