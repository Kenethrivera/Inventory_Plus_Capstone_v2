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
    required this.validTimingCount,
    required this.excludedTimingCount,
    required this.workloadPoints,
    required this.averageMinutes,
    required this.medianMinutes,
    required this.fastestMinutes,
    required this.onTimeRate,
    required this.delayedCount,
    required this.delayRate,
    required this.reliability,
    required this.efficiency,
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
  final int validTimingCount;
  final int excludedTimingCount;
  final double workloadPoints;
  final double? averageMinutes;
  final double? medianMinutes;
  final double? fastestMinutes;
  final double onTimeRate;
  final int delayedCount;
  final double delayRate;
  final double reliability;
  final double? efficiency;
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
      validTimingCount: integer('valid_timing_count'),
      excludedTimingCount: integer('excluded_timing_count'),
      workloadPoints: number('workload_points'),
      averageMinutes: optionalNumber('average_minutes'),
      medianMinutes: optionalNumber('median_minutes'),
      fastestMinutes: optionalNumber('fastest_minutes'),
      onTimeRate: number('on_time_rate'),
      delayedCount: integer('delayed_count'),
      delayRate: number('delay_rate'),
      reliability: number('reliability'),
      efficiency: optionalNumber('efficiency'),
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
    required this.activeHoursAvailable,
    required this.locationComplexityCoverage,
  });

  final StaffPerformanceRole role;
  final DateTime periodStart;
  final DateTime periodEnd;
  final List<StaffPerformanceRecord> records;
  final DateTime loadedAt;
  final bool activeHoursAvailable;
  final String locationComplexityCoverage;

  factory StaffPerformanceSnapshot.fromJson(
    Map<String, dynamic> json, {
    required StaffPerformanceRole role,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) {
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
      activeHoursAvailable: json['active_hours_available'] == true,
      locationComplexityCoverage:
          json['location_complexity_coverage']?.toString() ??
          'Current product map locations when available',
    );
  }
}
