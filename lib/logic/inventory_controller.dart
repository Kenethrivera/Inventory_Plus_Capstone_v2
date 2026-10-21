import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypto/crypto.dart';
import '../data/inventory.dart';
import '../services/realtime/realtime_sync_service.dart';
import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:async';

enum StockStatus { ok, low, critical, out }

enum MapLayoutSaveStatus { saved, conflict }

enum ChangePasswordResult {
  success,
  incorrectCurrentPassword,
  sameAsCurrentPassword,
  invalidNewPassword,
  concurrentChange,
  notAuthenticated,
  unexpectedFailure,
}

enum CurrentPasswordVerificationResult {
  correct,
  incorrect,
  notAuthenticated,
  unexpectedFailure,
}

class MapLayoutSaveResult {
  const MapLayoutSaveResult({
    required this.status,
    required this.layout,
    required this.signature,
  });

  final MapLayoutSaveStatus status;
  final List<MapElement> layout;
  final String signature;
}

class OrderHistoryData {
  const OrderHistoryData({
    required this.orders,
    required this.profileNamesById,
  });

  final List<Map<String, dynamic>> orders;
  final Map<String, String> profileNamesById;
}

class StockThresholdSettings {
  const StockThresholdSettings({required this.low, required this.critical});

  final double low;
  final double critical;
}

class InventoryRuntimeSettingsSnapshot {
  const InventoryRuntimeSettingsSnapshot({
    required this.lowStockPercent,
    required this.criticalStockPercent,
    required this.measurements,
    required this.gcashQrUrl,
    required this.thresholdsLoaded,
    required this.measurementsLoaded,
    required this.paymentLoaded,
  });

  final double lowStockPercent;
  final double criticalStockPercent;
  final List<Map<String, dynamic>> measurements;
  final String gcashQrUrl;
  final bool thresholdsLoaded;
  final bool measurementsLoaded;
  final bool paymentLoaded;
}

class CurrentUserProfileSnapshot {
  const CurrentUserProfileSnapshot({
    required this.id,
    required this.locationId,
    required this.name,
    required this.role,
    required this.mustChangePassword,
    this.email,
    this.address,
    this.phone,
  });

  final String id;
  final String locationId;
  final String name;
  final String role;
  final bool mustChangePassword;
  final String? email;
  final String? address;
  final String? phone;
}

class _SerializedHistoryQuery {
  Future<List<Map<String, dynamic>>>? inFlight;
  bool queued = false;
}

class InventoryController {
  // shared realtime controlelrs
  final StreamController<List<CustomerOrder>> _ordersController =
      StreamController<List<CustomerOrder>>.broadcast();
  final StreamController<List<InventoryItem>> _inventoryController =
      StreamController<List<InventoryItem>>.broadcast();
  final StreamController<void> _transactionHistoryInvalidationsController =
      StreamController<void>.broadcast();
  final StreamController<List<MapElement>> _mapLayoutController =
      StreamController<List<MapElement>>.broadcast();
  final StreamController<InventoryRuntimeSettingsSnapshot>
  _runtimeSettingsController =
      StreamController<InventoryRuntimeSettingsSnapshot>.broadcast();
  final StreamController<List<Map<String, dynamic>>>
  _staffConfigurationController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final StreamController<CurrentUserProfileSnapshot?>
  _currentUserProfileController =
      StreamController<CurrentUserProfileSnapshot?>.broadcast();

  StreamSubscription<void>? _orderChangesSubscription;
  StreamSubscription<void>? _inventoryChangesSubscription;
  StreamSubscription<void>? _transactionHistoryChangesSubscription;
  StreamSubscription<void>? _mapLayoutChangesSubscription;
  StreamSubscription<RuntimeSettingsChangeKind>?
  _runtimeSettingsChangesSubscription;
  StreamSubscription<void>? _staffConfigurationChangesSubscription;
  StreamSubscription<void>? _currentProfileChangesSubscription;

  final Map<String, _SerializedHistoryQuery> _historyQueries =
      <String, _SerializedHistoryQuery>{};
  Future<OrderHistoryData>? _orderHistoryRefreshInFlight;
  bool _orderHistoryRefreshQueued = false;

  List<CustomerOrder> _ordersSnapshot = const <CustomerOrder>[];

  String? _ordersSnapshotLocationId;

  bool _ordersSnapshotLoaded = false;
  bool _ordersAwaitingRealtimeInitial = false;

  Future<void>? _ordersRefreshInFlight;

  bool _ordersRefreshQueued = false;

  String? _inventorySnapshotLocationId;
  bool _inventorySnapshotLoaded = false;
  bool _inventoryAwaitingRealtimeInitial = false;
  Future<void>? _inventoryRefreshInFlight;
  bool _inventoryRefreshQueued = false;

  final SupabaseClient supabase = Supabase.instance.client;
  int? currentUserNumericId;
  List<InventoryItem> _items = [];
  List<InventoryItem> get allItems => List<InventoryItem>.unmodifiable(_items);
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
  String? _mapLayoutLocationId;
  String? _mapLayoutLoadLocationId;
  Future<void>? _mapLayoutLoadInFlight;
  bool _mapLayoutLoaded = false;
  bool _mapLayoutStale = true;
  bool _mapLayoutRefreshQueued = false;
  Future<MapLayoutSaveResult>? _mapLayoutSaveInFlight;

  bool _thresholdSettingsLoaded = false;
  bool _measurementSettingsLoaded = false;
  bool _measurementSettingsActivated = false;
  bool _paymentSettingsLoaded = false;
  Future<void>? _thresholdRefreshInFlight;
  Future<void>? _measurementRefreshInFlight;
  Future<void>? _paymentRefreshInFlight;
  bool _thresholdRefreshQueued = false;
  bool _measurementRefreshQueued = false;
  bool _paymentRefreshQueued = false;

  List<Map<String, dynamic>> _staffSnapshot = const [];
  String? _staffSnapshotLocationId;
  bool _staffSnapshotLoaded = false;
  bool _staffSnapshotActivated = false;
  bool _staffConfigurationLoadFailed = false;
  Future<void>? _staffRefreshInFlight;
  bool _staffRefreshQueued = false;
  Future<void>? _currentProfileRefreshInFlight;
  bool _currentProfileRefreshQueued = false;
  CurrentUserProfileSnapshot? _currentProfileSnapshot;

  static const int _baselineRestocks = 3;
  static const int _baselineWindowDays = 180;
  Map<String, double> _baselineByProduct = {};

  String gcashQrUrl = '';

  Future<void> loadStoreSettings() async {
    if (_paymentSettingsLoaded) return;
    await _refreshPaymentSettings();
  }

  Future<void> updateGcashQrUrl(String newUrl) async {
    try {
      await supabase
          .from('store_settings')
          .update({'gcash_qr_url': newUrl})
          .eq('id', 1);

      gcashQrUrl = newUrl;
      _paymentSettingsLoaded = true;
      _publishRuntimeSettings();
    } catch (e) {
      debugPrint("Error updating GCash QR: $e");
      throw Exception("Failed to save QR URL to database.");
    }
  }

  Future<void> Function({
    required String locationId,
    required String transactionId,
    required String productId,
    required String productName,
    required String staffId,
    required String staffName,
    required double quantityAdded,
    required double newQuantity,
  })?
  onRestockRecorded;

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
      if (activeLocationId != locId) return;
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
  List<InventoryItem> get reportableItems => List<InventoryItem>.unmodifiable(
    <InventoryItem>[..._items, ..._disabledItems],
  );

