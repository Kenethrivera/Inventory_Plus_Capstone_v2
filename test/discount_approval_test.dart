import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_approval.dart';

void main() {
  final migration = File(
    'database/phase_2c_discount_approval.sql',
  ).readAsStringSync();
  final controller = File(
    'lib/logic/inventory_controller.dart',
  ).readAsStringSync();
  final pos = File('lib/ui/pos_cart_page.dart').readAsStringSync();

  test('discount approval rows retain the reviewed checkout snapshot', () {
    final request = InventoryApprovalRequest.fromJson(<String, dynamic>{
      'id': 'request-1',
      'request_type': 'discount',
      'status': 'approved',
      'requested_by_id': '42',
      'requested_by_name': 'Cashier',
      'requested_by_role': 'cashier',
      'location_id': 'location-1',
      'discount_mode': 'fixed',
      'discount_value': 150,
      'discount_amount': 150,
      'discount_effective_percentage': 15,
      'subtotal_amount': 1000,
      'cart_fingerprint': 'fingerprint',
      'checkout_token': 'checkout-token',
      'reason': 'Manager-authorized promotion',
      'created_at': '2026-10-23T08:00:00Z',
    });

    expect(request.type, InventoryApprovalType.discount);
    expect(request.resultingTotal, 850);
    expect(request.discountEffectivePercentage, 15);
    expect(request.cartFingerprint, 'fingerprint');
    expect(request.checkoutToken, 'checkout-token');
  });

  test('server checkout enforces threshold and one-use exact approval', () {
    expect(migration, contains('create_customer_order_v1'));
    expect(migration, contains('private.discount_cart_snapshot_v1'));
    expect(migration, contains('v_snapshot.cart_fingerprint'));
    expect(migration, contains("v_request.status <> 'approved'"));
    expect(migration, contains('v_request.used_at is not null'));
    expect(migration, contains('discount_approval_request_id'));
    expect(migration, contains('revoke insert on table public.orders'));
  });

  test('cashier checkout waits for centralized approval state', () {
    expect(controller, contains('streamDiscountApproval'));
    expect(controller, contains('approvalRequestChanges'));
    expect(controller, contains('_refreshActiveDiscountApproval'));
    expect(pos, contains('Admin approval required'));
    expect(pos, contains('Request Approval'));
    expect(pos, contains('_hasUsableDiscountApproval'));
    expect(pos, isNot(contains('onPostgresChanges')));
  });

  test('runtime threshold is location-scoped and Admin-write-only', () {
    expect(migration, contains('location_id uuid'));
    expect(
      migration,
      contains('cashier_auto_approved_discount_limit_pct numeric'),
    );
    expect(migration, contains("if v_profile.role <> 'admin'"));
    expect(
      migration,
      contains('revoke insert, update, delete on table public.store_settings'),
    );
  });
}
