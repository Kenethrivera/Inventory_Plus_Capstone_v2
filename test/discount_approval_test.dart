import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/discount_calculation.dart';
import 'package:inventory_plus/logic/inventory_approval.dart';

void main() {
  final migration = File(
    'database/phase_2c_discount_approval.sql',
  ).readAsStringSync();
  final repair = File(
    'database/phase_2c_discount_approval_fix.sql',
  ).readAsStringSync();
  final controller = File(
    'lib/logic/inventory_controller.dart',
  ).readAsStringSync();
  final pos = File('lib/ui/pos_cart_page.dart').readAsStringSync();
  final approvalCenter = File(
    'lib/ui/approval_center_page.dart',
  ).readAsStringSync();

  DiscountCalculation calculate(
    DiscountMode mode,
    double value, {
    double subtotal = 1000,
  }) => DiscountCalculation.calculate(
    subtotal: subtotal,
    mode: mode,
    enteredValue: value,
  );

  InventoryApprovalRequest approval({
    String mode = 'amount',
    double value = 150,
    double subtotal = 1000,
    double amount = 150,
    String token = 'checkout-token-1234',
    String? usedAt,
  }) {
    final json = <String, dynamic>{
      'id': 'request-1',
      'request_type': 'discount',
      'status': 'approved',
      'requested_by_id': '42',
      'requested_by_name': 'Cashier',
      'requested_by_role': 'cashier',
      'location_id': 'location-1',
      'location_name': 'Main Store',
      'discount_mode': mode,
      'discount_value': value,
      'discount_amount': amount,
      'discount_effective_percentage': amount / subtotal * 100,
      'subtotal_amount': subtotal,
      'cart_items': <Map<String, dynamic>>[
        <String, dynamic>{
          'product_id': 'product-1',
          'product_name': 'Item',
          'quantity': 1,
          'unit': 'pcs',
          'unit_price': 1000,
          'line_total': 1000,
        },
      ],
      'cart_fingerprint': 'fingerprint',
      'checkout_token': token,
      'reason': 'Manager-authorized promotion',
      'requested_at': '2026-10-23T08:00:00Z',
    };
    if (usedAt != null) json['used_at'] = usedAt;
    return InventoryApprovalRequest.fromJson(json);
  }

  test('percentage input calculates a percentage of subtotal', () {
    final result = calculate(DiscountMode.percentage, 10);
    expect(result.discountAmount, 100);
    expect(result.effectivePercentage, 10);
  });

  test('discount modes serialize to the canonical database values', () {
    expect(DiscountMode.percentage.databaseValue, 'percentage');
    expect(DiscountMode.amount.databaseValue, 'amount');
    expect(
      DiscountModeValue.fromDatabase('fixed'),
      DiscountMode.amount,
      reason: 'legacy deployed rows remain readable',
    );
    expect(repair, contains("discount_mode in ('percentage', 'amount')"));
    expect(repair, contains("set discount_mode = 'amount'"));
  });

  test('amount input calculates a fixed peso discount', () {
    final result = calculate(DiscountMode.amount, 10);
    expect(result.discountAmount, 10);
    expect(result.effectivePercentage, 1);
  });

  test('fixed peso value is never interpreted as a percentage', () {
    expect(
      calculate(DiscountMode.amount, 10).discountAmount,
      isNot(calculate(DiscountMode.percentage, 10).discountAmount),
    );
  });

  test('effective percentage for fixed discount uses monetary amount', () {
    final result = calculate(DiscountMode.amount, 150);
    expect(result.discountAmount, 150);
    expect(result.effectivePercentage, 15);
  });

  test('discount exactly at threshold does not require approval', () {
    expect(
      calculate(DiscountMode.percentage, 10).requiresApproval(10),
      isFalse,
    );
    expect(calculate(DiscountMode.amount, 100).requiresApproval(10), isFalse);
  });

  test('discount above threshold requires approval', () {
    expect(calculate(DiscountMode.amount, 150).requiresApproval(10), isTrue);
  });

  test('reason is optional within limit and required above limit', () {
    expect(pos, contains('Reason (Optional)'));
    expect(pos, contains('Reason (Required for Approval)'));
    expect(
      migration,
      contains("raise exception 'A reason is required for discount approval'"),
    );
    expect(migration, contains("nullif(trim(reason), '') is not null"));
  });

  test(
    'approval and rejection updates preserve cart and never auto-checkout',
    () {
      final listenerStart = pos.indexOf('.streamDiscountApproval()');
      final listenerEnd = pos.indexOf('_pendingAutoOpenOrderId', listenerStart);
      final listener = pos.substring(listenerStart, listenerEnd);
      expect(listener, contains('_discountApproval = request'));
      expect(listener, isNot(contains('_cart.clear')));
      expect(listener, isNot(contains('_processOrder()')));
    },
  );

  test('changed mode or entered value invalidates approval', () {
    final request = approval();
    expect(
      request.authorizesDiscountCheckout(
        mode: 'percentage',
        enteredValue: 150,
        subtotal: 1000,
        monetaryDiscount: 150,
        cartToken: 'checkout-token-1234',
      ),
      isFalse,
    );
    expect(
      request.authorizesDiscountCheckout(
        mode: 'amount',
        enteredValue: 151,
        subtotal: 1000,
        monetaryDiscount: 151,
        cartToken: 'checkout-token-1234',
      ),
      isFalse,
    );
  });

  test('changed cart token or subtotal invalidates approval', () {
    final request = approval();
    expect(
      request.authorizesDiscountCheckout(
        mode: 'amount',
        enteredValue: 150,
        subtotal: 1000,
        monetaryDiscount: 150,
        cartToken: 'changed-cart-token',
      ),
      isFalse,
    );
    expect(
      request.authorizesDiscountCheckout(
        mode: 'amount',
        enteredValue: 150,
        subtotal: 2000,
        monetaryDiscount: 150,
        cartToken: 'checkout-token-1234',
      ),
      isFalse,
    );
    expect(pos, contains('_invalidateDiscountApproval();'));
  });

  test('approved snapshot can only be consumed once', () {
    final request = approval(usedAt: '2026-10-23T09:00:00Z');
    expect(
      request.authorizesDiscountCheckout(
        mode: 'amount',
        enteredValue: 150,
        subtotal: 1000,
        monetaryDiscount: 150,
        cartToken: 'checkout-token-1234',
      ),
      isFalse,
    );
    expect(migration, contains('v_request.used_at is not null'));
    expect(migration, contains('orders_discount_approval_request_unique'));
  });

  test('snapshot and Approval Center retain both representations', () {
    final request = approval();
    expect(request.discountDisplay, '₱150.00');
    expect(request.cartItems.single['quantity'], 1);
    expect(request.cartItems.single['unit'], 'pcs');
    expect(request.cartItems.single['unit_price'], 1000);
    expect(request.cartItems.single['line_total'], 1000);
    expect(migration, contains("discount_mode in ('percentage', 'amount')"));
    expect(migration, contains("'cart_items', p_request.cart_items"));
    expect(repair, contains('v_snapshot.normalized_items'));
    expect(repair, contains("'unit_price', scoped.product_price"));
    expect(repair, contains("'line_total'"));
    expect(approvalCenter, contains('REQUESTED BY'));
    expect(approvalCenter, contains('DETAILS'));
    expect(
      approvalCenter,
      contains('Detailed cart snapshot unavailable for this legacy request.'),
    );
    expect(approvalCenter, isNot(contains("'Checkout fingerprint'")));
    expect(approvalCenter, isNot(contains('scrollDirection: Axis.horizontal')));
  });

  test('server checkout remains authoritative and realtime is centralized', () {
    expect(migration, contains('create_customer_order_v1'));
    expect(migration, contains('v_request.cart_fingerprint'));
    expect(migration, contains('revoke insert on table public.orders'));
    expect(controller, contains('_refreshActiveDiscountApproval'));
    expect(pos, isNot(contains('onPostgresChanges')));
  });
}
