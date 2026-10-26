import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/staff_performance.dart';
import 'package:inventory_plus/ui/staff_performance_page.dart';

void main() {
  group('Staff Performance presentation ranking', () {
    test(
      'orders scored employees descending and leaves insufficient data last',
      () {
        final ranked = rankStaffPerformanceRecords([
          _record(id: 'low', name: 'Low', score: 71),
          _record(id: 'none', name: 'No Sample', score: null, valid: 2),
          _record(id: 'top', name: 'Top', score: 94),
          _record(id: 'second', name: 'Second', score: 86),
          _record(id: 'third', name: 'Third', score: 80),
        ]);

        expect(ranked.map((entry) => entry.record.employeeId), [
          'top',
          'second',
          'third',
          'low',
          'none',
        ]);
        expect(ranked.map((entry) => entry.rank), [1, 2, 3, 4, null]);
      },
    );

    testWidgets(
      'top three show medal badges and insufficient data has no rank',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  StaffPerformanceRankBadge(rank: 1),
                  StaffPerformanceRankBadge(rank: 2),
                  StaffPerformanceRankBadge(rank: 3),
                  StaffPerformanceRankBadge(rank: null),
                ],
              ),
            ),
          ),
        );

        expect(find.text('#1'), findsOneWidget);
        expect(find.text('#2'), findsOneWidget);
        expect(find.text('#3'), findsOneWidget);
        expect(find.byTooltip('Gold medal — rank #1'), findsOneWidget);
        expect(find.byTooltip('Silver medal — rank #2'), findsOneWidget);
        expect(find.byTooltip('Bronze medal — rank #3'), findsOneWidget);
        expect(find.byKey(const Key('staff-rank-unranked')), findsOneWidget);
        expect(find.text('#4'), findsNothing);
      },
    );
  });

  group('Staff Performance employee detail', () {
    testWidgets(
      'groups performance subsections and opens contribution details',
      (tester) async {
        final fixture = _fixture();
        await _pumpDetail(tester, fixture);

        expect(find.text('A. Data Basis'), findsOneWidget);
        expect(find.text('B. Speed'), findsOneWidget);
        expect(find.text('C. Timeliness & Delays'), findsOneWidget);
        expect(
          find.text('D. Complexity-Adjusted Productivity'),
          findsOneWidget,
        );

        final workloadShare = find.byKey(
          const Key('metric-row-Workload share'),
        );
        await tester.ensureVisible(workloadShare);
        await tester.tap(workloadShare);
        await tester.pumpAndSettle();

        expect(find.text('Workload share'), findsWidgets);
        expect(find.text('What it measures'), findsOneWidget);
        expect(find.text('Used in final score?'), findsOneWidget);
        expect(find.textContaining('90.00 / 300.00 × 100'), findsOneWidget);
      },
    );

    testWidgets('shows employee-specific On-Time formula', (tester) async {
      final fixture = _fixture();
      await _pumpDetail(tester, fixture);

      final onTime = find.byKey(const Key('metric-row-On-time rate'));
      await tester.ensureVisible(onTime);
      await tester.tap(onTime);
      await tester.pumpAndSettle();

      expect(find.textContaining('5 on-time / 5 valid × 100'), findsOneWidget);
      expect(find.textContaining('100.00 × 40% = 40.00'), findsOneWidget);
    });

    testWidgets('score header explains formula and actual result', (
      tester,
    ) async {
      final fixture = _fixture();
      await _pumpDetail(tester, fixture);

      final info = find.byTooltip('Explain Performance Score Breakdown');
      await tester.ensureVisible(info);
      await tester.tap(info);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Final Score = (On-Time × 40%)'),
        findsOneWidget,
      );
      expect(find.textContaining('= 91.50'), findsOneWidget);
    });

    testWidgets('Peer cohort row explains eligibility scope', (tester) async {
      final fixture = _fixture();
      await _pumpDetail(tester, fixture);

      final peer = find.byKey(const Key('metric-row-Peer cohort'));
      await tester.ensureVisible(peer);
      await tester.tap(peer);
      await tester.pumpAndSettle();

      expect(find.text('Peer cohort'), findsWidgets);
      expect(find.textContaining('same selected period'), findsOneWidget);
      expect(find.textContaining('at least 5 valid records'), findsOneWidget);
      expect(
        find.textContaining('Insufficient-data employees do not participate'),
        findsOneWidget,
      );
    });
  });

  testWidgets('Live Workload uses compact historical-separation layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StaffPerformanceLiveWorkloadCard(
            count: 3,
            periodLabel: 'October 2026',
          ),
        ),
      ),
    );

    expect(find.text('Live Workload'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('pending orders\ncurrently assigned'), findsOneWidget);
    expect(find.text('Live now • Separate from October 2026'), findsOneWidget);

    await tester.tap(find.byKey(const Key('live-workload-card')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('does not affect the historical score'),
      findsOneWidget,
    );
  });

  testWidgets('Data Confidence defaults to healthy collapsed state', (
    tester,
  ) async {
    final fixture = _fixture();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaffPerformanceDataConfidence(
            record: fixture.record,
            snapshot: fixture.snapshot,
          ),
        ),
      ),
    );

    expect(find.text('Data Confidence'), findsOneWidget);
    expect(find.textContaining('No data issues detected.'), findsOneWidget);
    expect(find.text('Audit details'), findsNothing);
  });

  testWidgets('Data Confidence warns and exposes audit details', (
    tester,
  ) async {
    final record = _record(
      id: 'helper-1',
      name: 'Mark',
      score: 91.5,
      excluded: 1,
    );
    final snapshot = _snapshot(record, excluded: 2, unattributed: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaffPerformanceDataConfidence(
            record: record,
            snapshot: snapshot,
          ),
        ),
      ),
    );

    expect(find.textContaining('3 records need attention.'), findsOneWidget);
    await tester.tap(find.text('View details'));
    await tester.pumpAndSettle();
    expect(find.text('Audit details'), findsOneWidget);
    expect(find.text('Employee timing records excluded'), findsOneWidget);
    expect(find.text('Period timing records excluded'), findsOneWidget);
  });
}

