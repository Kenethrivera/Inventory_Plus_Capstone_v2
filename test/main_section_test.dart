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
  });

  test('role page order matches MainScreen page construction', () {
    expect(MainSection.forRole('admin'), const <MainSection>[
      MainSection.dashboard,
      MainSection.forecasting,
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
      MainSection.inventory,
      MainSection.history,
    ]);
    expect(MainSection.forRole('cashier'), MainSection.forRole('staff'));
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
    expect(MainSection.resolveForRole(null, 'admin'), MainSection.dashboard);
  });
}
