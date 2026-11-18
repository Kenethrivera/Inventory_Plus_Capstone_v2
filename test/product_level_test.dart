import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/product_level.dart';

void main() {
  test('product levels allow no level or a whole number from 1 to 10', () {
    for (final value in ['', '1', '5', '10']) {
      expect(isValidProductLevel(value), isTrue, reason: value);
    }
    for (final value in ['A', '1A', '0', '11', '100', '9999', '1.5', '01']) {
      expect(isValidProductLevel(value), isFalse, reason: value);
    }
  });
}
