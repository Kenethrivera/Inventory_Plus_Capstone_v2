import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/data/inventory.dart';

void main() {
  test('product color survives a Supabase snapshot and identifies a variant', () {
    final item = InventoryItem.fromSupabase({
      'id': 'product-red',
      'sku': 'ROOF-RED',
      'product_name': 'Roofing sheet',
      'product_price': 450,
      'product_quantity': 12,
      'max_quantity': 30,
      'color': 'Red',
    });

    expect(item.color, 'Red');
    expect(item.displayName, 'Roofing sheet · Red');
    expect(item.copyWith(color: 'Blue').displayName, 'Roofing sheet · Blue');
    expect(item.copyWith(color: '').displayName, 'Roofing sheet');

    final olderItem = InventoryItem.fromSupabase({
      'id': 'product-plain',
      'sku': 'CEMENT-001',
      'product_name': 'Cement',
    });
    expect(olderItem.displayName, 'Cement');
  });
}