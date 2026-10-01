import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart';
import '../data/inventory.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;
enum StockStatus { ok, low, critical, out }

class InventoryController {
  final SupabaseClient supabase = Supabase.instance.client;
  int? currentUserNumericId;
  List<InventoryItem> _items = [];
  List<InventoryItem> get allItems => _items;
  List<InventoryItem> _disabledItems = [];
  String? activeLocationId;
  String? currentUserRole;
  String? currentUserName;
  String? currentUserId;
  String? loggedInUserEmail;
  bool get isAdmin => currentUserRole?.toLowerCase() == 'admin';
  double globalLowStockPct = 20.0;
  double globalCriticalPct = 10.0;
  List<Map<String, dynamic>> availableMeasurements = [];
  List<MapElement> storeLayout = [];

  static const int _baselineRestocks = 3;
  static const int _baselineWindowDays = 180;
  Map<String, double> _baselineByProduct = {};

  Future<void> _loadStockBaselines() async {
    final locId = activeLocationId;
    if (locId == null) return;
    try {
      final cutoff = DateTime.now()
          .subtract(const Duration(days: _baselineWindowDays))
          .toIso8601String();

      final res = await supabase
          .from('transaction_history')
          .select('product_id, new_quantity, created_at')
          .eq('location_id', locId)
          .inFilter('transaction_type', ['add', 'stock_in'])
          .gte('created_at', cutoff)
          .order('created_at', ascending: false);

      final Map<String, List<double>> levels = {};
      for (final row in List<Map<String, dynamic>>.from(res)) {
        final pid = row['product_id']?.toString();
        if (pid == null) continue;
        final list = levels.putIfAbsent(pid, () => []);
        if (list.length < _baselineRestocks) {
          list.add((row['new_quantity'] as num).toDouble());
        }
      }
      _baselineByProduct = {
        for (final e in levels.entries) e.key: e.value.reduce(math.max),
      };
    } catch (e) {
      print("Error loading stock baselines: $e");
    }
  }

  double baselineFor(InventoryItem item) =>
      math.max(item.quantity, _baselineByProduct[item.id] ?? item.maxQuantity);

  double stockPercentFor(InventoryItem item) {
    final base = baselineFor(item);
    return base <= 0 ? 100 : (item.quantity / base) * 100;
  }

  StockStatus stockStatusFor(InventoryItem item) {
    if (item.quantity <= 0) return StockStatus.out;
    final pct = stockPercentFor(item);
    if (pct <= globalCriticalPct) return StockStatus.critical;
    if (pct <= globalLowStockPct) return StockStatus.low;
    return StockStatus.ok;
  }
  

  List<InventoryItem> get disabledItems => List.unmodifiable(_disabledItems);

  bool isDisabled(String id) => _disabledItems.any((i) => i.id == id);

