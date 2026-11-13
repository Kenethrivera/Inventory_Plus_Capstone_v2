import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/rolling_stock_threshold.dart';

void main() {
  final now = DateTime.utc(2026, 11, 13, 12);

  test('seven-day sales use outgoing quantities and round alert levels up', () {
    final sales = <RollingSale>[
      RollingSale(
        quantity: 40,
        occurredAt: now.subtract(const Duration(days: 6)),
      ),
      RollingSale(
        quantity: 50,
        occurredAt: now.subtract(const Duration(days: 4)),
      ),
      RollingSale(
        quantity: 70,
        occurredAt: now.subtract(const Duration(days: 1)),
      ),
      RollingSale(quantity: 25, occurredAt: now),
    ];

    final baseline = RollingStockThreshold.totalSales(sales, now);
    expect(baseline, 185);
    expect(RollingStockThreshold.threshold(baseline, 10), 19);
    expect(RollingStockThreshold.threshold(baseline, 5), 10);
    expect(15 <= RollingStockThreshold.threshold(baseline, 10), isTrue);
    expect(15 <= RollingStockThreshold.threshold(baseline, 5), isFalse);
  });

  test('sales leave the rolling window after exactly seven days', () {
    final sales = <RollingSale>[
      RollingSale(
        quantity: 40,
        occurredAt: now.subtract(const Duration(days: 7)),
      ),
      RollingSale(
        quantity: 50,
        occurredAt: now.subtract(const Duration(days: 7, seconds: -1)),
      ),
      RollingSale(
        quantity: 10,
        occurredAt: now.subtract(const Duration(days: 8)),
      ),
    ];

    expect(RollingStockThreshold.totalSales(sales, now), 50);
    expect(
      RollingStockThreshold.totalSales(
        sales,
        now.add(const Duration(seconds: 1)),
      ),
      0,
    );
  });

  test(
    'zero or invalid outgoing quantities do not create an alert baseline',
    () {
      final sales = <RollingSale>[
        RollingSale(quantity: 0, occurredAt: now),
        RollingSale(quantity: -20, occurredAt: now),
        RollingSale(quantity: 10, occurredAt: now.add(const Duration(days: 1))),
      ];

      expect(RollingStockThreshold.totalSales(sales, now), 0);
    },
  );

  test('checkout rows exclude manual stock adjustments', () {
    final row = <String, dynamic>{
      'quantity_change': -25,
      'created_at': now.toIso8601String(),
      'operation_scope': 'checkout',
    };

    expect(RollingSale.fromCheckoutRow(row)?.quantity, 25);
    expect(
      RollingSale.fromCheckoutRow({...row, 'operation_scope': null})?.quantity,
      25,
    );
    expect(
      RollingSale.fromCheckoutRow({
        ...row,
        'operation_scope': 'inventory_adjustment',
      }),
      isNull,
    );
    expect(
      RollingSale.fromCheckoutRow({...row, 'quantity_change': 25}),
      isNull,
    );
  });
}
