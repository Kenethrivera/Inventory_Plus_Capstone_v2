import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/data/inventory.dart';
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

  test('completed order parses the receiving account snapshot', () {
    final order = CustomerOrder.fromJson({
      'id': 'test-order',
      'status': 'completed',
      'created_at': '2026-11-18T00:00:00Z',
      'items': <dynamic>[],
      'payment_mode': 'GCash',
      'payment_reference': '1234567890123',
      'gcash_destination_slot': 'alternate',
      'gcash_destination_name': 'Backup Store',
      'gcash_destination_number': '09222222222',
    });

    expect(order.gcashDestinationSlot, 'alternate');
    expect(order.gcashDestinationName, 'Backup Store');
    expect(order.gcashDestinationNumber, '09222222222');
  });
}
