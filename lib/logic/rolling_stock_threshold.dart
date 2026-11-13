class RollingSale {
  const RollingSale({required this.quantity, required this.occurredAt});

  final double quantity;
  final DateTime occurredAt;

  static RollingSale? fromCheckoutRow(Map<String, dynamic> row) {
    final scope = row['operation_scope']?.toString();
    // Legacy checkout rows have no scope. Manual stock adjustments use a
    // different scope, even when their transaction type is `checkout`.
    if (scope != null && scope != 'checkout') return null;
    final change = (row['quantity_change'] as num?)?.toDouble();
    final occurredAt = DateTime.tryParse(row['created_at']?.toString() ?? '');
    if (change == null || change >= 0 || occurredAt == null) return null;
    return RollingSale(quantity: -change, occurredAt: occurredAt);
  }
}

class RollingStockThreshold {
  static const Duration window = Duration(days: 7);

  static bool isInWindow(RollingSale sale, DateTime now) {
    final occurredAt = sale.occurredAt.toUtc();
    final currentTime = now.toUtc();
    return occurredAt.isAfter(currentTime.subtract(window)) &&
        !occurredAt.isAfter(currentTime);
  }

  static double totalSales(Iterable<RollingSale> sales, DateTime now) {
    var total = 0.0;
    for (final sale in sales) {
      if (sale.quantity > 0 && isInWindow(sale, now)) {
        total += sale.quantity;
      }
    }
    return total;
  }

  static double threshold(double totalSales, double percent) =>
      (totalSales * percent / 100).ceilToDouble();
}
