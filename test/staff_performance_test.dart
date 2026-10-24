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
      'valid_timing_count': 3,
      'workload_points': 8.5,
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
    expect(sql, contains("lower(active_order.status) = 'pending'"));
    expect(sql, isNot(contains('create table')));
  });
}
