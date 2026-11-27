import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';
import 'package:inventory_plus/ui/qr_labels_preview_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fits the selected number of QR labels on A4', () async {
    final items = List.generate(
      13,
      (index) => InventoryItem(
        id: '$index',
        name: 'Adjustable wrench – longer product name $index',
        sku: 'SKU-QR-$index',
        color: index == 0 ? 'Red' : null,
        price: 1000,
        quantity: 10,
        maxQuantity: 100,
        category: 'Tools',
        description: '',
        imageUrl: '',
      ),
    );

    final six = QrLabelPageLayout.forCount(6);
    final nine = QrLabelPageLayout.forCount(9);
    expect((six.columns, six.rows), (2, 3));
    expect((nine.columns, nine.rows), (3, 3));
    expect(nine.labelSizeMm, lessThan(six.labelSizeMm));

    for (final count in [6, 9, 12, 24]) {
      final pdf = await buildQrLabelsPdf(items, count);
      expect(latin1.decode(pdf.take(8).toList()), startsWith('%PDF-'));
      expect(pdf.length, greaterThan(1000));
    }
  });
}
