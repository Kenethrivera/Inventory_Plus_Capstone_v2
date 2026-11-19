import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/ui/widgets/startup_restoration_surface.dart';

void main() {
  testWidgets('restoration mark settles without holding the startup screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: StartupRestorationSurface()),
    );

    expect(find.text('Inventory Plus'), findsOneWidget);
    expect(find.text('Restoring your session\u2026'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFFF7F6F4),
    );

    final frames = await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
    );
    expect(frames, lessThan(20));
    expect(tester.takeException(), isNull);
  });
}