typedef _DetailFixture = ({
  StaffPerformanceRecord record,
  StaffPerformanceSnapshot snapshot,
});

_DetailFixture _fixture() {
  final record = _record(id: 'helper-1', name: 'Mark', score: 91.5);
  final peer = _record(
    id: 'helper-2',
    name: 'Kenneth',
    score: 80,
    workload: 75,
    adjustedThroughput: 70,
    adjustedEfficiency: 65,
  );
  return (record: record, snapshot: _snapshot(record, records: [record, peer]));
}

Future<void> _pumpDetail(WidgetTester tester, _DetailFixture fixture) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StaffPerformanceDetailContent(
            record: fixture.record,
            snapshot: fixture.snapshot,
            currentWorkload: 3,
            periodLabel: 'October 2026',
          ),
        ),
      ),
    ),
  );
}

StaffPerformanceRecord _record({
  required String id,
  required String name,
  required double? score,
  int valid = 5,
  int excluded = 0,
  double workload = 90,
  double adjustedThroughput = 85,
  double adjustedEfficiency = 80,
}) {
  return StaffPerformanceRecord.fromJson(<String, dynamic>{
    'employee_id': id,
    'employee_name': name,
    'is_active': true,
    'completed_count': 5,
    'order_share': 5,
    'valid_timing_count': valid,
    'excluded_timing_count': excluded,
    'workload_points': workload,
    'workload_share': 30,
    'on_time_count': valid,
    'total_service_minutes': 50,
    'timed_workload_points': workload,
    'average_minutes': 10,
    'median_minutes': 9,
    'fastest_minutes': 7,
    'on_time_rate': 100,
    'delayed_count': 0,
    'delay_rate': 0,
    'reliability': 100,
    'efficiency': workload / 50,
    'adjusted_throughput': score == null ? null : adjustedThroughput,
    'adjusted_efficiency': score == null ? null : adjustedEfficiency,
    'current_workload': 3,
    'sales_handled': 0,
    'discounted_transactions': 0,
    'discount_usage_rate': 0,
    'discount_approval_requests': 0,
    'discount_approvals_approved': 0,
    'discount_approvals_rejected': 0,
    'discount_approvals_pending': 0,
    'score': score,
    'peer_count': score == null ? 0 : 2,
  }, StaffPerformanceRole.helpers);
}

StaffPerformanceSnapshot _snapshot(
  StaffPerformanceRecord record, {
  List<StaffPerformanceRecord>? records,
  int excluded = 0,
  int unattributed = 0,
}) {
  return StaffPerformanceSnapshot(
    role: StaffPerformanceRole.helpers,
    periodStart: DateTime(2026, 10),
    periodEnd: DateTime(2026, 11),
    records: records ?? [record],
    loadedAt: DateTime(2026, 10, 26),
    totalStoreOrders: 100,
    totalRoleHandledOrders: 95,
    totalRoleWorkloadPoints: 300,
    unattributedOrderCount: unattributed,
    totalValidTimingCount: 5,
    totalExcludedTimingCount: excluded,
    activeHoursAvailable: false,
    totalRoleActiveHours: null,
    locationComplexityCoverage: 'Current product map locations when available',
  );
}