  void setLoggedInUser({
    required String name,
    required String id,
    required String role,
    String? email,
  }) {
    if (currentUserId != id) {
      _clearInventorySnapshot();
      _clearOrdersSnapshot();
      _inventoryAwaitingRealtimeInitial = true;
      _ordersAwaitingRealtimeInitial = true;
      _clearStaffConfigurationSnapshot();
      _currentProfileSnapshot = null;
    }

    currentUserName = name;
    currentUserId = id;
    currentUserRole = role;
    currentUserNumericId = int.tryParse(id);
    loggedInUserEmail = email;
  }

  void setActiveLocation(String locationId) {
    if (activeLocationId == locationId) return;

    activeLocationId = locationId;
    _clearInventorySnapshot();
    _clearOrdersSnapshot();
    _inventoryAwaitingRealtimeInitial = true;
    _ordersAwaitingRealtimeInitial = true;
    storeLayout = <MapElement>[];
    _mapLayoutLocationId = null;
    _mapLayoutLoaded = false;
    _mapLayoutStale = true;
    _mapLayoutRefreshQueued = false;
    _publishMapLayoutSnapshot();
    _clearStaffConfigurationSnapshot();
  }

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<void> loadSystemSettings() async {
    _measurementSettingsActivated = true;
    await Future.wait<void>([
      if (!_thresholdSettingsLoaded) _refreshThresholdSettings(),
      if (!_measurementSettingsLoaded) _refreshMeasurementSettings(),
    ]);
  }

  Future<void> loadStockThresholdSettings() async {
    if (_thresholdSettingsLoaded) return;
    await _refreshThresholdSettings();
  }

  Stream<InventoryRuntimeSettingsSnapshot> streamRuntimeSettings() async* {
    yield _runtimeSettingsSnapshot;
    yield* _runtimeSettingsController.stream;
  }

  InventoryRuntimeSettingsSnapshot get _runtimeSettingsSnapshot =>
      InventoryRuntimeSettingsSnapshot(
        lowStockPercent: globalLowStockPct,
        criticalStockPercent: globalCriticalPct,
        measurements: List<Map<String, dynamic>>.unmodifiable(
          availableMeasurements.map(Map<String, dynamic>.from),
        ),
        gcashQrUrl: gcashQrUrl,
        thresholdsLoaded: _thresholdSettingsLoaded,
        measurementsLoaded: _measurementSettingsLoaded,
        paymentLoaded: _paymentSettingsLoaded,
      );

  void _publishRuntimeSettings() {
    _runtimeSettingsController.add(_runtimeSettingsSnapshot);
  }

  Future<StockThresholdSettings> fetchStockThresholdSettings() async {
    final response = await supabase
        .from('threshold')
        .select('low_stock, critical')
        .eq('id', 1)
        .maybeSingle();
    return StockThresholdSettings(
      low: (response?['low_stock'] as num?)?.toDouble() ?? 20.0,
      critical: (response?['critical'] as num?)?.toDouble() ?? 10.0,
    );
  }

