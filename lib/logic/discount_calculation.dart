import 'dart:math' as math;

enum DiscountMode { percentage, amount }

extension DiscountModeValue on DiscountMode {
  String get databaseValue => name;

  static DiscountMode fromDatabase(String value) => switch (value) {
    'percentage' => DiscountMode.percentage,
    'amount' => DiscountMode.amount,
    _ => throw FormatException('Unknown discount mode: $value'),
  };
}

class DiscountCalculation {
  const DiscountCalculation({
    required this.subtotal,
    required this.mode,
    required this.enteredValue,
    required this.discountAmount,
    required this.effectivePercentage,
  });

  factory DiscountCalculation.calculate({
    required double subtotal,
    required DiscountMode mode,
    required double enteredValue,
  }) {
    final safeSubtotal = math.max(0.0, subtotal);
    final safeValue = math.max(0.0, enteredValue);
    final rawAmount = switch (mode) {
      DiscountMode.percentage => safeSubtotal * (safeValue / 100),
      DiscountMode.amount => safeValue,
    };
    final amount = _roundCurrency(math.min(rawAmount, safeSubtotal));
    final effective = safeSubtotal <= 0 ? 0.0 : (amount / safeSubtotal) * 100;
    return DiscountCalculation(
      subtotal: safeSubtotal,
      mode: mode,
      enteredValue: safeValue,
      discountAmount: amount,
      effectivePercentage: effective,
    );
  }

  final double subtotal;
  final DiscountMode mode;
  final double enteredValue;
  final double discountAmount;
  final double effectivePercentage;

  double get total => _roundCurrency(subtotal - discountAmount);

  bool requiresApproval(double thresholdPercentage) =>
      effectivePercentage > thresholdPercentage;

  static double _roundCurrency(double value) =>
      (value * 100).roundToDouble() / 100;
}