  InventoryItem? findAnyItemById(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    for (final i in _disabledItems) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Active + disabled. Only meant for reports.
  List<InventoryItem> get reportableItems => [..._items, ..._disabledItems];

  void setLoggedInUser({
    required String name,
    required String id,
    required String role,
    String? email,
  }) {
    currentUserName = name;
    currentUserId = id;
    currentUserRole = role;
    currentUserNumericId = int.tryParse(id);
    loggedInUserEmail = email;
  }

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<void> loadSystemSettings() async {
    try {
      // 1. Fetch thresholds (same row that updateGlobalThresholds writes: id = 1)
      final thresholdRes = await supabase
          .from('threshold')
          .select('low_stock, critical')
          .eq('id', 1)
          .maybeSingle();

      if (thresholdRes != null) {
        globalLowStockPct = (thresholdRes['low_stock'] as num).toDouble();
        globalCriticalPct = (thresholdRes['critical'] as num).toDouble();
      }

      // 2. Fetch measurements
      final measureRes = await supabase
          .from('measurements')
          .select('id, name, symbol');

      availableMeasurements = List<Map<String, dynamic>>.from(measureRes);
    } catch (e) {
      print("Error loading system settings: $e");
      rethrow; // callers decide how to show the error
    }
  }

  Future<void> updateGlobalThresholds(double low, double critical) async {
    try {
      await supabase.from('threshold').upsert({
        'id': 1, // Assuming row ID 1 for global settings
        'low_stock': low,
        'critical': critical,
      });
      globalLowStockPct = low;
      globalCriticalPct = critical;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> addMeasurement(String name, String symbol) async {
    try {
      final response = await supabase
          .from('measurements')
          .insert({'name': name, 'symbol': symbol})
          .select()
          .single();

      availableMeasurements.add(response);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> updateMeasurement(String id, String name, String symbol) async {
    try {
      final response = await supabase
          .from('measurements')
          .update({'name': name, 'symbol': symbol})
          .eq('id', id)
          .select()
          .single();

      final index = availableMeasurements.indexWhere(
        (m) => m['id'].toString() == id,
      );
      if (index != -1) {
        availableMeasurements[index] = response;
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteMeasurement(String id) async {
    try {
      await supabase.from('measurements').delete().eq('id', id);
      availableMeasurements.removeWhere((m) => m['id'].toString() == id);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> loadAppData(String userLocationId) async {
    activeLocationId = userLocationId;

    try {
      final productsResponse = await supabase
          .from('products')
          .select()
          .eq('location_id', userLocationId);

      final active = <InventoryItem>[];
      final disabled = <InventoryItem>[];
      for (final p in productsResponse as List) {
        final item = InventoryItem.fromSupabase(p);
        if (p['is_active'] == false) {
          disabled.add(item);
        } else {
          active.add(item);
        }
      }
      _items = active;
      _disabledItems = disabled;

      await _loadStockBaselines();
      await fetchMapLayout();
    } catch (e) {
      _items = [];
      _disabledItems = [];
    }
  }

  Future<void> addItem(InventoryItem newItem) async {
    final locId = activeLocationId;
    if (locId == null) {
      return;
    }

    final skuTaken = _disabledItems.any(
      (i) => i.sku.trim().toLowerCase() == newItem.sku.trim().toLowerCase(),
    );
    if (skuTaken) {
      throw Exception(
        'This SKU belongs to a disabled item. Restore it from '
        'Inventory > Show disabled instead of adding a new one.',
      );
    }

    try {
      final response = await supabase
          .from('products')
          .insert({
            'sku': newItem.sku,
            'product_name': newItem.name,
            'category': newItem.category,
            'product_price': newItem.price,
            'product_quantity': newItem.quantity,
            'description': newItem.description,
            'image_url': newItem.imageUrl,
            'location_id': locId,
            'manufacturer': newItem.manufacturer,
            'model': newItem.model,
            'product_size': newItem.productSize,
            'shelf_level': newItem.shelfLevel,
            'bin_number': newItem.binNumber,
            'unit': newItem.unit,
            'max_quantity': newItem.maxQuantity,
          })
          .select()
          .single();

      final savedItem = InventoryItem.fromSupabase(response);
      _items.add(savedItem);
      _baselineByProduct[savedItem.id] = savedItem.quantity; 

      await _logTransaction(
        productId: savedItem.id,
        type: 'add',
        quantityChange: savedItem.quantity,
        newQuantity: savedItem.quantity,
      );
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _logTransaction({
    String? productId,
    required String type,
    required double quantityChange,
    required double newQuantity,
    String? note,
  }) async {
    final locId = activeLocationId;
    final userId = currentUserId;
    final userName = currentUserName ?? 'Unknown User';

    if (locId == null || userId == null) return;
    try {
      final Map<String, dynamic> insertData = {
        'product_id': productId,
        'transaction_type': type,
        'quantity_change': quantityChange,
        'new_quantity': newQuantity,
        'location_id': locId,
        'user_id': int.tryParse(userId) ?? userId,
        'user_name': userName,
        if (note != null && note.isNotEmpty) 'note': note,
      };

      await supabase.from('transaction_history').insert(insertData);
    } catch (e) {}
  }

  Future<String?> uploadProductImage(File imageFile, String fileName) async {
    try {
      final path = 'public/${DateTime.now().millisecondsSinceEpoch}_$fileName';
      await supabase.storage.from('product_images').upload(path, imageFile);
      return supabase.storage.from('product_images').getPublicUrl(path);
    } catch (e) {
      return null;
    }
  }

  Future<void> writeOffStock(
    String id,
    double qty, {
    required String reason,
    String? note,
  }) async {
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) throw Exception('Item not found or is disabled.');
    final item = _items[index];

    if (qty <= 0) throw Exception('Quantity must be greater than 0.');
    if (qty > item.quantity) {
      throw Exception('Cannot remove more than the current stock.');
    }

    final newQty = item.quantity - qty;
    await supabase
        .from('products')
        .update({'product_quantity': newQty})
        .eq('id', id);

    _items[index] = item.copyWith(quantity: newQty);

    await _logTransaction(
      productId: id,
      type: 'write_off',
      quantityChange: -qty,
      newQuantity: newQty,
      note: (note == null || note.trim().isEmpty)
          ? reason
          : '$reason: ${note.trim()}',
    );
  }

  Future<String?> uploadImageBytes(
    Uint8List imageBytes,
    String fileName,
  ) async {
    try {
      final path = 'public/${DateTime.now().millisecondsSinceEpoch}_$fileName';
      await supabase.storage
          .from('product_images')
          .uploadBinary(path, imageBytes);
      return supabase.storage.from('product_images').getPublicUrl(path);
    } catch (e) {
      return null;
    }
  }

  Future<void> updateItem(InventoryItem updatedItem) async {
    final index = _items.indexWhere((item) => item.id == updatedItem.id);
    final oldItem = index != -1 ? _items[index] : null;

    // 1. Write to the DB first. If this throws, nothing local has changed.
    await supabase
        .from('products')
        .update({
          'product_name': updatedItem.name,
          'sku': updatedItem.sku,
          'product_price': updatedItem.price,
          'product_quantity': updatedItem.quantity,
          'description': updatedItem.description,
          'manufacturer': updatedItem.manufacturer,
          'model': updatedItem.model,
          'product_size': updatedItem.productSize,
          'shelf_level': updatedItem.shelfLevel,
          'bin_number': updatedItem.binNumber,
          'image_url': updatedItem.imageUrl,
          'unit': updatedItem.unit,
          'max_quantity': updatedItem.maxQuantity,
        })
        .eq('id', updatedItem.id);

    // 2. Only after success: update local state, log, refresh baselines.
    if (index != -1 && oldItem != null) {
      final quantityChange = updatedItem.quantity - oldItem.quantity;
      _items[index] = updatedItem;

      if (quantityChange != 0) {
        await _logTransaction(
          productId: updatedItem.id,
          type: quantityChange > 0 ? 'stock_in' : 'checkout',
          quantityChange: quantityChange,
          newQuantity: updatedItem.quantity,
        );
        if (quantityChange > 0) await _loadStockBaselines();
      }
    }
  }

  Future<bool> _isInOpenOrder(String productId) async {
    final locId = activeLocationId;
    if (locId == null) return false;
    final rows = await supabase
        .from('orders')
        .select('items')
        .eq('location_id', locId)
        .inFilter('status', ['pending', 'prepared', 'solo_picking']);

    for (final r in List<Map<String, dynamic>>.from(rows)) {
      final items = r['items'] as List<dynamic>? ?? [];
      final hit = items.any(
        (i) => i is Map && i['product_id']?.toString() == productId,
      );
      if (hit) return true;
    }
    return false;
  }

  Future<void> disableItem(String id) async {
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) return;

    if (await _isInOpenOrder(id)) {
      throw Exception(
        'This item is in an open order. Complete or cancel the order first.',
      );
    }

    await supabase.from('products').update({'is_active': false}).eq('id', id);

    final item = _items.removeAt(index);
    _disabledItems.add(item);

    await _logTransaction(
      productId: id,
      type: 'item_disabled',
      quantityChange: 0,
      newQuantity: item.quantity,
    );
  }

  Future<void> restoreItem(String id) async {
    final index = _disabledItems.indexWhere((i) => i.id == id);
    if (index == -1) return;

    await supabase.from('products').update({'is_active': true}).eq('id', id);

    final item = _disabledItems.removeAt(index);
    _items.add(item);

    await _logTransaction(
      productId: id,
      type: 'item_restored',
      quantityChange: 0,
      newQuantity: item.quantity,
    );
  }

  Future<void> deleteItem(String id) async {
    final index = _disabledItems.indexWhere((i) => i.id == id);
    if (index == -1) {
      throw Exception(
        'Only disabled items can be deleted. Disable the item first.',
      );
    }

    await supabase.from('products').delete().eq('id', id); // throws on failure

    final itemToDelete = _disabledItems.removeAt(index);
    await _logTransaction(
      productId: null,
      type: 'delete',
      quantityChange: -itemToDelete.quantity,
      newQuantity: 0,
    );
  }

  Future<void> updateItemLocationDetails(
    String itemId, {
    required int shelf,
    required String layer,
  }) async {
    try {
      await supabase
          .from('products')
          .update({
            'shelf_level': shelf.toString(),
            'bin_number': layer,
          })
          .eq('id', itemId);

      final index = _items.indexWhere((item) => item.id == itemId);
      if (index != -1) {
        _items[index] = _items[index].copyWith(
          shelfLevel: shelf.toString(),
          binNumber: layer,
        );
      }
    } catch (e) {}
  }

  List<InventoryItem> get unassignedItems =>
      _items.where((item) => item.shelfLevel == null || item.shelfLevel!.isEmpty).toList();

  List<InventoryItem> _applyFilter(
    List<InventoryItem> source,
    String query,
    String category,
  ) {
    final filtered = source.where((item) {
      final matchesSearch =
          item.name.toLowerCase().contains(query.toLowerCase()) ||
          item.sku.toLowerCase().contains(query.toLowerCase());

      final matchesCategory =
          category == 'All' ||
          (category == 'Unassigned' &&
              (item.shelfLevel == null || item.shelfLevel!.isEmpty)) ||
          item.category == category;

      return matchesSearch && matchesCategory;
    }).toList();

    filtered.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return filtered;
  }

   List<InventoryItem> filterInventory({
    required String query,
    required String category,
  }) => _applyFilter(_items, query, category);

  List<InventoryItem> filterDisabled({
    required String query,
    required String category,
  }) => _applyFilter(_disabledItems, query, category);

  List<String> getUniqueCategories() {
    final categories = _items.map((item) => item.category).toSet().toList();
    categories.sort();
    return ['All', 'Unassigned', ...categories];
  }

  InventoryItem prepareUpdatedItem({
    required InventoryItem originalItem,
    required String newName,
    required String newSku,
    required String newPrice,
    required String newStock,
    required String newMaxStock,
    required String newDesc,
    String? manufacturer,
    String? model,
    String? productSize,
    String? shelfLevel,
    String? binNumber,
    String? imageUrl,
    String? unit,
  }) {
    return originalItem.copyWith(
      name: newName,
      sku: newSku,
      price: double.tryParse(newPrice) ?? originalItem.price,
      quantity: double.tryParse(newStock) ?? originalItem.quantity,
      maxQuantity: double.tryParse(newMaxStock) ?? originalItem.maxQuantity,
      description: newDesc,
      manufacturer: manufacturer,
      model: model,
      productSize: productSize,
      shelfLevel: shelfLevel,
      binNumber: binNumber,
      imageUrl: imageUrl,
      unit: unit,
    );
  }

  InventoryItem createNewItem({
    required String name,
    required String sku,
    required String price,
    required String quantity,
    required String maxQuantity,
    required String category,
    required String description,
    String? manufacturer,
    String? model,
    String? productSize,
    String? shelfLevel,
    String? binNumber,
    String? imageUrl,
    String unit = 'pcs',
  }) {
    double parsedQty = double.tryParse(quantity) ?? 0.0;
    double parsedMax = double.tryParse(maxQuantity) ?? parsedQty;

    return InventoryItem(
      id: '',
      name: name,
      sku: sku,
      price: double.tryParse(price) ?? 0.0,
      quantity: parsedQty,
       maxQuantity: parsedMax == 0 ? parsedQty : parsedMax,
      category: category,
      description: description,
      manufacturer: manufacturer,
      model: model,
      productSize: productSize,
      shelfLevel: shelfLevel,
      binNumber: binNumber,
      imageUrl: imageUrl ?? '',
      unit: unit,
    );
  }

  InventoryItem calculateCheckout(InventoryItem item, double quantity) {
    return item.copyWith(
      quantity: (item.quantity - quantity).clamp(0.0, 999999.0),
    );
  }

  InventoryItem? findItemByCode(String code) {
    try {
      return _items.firstWhere((item) => item.sku.trim() == code.trim());
    } catch (e) {
      return null;
    }
  }

  List<InventoryItem> searchInventory(String query) {
    if (query.isEmpty) return _items;

    final lowercaseQuery = query.toLowerCase();
    return _items.where((item) {
      return item.name.toLowerCase().contains(lowercaseQuery) ||
          item.sku.toLowerCase().contains(lowercaseQuery) ||
          item.category.toLowerCase().contains(lowercaseQuery);
    }).toList();
  }

  Future<List<Map<String, dynamic>>> fetchStaff() async {
    final locId = activeLocationId;
    if (locId == null) return [];
    try {
      final response = await supabase
          .from('profiles')
          .select()
          .eq('location_id', locId);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  Future<bool> createStaff({
    required String name,
    required String username,
    required String password,
    required String role,
    String? email,
    String? phone,
    String? address,
  }) async {
    final locId = activeLocationId;
    if (locId == null) return false;
    try {
      final hashedPassword = _hashPassword(password);

      await supabase.from('profiles').insert({
        'name': name,
        'username': username,
        'password': hashedPassword,
        'role': role,
        'location_id': locId,
        'email': email,
        'phone': phone,
        'address': address,
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> updateStaffRole(String id, String newRole) async {
    try {
      await supabase.from('profiles').update({'role': newRole}).eq('id', id);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> deleteStaff(String id) async {
    try {
      await supabase.from('profiles').delete().eq('id', id);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<String?> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    if (currentUserId == null) return "User not logged in.";
    try {
      final hashedCurrentPassword = _hashPassword(currentPassword);
      final hashedNewPassword = _hashPassword(newPassword);

      final response = await supabase
          .from('profiles')
          .select('password')
          .eq('id', currentUserId!)
          .single();

      if (response['password'] != hashedCurrentPassword) {
        return "Incorrect current password.";
      }

      await supabase
          .from('profiles')
          .update({'password': hashedNewPassword})
          .eq('id', currentUserId!);
      return null;
    } catch (e) {
      return "An error occurred while changing the password.";
    }
  }

  Future<List<Map<String, dynamic>>> fetchTransactionHistory(
    String productId,
  ) async {
    try {
      final response = await supabase
          .from('transaction_history')
          .select('*, profiles(name, role)')
          .eq('product_id', productId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchAllTransactionHistory() async {
    final locId = activeLocationId;
    if (locId == null) return [];
    try {
      final response = await supabase
          .from('transaction_history')
          .select('*, products(product_name, sku), profiles(name, role)')
          .eq('location_id', locId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      return [];
    }
  }

  Future<void> clearTransactionHistory() async {
    final locId = activeLocationId;
    if (locId == null) return;
    try {
      await supabase
          .from('transaction_history')
          .delete()
          .eq('location_id', locId);
    } catch (e) {}
  }

  Future<List<Map<String, dynamic>>> generateInventoryAnalytics({
    int days = 30,
    int leadTimeDays = 7,
  }) async {
    final locId = activeLocationId;
    if (locId == null) return [];

    try {
      final cutoffDate = DateTime.now()
          .subtract(Duration(days: days))
          .toIso8601String();

      final response = await supabase
          .from('transaction_history')
          .select('product_id, quantity_change, created_at')
          .eq('location_id', locId)
          .eq('transaction_type', 'checkout')
          .gte('created_at', cutoffDate);

      final transactions = List<Map<String, dynamic>>.from(response);

      Map<String, int> salesData = {};
      for (var tx in transactions) {
        final String? pId = tx['product_id']?.toString();
        if (pId != null) {
          final int qty = (tx['quantity_change'] as num).abs().toInt();
          salesData[pId] = (salesData[pId] ?? 0) + qty;
        }
      }

      List<Map<String, dynamic>> analyticsList = [];

      for (var item in _items) {
        final totalSold = salesData[item.id] ?? 0;
        final dailySalesVelocity = totalSold / days;

        String classification;
        if (totalSold == 0) {
          classification = 'Dead Stock';
        } else if (dailySalesVelocity >= 1.0) {
          classification = 'Fast-Moving';
        } else {
          classification = 'Slow-Moving';
        }

        double daysUntilStockout = -1;
        DateTime? stockoutDate;
        if (dailySalesVelocity > 0) {
          daysUntilStockout = item.quantity / dailySalesVelocity;
          stockoutDate = DateTime.now().add(
            Duration(days: daysUntilStockout.floor()),
          );
        }

        int safetyStock = 0;
        int reorderPoint = 0;
        int optimalReorderQuantity = 0;

        if (classification == 'Fast-Moving') {
          safetyStock = (leadTimeDays * dailySalesVelocity * 1.5).ceil();
          reorderPoint =
              (leadTimeDays * dailySalesVelocity).ceil() + safetyStock;
          optimalReorderQuantity = (dailySalesVelocity * 30).ceil();
        } else if (classification == 'Slow-Moving') {
          safetyStock = (leadTimeDays * dailySalesVelocity * 1.0).ceil();
          reorderPoint =
              (leadTimeDays * dailySalesVelocity).ceil() + safetyStock;
          optimalReorderQuantity = (dailySalesVelocity * 15).ceil();
        } else {
          safetyStock = 0;
          reorderPoint = 0;
          optimalReorderQuantity = 0;
        }

        analyticsList.add({
          'item': item,
          'totalSoldLast30Days': totalSold,
          'dailySalesVelocity': dailySalesVelocity,
          'classification': classification,
          'daysUntilStockout': daysUntilStockout,
          'stockoutDate': stockoutDate,
          'safetyStock': safetyStock,
          'reorderPoint': reorderPoint,
          'optimalReorderQuantity': optimalReorderQuantity,
          'needsReorder':
              item.quantity <= reorderPoint && classification != 'Dead Stock',
        });
      }

      analyticsList.sort((a, b) {
        if (a['needsReorder'] && !b['needsReorder']) return -1;
        if (!a['needsReorder'] && b['needsReorder']) return 1;
        if (a['daysUntilStockout'] != -1 && b['daysUntilStockout'] != -1) {
          return (a['daysUntilStockout'] as double).compareTo(
            b['daysUntilStockout'] as double,
          );
        }
        return 0;
      });

      return analyticsList;
    } catch (e) {
      return [];
    }
  }

  // CHANGE 1: Update the signature to return Future<CustomerOrder?>
  Future<CustomerOrder?> createCustomerOrder(
    List<CustomerOrderItem> items, {
    required double totalAmount,
    required double discountAmount,
    String? paymentMode,
    double? cashGiven,
    double? changeAmount,
    bool soloHandled = false,  
  }) async {
    final locId = activeLocationId;
    if (locId == null) return null; // CHANGE 2: return null

    for (final oi in items) {
      if (!_items.any((i) => i.id == oi.productId)) {
        throw Exception(
          'An item in this order is no longer available. '
          'Remove it from the cart and try again.',
        );
      }
    }

    try {
      final response = await supabase.from('orders').insert({
        'location_id': locId,
        'status': 'pending',
        'total_amount': totalAmount,
        'discount_amount': discountAmount,
        'payment_mode': paymentMode ?? 'Cash',
        'cash_given': cashGiven,
        'change_amount': changeAmount,
        'items': items.map((i) => i.toJson()).toList(),
        'created_by': currentUserNumericId,
        'status': soloHandled ? 'solo_picking' : 'pending', 
      }).select();

      for (var orderItem in items) {
        final index = _items.indexWhere((i) => i.id == orderItem.productId);
        if (index != -1) {
          final currentItem = _items[index];
          final updatedItem = calculateCheckout(
            currentItem,
            orderItem.quantity,
          );
          await updateItem(updatedItem);
        }
      }

      // CHANGE 3: Return the created order object
      if (response.isNotEmpty) {
        return CustomerOrder.fromJson(response.first);
      }
      return null;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> cancelOrder(CustomerOrder order) async {
    final row = await supabase
        .from('orders')
        .select('status')
        .eq('id', order.id)
        .single();
    final status = row['status'];
    if (status == 'completed' || status == 'cancelled') {
      throw Exception('Order is already $status.');
    }

    await supabase
        .from('orders')
        .update({'status': 'cancelled'})
        .eq('id', order.id);

    for (final oi in order.items) {
      final index = _items.indexWhere((i) => i.id == oi.productId);
      if (index == -1) continue;
      final restored = _items[index].copyWith(
        quantity: _items[index].quantity + oi.quantity,
      );
      await supabase
          .from('products')
          .update({'product_quantity': restored.quantity})
          .eq('id', restored.id);
      _items[index] = restored;
      await _logTransaction(
        productId: restored.id,
        type: 'order_cancelled',
        quantityChange: oi.quantity,
        newQuantity: restored.quantity,
      );
    }
  }

Stream<List<CustomerOrder>> streamOrders() {
    final locId = activeLocationId;
    if (locId == null) return Stream.value([]);

    return supabase
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('location_id', locId)
        .order('created_at', ascending: false)
        .map(
          (list) =>
              list.map((item) => CustomerOrder.fromJson(item)).toList(),
        );
  }

 Future<void> updateOrderStatus(String orderId, String newStatus) async {
    try {
      final Map<String, dynamic> updateData = {'status': newStatus};
      if (newStatus == 'prepared') {
        updateData['prepared_by'] = currentUserNumericId;
        updateData['prepared_at'] = DateTime.now().toUtc().toIso8601String();
      }
      await supabase
          .from('orders')
          .update(updateData)
          .eq('id', orderId)
          .neq('status', 'cancelled')
          .neq('status', 'completed');
    } catch (e) {}
  }

  Set<String>? _processingOrders;

    Future<({DateTime createdAt, DateTime completedAt})?> completeOrder(
    CustomerOrder order, {
    String? paymentMode,
    double? cashGiven,
    double? changeAmount,
  }) async {
    _processingOrders ??= {};
    if (_processingOrders!.contains(order.id)) return null;
    _processingOrders!.add(order.id);

    try {
      final checkOrder = await supabase
          .from('orders')
          .select('status')
          .eq('id', order.id)
          .single();
      final s = checkOrder['status'];
      if (s == 'completed') return null;
      if (s == 'cancelled') throw Exception('This order was cancelled.');

      final completedAt = DateTime.now().toUtc();
      final Map<String, dynamic> updateData = {
        'status': 'completed',
        'completed_at': completedAt.toIso8601String(),
      };
      if (paymentMode != null) updateData['payment_mode'] = paymentMode;
      if (cashGiven != null) updateData['cash_given'] = cashGiven;
      if (changeAmount != null) updateData['change_amount'] = changeAmount;

      final row = await supabase
          .from('orders')
          .update(updateData)
          .eq('id', order.id)
          .select('created_at')
          .single();

      return (
        createdAt: DateTime.parse(row['created_at'].toString()).toLocal(),
        completedAt: completedAt.toLocal(),
      );
    } finally {
      _processingOrders!.remove(order.id);
    }
  }

  Future<void> updateProfile({
    required String userId,
    required String name,
    required String email,
    required String location,
    required String phone,
  }) async {
    try {
      final updateData = {
        'name': name,
        'email': email.isEmpty ? null : email,
        'address': location,
        'phone': phone,
      };

      await Supabase.instance.client
          .from('profiles')
          .update(updateData)
          .eq('id', userId);
    } catch (e) {
      throw Exception("Failed to save changes to the database.");
    }
  }

  Future<bool> adminResetUserPassword(
    String targetUserId,
    String newPassword,
  ) async {
    try {
      final hashedNewPassword = _hashPassword(newPassword);

      await supabase
          .from('profiles')
          .update({'password': hashedNewPassword})
          .eq('id', targetUserId);

      return true;
    } catch (e) {
      return false;
    }
  }
  Future<void> fetchMapLayout() async {
    final locId = activeLocationId;
    if (locId == null) return;

    try {
      final locationResponse = await supabase
          .from('locations')
          .select('layout_data')
          .eq('id', locId)
          .maybeSingle();

      if (locationResponse != null && locationResponse['layout_data'] != null) {
        final List<dynamic> layoutJson = locationResponse['layout_data'] is String 
              ? jsonDecode(locationResponse['layout_data']) 
              : locationResponse['layout_data'];
              
        storeLayout = layoutJson.map((el) => MapElement.fromJson(el as Map<String, dynamic>)).toList();
        debugPrint("✅ Map loaded successfully: ${storeLayout.length} elements.");
      } else {
        storeLayout = [];
      }
    } catch (e) {
      debugPrint("❌ Error parsing map data: $e");
      storeLayout = [];
    }
  }
  // ─── MAP EDITOR METHODS ────────────────────────────────────────────────────

  Future<void> saveLayout() async {
    final locId = activeLocationId;
    if (locId == null) return;

    try {
      // Using your exact old working serialization method!
      final String encodedData = jsonEncode(
        storeLayout.map((el) => el.toJson()).toList(),
      );

      // Adding .select() forces Supabase to return the row if it succeeded
      final response = await supabase
          .from('locations')
          .update({'layout_data': jsonDecode(encodedData)})
          .eq('id', locId)
          .select(); 
          
      if (response.isEmpty) {
        debugPrint("❌ ALERT: Location ID '$locId' does not exist in the locations table! Map cannot save.");
      } else {
        debugPrint("✅ Map saved to database successfully!");
      }
    } catch (e) {
      debugPrint("❌ Error saving layout: $e");
    }
  }

  Future<void> clearMapLayout() async {
    final locId = activeLocationId;
    if (locId == null) return;

    try {
      storeLayout.clear();

      final response = await supabase
          .from('locations')
          .update({'layout_data': null})
          .eq('id', locId)
          .select();

      if (response.isEmpty) {
        debugPrint("❌ ALERT: Location ID '$locId' does not exist!");
      } else {
        debugPrint("✅ Map cleared successfully!");
      }
    } catch (e) {
      debugPrint("❌ Error clearing layout: $e");
    }
  }
  void deleteMapElement(String id) {
    storeLayout.removeWhere((element) => element.id == id);
  }

  Future<void> assignItemToLocation(String itemId, String mapElementId) async {
    try {
      await supabase
          .from('products')
          .update({'map_element_id': mapElementId})
          .eq('id', itemId);
      
      final index = allItems.indexWhere((item) => item.id == itemId);
      if (index != -1) {
        allItems[index] = allItems[index].copyWith(locationId: mapElementId);
      }
    } catch (e) {
      debugPrint("Error assigning item to location: $e");
      rethrow;
    }
  }
  
}