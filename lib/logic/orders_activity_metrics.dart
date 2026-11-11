import '../data/inventory.dart';

class PaymentTotals {
  const PaymentTotals({
    required this.collected,
    required this.cash,
    required this.gcash,
    required this.transactions,
  });

  final double collected;
  final double cash;
  final double gcash;
  final int transactions;

  factory PaymentTotals.fromOrders(Iterable<CustomerOrder> orders) {
    var cash = 0.0;
    var gcash = 0.0;
    var count = 0;
    for (final order in orders) {
      final status = order.status.toLowerCase();
      if (status == 'cancelled' || status == 'returned') continue;
      switch (order.paymentMode?.trim().toLowerCase()) {
        case 'cash':
          cash += order.totalAmount;
          count++;
        case 'gcash':
          gcash += order.totalAmount;
          count++;
      }
    }
    return PaymentTotals(
      collected: cash + gcash,
      cash: cash,
      gcash: gcash,
      transactions: count,
    );
  }
}
