import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/logic/payment_reference.dart';

void main() {
  final pos = File('lib/ui/pos_cart_page.dart').readAsStringSync();
  final controller = File(
    'lib/logic/inventory_controller.dart',
  ).readAsStringSync();
  final ordersSchema = File(
    'supabase/schemas/public/tables/orders.sql',
  ).readAsStringSync();
  final historyPage = File(
    'supabase/schemas/public/functions/history_page_v1.sql',
  ).readAsStringSync();
  final historyDetail = File(
    'supabase/schemas/public/functions/history_order_detail_v1.sql',
  ).readAsStringSync();
  final historyExport = File(
    'supabase/schemas/public/functions/history_export_sales_v1.sql',
  ).readAsStringSync();

  test('full GCash reference remains text and preserves leading zeros', () {
    expect(normalizeGcashReference(' 001234567890 '), '001234567890');

    final order = CustomerOrder.fromJson({
      'id': 'order-1',
      'status': 'completed',
      'created_at': '2026-10-24T10:00:00Z',
      'payment_mode': 'GCash',
      'payment_reference': '001234567890',
      'items': <Map<String, dynamic>>[],
    });
    expect(order.paymentReference, '001234567890');
  });

  test('GCash reference validation requires digits and a non-empty value', () {
    expect(() => normalizeGcashReference(null), throwsFormatException);
    expect(() => normalizeGcashReference('   '), throwsFormatException);
    expect(() => normalizeGcashReference('123ABC'), throwsFormatException);
    expect(() => normalizeGcashReference('123-456'), throwsFormatException);
  });

  test('POS requests and stores the full normalized reference', () {
    expect(pos, contains('GCash Reference Number'));
    expect(pos, contains('Enter the full reference number'));
    expect(pos, contains('FilteringTextInputFormatter.digitsOnly'));
    expect(pos, contains('normalizeGcashReference'));
    expect(pos, isNot(contains('Insert last 5 digits')));
    expect(controller, contains('normalizeGcashReference(paymentReference)'));
    expect(controller, contains("updateData['payment_reference']"));
  });

  test('live text field is reused and history reads the stored value', () {
    expect(ordersSchema, contains('"payment_reference"      text'));
    expect(historyPage, contains("'payment_reference', payment_reference"));
    expect(historyDetail, contains("'payment_reference'"));
    expect(historyExport, contains("'payment_reference'"));
  });
}