  Future<void> _refreshThresholdSettings() {
    final inFlight = _thresholdRefreshInFlight;
    if (inFlight != null) {
      _thresholdRefreshQueued = true;
      return inFlight;
    }
    final refresh = _performThresholdRefresh();
    _thresholdRefreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_thresholdRefreshInFlight, refresh)) {
        _thresholdRefreshInFlight = null;
      }
      if (_thresholdRefreshQueued) {
        _thresholdRefreshQueued = false;
        unawaited(_refreshThresholdSettings());
      }
    });
  }

  Future<void> _performThresholdRefresh() async {
    try {
      final settings = await fetchStockThresholdSettings();
      globalLowStockPct = settings.low;
      globalCriticalPct = settings.critical;
      _thresholdSettingsLoaded = true;
      _publishRuntimeSettings();
      _publishInventorySnapshot();
      debugPrint('[InventoryController] THRESHOLD SETTINGS REFRESHED');
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Threshold refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _refreshMeasurementSettings() {
    final inFlight = _measurementRefreshInFlight;
    if (inFlight != null) {
      _measurementRefreshQueued = true;
      return inFlight;
    }
    final refresh = _performMeasurementRefresh();
    _measurementRefreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_measurementRefreshInFlight, refresh)) {
        _measurementRefreshInFlight = null;
      }
      if (_measurementRefreshQueued) {
        _measurementRefreshQueued = false;
        unawaited(_refreshMeasurementSettings());
      }
    });
  }

  Future<void> _performMeasurementRefresh() async {
    try {
      final rows = await supabase
          .from('measurements')
          .select('id, name, symbol');
      availableMeasurements = List<Map<String, dynamic>>.from(rows);
      _measurementSettingsLoaded = true;
      _publishRuntimeSettings();
      debugPrint(
        '[InventoryController] MEASUREMENT SETTINGS REFRESHED '
        'count=${availableMeasurements.length}',
      );
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Measurement refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _refreshPaymentSettings() {
    final inFlight = _paymentRefreshInFlight;
    if (inFlight != null) {
      _paymentRefreshQueued = true;
      return inFlight;
    }
    final refresh = _performPaymentRefresh();
    _paymentRefreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_paymentRefreshInFlight, refresh)) {
        _paymentRefreshInFlight = null;
      }
      if (_paymentRefreshQueued) {
        _paymentRefreshQueued = false;
        unawaited(_refreshPaymentSettings());
      }
    });
  }

  Future<void> _performPaymentRefresh() async {
    try {
      final response = await supabase
          .from('store_settings')
          .select('gcash_qr_url')
          .eq('id', 1)
          .maybeSingle();
      gcashQrUrl = response?['gcash_qr_url']?.toString() ?? '';
      _paymentSettingsLoaded = true;
      _publishRuntimeSettings();
      debugPrint('[InventoryController] PAYMENT SETTINGS REFRESHED');
    } catch (error, stackTrace) {
      debugPrint(
        '[InventoryController] Payment settings refresh failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
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
      _thresholdSettingsLoaded = true;
      _publishRuntimeSettings();
      _publishInventorySnapshot();
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
      _measurementSettingsLoaded = true;
      _publishRuntimeSettings();
    } catch (e) {
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> fetchMeasurement(String id) async {
    final response = await supabase
        .from('measurements')
        .select('id, name, symbol')
        .eq('id', id)
        .maybeSingle();
    return response == null ? null : Map<String, dynamic>.from(response);
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
      _measurementSettingsLoaded = true;
      _publishRuntimeSettings();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteMeasurement(String id) async {
    try {
      await supabase.from('measurements').delete().eq('id', id);
      availableMeasurements.removeWhere((m) => m['id'].toString() == id);
      _measurementSettingsLoaded = true;
      _publishRuntimeSettings();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> loadAppData(String userLocationId) async {
    setActiveLocation(userLocationId);
    await Future.wait<void>([
      _refreshInventoryFromDatabase(),
      loadDeferredAppData(),
    ]);
  }

  Future<void> loadDeferredAppData() async {
    final stopwatch = Stopwatch()..start();
    if (kDebugMode) {
      debugPrint('[Startup] Deferred controller data started');
    }

    await Future.wait<void>([_loadStockBaselines()]);

    if (kDebugMode) {
      debugPrint(
        '[Startup] Deferred controller data finished '
        'elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
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
      _publishInventorySnapshot();

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

  Future<String?> _logTransaction({
    String? productId,
    required String type,
    required double quantityChange,
    required double newQuantity,
    String? note,
  }) async {
    final locId = activeLocationId;
    final userId = currentUserId;
    final userName = currentUserName ?? 'Unknown User';

    if (locId == null || userId == null) {
      throw StateError('Cannot log transaction without a user and location.');
    }

    final insertData = <String, dynamic>{
      'product_id': productId,
      'transaction_type': type,
      'quantity_change': quantityChange,
      'new_quantity': newQuantity,
      'location_id': locId,
      'user_id': int.tryParse(userId) ?? userId,
      'user_name': userName,
      if (note != null && note.isNotEmpty) 'note': note,
    };

    final saved = await supabase
        .from('transaction_history')
        .insert(insertData)
        .select('id')
        .single();

    return saved['id']?.toString();
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
    _publishInventorySnapshot();

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
      _publishInventorySnapshot();

      if (quantityChange != 0) {
        final transactionId = await _logTransaction(
          productId: updatedItem.id,
          type: quantityChange > 0 ? 'stock_in' : 'checkout',
          quantityChange: quantityChange,
          newQuantity: updatedItem.quantity,
        );

        if (quantityChange > 0) {
          await _loadStockBaselines();

          final callback = onRestockRecorded;
          final locationId = activeLocationId;
          final userId = currentUserId;

          if (callback != null &&
              transactionId != null &&
              locationId != null &&
              userId != null) {
            try {
              await callback(
                locationId: locationId,
                transactionId: transactionId,
                productId: updatedItem.id,
                productName: updatedItem.name,
                staffId: userId,
                staffName: currentUserName ?? 'Unknown User',
                quantityAdded: quantityChange,
                newQuantity: updatedItem.quantity,
              );
            } catch (e, stackTrace) {
              debugPrint('RESTOCK NOTIFICATION ERROR: $e');
              debugPrintStack(stackTrace: stackTrace);
            }
          }
        }
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
    _publishInventorySnapshot();

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
    _publishInventorySnapshot();

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
    _publishInventorySnapshot();
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
          .update({'shelf_level': shelf.toString(), 'bin_number': layer})
          .eq('id', itemId);

      final index = _items.indexWhere((item) => item.id == itemId);
      if (index != -1) {
        _items[index] = _items[index].copyWith(
          shelfLevel: shelf.toString(),
          binNumber: layer,
        );
        _publishInventorySnapshot();
      }
    } catch (e) {}
  }

  List<InventoryItem> get unassignedItems => _items
      .where((item) => item.shelfLevel == null || item.shelfLevel!.isEmpty)
      .toList();

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
    _staffSnapshotActivated = true;
    await _refreshStaffConfiguration();
    return List<Map<String, dynamic>>.unmodifiable(_staffSnapshot);
  }

  bool get staffConfigurationLoadFailed => _staffConfigurationLoadFailed;

  Stream<List<Map<String, dynamic>>> streamStaffConfiguration() async* {
    _staffSnapshotActivated = true;
    final locationId = activeLocationId;
    if (!_staffSnapshotLoaded || _staffSnapshotLocationId != locationId) {
      await _refreshStaffConfiguration();
    }
    yield List<Map<String, dynamic>>.unmodifiable(_staffSnapshot);
    yield* _staffConfigurationController.stream;
  }

  Stream<CurrentUserProfileSnapshot?> get currentUserProfileSnapshots =>
      _currentUserProfileController.stream;

  Future<CurrentUserProfileSnapshot?> refreshCurrentUserProfile() async {
    await _refreshCurrentProfile();
    return _currentProfileSnapshot;
  }

  void _clearStaffConfigurationSnapshot() {
    _staffSnapshot = const [];
    _staffSnapshotLocationId = null;
    _staffSnapshotLoaded = false;
    if (_staffSnapshotActivated) {
      _staffConfigurationController.add(const []);
    }
  }

  void _publishStaffConfigurationSnapshot() {
    if (_staffSnapshotActivated) {
      _staffConfigurationController.add(
        List<Map<String, dynamic>>.unmodifiable(_staffSnapshot),
      );
    }
  }

  Future<void> _refreshStaffConfiguration() {
    final inFlight = _staffRefreshInFlight;
    if (inFlight != null) {
      _staffRefreshQueued = true;
      return inFlight;
    }
    final refresh = _performStaffConfigurationRefresh();
    _staffRefreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_staffRefreshInFlight, refresh)) {
        _staffRefreshInFlight = null;
      }
      if (_staffRefreshQueued) {
        _staffRefreshQueued = false;
        unawaited(_refreshStaffConfiguration());
      }
    });
  }

  Future<void> _performStaffConfigurationRefresh() async {
    final locationId = activeLocationId;
    final userId = currentUserId;
    final role = currentUserRole?.toLowerCase();
    if (locationId == null ||
        locationId.isEmpty ||
        userId == null ||
        role != 'admin') {
      _clearStaffConfigurationSnapshot();
      return;
    }
    try {
      final rows = await supabase
          .from('profiles')
          .select()
          .eq('location_id', locationId);
      if (activeLocationId != locationId ||
          currentUserId != userId ||
          currentUserRole?.toLowerCase() != 'admin') {
        _staffRefreshQueued =
            _staffSnapshotActivated &&
            currentUserRole?.toLowerCase() == 'admin';
        return;
      }
      _staffSnapshot = List<Map<String, dynamic>>.unmodifiable(
        List<Map<String, dynamic>>.from(rows).map(Map<String, dynamic>.from),
      );
      _staffSnapshotLocationId = locationId;
      _staffSnapshotLoaded = true;
      _staffConfigurationLoadFailed = false;
      _staffConfigurationController.add(_staffSnapshot);
      debugPrint(
        '[InventoryController] STAFF CONFIGURATION REFRESHED '
        'location=$locationId count=${_staffSnapshot.length}',
      );
    } catch (error, stackTrace) {
      _staffConfigurationLoadFailed = true;
      debugPrint('[InventoryController] Staff refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _refreshCurrentProfile() {
    final inFlight = _currentProfileRefreshInFlight;
    if (inFlight != null) {
      _currentProfileRefreshQueued = true;
      return inFlight;
    }
    final refresh = _performCurrentProfileRefresh();
    _currentProfileRefreshInFlight = refresh;
    return refresh.whenComplete(() {
      if (identical(_currentProfileRefreshInFlight, refresh)) {
        _currentProfileRefreshInFlight = null;
      }
      if (_currentProfileRefreshQueued) {
        _currentProfileRefreshQueued = false;
        unawaited(_refreshCurrentProfile());
      }
    });
  }

  Future<void> _performCurrentProfileRefresh() async {
    final userId = currentUserId;
    final locationId = activeLocationId;
    if (userId == null || locationId == null) return;
    try {
      final isHelperSession = currentUserRole?.toLowerCase() == 'helper';
      final profileColumns = isHelperSession
          ? 'id, location_id, name, role, email, address, phone, '
                'must_change_password'
          : 'id, location_id, name, role, email, address, phone';
      final row = await supabase
          .from('profiles')
          .select(profileColumns)
          .eq('id', userId)
          .maybeSingle();
      if (currentUserId != userId || activeLocationId != locationId) return;
      if (row == null || row['location_id']?.toString() != locationId) {
        _currentProfileSnapshot = null;
        _currentUserProfileController.add(null);
        return;
      }
      final snapshot = CurrentUserProfileSnapshot(
        id: row['id'].toString(),
        locationId: row['location_id'].toString(),
        name: row['name']?.toString() ?? 'User',
        role: row['role']?.toString() ?? 'staff',
        mustChangePassword:
            isHelperSession && row['must_change_password'] == true,
        email: row['email']?.toString(),
        address: row['address']?.toString(),
        phone: row['phone']?.toString(),
      );
      if (currentUserRole?.toLowerCase() == 'admin' &&
          snapshot.role.toLowerCase() != 'admin') {
        _clearStaffConfigurationSnapshot();
      }
      currentUserName = snapshot.name;
      currentUserRole = snapshot.role;
      loggedInUserEmail = snapshot.email;
      _currentProfileSnapshot = snapshot;
      _currentUserProfileController.add(snapshot);
    } catch (error, stackTrace) {
      debugPrint(
        '[InventoryController] Current profile refresh failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
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

      final row = await supabase
          .from('profiles')
          .insert({
            'name': name,
            'username': username,
            'password': hashedPassword,
            'role': role,
            'location_id': locId,
            'email': email,
            'phone': phone,
            'address': address,
          })
          .select()
          .single();
      if (_staffSnapshotActivated && _staffSnapshotLocationId == locId) {
        _staffSnapshot = List<Map<String, dynamic>>.unmodifiable([
          ..._staffSnapshot,
          Map<String, dynamic>.from(row),
        ]);
        _publishStaffConfigurationSnapshot();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> updateStaffRole(String id, String newRole) async {
    try {
      final row = await supabase
          .from('profiles')
          .update({'role': newRole})
          .eq('id', id)
          .select()
          .single();
      final index = _staffSnapshot.indexWhere(
        (staff) => staff['id'].toString() == id,
      );
      if (index >= 0) {
        final updated = List<Map<String, dynamic>>.from(_staffSnapshot);
        updated[index] = Map<String, dynamic>.from(row);
        _staffSnapshot = List<Map<String, dynamic>>.unmodifiable(updated);
        _publishStaffConfigurationSnapshot();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> fetchStaffProfile(String id) async {
    final locationId = activeLocationId;
    if (locationId == null) return null;
    final row = await supabase
        .from('profiles')
        .select()
        .eq('id', id)
        .eq('location_id', locationId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<bool> deleteStaff(String id) async {
    try {
      await supabase.from('profiles').delete().eq('id', id);
      _staffSnapshot = List<Map<String, dynamic>>.unmodifiable(
        _staffSnapshot.where((staff) => staff['id'].toString() != id),
      );
      _publishStaffConfigurationSnapshot();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<ChangePasswordResult> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final userId = currentUserId;
    if (userId == null) return ChangePasswordResult.notAuthenticated;

    try {
      final hashedCurrentPassword = _hashPassword(currentPassword);
      final hashedNewPassword = _hashPassword(newPassword);

      final response = await supabase
          .from('profiles')
          .select('password, role')
          .eq('id', userId)
          .maybeSingle();

      if (response == null) {
        return ChangePasswordResult.notAuthenticated;
      }
      if (response['password'] != hashedCurrentPassword) {
        return ChangePasswordResult.incorrectCurrentPassword;
      }
      if (hashedNewPassword == hashedCurrentPassword) {
        return ChangePasswordResult.sameAsCurrentPassword;
      }
      if (!_meetsPasswordPolicy(newPassword)) {
        return ChangePasswordResult.invalidNewPassword;
      }
      if (currentUserId != userId) {
        return ChangePasswordResult.notAuthenticated;
      }

      final role = response['role']?.toString() ?? '';
      final isHelper = role.toLowerCase() == 'helper';
      final Map<String, dynamic>? updatedProfile;
      if (isHelper) {
        updatedProfile = await supabase
            .from('profiles')
            .update({
              'password': hashedNewPassword,
              'must_change_password': false,
            })
            .eq('id', userId)
            .eq('role', role)
            .eq('password', hashedCurrentPassword)
            .select('id, must_change_password')
            .maybeSingle();
      } else {
        updatedProfile = await supabase
            .from('profiles')
            .update({'password': hashedNewPassword})
            .eq('id', userId)
            .eq('role', role)
            .eq('password', hashedCurrentPassword)
            .select('id')
            .maybeSingle();
      }

      if (updatedProfile == null) {
        return ChangePasswordResult.concurrentChange;
      }
      if (isHelper && updatedProfile['must_change_password'] != false) {
        return ChangePasswordResult.unexpectedFailure;
      }
      if (isHelper) _setCurrentProfileMustChangePassword(false);
      return ChangePasswordResult.success;
    } on PostgrestException catch (error) {
      debugPrint(
        '[Password] Profile operation failed: '
        'code=${error.code} message=${error.message}',
      );
      return ChangePasswordResult.unexpectedFailure;
    } catch (_) {
      return ChangePasswordResult.unexpectedFailure;
    }
  }

  Future<CurrentPasswordVerificationResult> verifyCurrentPassword(
    String currentPassword,
  ) async {
    final userId = currentUserId;
    if (userId == null) {
      return CurrentPasswordVerificationResult.notAuthenticated;
    }
    try {
      final response = await supabase
          .from('profiles')
          .select('password')
          .eq('id', userId)
          .maybeSingle();
      if (currentUserId != userId || response == null) {
        return CurrentPasswordVerificationResult.notAuthenticated;
      }
      return response['password'] == _hashPassword(currentPassword)
          ? CurrentPasswordVerificationResult.correct
          : CurrentPasswordVerificationResult.incorrect;
    } catch (_) {
      return CurrentPasswordVerificationResult.unexpectedFailure;
    }
  }

  void _setCurrentProfileMustChangePassword(bool value) {
    final snapshot = _currentProfileSnapshot;
    if (snapshot == null || snapshot.id != currentUserId) return;
    final updated = CurrentUserProfileSnapshot(
      id: snapshot.id,
      locationId: snapshot.locationId,
      name: snapshot.name,
      role: snapshot.role,
      mustChangePassword: value,
      email: snapshot.email,
      address: snapshot.address,
      phone: snapshot.phone,
    );
    _currentProfileSnapshot = updated;
    _currentUserProfileController.add(updated);
  }

  bool _meetsPasswordPolicy(String password) {
    return password.length >= 8 &&
        password.contains(RegExp(r'[A-Z]')) &&
        password.contains(RegExp(r'[a-z]')) &&
        password.contains(RegExp(r'[0-9]')) &&
        password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));
  }

  Future<List<Map<String, dynamic>>> loadProductTransactionHistory(
    String productId,
  ) {
    final String? locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      return Future<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return _runSerializedHistoryQuery(
      'product:$locationId:$productId',
      () async {
        final response = await supabase
            .from('transaction_history')
            .select('*, profiles(name, role)')
            .eq('location_id', locationId)
            .eq('product_id', productId)
            .order('created_at', ascending: false);

        if (activeLocationId != locationId) {
          throw StateError('Transaction history location changed.');
        }

        return List<Map<String, dynamic>>.unmodifiable(
          List<Map<String, dynamic>>.from(response),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchTransactionHistory(
    String productId,
  ) async {
    try {
      return await loadProductTransactionHistory(productId);
    } catch (error, stackTrace) {
      debugPrint(
        '[InventoryController] Failed to load product transaction history: '
        '$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> loadAllTransactionHistory() {
    final String? locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      return Future<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return _runSerializedHistoryQuery('all:$locationId', () async {
      final response = await supabase
          .from('transaction_history')
          .select('*, products(product_name, sku), profiles(name, role)')
          .eq('location_id', locationId)
          .order('created_at', ascending: false);

      if (activeLocationId != locationId) {
        throw StateError('Transaction history location changed.');
      }

      return List<Map<String, dynamic>>.unmodifiable(
        List<Map<String, dynamic>>.from(response),
      );
    });
  }

  Future<List<Map<String, dynamic>>> fetchAllTransactionHistory() async {
    try {
      return await loadAllTransactionHistory();
    } catch (error, stackTrace) {
      debugPrint(
        '[InventoryController] Failed to load transaction history: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _runSerializedHistoryQuery(
    String key,
    Future<List<Map<String, dynamic>>> Function() query,
  ) {
    final _SerializedHistoryQuery state = _historyQueries.putIfAbsent(
      key,
      _SerializedHistoryQuery.new,
    );

    final Future<List<Map<String, dynamic>>>? inFlight = state.inFlight;
    if (inFlight != null) {
      state.queued = true;
      return inFlight;
    }

    late final Future<List<Map<String, dynamic>>> refresh;
    refresh =
        () async {
          List<Map<String, dynamic>> result = const <Map<String, dynamic>>[];
          do {
            state.queued = false;
            result = await query();
          } while (state.queued);
          return result;
        }().whenComplete(() {
          if (identical(state.inFlight, refresh)) {
            _historyQueries.remove(key);
          }
        });

    state.inFlight = refresh;
    return refresh;
  }

  Future<OrderHistoryData> loadOrderHistory() {
    final Future<OrderHistoryData>? inFlight = _orderHistoryRefreshInFlight;
    if (inFlight != null) {
      _orderHistoryRefreshQueued = true;
      return inFlight;
    }

    late final Future<OrderHistoryData> refresh;
    refresh =
        () async {
          OrderHistoryData result;
          do {
            _orderHistoryRefreshQueued = false;
            result = await _performOrderHistoryLoad();
          } while (_orderHistoryRefreshQueued);
          return result;
        }().whenComplete(() {
          if (identical(_orderHistoryRefreshInFlight, refresh)) {
            _orderHistoryRefreshInFlight = null;
          }
        });

    _orderHistoryRefreshInFlight = refresh;
    return refresh;
  }

  Future<OrderHistoryData> _performOrderHistoryLoad() async {
    final String? locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      return const OrderHistoryData(
        orders: <Map<String, dynamic>>[],
        profileNamesById: <String, String>{},
      );
    }

    final response = await supabase
        .from('orders')
        .select()
        .eq('location_id', locationId)
        .order('created_at', ascending: false);

    if (activeLocationId != locationId) {
      throw StateError('Order history location changed.');
    }

    final List<Map<String, dynamic>> orders = List<Map<String, dynamic>>.from(
      response,
    );
    final Set<Object> profileIds = <Object>{};

    for (final Map<String, dynamic> order in orders) {
      for (final String key in <String>[
        'created_by',
        'prepared_by',
        'created_by_id',
        'prepared_by_id',
      ]) {
        final Object? rawId = order[key];
        if (rawId == null) continue;
        profileIds.add(int.tryParse(rawId.toString()) ?? rawId.toString());
      }
    }

    final Map<String, String> profileNames = <String, String>{};
    if (profileIds.isNotEmpty) {
      final profiles = await supabase
          .from('profiles')
          .select('id, name')
          .inFilter('id', profileIds.toList(growable: false));

      if (activeLocationId != locationId) {
        throw StateError('Order history location changed.');
      }

      for (final dynamic row in profiles) {
        final Map<String, dynamic> profile = Map<String, dynamic>.from(
          row as Map,
        );
        profileNames[profile['id'].toString()] =
            profile['name']?.toString() ?? '—';
      }
    }

    return OrderHistoryData(
      orders: List<Map<String, dynamic>>.unmodifiable(orders),
      profileNamesById: Map<String, String>.unmodifiable(profileNames),
    );
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
    if (locId == null) return null;

    // Reconcile immediately before checkout so a cart that was built before a
    // remote stock change cannot sell more than the latest canonical snapshot.
    await _refreshInventoryFromDatabase();

    for (final oi in items) {
      final int index = _items.indexWhere((i) => i.id == oi.productId);
      if (index == -1) {
        throw Exception(
          'An item in this order is no longer available. '
          'Remove it from the cart and try again.',
        );
      }

      if (oi.quantity > _items[index].quantity) {
        throw Exception(
          'There is not enough stock for ${_items[index].name}. '
          'Update the cart quantity and try again.',
        );
      }
    }

    try {
      final now = DateTime.now().toUtc().toIso8601String();

      final response = await supabase
          .from('orders')
          .insert({
            'location_id': locId,
            'status': soloHandled ? 'solo_picking' : 'pending',
            'total_amount': totalAmount,
            'discount_amount': discountAmount,
            'payment_mode': paymentMode ?? 'Cash',
            'cash_given': cashGiven,
            'change_amount': changeAmount,
            'items': items.map((i) => i.toJson()).toList(),

            // ownership
            'created_by_id': currentUserId,
            'created_by_name': currentUserName ?? 'Unknown User',

            // optional old field, keep only if your old DB still uses it
            'created_by': currentUserNumericId,
          })
          .select()
          .single();

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

      return CustomerOrder.fromJson(Map<String, dynamic>.from(response));
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
        .update({
          'status': 'cancelled',
          'cancelled_by_id': currentUserId,
          'cancelled_by_name': currentUserName ?? 'Unknown User',
          'cancelled_at': DateTime.now().toUtc().toIso8601String(),
        })
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
      _publishInventorySnapshot();

      await _logTransaction(
        productId: restored.id,
        type: 'order_cancelled',
        quantityChange: oi.quantity,
        newQuantity: restored.quantity,
      );
    }
  }

  void bindRealtimeSync(RealtimeSyncService realtimeSync) {
    _orderChangesSubscription ??= realtimeSync.orderChanges.listen(
      (_) {
        _ordersAwaitingRealtimeInitial = false;
        unawaited(_refreshOrdersFromDatabase());
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[InventoryController] Order realtime error: $error');
      },
    );

    _inventoryChangesSubscription ??= realtimeSync.inventoryChanges.listen(
      (_) {
        _inventoryAwaitingRealtimeInitial = false;
        unawaited(_refreshInventoryFromDatabase());
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[InventoryController] Inventory realtime error: $error');
      },
    );

    _transactionHistoryChangesSubscription ??= realtimeSync
        .transactionHistoryChanges
        .listen(
          (_) => _transactionHistoryInvalidationsController.add(null),
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              '[InventoryController] Transaction history realtime error: '
              '$error',
            );
          },
        );

    _mapLayoutChangesSubscription ??= realtimeSync.mapLayoutChanges.listen(
      (_) {
        _mapLayoutStale = true;
        if (_mapLayoutSaveInFlight != null) {
          _mapLayoutRefreshQueued = true;
          return;
        }
        if (_mapLayoutLoaded &&
            _mapLayoutLocationId == activeLocationId &&
            activeLocationId != null) {
          unawaited(_refreshLoadedMapLayout());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[InventoryController] Map layout realtime error: $error');
      },
    );

    _runtimeSettingsChangesSubscription ??= realtimeSync.runtimeSettingsChanges
        .listen(
          (kind) {
            switch (kind) {
              case RuntimeSettingsChangeKind.thresholds:
                unawaited(_refreshThresholdSettings());
              case RuntimeSettingsChangeKind.measurements:
                if (_measurementSettingsActivated) {
                  unawaited(_refreshMeasurementSettings());
                }
              case RuntimeSettingsChangeKind.payment:
                if (currentUserRole?.toLowerCase() != 'helper') {
                  unawaited(_refreshPaymentSettings());
                }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              '[InventoryController] Runtime settings realtime error: $error',
            );
          },
        );

    _staffConfigurationChangesSubscription ??= realtimeSync
        .staffConfigurationChanges
        .listen(
          (_) {
            if (_staffSnapshotActivated) {
              unawaited(_refreshStaffConfiguration());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              '[InventoryController] Staff configuration realtime error: '
              '$error',
            );
          },
        );

    _currentProfileChangesSubscription ??= realtimeSync.currentProfileChanges
        .listen(
          (_) => unawaited(_refreshCurrentProfile()),
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              '[InventoryController] Current profile realtime error: $error',
            );
          },
        );
  }

  Future<void> _refreshLoadedMapLayout() async {
    try {
      await fetchMapLayout(force: true);
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Map layout refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Stream<void> get transactionHistoryInvalidations =>
      _transactionHistoryInvalidationsController.stream;

  /// Emits after the shared canonical Order snapshot changes. History screens
  /// use this as invalidation rather than creating a second Orders channel.
  Stream<List<CustomerOrder>> get orderSnapshots => _ordersController.stream;

  Stream<List<InventoryItem>> streamInventory() {
    final String? locationId = activeLocationId;

    if (!_inventorySnapshotLoaded ||
        _inventorySnapshotLocationId != locationId) {
      if (!_inventoryAwaitingRealtimeInitial &&
          _inventoryRefreshInFlight == null) {
        unawaited(_refreshInventoryFromDatabase());
      }
    }

    return _inventoryController.stream;
  }

  List<InventoryItem> get currentInventory => _inventorySnapshot;
  Stream<List<InventoryItem>> get inventorySnapshots =>
      _inventoryController.stream;

  List<InventoryItem> get _inventorySnapshot =>
      List<InventoryItem>.unmodifiable(<InventoryItem>[
        ..._items,
        ..._disabledItems,
      ]);

  void _publishInventorySnapshot() {
    _inventoryController.add(_inventorySnapshot);
  }

  void _clearInventorySnapshot() {
    _items = <InventoryItem>[];
    _disabledItems = <InventoryItem>[];
    _baselineByProduct = <String, double>{};
    _inventorySnapshotLocationId = null;
    _inventorySnapshotLoaded = false;
    _publishInventorySnapshot();
  }

  void _clearOrdersSnapshot() {
    _ordersSnapshot = const <CustomerOrder>[];
    _ordersSnapshotLocationId = null;
    _ordersSnapshotLoaded = false;
    _ordersController.add(_ordersSnapshot);
  }

  Future<void> _refreshInventoryFromDatabase() {
    if (_inventoryRefreshInFlight != null) {
      _inventoryRefreshQueued = true;
      return _inventoryRefreshInFlight!;
    }

    final Future<void> refresh = _performInventoryRefresh();
    _inventoryRefreshInFlight = refresh;

    return refresh.whenComplete(() {
      if (identical(_inventoryRefreshInFlight, refresh)) {
        _inventoryRefreshInFlight = null;
      }

      if (_inventoryRefreshQueued) {
        _inventoryRefreshQueued = false;
        unawaited(_refreshInventoryFromDatabase());
      }
    });
  }

  Future<void> _performInventoryRefresh() async {
    final String? locationId = activeLocationId;

    if (locationId == null || locationId.isEmpty) {
      _clearInventorySnapshot();
      _inventorySnapshotLoaded = true;
      return;
    }

    try {
      final rows = await supabase
          .from('products')
          .select()
          .eq('location_id', locationId);

      if (activeLocationId != locationId) {
        _inventoryRefreshQueued = true;
        return;
      }

      final List<InventoryItem> active = <InventoryItem>[];
      final List<InventoryItem> disabled = <InventoryItem>[];

      for (final dynamic row in rows) {
        final Map<String, dynamic> product = Map<String, dynamic>.from(
          row as Map,
        );
        final InventoryItem item = InventoryItem.fromSupabase(product);

        if (product['is_active'] == false) {
          disabled.add(item);
        } else {
          active.add(item);
        }
      }

      _items = active;
      _disabledItems = disabled;
      _inventorySnapshotLocationId = locationId;
      _inventorySnapshotLoaded = true;
      _publishInventorySnapshot();

      debugPrint(
        '[InventoryController] INVENTORY REFRESHED '
        'location=$locationId count=${active.length + disabled.length}',
      );
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Failed to refresh inventory: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Stream<List<CustomerOrder>> streamOrders() async* {
    final String? locationId = activeLocationId;

    if (!_ordersSnapshotLoaded || _ordersSnapshotLocationId != locationId) {
      if (!_ordersAwaitingRealtimeInitial) {
        final inFlight = _ordersRefreshInFlight;
        if (inFlight != null) {
          await inFlight;
        } else {
          await _refreshOrdersFromDatabase();
        }
      }
    }

    // Send the latest known state immediately to the new subscriber.
    yield List<CustomerOrder>.unmodifiable(_ordersSnapshot);

    // Then keep the subscriber updated from the shared stream.
    yield* _ordersController.stream;
  }

  Future<void> _refreshOrdersFromDatabase() {
    // If a refresh is already running, do not start another query.
    // Remember that another refresh is needed afterward.
    if (_ordersRefreshInFlight != null) {
      _ordersRefreshQueued = true;
      return _ordersRefreshInFlight!;
    }

    final Future<void> refresh = _performOrdersRefresh();

    _ordersRefreshInFlight = refresh;

    return refresh.whenComplete(() {
      if (identical(_ordersRefreshInFlight, refresh)) {
        _ordersRefreshInFlight = null;
      }

      if (_ordersRefreshQueued) {
        _ordersRefreshQueued = false;

        unawaited(_refreshOrdersFromDatabase());
      }
    });
  }

  Future<void> _performOrdersRefresh() async {
    final String? locationId = activeLocationId;

    if (locationId == null || locationId.isEmpty) {
      _ordersSnapshot = const <CustomerOrder>[];
      _ordersSnapshotLocationId = null;
      _ordersSnapshotLoaded = true;

      _ordersController.add(_ordersSnapshot);

      return;
    }

    try {
      final rows = await supabase
          .from('orders')
          .select()
          .eq('location_id', locationId)
          .order('created_at', ascending: false);

      // The active store may have changed while the query was running.
      // Never publish results from the previous location.
      if (activeLocationId != locationId) {
        _ordersRefreshQueued = true;
        return;
      }

      final List<CustomerOrder> orders = rows
          .map((row) => CustomerOrder.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false);

      _ordersSnapshot = List<CustomerOrder>.unmodifiable(orders);

      _ordersSnapshotLocationId = locationId;
      _ordersSnapshotLoaded = true;

      _ordersController.add(_ordersSnapshot);

      debugPrint(
        '[InventoryController] ORDERS REFRESHED '
        'location=$locationId count=${orders.length}',
      );
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Failed to refresh orders: $error');

      debugPrintStack(stackTrace: stackTrace);
    }
  }

  List<CustomerOrder> get currentOrders =>
      List<CustomerOrder>.unmodifiable(_ordersSnapshot);

  CustomerOrder? orderById(Object? orderId) {
    if (orderId == null) {
      return null;
    }

    final String targetId = orderId.toString();

    for (final CustomerOrder order in _ordersSnapshot) {
      if (order.id.toString() == targetId) {
        return order;
      }
    }

    return null;
  }

  Future<void> updateOrderStatus(String orderId, String newStatus) async {
    try {
      final Map<String, dynamic> updateData = {'status': newStatus};

      if (newStatus == 'prepared') {
        updateData['prepared_by_id'] = currentUserId;
        updateData['prepared_by_name'] = currentUserName ?? 'Unknown User';
        updateData['prepared_at'] = DateTime.now().toUtc().toIso8601String();

        // optional old field, keep only if your old DB still uses it
        updateData['prepared_by'] = currentUserNumericId;
      }

      await supabase
          .from('orders')
          .update(updateData)
          .eq('id', orderId)
          .neq('status', 'cancelled')
          .neq('status', 'completed');
    } catch (e) {
      rethrow;
    }
  }

  Future<bool> claimOrderForCurrentHelper(Object orderId) async {
    final locationId = activeLocationId;
    final helperId = currentUserNumericId;
    final helperName = currentUserName;

    if (locationId == null ||
        locationId.toString().isEmpty ||
        helperId == null ||
        helperName == null ||
        helperName.toString().trim().isEmpty) {
      debugPrint(
        '[Orders] CLAIM FAILED order=$orderId '
        'reason=missing helper/location information',
      );
      return false;
    }

    final CustomerOrder? currentOrder = orderById(orderId);

    // If this Helper already owns the order, allow them to reopen it.
    if (currentOrder != null &&
        currentOrder.assignedHelperId != null &&
        currentOrder.assignedHelperId.toString() == helperId.toString() &&
        currentOrder.status == 'pending') {
      return true;
    }

    // Do not steal an order already assigned to another Helper.
    if (currentOrder != null &&
        currentOrder.assignedHelperId != null &&
        currentOrder.assignedHelperId.toString() != helperId.toString()) {
      return false;
    }

    // Only pending orders can be claimed.
    if (currentOrder != null && currentOrder.status != 'pending') {
      return false;
    }

    try {
      final updatedRows = await supabase
          .from('orders')
          .update({
            'assigned_helper_id': helperId,
            'assigned_helper_name': helperName.toString().trim(),
            'assigned_at': DateTime.now().toIso8601String(),
          })
          .eq('id', orderId)
          .eq('location_id', locationId)
          .eq('status', 'pending')
          .isFilter('assigned_helper_id', null)
          .select('id');

      if (updatedRows.isNotEmpty) {
        debugPrint(
          '[Orders] CLAIMED order=$orderId '
          'helper=$helperId '
          'name=${helperName.toString().trim()}',
        );

        // Do not wait for the realtime round trip before updating this client.
        await _refreshOrdersFromDatabase();

        return true;
      }

      // No row matched. Usually this means another Helper claimed it first.
      await _refreshOrdersFromDatabase();

      final CustomerOrder? refreshedOrder = orderById(orderId);

      // Allow another tab/session belonging to the same Helper.
      return refreshedOrder != null &&
          refreshedOrder.status == 'pending' &&
          refreshedOrder.assignedHelperId != null &&
          refreshedOrder.assignedHelperId.toString() == helperId.toString();
    } catch (error, stackTrace) {
      debugPrint('[Orders] CLAIM ERROR order=$orderId error=$error');
      debugPrintStack(stackTrace: stackTrace);

      return false;
    }
  }

  Future<void> assignOrderToHelper({
    required String orderId,
    required String helperId,
    required String helperName,
  }) async {
    await supabase
        .from('orders')
        .update({
          'assigned_helper_id': helperId,
          'assigned_helper_name': helperName,
          'assigned_at': DateTime.now().toUtc().toIso8601String(),
          'assigned_by_admin_id': currentUserId,
          'assigned_by_admin_name': currentUserName ?? 'Unknown Admin',
        })
        .eq('id', orderId)
        .neq('status', 'cancelled')
        .neq('status', 'completed');
  }

  Set<String>? _processingOrders;

  Future<({DateTime createdAt, DateTime completedAt})?> completeOrder(
    CustomerOrder order, {
    String? paymentMode,
    double? cashGiven,
    double? changeAmount,
    String? paymentReference,
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
        'completed_by_id': currentUserId,
        'completed_by_name': currentUserName ?? 'Unknown User',
      };

      if (paymentMode != null) updateData['payment_mode'] = paymentMode;
      if (cashGiven != null) updateData['cash_given'] = cashGiven;
      if (changeAmount != null) updateData['change_amount'] = changeAmount;

      if (paymentReference != null && paymentReference.isNotEmpty) {
        updateData['payment_reference'] = paymentReference;
      }

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
      if (userId == currentUserId) await _refreshCurrentProfile();
      if (_staffSnapshotActivated) await _refreshStaffConfiguration();
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

      final target = await supabase
          .from('profiles')
          .select('role')
          .eq('id', targetUserId)
          .maybeSingle();
      if (target == null) return false;
      final targetRole = target['role']?.toString() ?? '';

      final update = <String, dynamic>{'password': hashedNewPassword};
      final isHelper = targetRole.toLowerCase() == 'helper';
      if (isHelper) {
        update['must_change_password'] = true;
      }

      final Map<String, dynamic>? updatedProfile;
      if (isHelper) {
        updatedProfile = await supabase
            .from('profiles')
            .update(update)
            .eq('id', targetUserId)
            .eq('role', targetRole)
            .select('id, role, must_change_password')
            .maybeSingle();
      } else {
        updatedProfile = await supabase
            .from('profiles')
            .update(update)
            .eq('id', targetUserId)
            .eq('role', targetRole)
            .select('id, role')
            .maybeSingle();
      }

      if (updatedProfile == null) return false;
      return !isHelper || updatedProfile['must_change_password'] == true;
    } catch (e) {
      return false;
    }
  }

  Stream<List<MapElement>> get mapLayoutSnapshots =>
      _mapLayoutController.stream;

  List<MapElement> get currentMapLayout =>
      List<MapElement>.unmodifiable(_cloneMapLayout(storeLayout));

  bool get isMapLayoutLoadedForActiveLocation =>
      _mapLayoutLoaded && _mapLayoutLocationId == activeLocationId;

  String get currentMapLayoutSignature => mapLayoutSignature(storeLayout);

  List<MapElement> cloneMapLayout(Iterable<MapElement> layout) =>
      _cloneMapLayout(layout);

  String mapLayoutSignature(Iterable<MapElement> layout) {
    final String encoded = jsonEncode(
      layout.map((MapElement element) => element.toJson()).toList(),
    );
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  List<MapElement> _cloneMapLayout(Iterable<MapElement> layout) {
    return layout
        .map(
          (MapElement element) =>
              MapElement.fromJson(Map<String, dynamic>.from(element.toJson())),
        )
        .toList();
  }

  void _publishMapLayoutSnapshot() {
    _mapLayoutController.add(currentMapLayout);
  }

  Future<void> fetchMapLayout({bool force = false}) {
    final String? locId = activeLocationId;
    if (locId == null || locId.isEmpty) return Future<void>.value();
    if (!force &&
        _mapLayoutLoaded &&
        !_mapLayoutStale &&
        _mapLayoutLocationId == locId) {
      return Future<void>.value();
    }

    final Future<void>? inFlight = _mapLayoutLoadInFlight;
    if (inFlight != null) {
      if (_mapLayoutLoadLocationId != locId) {
        return _waitForMapLayoutScopeThenLoad(inFlight, force: force);
      }
      _mapLayoutRefreshQueued = true;
      return inFlight;
    }

    final Future<void> load = _performMapLayoutLoad(locId);
    _mapLayoutLoadInFlight = load;
    _mapLayoutLoadLocationId = locId;

    return load.whenComplete(() {
      if (identical(_mapLayoutLoadInFlight, load)) {
        _mapLayoutLoadInFlight = null;
        _mapLayoutLoadLocationId = null;
      }
      if (_mapLayoutRefreshQueued) {
        _mapLayoutRefreshQueued = false;
        unawaited(_refreshLoadedMapLayout());
      }
    });
  }

  Future<void> _waitForMapLayoutScopeThenLoad(
    Future<void> previousLoad, {
    required bool force,
  }) async {
    try {
      await previousLoad;
    } catch (_) {
      // A failed old-location request must not prevent the new location load.
    }
    await fetchMapLayout(force: force);
  }

  Future<List<MapElement>> _readMapLayout(String locId) async {
    final Map<String, dynamic>? locationResponse = await supabase
        .from('locations')
        .select('layout_data')
        .eq('id', locId)
        .maybeSingle();

    final dynamic storedLayout = locationResponse?['layout_data'];
    if (storedLayout == null) return <MapElement>[];
    return _decodeMapLayoutValue(storedLayout);
  }

  List<MapElement> _decodeMapLayoutValue(dynamic value) {
    final dynamic decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! List) {
      throw const FormatException('Map layout_data is not a JSON list.');
    }
    return decoded
        .map(
          (dynamic element) =>
              MapElement.fromJson(Map<String, dynamic>.from(element as Map)),
        )
        .toList();
  }

  void _acceptCanonicalMapLayout(String locId, List<MapElement> layout) {
    if (activeLocationId != locId) return;
    storeLayout = _cloneMapLayout(layout);
    _mapLayoutLocationId = locId;
    _mapLayoutLoaded = true;
    _mapLayoutStale = false;
    _publishMapLayoutSnapshot();
    debugPrint(
      '[InventoryController] MAP LAYOUT REFRESHED '
      'location=$locId count=${storeLayout.length}',
    );
  }

  Future<void> _performMapLayoutLoad(String locId) async {
    try {
      final List<MapElement> layout = await _readMapLayout(locId);
      if (activeLocationId != locId) return;
      _acceptCanonicalMapLayout(locId, layout);
    } catch (error, stackTrace) {
      _mapLayoutStale = true;
      debugPrint('[InventoryController] Failed to load map layout: $error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  // ─── MAP EDITOR METHODS ────────────────────────────────────────────────────

  Future<MapLayoutSaveResult> saveMapLayoutIfUnchanged({
    required List<MapElement> draft,
    required String baselineSignature,
    required String expectedLocationId,
    required String expectedUserId,
    bool clear = false,
  }) {
    final Future<MapLayoutSaveResult>? inFlight = _mapLayoutSaveInFlight;
    if (inFlight != null) return inFlight;

    final Future<MapLayoutSaveResult> save = _performMapLayoutSave(
      draft: _cloneMapLayout(draft),
      baselineSignature: baselineSignature,
      expectedLocationId: expectedLocationId,
      expectedUserId: expectedUserId,
      clear: clear,
    );
    _mapLayoutSaveInFlight = save;
    return save.whenComplete(() {
      if (identical(_mapLayoutSaveInFlight, save)) {
        _mapLayoutSaveInFlight = null;
      }
      if (_mapLayoutRefreshQueued) {
        _mapLayoutRefreshQueued = false;
        unawaited(_refreshLoadedMapLayout());
      }
    });
  }

  Future<MapLayoutSaveResult> _performMapLayoutSave({
    required List<MapElement> draft,
    required String baselineSignature,
    required String expectedLocationId,
    required String expectedUserId,
    required bool clear,
  }) async {
    final String? locId = activeLocationId;
    if (locId == null || locId.isEmpty) {
      throw StateError('No active location is available for the map save.');
    }
    if (locId != expectedLocationId) {
      throw StateError('The map draft belongs to a different location.');
    }
    if (currentUserId != expectedUserId) {
      throw StateError('The map draft belongs to a different user session.');
    }

    final Future<void>? refreshInFlight = _mapLayoutLoadInFlight;
    if (refreshInFlight != null) await refreshInFlight;

    final List<MapElement> latest = await _readMapLayout(locId);
    if (activeLocationId != locId || currentUserId != expectedUserId) {
      throw StateError('The active session changed during the map save.');
    }

    final String latestSignature = mapLayoutSignature(latest);
    if (latestSignature != baselineSignature) {
      _acceptCanonicalMapLayout(locId, latest);
      return MapLayoutSaveResult(
        status: MapLayoutSaveStatus.conflict,
        layout: currentMapLayout,
        signature: latestSignature,
      );
    }

    final dynamic persistedValue = clear
        ? null
        : draft.map((MapElement element) => element.toJson()).toList();
    final List<dynamic> response = await supabase
        .from('locations')
        .update(<String, dynamic>{'layout_data': persistedValue})
        .eq('id', locId)
        .select('layout_data');

    if (response.isEmpty) {
      throw StateError(
        "Location '$locId' does not exist or cannot be updated.",
      );
    }
    if (activeLocationId != locId || currentUserId != expectedUserId) {
      throw StateError('The active session changed during the map save.');
    }

    final dynamic returnedValue = (response.first as Map)['layout_data'];
    final List<MapElement> saved = returnedValue == null
        ? <MapElement>[]
        : _decodeMapLayoutValue(returnedValue);
    _acceptCanonicalMapLayout(locId, saved);
    return MapLayoutSaveResult(
      status: MapLayoutSaveStatus.saved,
      layout: currentMapLayout,
      signature: mapLayoutSignature(saved),
    );
  }

  Future<void> assignItemToLocation(String itemId, String mapElementId) async {
    try {
      await supabase
          .from('products')
          .update({'map_element_id': mapElementId})
          .eq('id', itemId);

      final index = _items.indexWhere((item) => item.id == itemId);
      if (index != -1) {
        _items[index] = _items[index].copyWith(locationId: mapElementId);
        _publishInventorySnapshot();
      }
    } catch (e) {
      debugPrint("Error assigning item to location: $e");
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> loadMyRestockHistory({
    int page = 0,
    int pageSize = 25,
  }) {
    final locationId = activeLocationId;
    final userId = currentUserNumericId;

    if (locationId == null || userId == null) {
      return Future<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    final from = page * pageSize;
    final to = from + pageSize - 1;

    return _runSerializedHistoryQuery(
      'restock:$locationId:$userId:$page:$pageSize',
      () async {
        final response = await supabase
            .from('transaction_history')
            .select('''
        id,
        product_id,
        transaction_type,
        quantity_change,
        new_quantity,
        user_id,
        user_name,
        created_at,
        note,
        products(product_name, sku)
      ''')
            .eq('location_id', locationId)
            .eq('user_id', userId)
            .eq('transaction_type', 'stock_in')
            .gt('quantity_change', 0)
            .order('created_at', ascending: false)
            .range(from, to);

        if (activeLocationId != locationId || currentUserNumericId != userId) {
          throw StateError('Restock history session changed.');
        }

        return List<Map<String, dynamic>>.unmodifiable(
          List<Map<String, dynamic>>.from(response),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchMyRestockHistory({
    int page = 0,
    int pageSize = 25,
  }) async {
    try {
      return await loadMyRestockHistory(page: page, pageSize: pageSize);
    } catch (error, stackTrace) {
      debugPrint(
        '[InventoryController] Failed to load restock history: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      return [];
    }
  }
}
