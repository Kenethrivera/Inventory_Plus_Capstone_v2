import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/store_access_service.dart';
import 'package:inventory_plus/ui/widgets/admin_store_status_clock.dart';

void main() {
  testWidgets('refreshes store status at opening', (tester) async {
    var now = DateTime(2026, 11, 18, 7, 29, 59, 500);
    final window = StoreAccessWindow(
      opening: DateTime(2026, 11, 18, 7, 30),
      shiftEnd: DateTime(2026, 11, 18, 17),
      accessStart: DateTime(2026, 11, 18, 7),
      accessEnd: DateTime(2026, 11, 18, 18),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            child: AdminStoreStatusClock(
              resolveWindow: (_) => window,
              now: () => now,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Closed · opens 7:30 AM'), findsOneWidget);
    expect(find.textContaining('Now '), findsNothing);

    now = DateTime(2026, 11, 18, 7, 30);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Open · closes 5:00 PM'), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.circle)).color,
      const Color(0xFF16A34A),
    );
  });

  testWidgets('shows an unavailable state when hours have not loaded', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminStoreStatusClock(
            resolveWindow: (_) => null,
            now: () => DateTime(2026, 11, 18, 12),
          ),
        ),
      ),
    );
    expect(find.text('Store hours unavailable'), findsOneWidget);
    expect(find.text('Store overview'), findsNothing);
  });

  testWidgets('shows a saved reason on a closed day', (tester) async {
    final now = DateTime(2026, 11, 18, 12);
    final nextWindow = StoreAccessWindow(
      opening: DateTime(2026, 11, 19, 7, 30),
      shiftEnd: DateTime(2026, 11, 19, 19),
      accessStart: DateTime(2026, 11, 19, 7),
      accessEnd: DateTime(2026, 11, 19, 19, 30),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminStoreStatusClock(
            resolveWindow: (_) => nextWindow,
            closureReason: (_) => 'Maintenance',
            now: () => now,
          ),
        ),
      ),
    );
    expect(find.text('Closed · Maintenance · opens 7:30 AM'), findsOneWidget);
  });
}
