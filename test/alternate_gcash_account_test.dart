import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
    );
  });

  test('alternate GCash is complete only with name, number, and QR', () {
    final controller = InventoryController();
    controller.alternateGcashAccountName = 'Backup Store';
    controller.alternateGcashNumber = '09123456789';
    expect(controller.hasAlternateGcashAccount, isFalse);

    controller.alternateGcashQrUrl = 'https://example.com/backup-qr.png';
    expect(controller.hasAlternateGcashAccount, isTrue);

    controller.alternateGcashNumber = '';
    expect(controller.hasAlternateGcashAccount, isFalse);
  });

  test('cashier details come from the active account only', () {
    final controller = InventoryController()
      ..gcashAccountName = 'Main Store'
      ..gcashNumber = '09111111111'
      ..gcashQrUrl = 'https://example.com/main.png'
      ..alternateGcashAccountName = 'Backup Store'
      ..alternateGcashNumber = '09222222222'
      ..alternateGcashQrUrl = 'https://example.com/backup.png';

    expect(controller.activeGcashAccountName, 'Main Store');
    expect(controller.activeGcashNumber, '09111111111');
    expect(controller.activeGcashQrUrl, 'https://example.com/main.png');

    controller.activeGcashAccount = 'alternate';
    expect(controller.activeGcashAccountName, 'Backup Store');
    expect(controller.activeGcashNumber, '09222222222');
    expect(controller.activeGcashQrUrl, 'https://example.com/backup.png');
  });
}
