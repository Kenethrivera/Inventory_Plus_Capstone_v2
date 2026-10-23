import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/helper_assignment.dart';

void main() {
  final now = DateTime.utc(2026, 10, 23, 10);

  HelperAssignmentCandidate helper(String id, String name) {
    return HelperAssignmentCandidate(
      id: id,
      name: name,
      locationId: 'location-a',
      lastSeenAt: now,
    );
  }

  CustomerOrder order({
    required String id,
    String? helperId,
    required String status,
    required DateTime assignedAt,
  }) {
    return CustomerOrder(
      id: id,
      items: const <CustomerOrderItem>[],
      status: status,
      createdAt: assignedAt.subtract(const Duration(minutes: 1)),
      assignedHelperId: helperId,
      assignedAt: assignedAt,
    );
  }

  test('manual Helper selection is included in the initial order insert', () {
    final fields = initialHelperAssignmentFields(
      helper: helper('22', 'Helper Two'),
      assignedAt: now,
    );

    expect(fields['assigned_helper_id'], '22');
    expect(fields['assigned_helper_name'], 'Helper Two');
    expect(fields['assigned_at'], now.toIso8601String());

    final controllerSource = File(
      'lib/logic/inventory_controller.dart',
    ).readAsStringSync();
    expect(controllerSource, contains('...initialAssignment'));
  });

  test('Auto-assign leaves all initial assignment fields unset', () {
    expect(
      initialHelperAssignmentFields(helper: null, assignedAt: now),
      isEmpty,
    );
  });

  test(
    'Helper Queue includes only pending work assigned to current Helper',
    () {
      final orders = <CustomerOrder>[
        order(id: 'mine', helperId: '1', status: 'pending', assignedAt: now),
        order(id: 'unassigned', status: 'pending', assignedAt: now),
        order(id: 'other', helperId: '2', status: 'pending', assignedAt: now),
        order(
          id: 'prepared',
          helperId: '1',
          status: 'prepared',
          assignedAt: now,
        ),
      ];

      final visible = assignedPendingOrdersForHelper(
        orders: orders,
        helperId: '1',
      );
      expect(visible.map((entry) => entry.id), ['mine']);
    },
  );

  test('eligible Helpers are online, fresh, same-location Helper profiles', () {
    final rows = <Map<String, dynamic>>[
      {
        'user_id': '1',
        'user_name': 'Eligible',
        'user_role': 'helper',
        'location_id': 'location-a',
        'is_online': true,
        'last_seen_at': now
            .subtract(const Duration(seconds: 30))
            .toIso8601String(),
      },
      {
        'user_id': '2',
        'user_name': 'Wrong role',
        'user_role': 'staff',
        'location_id': 'location-a',
        'is_online': true,
        'last_seen_at': now.toIso8601String(),
      },
      {
        'user_id': '3',
        'user_name': 'Wrong location',
        'user_role': 'helper',
        'location_id': 'location-b',
        'is_online': true,
        'last_seen_at': now.toIso8601String(),
      },
      {
        'user_id': '4',
        'user_name': 'Stale',
        'user_role': 'helper',
        'location_id': 'location-a',
        'is_online': true,
        'last_seen_at': now
            .subtract(const Duration(minutes: 3))
            .toIso8601String(),
      },
    ];

    final eligible = eligibleHelpersFromPresence(
      presenceRows: rows,
      locationId: 'location-a',
      now: now,
      activeTimeout: const Duration(minutes: 2),
    );

    expect(eligible.map((candidate) => candidate.id), ['1']);
  });

  test('least-loaded wins and multiple active orders do not disqualify', () {
    final helpers = [helper('1', 'H1'), helper('2', 'H2'), helper('3', 'H3')];
    final orders = <CustomerOrder>[
      for (var index = 0; index < 3; index++)
        order(
          id: 'h1-$index',
          helperId: '1',
          status: 'pending',
          assignedAt: now.subtract(Duration(minutes: 30 - index)),
        ),
      for (var index = 0; index < 4; index++)
        order(
          id: 'h2-$index',
          helperId: '2',
          status: 'pending',
          assignedAt: now.subtract(Duration(minutes: 20 - index)),
        ),
      for (var index = 0; index < 2; index++)
        order(
          id: 'h3-$index',
          helperId: '3',
          status: 'pending',
          assignedAt: now.subtract(Duration(minutes: 10 - index)),
        ),
    ];

    final ranked = rankHelpersByActiveWorkload(
      helpers: helpers,
      orders: orders,
    );

    expect(ranked.map((candidate) => candidate.id), ['3', '1', '2']);
    expect(ranked, hasLength(3));
  });

  test('workload counts only assigned pending preparation orders', () {
    final orders = <CustomerOrder>[
      order(id: 'active', helperId: '1', status: 'pending', assignedAt: now),
      order(
        id: 'active-two',
        helperId: '1',
        status: 'pending',
        assignedAt: now,
      ),
      order(id: 'unassigned', status: 'pending', assignedAt: now),
      order(id: 'prepared', helperId: '1', status: 'prepared', assignedAt: now),
      order(
        id: 'completed',
        helperId: '1',
        status: 'completed',
        assignedAt: now,
      ),
      order(
        id: 'cancelled',
        helperId: '1',
        status: 'cancelled',
        assignedAt: now,
      ),
      order(id: 'solo', helperId: '1', status: 'solo_picking', assignedAt: now),
    ];

    expect(activePreparationWorkloads(orders), {'1': 2});
    expect(
      rankHelpersByActiveWorkload(
        helpers: [helper('1', 'H1'), helper('2', 'H2')],
        orders: orders,
      ).first.id,
      '2',
    );
  });

  test('equal workload uses least-recent assignment then stable ID', () {
    final rankedByTime = rankHelpersByActiveWorkload(
      helpers: [helper('1', 'H1'), helper('2', 'H2')],
      orders: [
        order(
          id: 'one',
          helperId: '1',
          status: 'completed',
          assignedAt: now.subtract(const Duration(minutes: 5)),
        ),
        order(
          id: 'two',
          helperId: '2',
          status: 'completed',
          assignedAt: now.subtract(const Duration(minutes: 10)),
        ),
      ],
    );
    expect(rankedByTime.map((candidate) => candidate.id), ['2', '1']);

    final rankedById = rankHelpersByActiveWorkload(
      helpers: [helper('10', 'H10'), helper('2', 'H2')],
      orders: const <CustomerOrder>[],
    );
    expect(rankedById.map((candidate) => candidate.id), ['2', '10']);
  });

  test('no online Helper produces no eligible assignment candidate', () {
    final eligible = eligibleHelpersFromPresence(
      presenceRows: const <Map<String, dynamic>>[],
      locationId: 'location-a',
      now: now,
      activeTimeout: const Duration(minutes: 2),
    );
    expect(eligible, isEmpty);
  });

  test(
    'reconciliation gate allows one in flight and at most one rerun',
    () async {
      final gate = AssignmentReconciliationGate();
      final releaseFirst = Completer<void>();
      var runs = 0;
      var concurrent = 0;
      var maxConcurrent = 0;

      Future<void> reconcile() async {
        runs++;
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        if (runs == 1) await releaseFirst.future;
        concurrent--;
      }

      final first = gate.schedule(reconcile);
      await Future<void>.delayed(Duration.zero);
      final second = gate.schedule(reconcile);
      final third = gate.schedule(reconcile);
      final fourth = gate.schedule(reconcile);
      releaseFirst.complete();
      await Future.wait([first, second, third, fourth]);

      expect(runs, 2);
      expect(maxConcurrent, 1);
    },
  );

  test('normal Helper UI has no claim pool and backend claim remains', () {
    final helperUi = File('lib/ui/order_queue_page.dart').readAsStringSync();
    final controller = File(
      'lib/logic/inventory_controller.dart',
    ).readAsStringSync();

    expect(helperUi, contains('assignedPendingOrdersForHelper'));
    expect(helperUi, contains('_openAssignedOrderChecklist'));
    expect(helperUi, isNot(contains('claimOrderForCurrentHelper(')));
    expect(helperUi.toLowerCase(), isNot(contains('claimed by you')));
    expect(helperUi.toLowerCase(), isNot(contains('unassigned pending')));
    expect(controller, contains('claimOrderForCurrentHelper('));
  });

  test(
    'Cashier UI removes solo CTA and immediately reconciles Auto-assign',
    () {
      final cashierUi = File('lib/ui/pos_cart_page.dart').readAsStringSync();
      final selectorUi = File(
        'lib/ui/widgets/helper_assignment_selector.dart',
      ).readAsStringSync();

      expect(selectorUi, contains('Helper packs'));
      expect(selectorUi, contains('Auto-assign — least loaded'));
      expect(selectorUi, contains("count == 1 ? 'order' : 'orders'"));
      expect(cashierUi.toLowerCase(), isNot(contains("i'll pack it")));
      expect(selectorUi.toLowerCase(), isNot(contains("i'll pack it")));
      expect(cashierUi, contains('reconcileCreatedOrder()'));
    },
  );

  test(
    'auto-assignment SQL uses type-safe workload comparison and ordering',
    () {
      final sql = File(
        'database/queue_monitor_auto_assignment.sql',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

      expect(sql, contains('work.assigned_helper_id = profile.id::text'));
      expect(sql, isNot(contains('work.assigned_helper_id = profile.id ')));
      expect(
        sql,
        contains("count(*) filter ( where lower(work.status) = 'pending'"),
      );
      expect(
        sql,
        contains(
          'order by coalesce(workload.active_count, 0) asc, '
          'workload.last_assigned_at asc nulls first, profile.id asc',
        ),
      );
      expect(sql, contains('order by pending.created_at asc, pending.id asc'));
    },
  );
}
