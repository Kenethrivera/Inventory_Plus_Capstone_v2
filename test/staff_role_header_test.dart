import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/ui/widgets/staff_role_header.dart';

void main() {
  testWidgets('Staff app bar clears the Android status bar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 32),
            viewPadding: const EdgeInsets.only(top: 32),
          ),
          child: child!,
        ),
        home: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(64),
            child: StaffRoleHeader(
              userName: 'Cashier',
              tabs: const [],
              selectedTab: 0,
              onTabSelected: (_) {},
              onProfile: () {},
              onLogout: () {},
              showTabs: false,
            ),
          ),
          body: const Text('Page content'),
        ),
      ),
    );

    expect(tester.getTopLeft(find.text('Inventory Plus')).dy, greaterThan(32));
    expect(
      tester.getTopLeft(find.text('Page content')).dy,
      greaterThanOrEqualTo(96),
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('Staff header fits ${width.toInt()}px and keeps actions', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selectedTab = -1;
      var profileOpened = false;
      var logoutRequested = false;
      await tester.pumpWidget(
        MaterialApp(
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
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (width < 600) {
        expect(find.text('History'), findsNothing);
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Profile'));
        await tester.pumpAndSettle();
        expect(profileOpened, isTrue);
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Log out'));
        expect(logoutRequested, isTrue);
      } else {
        await tester.tap(find.text('History'));
        expect(selectedTab, 2);
        await tester.tap(find.byType(CircleAvatar));
        expect(profileOpened, isTrue);
        await tester.tap(find.byTooltip('Log out'));
        expect(logoutRequested, isTrue);
      }
    });
  }
}
