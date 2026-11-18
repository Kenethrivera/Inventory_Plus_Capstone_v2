import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/ui/widgets/staff_role_header.dart';

void main() {
  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('Staff header fits ${width.toInt()}px and keeps actions', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selectedTab = -1;
      var profileOpened = false;
      var logoutRequested = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StaffRoleHeader(
                userName: 'Kenneth Rivera',
                tabs: const ['Queue', 'Inventory', 'History'],
                selectedTab: 0,
                onTabSelected: (index) => selectedTab = index,
                onProfile: () => profileOpened = true,
                onLogout: () => logoutRequested = true,
                availability: const Chip(label: Text('Busy')),
                notifications: const Icon(Icons.notifications_outlined),
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('History'));
      expect(selectedTab, 2);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(profileOpened, isTrue);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out'));
      expect(logoutRequested, isTrue);
    });
  }
}
