import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/navigation/main_section.dart';

void main() {
  test('main section paths round-trip', () {
    for (final section in MainSection.values) {
      expect(MainSection.fromPath(section.routePath), section);
    }
    expect(
      MainSection.fromPath('#/main/transactions?source=refresh'),
      MainSection.transactions,
    );
    expect(MainSection.fromPath('/main'), isNull);
    expect(MainSection.fromPath('/main/not-a-page'), isNull);
    expect(
      MainSection.fromPath('/classification_test'),
      MainSection.classificationTest,
    );
    expect(MainSection.classificationTest.routePath, '/classification_test');
  });

  test('role page order matches MainScreen page construction', () {
    expect(MainSection.forRole('admin'), const <MainSection>[
      MainSection.dashboard,
      MainSection.ordersActivity,
      MainSection.analytics,
      MainSection.forecasting,
      MainSection.classificationTest,
      MainSection.pos,
      MainSection.queue,
      MainSection.inventory,
      MainSection.approvals,
      MainSection.performance,
      MainSection.transactions,
      MainSection.storeMap,
      MainSection.systemSettings,
    ]);
    expect(MainSection.forRole('helper'), const <MainSection>[
      MainSection.queue,
      MainSection.inventory,
      MainSection.history,
    ]);
    expect(MainSection.forRole('staff'), const <MainSection>[
      MainSection.pos,
      MainSection.cashierRequests,
      MainSection.history,
    ]);
    expect(MainSection.forRole('cashier'), MainSection.forRole('staff'));
    for (final role in ['admin', 'helper', 'staff', 'cashier']) {
      for (final section in MainSection.forRole(role)) {
        expect(section.allowsRole(role), isTrue);
      }
    }
  });

  test('forbidden or unknown routes fall back to role default', () {
    expect(
      MainSection.resolveForRole(MainSection.systemSettings, 'helper'),
      MainSection.queue,
    );
    expect(
      MainSection.resolveForRole(MainSection.transactions, 'staff'),
      MainSection.pos,
    );
    for (final role in ['staff', 'cashier']) {
      expect(MainSection.inventory.allowsRole(role), isFalse);
      expect(
        MainSection.resolveForRole(
          MainSection.fromPath('#/main/inventory'),
          role,
        ),
        MainSection.pos,
      );
      expect(MainSection.forRole(role), isNot(contains(MainSection.inventory)));
    }
    expect(
      MainSection.resolveForRole(MainSection.inventory, 'helper'),
      MainSection.inventory,
    );
    expect(MainSection.resolveForRole(null, 'admin'), MainSection.dashboard);
  });
}
