import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/helper_assignment.dart';
import 'package:inventory_plus/ui/widgets/helper_assignment_selector.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  HelperAssignmentCandidate helper(String id, String name) {
    return HelperAssignmentCandidate(
      id: id,
      name: name,
      locationId: 'location-a',
      lastSeenAt: DateTime.utc(2026, 10, 23),
    );
  }

  testWidgets('entire selector trigger opens the anchored menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: HelperAssignmentSelector(
              helpers: [helper('1', 'Kenneth')],
              workloads: const {'1': 1},
              selectedHelperId: null,
              enabled: true,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final trigger = find.byKey(const Key('helper-assignment-trigger'));
    final rect = tester.getRect(trigger);
    await tester.tapAt(Offset(rect.left + 12, rect.center.dy));
    await tester.pump();

    expect(find.byKey(const Key('helper-option-auto')), findsOneWidget);
    expect(find.byKey(const Key('helper-option-1')), findsOneWidget);
  });

  testWidgets('selected Helper and workload are visually identified', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: HelperAssignmentSelector(
              helpers: [helper('1', 'Kenneth')],
              workloads: const {'1': 1},
              selectedHelperId: '1',
              enabled: true,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Kenneth — 1 active order'), findsOneWidget);
    await tester.tap(find.byKey(const Key('helper-assignment-trigger')));
    await tester.pump();

    final selectedRow = find.byKey(const Key('helper-option-1'));
    expect(
      find.descendant(
        of: selectedRow,
        matching: find.byIcon(LucideIcons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('open menu rebuilds live workload and eligibility changes', (
    tester,
  ) async {
    var helpers = <HelperAssignmentCandidate>[helper('1', 'Kenneth')];
    var workloads = <String, int>{'1': 2};
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                return HelperAssignmentSelector(
                  helpers: helpers,
                  workloads: workloads,
                  selectedHelperId: null,
                  enabled: true,
                  onChanged: (_) {},
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('helper-assignment-trigger')));
    await tester.pump();
    expect(find.text('2 active orders'), findsOneWidget);

    updateHost(() {
      workloads = <String, int>{'1': 1, '2': 0};
      helpers = <HelperAssignmentCandidate>[
        helper('1', 'Kenneth'),
        helper('2', 'Jane'),
      ];
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('1 active order'), findsOneWidget);
    expect(find.text('Jane'), findsOneWidget);
    expect(find.text('0 active orders'), findsOneWidget);
    expect(find.byKey(const Key('helper-option-auto')), findsOneWidget);

    updateHost(() {
      workloads = <String, int>{'2': 0};
      helpers = <HelperAssignmentCandidate>[helper('2', 'Jane')];
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Kenneth'), findsNothing);
    expect(find.text('Jane'), findsOneWidget);
    expect(find.byKey(const Key('helper-option-auto')), findsOneWidget);
  });

  testWidgets('unavailable selected Helper falls back to Auto-assign', (
    tester,
  ) async {
    var helpers = <HelperAssignmentCandidate>[helper('1', 'Kenneth')];
    String? selectedId = '1';
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                return HelperAssignmentSelector(
                  helpers: helpers,
                  workloads: const {'1': 2},
                  selectedHelperId: selectedId,
                  enabled: true,
                  onChanged: (value) {
                    setState(() => selectedId = value);
                  },
                );
              },
            ),
          ),
        ),
      ),
    );

    updateHost(() => helpers = <HelperAssignmentCandidate>[]);
    await tester.pump();
    await tester.pump();

    expect(selectedId, isNull);
    expect(find.text('Auto-assign — least loaded'), findsOneWidget);
  });

  test('selector uses canonical UI snapshots without transport ownership', () {
    final selectorSource = File(
      'lib/ui/widgets/helper_assignment_selector.dart',
    ).readAsStringSync();
    final cashierSource = File('lib/ui/pos_cart_page.dart').readAsStringSync();

    expect(cashierSource, contains('widget.controller.orderSnapshots'));
    expect(cashierSource, contains('eligibleHelpersForAssignment'));
    expect(selectorSource, isNot(contains('Supabase')));
    expect(selectorSource, isNot(contains('RealtimeChannel')));
    expect(selectorSource, isNot(contains('Timer.periodic')));
  });
}
