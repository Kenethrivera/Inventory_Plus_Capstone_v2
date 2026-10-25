import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/staff_performance.dart';
import 'package:inventory_plus/navigation/main_section.dart';

void main() {
  group('Staff Performance V1 constants', () {
    test('quantity burden uses the documented per-line bands', () {
      expect(StaffPerformanceV1.quantityBurden(1), 0);
      expect(StaffPerformanceV1.quantityBurden(1.01), 0.25);
      expect(StaffPerformanceV1.quantityBurden(5), 0.25);
      expect(StaffPerformanceV1.quantityBurden(10), 0.50);
      expect(StaffPerformanceV1.quantityBurden(20), 0.75);
      expect(StaffPerformanceV1.quantityBurden(20.01), 1.00);
    });

    test('order and workload shares retain their actual denominators', () {
      expect(StaffPerformanceV1.percentageShare(35, 100), 35);
      expect(
        StaffPerformanceV1.percentageShare(80, 300),
        closeTo(26.6667, 0.001),
      );
      expect(StaffPerformanceV1.percentageShare(0, 0), 0);
    });

    test('Contribution Index requires reliable active-time share', () {
      expect(
        StaffPerformanceV1.contributionIndex(
          workloadShare: 35,
          activeTimeShare: 25,
        ),
        1.4,
      );
      expect(
        StaffPerformanceV1.contributionIndex(
          workloadShare: 35,
          activeTimeShare: null,
        ),
        isNull,
      );
      expect(
        StaffPerformanceV1.contributionIndex(
          workloadShare: 35,
          activeTimeShare: 0,
        ),
        isNull,
      );
    });

    test('Helper score uses the documented weighted formula', () {
      expect(
        StaffPerformanceV1.weightedScore(
          onTime: 92,
          adjustedThroughput: 85,
          adjustedEfficiency: 80,
          reliability: 92,
        ),
        closeTo(87.5, 0.0001),
      );
    });

    test('Cashier score uses the same documented weighted formula', () {
      expect(
        StaffPerformanceV1.weightedScore(
          onTime: 80,
          adjustedThroughput: 70,
          adjustedEfficiency: 60,
          reliability: 90,
        ),
        closeTo(74, 0.0001),
      );
    });

    test('invalid reverse and missing durations are excluded', () {
      final start = DateTime.utc(2026, 10, 25, 8);
      expect(
        StaffPerformanceV1.isValidDuration(
          start,
          start.add(const Duration(minutes: 5)),
        ),
        isTrue,
      );
      expect(
        StaffPerformanceV1.isValidDuration(
          start,
          start.subtract(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(StaffPerformanceV1.isValidDuration(null, start), isFalse);
    });

    test('peer normalization uses only the supplied same-role cohort', () {
      expect(
        StaffPerformanceV1.normalizedPeerScore(
          value: 20,
          eligiblePeerValues: const [10, 20, 30],
        ),
        50,
      );
      expect(
        StaffPerformanceV1.normalizedPeerScore(
          value: 30,
          eligiblePeerValues: const [10, 20, 30],
        ),
        100,
      );
    });

    test('one-person cohort uses the explicit neutral peer score', () {
      expect(
        StaffPerformanceV1.normalizedPeerScore(
          value: 42,
          eligiblePeerValues: const [42],
        ),
        50,
      );
    });

    test('score bands and minimum sample language remain non-hostile', () {
      expect(StaffPerformanceV1.bandFor(null), 'Insufficient data');
      expect(StaffPerformanceV1.bandFor(59.9), 'Needs Review');
      expect(StaffPerformanceV1.bandFor(60), 'Developing');
      expect(StaffPerformanceV1.bandFor(70), 'Good');
      expect(StaffPerformanceV1.bandFor(80), 'Strong');
      expect(StaffPerformanceV1.bandFor(90), 'Excellent');
      expect(StaffPerformanceV1.minimumScoredSample, 5);
    });
  });

  test('RPC records preserve nullable scores and role-specific metrics', () {
    final record = StaffPerformanceRecord.fromJson(<String, dynamic>{
      'employee_id': '07',
      'employee_name': 'Cashier Ana',
      'completed_count': 3,
      'order_share': 30,
      'valid_timing_count': 3,
      'workload_points': 8.5,
      'workload_share': 28.3,
      'on_time_count': 3,
      'total_service_minutes': 12,
      'timed_workload_points': 8.5,
      'on_time_rate': 100,
      'reliability': 100,
      'sales_handled': 1250.75,
      'discounted_transactions': 1,
      'discount_approval_requests': 1,
      'discount_approvals_approved': 1,
      'score': null,
    }, StaffPerformanceRole.cashiers);

    expect(record.employeeId, '07');
    expect(record.score, isNull);
    expect(record.scoreBand, 'Insufficient data');
    expect(record.salesHandled, 1250.75);
    expect(record.discountApprovalsApproved, 1);
    expect(record.orderShare, 30);
    expect(record.workloadShare, 28.3);
    expect(record.totalServiceMinutes, 12);
  });

  test('Admin navigation exposes the performance route only to Admin', () {
    expect(MainSection.performance.routePath, '/main/performance');
    expect(MainSection.forRole('admin'), contains(MainSection.performance));
    expect(
      MainSection.forRole('helper'),
      isNot(contains(MainSection.performance)),
    );
    expect(
      MainSection.forRole('staff'),
      isNot(contains(MainSection.performance)),
    );
  });

  test('migration derives scores without creating a score table', () {
    final sql = File(
      'database/phase_4_staff_performance.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains('staff_performance_v1'));
    expect(sql, contains('private.order_complexity_v1'));
    expect(sql, contains('prepared_at >= p_period_start'));
    expect(sql, contains('completed_at >= p_period_start'));
    expect(sql, contains("'total_store_orders'"));
    expect(sql, contains("'total_role_workload_points'"));
    expect(sql, contains("'order_share'"));
    expect(sql, contains("'workload_share'"));
    expect(sql, contains("'contribution_index', null"));
    expect(sql, contains('history.prepared_at >= history.assigned_at'));
    expect(sql, contains('history.completed_at >= history.prepared_at'));
    expect(sql, contains("lower(active_order.status) = 'pending'"));
    expect(sql, isNot(contains('create table')));
  });
}
