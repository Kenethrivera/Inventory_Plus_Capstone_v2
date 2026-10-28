import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../data/inventory.dart';
import '../services/realtime/realtime_sync_service.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import 'helper_assignment.dart';
import 'history_pagination.dart';
import 'inventory_approval.dart';
import 'payment_reference.dart';
import 'staff_performance.dart';
import 'staff_management.dart';
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
    required this.cashierAutoApprovedDiscountLimitPct,
    required this.thresholdsLoaded,
    required this.measurementsLoaded,
    required this.paymentLoaded,
  });

  final double lowStockPercent;
  final double criticalStockPercent;
  final List<Map<String, dynamic>> measurements;
  final String gcashQrUrl;
  final double cashierAutoApprovedDiscountLimitPct;
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
  static const Duration _operationalOrderLookback = Duration(days: 60);

  // shared realtime controlelrs
  final StreamController<List<CustomerOrder>> _ordersController =
      StreamController<List<CustomerOrder>>.broadcast();
  final StreamController<List<InventoryItem>> _inventoryController =
      StreamController<List<InventoryItem>>.broadcast();
  final StreamController<void> _transactionHistoryInvalidationsController =
      StreamController<void>.broadcast();
  final StreamController<HistoryInvalidation> _historyInvalidationsController =
      StreamController<HistoryInvalidation>.broadcast();
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
  final StreamController<InventoryApprovalPage> _approvalPagesController =
      StreamController<InventoryApprovalPage>.broadcast();
  final StreamController<InventoryApprovalRequest?>
  _discountApprovalController =
      StreamController<InventoryApprovalRequest?>.broadcast();
  final StreamController<void> _staffPerformanceInvalidationsController =
      StreamController<void>.broadcast();

  StreamSubscription<void>? _orderChangesSubscription;
  StreamSubscription<void>? _orderHistoryChangesSubscription;
  StreamSubscription<void>? _inventoryChangesSubscription;
  StreamSubscription<void>? _transactionHistoryChangesSubscription;
  StreamSubscription<void>? _mapLayoutChangesSubscription;
  StreamSubscription<RuntimeSettingsChangeKind>?
  _runtimeSettingsChangesSubscription;
  StreamSubscription<void>? _staffConfigurationChangesSubscription;
  StreamSubscription<void>? _currentProfileChangesSubscription;
  StreamSubscription<void>? _approvalRequestChangesSubscription;

  final Map<String, _SerializedHistoryQuery> _historyQueries =
      <String, _SerializedHistoryQuery>{};
  static const int _productHistoryCacheLimit = 24;
  final Map<String, List<Map<String, dynamic>>> _productHistoryCache =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, int> _productHistoryCacheGenerations = <String, int>{};
  final Map<String, Future<List<Map<String, dynamic>>>>
  _productHistoryRequests = <String, Future<List<Map<String, dynamic>>>>{};
  final Map<String, int> _productHistoryRequestGenerations = <String, int>{};
  int _productHistoryGeneration = 0;
  final HistoryPageCache<Map<String, dynamic>> _historyPageCache =
      HistoryPageCache<Map<String, dynamic>>();
  final Map<HistoryPageKey, Future<HistoryPageResult<Map<String, dynamic>>>>
  _historyPageRequests =
      <HistoryPageKey, Future<HistoryPageResult<Map<String, dynamic>>>>{};
  final Map<String, Future<Map<String, dynamic>?>> _historyDetailRequests =
      <String, Future<Map<String, dynamic>?>>{};
  final Map<HistoryDomain, int> _historyDomainGenerations =
      <HistoryDomain, int>{
        for (final domain in HistoryDomain.values) domain: 0,
      };
  int _historyCacheGeneration = 0;
  Future<OrderHistoryData>? _orderHistoryRefreshInFlight;
  bool _orderHistoryRefreshQueued = false;
  final InventoryApprovalPageCache _approvalPageCache =
      InventoryApprovalPageCache();
  final Map<InventoryApprovalPageKey, Future<InventoryApprovalPage>>
  _approvalPageRequests =
      <InventoryApprovalPageKey, Future<InventoryApprovalPage>>{};
  InventoryApprovalPageKey? _activeApprovalPageKey;
  String? _activeDiscountApprovalId;
  InventoryApprovalRequest? _activeDiscountApproval;
  Future<void>? _discountApprovalRefreshInFlight;
  final Map<String, StaffPerformanceSnapshot> _staffPerformanceCache =
      <String, StaffPerformanceSnapshot>{};
  final Map<String, Future<StaffPerformanceSnapshot>>
  _staffPerformanceRequests = <String, Future<StaffPerformanceSnapshot>>{};
  int _staffPerformanceGeneration = 0;

  List<CustomerOrder> _ordersSnapshot = const <CustomerOrder>[];

  String? _ordersSnapshotLocationId;

  bool _ordersSnapshotLoaded = false;
  Object? _ordersSnapshotError;
  bool _ordersAwaitingRealtimeInitial = false;

  Future<void>? _ordersRefreshInFlight;

  bool _ordersRefreshQueued = false;

  String? _inventorySnapshotLocationId;
  bool _inventorySnapshotLoaded = false;
  bool _inventoryAwaitingRealtimeInitial = false;
  Future<void>? _inventoryRefreshInFlight;
  bool _inventoryRefreshQueued = false;

  final SupabaseClient supabase = Supabase.instance.client;
  final Map<String, ({String signature, String operationId})>
  _pendingQuantityOperations =
      <String, ({String signature, String operationId})>{};
  int? currentUserNumericId;
  List<InventoryItem> _items = [];
  List<InventoryItem> get allItems => List<InventoryItem>.unmodifiable(_items);
  List<InventoryItem> _disabledItems = [];
  String? activeLocationId;
  String? currentUserRole;
  String? currentUserName;
  String? currentUserId;
  String? _sessionToken;

  String get currentSessionToken => _requireSessionToken();
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
  double cashierAutoApprovedDiscountLimitPct = 10.0;

  Future<void> loadStoreSettings() async {
    if (_paymentSettingsLoaded) return;
    await _refreshPaymentSettings();
  }

  Future<void> updateGcashQrUrl(String newUrl) async {
    if (activeLocationId == null) {
      throw StateError('Payment settings require an active location.');
    }
    try {
      await supabase.rpc(
        'update_store_payment_settings_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_gcash_qr_url': newUrl,
        },
      );

      gcashQrUrl = newUrl;
      _paymentSettingsLoaded = true;
      _publishRuntimeSettings();
    } catch (error, stackTrace) {
      AppLogger.error(
        'GCash QR settings update failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AppUserFacingException(
        'Unable to complete the upload. Please try again.',
      );
    }
  }

  String gcashQrAssetFingerprint(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  Future<String> replaceGcashQrAsset(
    Uint8List bytes, {
    required String operationId,
  }) async {
    final locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      throw StateError('Payment settings require an active location.');
    }
    if (bytes.isEmpty) throw ArgumentError('A QR image is required.');
    final normalizedOperationId = operationId.trim();
    if (normalizedOperationId.length < 16) {
      throw ArgumentError('A QR upload identity is required.');
    }
    final objectKey = sha256
        .convert(utf8.encode(normalizedOperationId))
        .toString();
    final path = 'public/$locationId/gcash/$objectKey';
    final newUrl = supabase.storage.from('store_assets').getPublicUrl(path);
    String previousUrl = '';
    var uploaded = false;

    try {
      final contentType = _imageContentType(bytes);
      if (contentType == null) {
        throw const AppUserFacingException(
          'Unable to complete the upload. Please try again.',
        );
      }
      previousUrl = await _fetchPersistedGcashQrUrl(locationId);
      await supabase.storage
          .from('store_assets')
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
              upsert: true,
              contentType: contentType,
              cacheControl: '0',
            ),
          );
      uploaded = true;
      if (activeLocationId != locationId) {
        throw StateError('The active location changed during the QR upload.');
      }

      try {
        await updateGcashQrUrl(newUrl);
      } catch (_) {
        // A lost response may hide a committed settings update. Reconcile the
        // canonical reference before deciding whether the staged object is an
        // orphan or the active QR.
        final persistedUrl = await _tryFetchPersistedGcashQrUrl(locationId);
        if (persistedUrl != newUrl) rethrow;
        gcashQrUrl = newUrl;
        _paymentSettingsLoaded = true;
        _publishRuntimeSettings();
      }

      if (previousUrl.isNotEmpty && previousUrl != newUrl) {
        await _removeManagedGcashObjectIfUnreferenced(
          locationId: locationId,
          candidateUrl: previousUrl,
        );
      }
      return newUrl;
    } catch (error, stackTrace) {
      if (uploaded) {
        await _removeManagedGcashObjectIfUnreferenced(
          locationId: locationId,
          candidateUrl: newUrl,
          knownPath: path,
        );
      }
      AppLogger.error(
        'GCash QR replacement failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AppUserFacingException(
        'Unable to complete the upload. Please try again.',
      );
    }
  }

  Future<String> _fetchPersistedGcashQrUrl(String locationId) async {
    final response = await supabase
        .from('store_settings')
        .select('gcash_qr_url')
        .eq('location_id', locationId)
        .maybeSingle();
    return response?['gcash_qr_url']?.toString() ?? '';
  }

  Future<String?> _tryFetchPersistedGcashQrUrl(String locationId) async {
    try {
      return await _fetchPersistedGcashQrUrl(locationId);
    } catch (error, stackTrace) {
      AppLogger.error(
        'GCash QR reference verification failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> _removeManagedGcashObjectIfUnreferenced({
    required String locationId,
    required String candidateUrl,
    String? knownPath,
  }) async {
    final candidatePath =
        knownPath ??
        _managedGcashObjectPath(candidateUrl, locationId: locationId);
    if (candidatePath == null) return;

    final currentUrl = await _tryFetchPersistedGcashQrUrl(locationId);
    if (currentUrl == null || currentUrl == candidateUrl) return;
    final currentPath = _managedGcashObjectPath(
      currentUrl,
      locationId: locationId,
    );
    if (currentPath == candidatePath) return;

    try {
      await supabase.storage.from('store_assets').remove([candidatePath]);
    } catch (error, stackTrace) {
      // Cleanup is best effort. Keeping an unreferenced object is safer than
      // turning a cleanup failure into a false save failure.
      AppLogger.error(
        'GCash QR cleanup failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String? _managedGcashObjectPath(
    String publicUrl, {
    required String locationId,
  }) {
    final uri = Uri.tryParse(publicUrl);
    if (uri == null) return null;
    final segments = uri.pathSegments;
    for (var index = 0; index + 2 < segments.length; index++) {
      if (segments[index] != 'object' ||
          segments[index + 1] != 'public' ||
          segments[index + 2] != 'store_assets') {
        continue;
      }
      final path = segments.skip(index + 3).join('/');
      final locationPrefix = 'public/$locationId/gcash/';
      return path.startsWith(locationPrefix) ? path : null;
    }
    return null;
  }

  String? _imageContentType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 6) {
      final header = ascii.decode(bytes.take(6).toList(), allowInvalid: true);
      if (header == 'GIF87a' || header == 'GIF89a') return 'image/gif';
    }
    if (bytes.length >= 12) {
      final riff = ascii.decode(bytes.take(4).toList(), allowInvalid: true);
      final webp = ascii.decode(
        bytes.skip(8).take(4).toList(),
        allowInvalid: true,
      );
      if (riff == 'RIFF' && webp == 'WEBP') return 'image/webp';
    }
    return null;
  }

  Future<void> updateCashierAutoApprovedDiscountLimit(double value) async {
    if (!value.isFinite || value < 0 || value > 100) {
      throw ArgumentError.value(value, 'value', 'Must be between 0 and 100');
    }
    final response = await supabase.rpc(
      'update_cashier_discount_limit_v1',
      params: <String, dynamic>{
        'p_session_token': _requireSessionToken(),
        'p_limit_pct': value,
      },
    );
    cashierAutoApprovedDiscountLimitPct = (response as num).toDouble();
    _paymentSettingsLoaded = true;
    _publishRuntimeSettings();
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

  InventoryApprovalNotificationCallback? onApprovalRequestChanged;

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
      AppLogger.error('Error loading stock baselines', error: e);
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
    required String sessionToken,
    String? email,
  }) {
    final accountChanged = currentUserId != id;
    final roleChanged = currentUserRole?.toLowerCase() != role.toLowerCase();
    _clearPaginatedHistoryState();
    _invalidateStaffPerformance();
    if (accountChanged) {
      _pendingQuantityOperations.clear();
      _clearInventorySnapshot();
      _clearOrdersSnapshot();
      _inventoryAwaitingRealtimeInitial = true;
      _ordersAwaitingRealtimeInitial = true;
      _clearStaffConfigurationSnapshot();
      _currentProfileSnapshot = null;
      _clearApprovalState();
    }
    if (!accountChanged && roleChanged) _clearApprovalState();

    currentUserName = name;
    currentUserId = id;
    currentUserRole = role;
    currentUserNumericId = int.tryParse(id);
    loggedInUserEmail = email;
    _sessionToken = sessionToken;
    if (activeLocationId != null) {
      _historyInvalidationsController.add(
        HistoryInvalidation(
          kind: HistoryInvalidationKind.scope,
          locationId: activeLocationId!,
        ),
      );
    }
  }

  void setActiveLocation(String locationId) {
    if (activeLocationId == locationId) return;

    activeLocationId = locationId;
    _pendingQuantityOperations.clear();
    _invalidateStaffPerformance();
    _clearPaginatedHistoryState();
    _historyInvalidationsController.add(
      HistoryInvalidation(
        kind: HistoryInvalidationKind.scope,
        locationId: locationId,
      ),
    );
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
    _clearApprovalState();
    gcashQrUrl = '';
    cashierAutoApprovedDiscountLimitPct = 10.0;
    _paymentSettingsLoaded = false;
    _publishRuntimeSettings();
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
      if (!_paymentSettingsLoaded) _refreshPaymentSettings(),
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
        cashierAutoApprovedDiscountLimitPct:
            cashierAutoApprovedDiscountLimitPct,
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
    final locationId = activeLocationId;
    if (locationId == null) return;
    try {
      final response = await supabase
          .from('store_settings')
          .select('gcash_qr_url, cashier_auto_approved_discount_limit_pct')
          .eq('location_id', locationId)
          .maybeSingle();
      if (activeLocationId != locationId) return;
      gcashQrUrl = response?['gcash_qr_url']?.toString() ?? '';
      cashierAutoApprovedDiscountLimitPct =
          (response?['cashier_auto_approved_discount_limit_pct'] as num?)
              ?.toDouble() ??
          10.0;
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

  Future<InventoryItem> addItem(
    InventoryItem newItem, {
    required String operationId,
  }) async {
    final locId = activeLocationId;
    if (locId == null) {
      throw StateError('Cannot add a product without an active location.');
    }

    final skuTaken = _disabledItems.any(
      (i) => i.sku.trim().toLowerCase() == newItem.sku.trim().toLowerCase(),
    );
    if (skuTaken) {
      throw Exception(
        'This SKU already belongs to a legacy inventory record and cannot '
        'be reused.',
      );
    }

    try {
      final response = await supabase.rpc(
        'create_product_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_operation_id': operationId,
          'p_sku': newItem.sku,
          'p_product_name': newItem.name,
          'p_category': newItem.category,
          'p_product_price': newItem.price,
          'p_product_quantity': newItem.quantity,
          'p_description': newItem.description,
          'p_image_url': newItem.imageUrl,
          'p_manufacturer': newItem.manufacturer,
          'p_model': newItem.model,
          'p_product_size': newItem.productSize,
          'p_shelf_level': newItem.shelfLevel,
          'p_bin_number': newItem.binNumber,
          'p_unit': newItem.unit,
          'p_max_quantity': newItem.maxQuantity,
        },
      );

      final savedItem = InventoryItem.fromSupabase(
        Map<String, dynamic>.from(response as Map),
      );
      final existingIndex = _items.indexWhere(
        (item) => item.id == savedItem.id,
      );
      if (existingIndex == -1) {
        _items.add(savedItem);
      } else {
        _items[existingIndex] = savedItem;
      }
      _baselineByProduct[savedItem.id] = savedItem.quantity;
      _publishInventorySnapshot();
      return savedItem;
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Transactional product creation failed',
        error,
        stackTrace,
      );
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

  Future<String> uploadProductImage(
    File imageFile,
    String fileName, {
    required String uploadKey,
  }) async {
    try {
      final path = _productImagePath(uploadKey, fileName);
      await supabase.storage
          .from('product_images')
          .upload(
            path,
            imageFile,
            fileOptions: const FileOptions(upsert: true, cacheControl: '0'),
          );
      return supabase.storage.from('product_images').getPublicUrl(path);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Product image upload failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AppUserFacingException(
        'Unable to complete the upload. Please try again.',
      );
    }
  }

  String _productImagePath(String uploadKey, String fileName) {
    final locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      throw StateError('Product image upload requires an active location.');
    }
    final normalizedKey = uploadKey.trim();
    if (normalizedKey.isEmpty) {
      throw ArgumentError('A product upload identity is required.');
    }
    final rawExtension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : 'jpg';
    final extension =
        const <String>{
          'jpg',
          'jpeg',
          'png',
          'webp',
          'gif',
        }.contains(rawExtension)
        ? rawExtension
        : 'jpg';
    final digest = sha256.convert(utf8.encode(normalizedKey)).toString();
    return 'public/$locationId/$digest.$extension';
  }

  Future<void> writeOffStock(
    String id,
    double qty, {
    required String reason,
    String? note,
  }) async {
    final index = _items.indexWhere((i) => i.id == id);
    if (index == -1) throw Exception('Item not found or unavailable.');
    final item = _items[index];

    if (qty <= 0) throw Exception('Quantity must be greater than 0.');
    if (qty > item.quantity) {
      throw Exception('Cannot remove more than the current stock.');
    }

    final newQty = item.quantity - qty;
    final result = await _adjustInventoryQuantity(
      productId: id,
      expectedQuantity: item.quantity,
      newQuantity: newQty,
      transactionType: 'write_off',
      note: (note == null || note.trim().isEmpty)
          ? reason
          : '$reason: ${note.trim()}',
    );
    final authoritativeQuantity =
        (result['new_quantity'] as num?)?.toDouble() ?? newQty;

    final currentIndex = _items.indexWhere((candidate) => candidate.id == id);
    if (currentIndex != -1) {
      _items[currentIndex] = item.copyWith(quantity: authoritativeQuantity);
      _publishInventorySnapshot();
    }
  }

  bool get canRequestInventoryApproval {
    final role = currentUserRole?.toLowerCase();
    return role == 'helper' || role == 'staff' || role == 'cashier';
  }

  Stream<InventoryApprovalPage> get approvalPageSnapshots =>
      _approvalPagesController.stream;

  Stream<InventoryApprovalRequest?> streamDiscountApproval() async* {
    yield _activeDiscountApproval;
    yield* _discountApprovalController.stream;
  }

  Future<InventoryApprovalRequest> submitDiscountApprovalRequest({
    required List<CustomerOrderItem> items,
    required String discountMode,
    required double discountValue,
    required String checkoutToken,
    String? reason,
  }) async {
    final role = currentUserRole?.toLowerCase();
    if (role != 'staff' && role != 'cashier') {
      throw StateError('Only Cashier accounts may request discount approval.');
    }
    if (items.isEmpty) throw ArgumentError('The cart cannot be empty.');
    if (!discountValue.isFinite || discountValue < 0) {
      throw ArgumentError.value(
        discountValue,
        'discountValue',
        'Must be zero or greater',
      );
    }
    final response = await supabase.rpc(
      'create_discount_approval_request_v1',
      params: <String, dynamic>{
        'p_session_token': _requireSessionToken(),
        'p_items': items.map((item) => item.toJson()).toList(growable: false),
        'p_discount_mode': discountMode,
        'p_discount_value': discountValue,
        'p_reason': reason?.trim(),
        'p_checkout_token': checkoutToken,
      },
    );
    final request = InventoryApprovalRequest.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
    _activeDiscountApprovalId = request.id;
    _activeDiscountApproval = request;
    _discountApprovalController.add(request);
    _invalidateApprovalPages(refreshVisible: false);
    await _notifyApprovalLifecycle(request);
    return request;
  }

  void clearDiscountApprovalTracking() {
    _activeDiscountApprovalId = null;
    _activeDiscountApproval = null;
    _discountApprovalController.add(null);
  }

  Future<void> _refreshActiveDiscountApproval() async {
    final requestId = _activeDiscountApprovalId;
    if (requestId == null || _discountApprovalRefreshInFlight != null) return;
    final refresh = () async {
      try {
        final response = await supabase.rpc(
          'discount_approval_request_v1',
          params: <String, dynamic>{
            'p_session_token': _requireSessionToken(),
            'p_request_id': requestId,
          },
        );
        if (_activeDiscountApprovalId != requestId || response == null) return;
        final request = InventoryApprovalRequest.fromJson(
          Map<String, dynamic>.from(response as Map),
        );
        _activeDiscountApproval = request;
        _discountApprovalController.add(request);
      } catch (error, stackTrace) {
        debugPrint(
          '[InventoryController] Discount approval refresh failed: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
    }();
    _discountApprovalRefreshInFlight = refresh;
    await refresh.whenComplete(() {
      if (identical(_discountApprovalRefreshInFlight, refresh)) {
        _discountApprovalRefreshInFlight = null;
      }
    });
  }

  InventoryApprovalPage? cachedApprovalPage({
    required InventoryApprovalStatus status,
    required int page,
    int pageSize = 20,
  }) {
    final accountId = currentUserId;
    final locationId = activeLocationId;
    if (accountId == null || locationId == null) return null;
    return _approvalPageCache.read(
      InventoryApprovalPageKey(
        accountId: accountId,
        locationId: locationId,
        status: status,
        page: page,
        pageSize: pageSize,
      ),
    );
  }

  Future<InventoryApprovalRequest> submitInventoryApprovalRequest({
    required String operationId,
    required InventoryApprovalType type,
    required String productId,
    required double quantity,
    required String proofStoragePath,
    required String proofFileName,
    required String proofMimeType,
    String? reason,
    String? note,
  }) async {
    if (!canRequestInventoryApproval) {
      throw StateError(
        'Only Cashier or Helper accounts may request stock changes.',
      );
    }
    final matches = _items.where((candidate) => candidate.id == productId);
    if (matches.isEmpty) throw StateError('Item not found or unavailable.');
    final item = matches.first;
    if (!quantity.isFinite || quantity <= 0) {
      throw ArgumentError.value(quantity, 'quantity', 'Must be greater than 0');
    }
    if (type == InventoryApprovalType.writeOff && quantity > item.quantity) {
      throw StateError('Cannot request more than the current stock.');
    }
    if (type == InventoryApprovalType.writeOff &&
        (reason == null || reason.trim().isEmpty)) {
      throw ArgumentError.value(reason, 'reason', 'A reason is required');
    }
    if (proofStoragePath.trim().isEmpty ||
        proofFileName.trim().isEmpty ||
        proofMimeType.trim().isEmpty) {
      throw ArgumentError('Photo evidence is required.');
    }
    late final dynamic response;
    try {
      response = await supabase.rpc(
        'create_inventory_approval_request_v2',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_operation_id': operationId,
          'p_request_type': type.databaseValue,
          'p_product_id': productId,
          'p_quantity': quantity,
          'p_reason': reason?.trim(),
          'p_note': note?.trim(),
          'p_proof_storage_path': proofStoragePath.trim(),
          'p_proof_file_name': proofFileName.trim(),
          'p_proof_mime_type': proofMimeType.trim().toLowerCase(),
        },
      );
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Inventory approval submission failed',
        error,
        stackTrace,
      );
    }
    final request = InventoryApprovalRequest.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
    _invalidateApprovalPages(refreshVisible: false);
    await _notifyApprovalLifecycle(request);
    return request;
  }

  Future<String> uploadApprovalEvidence({
    required String operationId,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    const allowedMimeTypes = <String>{
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    };
    final normalizedMimeType = mimeType.trim().toLowerCase();
    if (!allowedMimeTypes.contains(normalizedMimeType)) {
      throw ArgumentError('Only JPG, PNG, WebP, or GIF images are allowed.');
    }
    if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
      throw ArgumentError('Proof image must be between 1 byte and 10 MB.');
    }
    if (activeLocationId == null || currentUserId == null) {
      throw StateError('Evidence upload requires an active session.');
    }
    final response = await supabase.functions.invoke(
      'approval-evidence',
      headers: <String, String>{'x-app-session-token': _requireSessionToken()},
      body: <String, String>{
        'action': 'upload',
        'fileName': fileName,
        'mimeType': normalizedMimeType,
        'operationId': operationId,
      },
      files: <http.MultipartFile>[
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      ],
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    final storagePath = data['storagePath']?.toString();
    if (storagePath == null || storagePath.isEmpty) {
      throw StateError('Evidence upload did not return a storage path.');
    }
    return storagePath;
  }

  Future<String?> fetchApprovalEvidenceUrl(String requestId) async {
    final response = await supabase.functions.invoke(
      'approval-evidence',
      headers: <String, String>{'x-app-session-token': _requireSessionToken()},
      body: <String, dynamic>{'action': 'signedUrl', 'requestId': requestId},
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    return data['signedUrl']?.toString();
  }

  Future<Map<InventoryApprovalStatus, int>> fetchApprovalStatusCounts() async {
    if (!isAdmin) {
      throw StateError('Only Admin accounts may review approval requests.');
    }
    final accountId = currentUserId;
    final locationId = activeLocationId;
    if (accountId == null || locationId == null) {
      throw StateError('Approval summary requires an active session.');
    }
    final responses = await Future.wait(
      InventoryApprovalStatus.values.map(
        (status) => supabase.rpc(
          'approval_requests_page_v1',
          params: <String, dynamic>{
            'p_session_token': _requireSessionToken(),
            'p_status': status.databaseValue,
            'p_page': 1,
            'p_page_size': 1,
          },
        ),
      ),
    );
    if (accountId != currentUserId ||
        locationId != activeLocationId ||
        !isAdmin) {
      throw StateError('Approval summary scope changed while loading.');
    }
    return <InventoryApprovalStatus, int>{
      for (
        var index = 0;
        index < InventoryApprovalStatus.values.length;
        index++
      )
        InventoryApprovalStatus.values[index]:
            (Map<String, dynamic>.from(responses[index] as Map)['total_count']
                    as num?)
                ?.toInt() ??
            0,
    };
  }

  Future<InventoryApprovalRequest> approveInventoryApprovalRequest(
    String requestId, {
    String? reviewNote,
  }) => _reviewInventoryApprovalRequest(
    requestId,
    approve: true,
    reviewNote: reviewNote,
  );

  Future<InventoryApprovalRequest> rejectInventoryApprovalRequest(
    String requestId, {
    String? reviewNote,
  }) => _reviewInventoryApprovalRequest(
    requestId,
    approve: false,
    reviewNote: reviewNote,
  );

  Future<InventoryApprovalRequest> _reviewInventoryApprovalRequest(
    String requestId, {
    required bool approve,
    String? reviewNote,
  }) async {
    if (!isAdmin) {
      throw StateError('Only Admin accounts may review approval requests.');
    }
    final response = await supabase.rpc(
      approve
          ? 'approve_inventory_approval_request_v1'
          : 'reject_inventory_approval_request_v1',
      params: <String, dynamic>{
        'p_session_token': _requireSessionToken(),
        'p_request_id': requestId,
        'p_review_note': reviewNote?.trim(),
      },
    );
    final request = InventoryApprovalRequest.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
    _invalidateApprovalPages(refreshVisible: true);
    await _notifyApprovalLifecycle(request);
    return request;
  }

  Future<void> _notifyApprovalLifecycle(
    InventoryApprovalRequest request,
  ) async {
    final callback = onApprovalRequestChanged;
    if (callback == null) return;
    try {
      await callback(request);
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Approval notification failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<InventoryApprovalPage> activateApprovalPage({
    InventoryApprovalStatus status = InventoryApprovalStatus.pending,
    int page = 1,
    int pageSize = 20,
    bool force = false,
  }) {
    if (!isAdmin) {
      throw StateError('Only Admin accounts may review approval requests.');
    }
    final accountId = currentUserId;
    final locationId = activeLocationId;
    if (accountId == null || locationId == null) {
      throw StateError('Approval review requires an active user and location.');
    }
    final key = InventoryApprovalPageKey(
      accountId: accountId,
      locationId: locationId,
      status: status,
      page: page < 1 ? 1 : page,
      pageSize: pageSize,
    );
    _activeApprovalPageKey = key;
    final cached = _approvalPageCache.read(key);
    if (!force && cached != null && !cached.stale) {
      _approvalPagesController.add(cached);
      return Future<InventoryApprovalPage>.value(cached);
    }
    if (cached != null) _approvalPagesController.add(cached);
    return _fetchApprovalPage(key);
  }

  Future<InventoryApprovalPage> _fetchApprovalPage(
    InventoryApprovalPageKey key,
  ) {
    final existing = _approvalPageRequests[key];
    if (existing != null) return existing;
    late final Future<InventoryApprovalPage> request;
    request =
        () async {
          final response = await supabase.rpc(
            'approval_requests_page_v1',
            params: <String, dynamic>{
              'p_session_token': _requireSessionToken(),
              'p_status': key.status.databaseValue,
              'p_page': key.page,
              'p_page_size': key.pageSize,
            },
          );
          if (key.accountId != currentUserId ||
              key.locationId != activeLocationId ||
              !isAdmin) {
            throw StateError('Approval request scope changed while loading.');
          }
          final json = Map<String, dynamic>.from(response as Map);
          final rawRecords = json['records'] as List<dynamic>? ?? const [];
          final page = InventoryApprovalPage(
            key: key,
            requests: List<InventoryApprovalRequest>.unmodifiable(
              rawRecords.map(
                (row) => InventoryApprovalRequest.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              ),
            ),
            totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
            loadedAt: DateTime.now(),
          );
          _approvalPageCache.write(page);
          if (_activeApprovalPageKey == key) _approvalPagesController.add(page);
          return page;
        }().whenComplete(() {
          if (identical(_approvalPageRequests[key], request)) {
            _approvalPageRequests.remove(key);
          }
        });
    _approvalPageRequests[key] = request;
    return request;
  }

  void _invalidateApprovalPages({required bool refreshVisible}) {
    _approvalPageCache.markAllStale();
    if (refreshVisible) unawaited(_refreshActiveApprovalPage());
  }

  Future<void> _refreshActiveApprovalPage() async {
    final key = _activeApprovalPageKey;
    if (key == null ||
        key.accountId != currentUserId ||
        key.locationId != activeLocationId ||
        !isAdmin) {
      return;
    }
    try {
      await _fetchApprovalPage(key);
    } catch (error, stackTrace) {
      debugPrint('[InventoryController] Approval refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _clearApprovalState() {
    _approvalPageCache.clear();
    _approvalPageRequests.clear();
    _activeApprovalPageKey = null;
    _activeDiscountApprovalId = null;
    _activeDiscountApproval = null;
    _discountApprovalRefreshInFlight = null;
    _discountApprovalController.add(null);
  }

  Future<String> uploadImageBytes(
    Uint8List imageBytes,
    String fileName, {
    required String uploadKey,
  }) async {
    try {
      final path = _productImagePath(uploadKey, fileName);
      await supabase.storage
          .from('product_images')
          .uploadBinary(
            path,
            imageBytes,
            fileOptions: const FileOptions(upsert: true, cacheControl: '0'),
          );
      return supabase.storage.from('product_images').getPublicUrl(path);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Product image upload failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AppUserFacingException(
        'Unable to complete the upload. Please try again.',
      );
    }
  }

  Future<void> updateItem(InventoryItem updatedItem) async {
    final index = _items.indexWhere((item) => item.id == updatedItem.id);
    final oldItem = index != -1 ? _items[index] : null;
    final locationId = activeLocationId;
    if (oldItem == null || locationId == null) {
      throw const AppUserFacingException(
        'Inventory changed while processing this request. Please review and try again.',
      );
    }
    final quantityChange = updatedItem.quantity - oldItem.quantity;

    // Product details remain a normal save. Quantity and its history entry are
    // committed together by adjust_inventory_quantity_v1 below.
    await supabase
        .from('products')
        .update({
          'product_name': updatedItem.name,
          'sku': updatedItem.sku,
          'product_price': updatedItem.price,
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
        .eq('id', updatedItem.id)
        .eq('location_id', locationId);

    String? transactionId;
    var authoritativeQuantity = oldItem.quantity;
    if (quantityChange != 0) {
      final result = await _adjustInventoryQuantity(
        productId: updatedItem.id,
        expectedQuantity: oldItem.quantity,
        newQuantity: updatedItem.quantity,
        transactionType: quantityChange > 0 ? 'stock_in' : 'checkout',
      );
      transactionId = result['transaction_id']?.toString();
      authoritativeQuantity =
          (result['new_quantity'] as num?)?.toDouble() ?? updatedItem.quantity;
    }

    final currentIndex = _items.indexWhere((item) => item.id == updatedItem.id);
    if (activeLocationId == locationId && currentIndex != -1) {
      _items[currentIndex] = updatedItem.copyWith(
        quantity: authoritativeQuantity,
      );
      _publishInventorySnapshot();
    }

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
            newQuantity: authoritativeQuantity,
          );
        } catch (e, stackTrace) {
          debugPrint('RESTOCK NOTIFICATION ERROR: $e');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
    }
  }

  Future<Map<String, dynamic>> _adjustInventoryQuantity({
    required String productId,
    required double expectedQuantity,
    required double newQuantity,
    required String transactionType,
    String? note,
  }) async {
    final signature = <Object?>[
      activeLocationId,
      currentUserId,
      expectedQuantity,
      newQuantity,
      transactionType,
      note,
    ].join('|');
    final pending = _pendingQuantityOperations[productId];
    final operationId = pending?.signature == signature
        ? pending!.operationId
        : newOperationId('inventory-adjustment');
    _pendingQuantityOperations[productId] = (
      signature: signature,
      operationId: operationId,
    );

    try {
      final response = await supabase.rpc(
        'adjust_inventory_quantity_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_operation_id': operationId,
          'p_product_id': productId,
          'p_expected_quantity': expectedQuantity,
          'p_new_quantity': newQuantity,
          'p_transaction_type': transactionType,
          'p_note': note,
        },
      );
      _pendingQuantityOperations.remove(productId);
      return Map<String, dynamic>.from(response as Map);
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Inventory quantity adjustment failed',
        error,
        stackTrace,
      );
    }
  }

  String newOperationId(String scope) {
    final random = math.Random.secure();
    final entropy = List<String>.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '$scope:'
        '${DateTime.now().microsecondsSinceEpoch}-$entropy';
  }

  Never _throwCriticalOperationError(
    String diagnostic,
    Object error,
    StackTrace stackTrace,
  ) {
    AppLogger.error(diagnostic, error: error, stackTrace: stackTrace);
    final details = error.toString().toLowerCase();

    if (details.contains('payment_reference_already_used')) {
      throw const AppUserFacingException(
        'This payment reference has already been used.',
        code: AppUserFacingErrorCode.duplicatePaymentReference,
      );
    }
    if (details.contains('order_already_completed')) {
      throw const AppUserFacingException(
        'This order has already been completed.',
        code: AppUserFacingErrorCode.orderAlreadyCompleted,
      );
    }
    if (details.contains('order_cannot_be_cancelled')) {
      throw const AppUserFacingException(
        'This order can no longer be cancelled.',
      );
    }
    if (details.contains('order_not_prepared')) {
      throw const AppUserFacingException(
        'This order is not ready for payment.',
      );
    }
    if (details.contains('order_preparation_conflict')) {
      throw const AppUserFacingException(
        'This order was updated by another user. Refresh and try again.',
      );
    }
    if (details.contains('order_assignment_conflict')) {
      throw const AppUserFacingException(
        "This order's assignment has already changed.",
      );
    }
    if (details.contains('approval_submission_conflict')) {
      throw const AppUserFacingException(
        'This request has already been submitted.',
      );
    }
    if (details.contains('product_submission_conflict')) {
      throw const AppUserFacingException(
        'This product submission conflicts with an earlier request. Please refresh and try again.',
      );
    }
    if (details.contains('product_sku_already_exists')) {
      throw const AppUserFacingException(
        'An item with this SKU already exists.',
      );
    }
    if (details.contains('inventory_operation_conflict')) {
      throw const AppUserFacingException(
        'This request could not be safely retried. Please refresh and try again.',
      );
    }
    if (details.contains('inventory_changed') ||
        details.contains('checkout_inventory_changed')) {
      throw const AppUserFacingException(
        'Inventory changed while processing this request. Please review and try again.',
      );
    }

    throw error;
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
      throw Exception('Only legacy inactive items can be deleted.');
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

  List<InventoryItem> filterDeadStock({
    required String query,
    required String category,
  }) => _applyFilter(
    _items.where((item) => item.quantity <= 0).toList(growable: false),
    query,
    category,
  );

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

  CurrentUserProfileSnapshot? get currentUserProfileSnapshot {
    final snapshot = _currentProfileSnapshot;
    if (snapshot == null ||
        snapshot.id != currentUserId ||
        snapshot.locationId != activeLocationId) {
      return null;
    }
    return snapshot;
  }

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
      final row = await supabase
          .from('profiles')
          .select(
            'id, location_id, name, role, email, address, phone, '
            'must_change_password',
          )
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
            roleRequiresForcedPasswordChange(row['role']?.toString()) &&
            row['must_change_password'] == true,
        email: row['email']?.toString(),
        address: row['address']?.toString(),
        phone: row['phone']?.toString(),
      );
      if (currentUserRole?.toLowerCase() == 'admin' &&
          snapshot.role.toLowerCase() != 'admin') {
        _clearStaffConfigurationSnapshot();
      }
      final roleChanged =
          currentUserRole?.toLowerCase() != snapshot.role.toLowerCase();
      currentUserName = snapshot.name;
      currentUserRole = snapshot.role;
      loggedInUserEmail = snapshot.email;
      if (roleChanged) {
        _clearPaginatedHistoryState();
        _historyInvalidationsController.add(
          HistoryInvalidation(
            kind: HistoryInvalidationKind.scope,
            locationId: locationId,
          ),
        );
      }
      _currentProfileSnapshot = snapshot;
      _currentUserProfileController.add(snapshot);
    } catch (error, stackTrace) {
      debugPrint(
        '[InventoryController] Current profile refresh failed: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<StaffCreationResult> createStaff({
    required String name,
    required String username,
    required String password,
    required String role,
    String? email,
    String? phone,
    String? address,
  }) async {
    final locId = activeLocationId;
    if (locId == null || locId.isEmpty) {
      return const StaffCreationResult.failure(StaffCreationFailure.unexpected);
    }

    late final Map<String, dynamic> row;
    try {
      final hashedPassword = _hashPassword(password);
      final inserted = await supabase
          .from('profiles')
          .insert(
            buildStaffCreationPayload(
              name: name,
              username: username,
              passwordHash: hashedPassword,
              role: role,
              locationId: locId,
              email: email,
              phone: phone,
              address: address,
            ),
          )
          .select()
          .single();
      row = Map<String, dynamic>.from(inserted);
    } on PostgrestException catch (error) {
      final constraint = staffCreationConstraintName(
        message: error.message,
        details: error.details?.toString(),
      );
      debugPrint(
        '[StaffCreation] profiles insert failed '
        'code=${error.code} constraint=${constraint ?? 'unknown'} '
        'message=${error.message} hint=${error.hint}',
      );
      return StaffCreationResult.failure(
        classifyStaffCreationFailure(
          code: error.code,
          message: error.message,
          details: error.details?.toString(),
          hint: error.hint,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[StaffCreation] profiles insert failed '
        'type=${error.runtimeType}',
      );
      debugPrintStack(stackTrace: stackTrace);
      return const StaffCreationResult.failure(StaffCreationFailure.unexpected);
    }

    try {
      if (_staffSnapshotActivated && _staffSnapshotLocationId == locId) {
        _staffSnapshot = List<Map<String, dynamic>>.unmodifiable([
          ..._staffSnapshot,
          row,
        ]);
        _publishStaffConfigurationSnapshot();
      }
    } catch (error, stackTrace) {
      // The database insert already succeeded. A local publication problem
      // must not make the UI report a failed account creation and invite a
      // duplicate retry; realtime reconciliation will restore the snapshot.
      debugPrint(
        '[StaffCreation] local snapshot publication failed '
        'type=${error.runtimeType}',
      );
      debugPrintStack(stackTrace: stackTrace);
    }
    return const StaffCreationResult.success();
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
    if (currentUserId == null || _sessionToken == null) {
      return ChangePasswordResult.notAuthenticated;
    }
    if (!_meetsPasswordPolicy(newPassword)) {
      return ChangePasswordResult.invalidNewPassword;
    }

    try {
      final response = await supabase.rpc(
        'profile_change_password_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_current_password': currentPassword,
          'p_new_password': newPassword,
        },
      );
      if (response is! Map) return ChangePasswordResult.unexpectedFailure;
      final payload = Map<String, dynamic>.from(response);
      switch (payload['status']?.toString()) {
        case 'success':
          final replacementToken = payload['session_token']?.toString();
          if (replacementToken == null || replacementToken.isEmpty) {
            return ChangePasswordResult.unexpectedFailure;
          }
          _sessionToken = replacementToken;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('sessionToken', replacementToken);
          if (roleRequiresForcedPasswordChange(currentUserRole)) {
            _setCurrentProfileMustChangePassword(false);
          }
          _clearPaginatedHistoryState();
          return ChangePasswordResult.success;
        case 'incorrect_current':
          return ChangePasswordResult.incorrectCurrentPassword;
        case 'same_password':
          return ChangePasswordResult.sameAsCurrentPassword;
        case 'invalid_new':
          return ChangePasswordResult.invalidNewPassword;
        case 'concurrent_change':
          return ChangePasswordResult.concurrentChange;
        case 'not_authenticated':
          return ChangePasswordResult.notAuthenticated;
        default:
          return ChangePasswordResult.unexpectedFailure;
      }
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
    if (currentUserId == null || _sessionToken == null) {
      return CurrentPasswordVerificationResult.notAuthenticated;
    }
    try {
      final response = await supabase.rpc(
        'profile_verify_password_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_password': currentPassword,
        },
      );
      return response == true
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
    String productId, {
    bool force = false,
  }) {
    final String? locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      return Future<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    final key = '$locationId:$productId';
    final generation = _productHistoryGeneration;
    final cached = _productHistoryCache[key];
    if (!force &&
        cached != null &&
        _productHistoryCacheGenerations[key] == generation) {
      return Future<List<Map<String, dynamic>>>.value(cached);
    }

    final inFlight = _productHistoryRequests[key];
    if (inFlight != null &&
        _productHistoryRequestGenerations[key] == generation) {
      return inFlight;
    }

    late final Future<List<Map<String, dynamic>>> request;
    request =
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
          if (_productHistoryGeneration != generation) {
            return loadProductTransactionHistory(productId);
          }

          final result = List<Map<String, dynamic>>.unmodifiable(
            List<Map<String, dynamic>>.from(response),
          );
          if (_productHistoryGeneration == generation &&
              activeLocationId == locationId) {
            _productHistoryCache.remove(key);
            _productHistoryCache[key] = result;
            _productHistoryCacheGenerations[key] = generation;
            while (_productHistoryCache.length > _productHistoryCacheLimit) {
              final oldestKey = _productHistoryCache.keys.first;
              _productHistoryCache.remove(oldestKey);
              _productHistoryCacheGenerations.remove(oldestKey);
            }
          }
          return result;
        }().whenComplete(() {
          if (identical(_productHistoryRequests[key], request)) {
            _productHistoryRequests.remove(key);
            _productHistoryRequestGenerations.remove(key);
          }
        });
    _productHistoryRequests[key] = request;
    _productHistoryRequestGenerations[key] = generation;
    return request;
  }

  void _invalidateProductTransactionHistory() {
    _productHistoryGeneration++;
    _productHistoryCache.clear();
    _productHistoryCacheGenerations.clear();
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

  Stream<HistoryInvalidation> get historyInvalidations =>
      _historyInvalidationsController.stream;

  Stream<void> get staffPerformanceInvalidations =>
      _staffPerformanceInvalidationsController.stream;

  void _invalidateStaffPerformance() {
    _staffPerformanceGeneration++;
    _staffPerformanceCache.clear();
    _staffPerformanceInvalidationsController.add(null);
  }

  Future<StaffPerformanceSnapshot> loadStaffPerformance({
    required StaffPerformanceRole role,
    required DateTime periodStart,
    required DateTime periodEnd,
    bool forceRefresh = false,
  }) {
    if (!isAdmin) {
      throw StateError(
        'Staff Performance is available to Admin accounts only.',
      );
    }
    final locationId = activeLocationId;
    if (locationId == null || locationId.isEmpty) {
      throw StateError('Select a store location before viewing performance.');
    }
    if (!periodEnd.isAfter(periodStart)) {
      throw ArgumentError('Performance period end must follow its start.');
    }

    final startUtc = periodStart.toUtc();
    final endUtc = periodEnd.toUtc();
    final key =
        '$locationId:${role.rpcValue}:'
        '${startUtc.toIso8601String()}:${endUtc.toIso8601String()}';
    if (!forceRefresh) {
      final cached = _staffPerformanceCache[key];
      if (cached != null) return SynchronousFuture(cached);
    }
    final existing = _staffPerformanceRequests[key];
    if (existing != null) return existing;

    late final Future<StaffPerformanceSnapshot> request;
    request =
        () async {
          dynamic response;
          while (true) {
            final generation = _staffPerformanceGeneration;
            response = await supabase.rpc(
              'staff_performance_v1',
              params: <String, dynamic>{
                'p_session_token': _requireSessionToken(),
                'p_role': role.rpcValue,
                'p_period_start': startUtc.toIso8601String(),
                'p_period_end': endUtc.toIso8601String(),
              },
            );
            if (activeLocationId != locationId) {
              throw StateError('Performance request became stale.');
            }
            if (generation == _staffPerformanceGeneration) break;
          }
          final snapshot = StaffPerformanceSnapshot.fromJson(
            Map<String, dynamic>.from(response as Map),
            role: role,
            periodStart: periodStart,
            periodEnd: periodEnd,
          );
          if (_staffPerformanceCache.length >= 18) {
            _staffPerformanceCache.remove(_staffPerformanceCache.keys.first);
          }
          _staffPerformanceCache[key] = snapshot;
          return snapshot;
        }().whenComplete(() {
          _staffPerformanceRequests.remove(key);
        });
    _staffPerformanceRequests[key] = request;
    return request;
  }

  Future<HistoryPageResult<Map<String, dynamic>>> loadHistoryPage({
    required HistoryQueryFamily family,
    required int page,
    bool forceRefresh = false,
  }) {
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'History pages start at 1.');
    }
    _validateHistoryFamilyScope(family);

    final key = HistoryPageKey(family, page);
    if (!forceRefresh) {
      final cached = _historyPageCache.read(key);
      if (cached != null && !cached.stale) return SynchronousFuture(cached);
    }

    final inFlight = _historyPageRequests[key];
    if (inFlight != null) return inFlight;

    final scopeGeneration = _historyCacheGeneration;
    late final Future<HistoryPageResult<Map<String, dynamic>>> request;
    request =
        () async {
          late HistoryPageResult<Map<String, dynamic>> result;
          while (true) {
            final domainGeneration =
                _historyDomainGenerations[family.domain] ?? 0;
            result = await _fetchHistoryPage(family, page);
            _validateHistoryFamilyScope(family);
            if (scopeGeneration != _historyCacheGeneration) {
              throw StateError('History request became stale.');
            }
            if (domainGeneration == _historyDomainGenerations[family.domain]) {
              break;
            }
          }

          _historyPageCache.write(key, result);
          if (result.page != page) {
            _historyPageCache.write(
              HistoryPageKey(family, result.page),
              result,
            );
          }
          return result;
        }().whenComplete(() {
          if (identical(_historyPageRequests[key], request)) {
            _historyPageRequests.remove(key);
          }
        });
    _historyPageRequests[key] = request;
    return request;
  }

  Future<HistoryPageResult<Map<String, dynamic>>> _fetchHistoryPage(
    HistoryQueryFamily family,
    int page,
  ) async {
    dynamic response;
    try {
      final sessionToken = _requireSessionToken();
      response = await supabase.rpc(
        'history_page_v1',
        params: family.toRpcParameters(page, sessionToken: sessionToken),
      );
    } on PostgrestException catch (error) {
      debugPrint(
        '[History] RPC failed domain=${family.domain.name} page=$page '
        'code=${error.code} message=${error.message}',
      );
      rethrow;
    }
    final payload = Map<String, dynamic>.from(response as Map);
    final rawRecords = payload['records'] as List<dynamic>? ?? const [];
    final rawMetrics = payload['metrics'];
    final metrics = <String, num>{};
    if (rawMetrics is Map) {
      for (final entry in rawMetrics.entries) {
        final value = entry.value;
        if (value is num) metrics[entry.key.toString()] = value;
      }
    }
    final totalCount = (payload['total_count'] as num?)?.toInt() ?? 0;
    final totalPages = totalCount == 0
        ? 1
        : (totalCount / family.pageSize).ceil();
    if (page > totalPages) return _fetchHistoryPage(family, totalPages);
    return HistoryPageResult<Map<String, dynamic>>(
      family: family,
      page: page,
      records: List<Map<String, dynamic>>.unmodifiable(
        rawRecords.map((row) => Map<String, dynamic>.from(row as Map)),
      ),
      totalCount: totalCount,
      metrics: Map<String, num>.unmodifiable(metrics),
      loadedAt: DateTime.now(),
    );
  }

  void invalidateHistoryFamily(HistoryQueryFamily family) {
    _historyPageCache.markFamilyStale(family);
  }

  HistoryPageResult<Map<String, dynamic>>? cachedHistoryPage({
    required HistoryQueryFamily family,
    required int page,
  }) {
    _validateHistoryFamilyScope(family);
    return _historyPageCache.read(HistoryPageKey(family, page));
  }

  void clearHistorySession() {
    _clearPaginatedHistoryState();
  }

  Future<void> revokeCurrentSession() async {
    final token = _sessionToken;
    _sessionToken = null;
    _pendingQuantityOperations.clear();
    _clearPaginatedHistoryState();
    if (token == null || token.isEmpty) return;
    try {
      await supabase.rpc(
        'profile_logout_v1',
        params: <String, dynamic>{'p_session_token': token},
      );
    } catch (error, stackTrace) {
      debugPrint('[Session] Server revocation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<Map<String, dynamic>?> loadHistoryOrderDetail({
    required HistoryQueryFamily family,
    required String orderId,
  }) {
    _validateHistoryFamilyScope(family);
    final key =
        '${family.accountId}:${family.role}:${family.locationId}:$orderId';
    final inFlight = _historyDetailRequests[key];
    if (inFlight != null) return inFlight;
    final scopeGeneration = _historyCacheGeneration;
    late final Future<Map<String, dynamic>?> request;
    request =
        () async {
          while (true) {
            final domainGeneration =
                _historyDomainGenerations[family.domain] ?? 0;
            final response = await supabase.rpc(
              'history_order_detail_v1',
              params: <String, dynamic>{
                'p_session_token': _requireSessionToken(),
                'p_order_id': orderId,
              },
            );
            _validateHistoryFamilyScope(family);
            if (scopeGeneration != _historyCacheGeneration) {
              throw StateError('History detail request became stale.');
            }
            if (domainGeneration == _historyDomainGenerations[family.domain]) {
              return response == null
                  ? null
                  : Map<String, dynamic>.from(response as Map);
            }
          }
        }().whenComplete(() {
          if (identical(_historyDetailRequests[key], request)) {
            _historyDetailRequests.remove(key);
          }
        });
    _historyDetailRequests[key] = request;
    return request;
  }

  Future<List<Map<String, dynamic>>> loadSalesExport({
    required DateTime start,
    required DateTime endExclusive,
  }) async {
    final locationId = activeLocationId;
    final accountId = currentUserId;
    if (locationId == null || accountId == null) return const [];
    final sessionToken = _requireSessionToken();
    final response = await supabase.rpc(
      'history_export_sales_v1',
      params: <String, dynamic>{
        'p_session_token': sessionToken,
        'p_period_start': start.toUtc().toIso8601String(),
        'p_period_end': endExclusive.toUtc().toIso8601String(),
      },
    );
    if (activeLocationId != locationId || currentUserId != accountId) {
      throw StateError('Sales export session changed.');
    }
    return List<Map<String, dynamic>>.unmodifiable(
      (response as List<dynamic>).map(
        (row) => Map<String, dynamic>.from(row as Map),
      ),
    );
  }

  void _validateHistoryFamilyScope(HistoryQueryFamily family) {
    if (family.accountId != currentUserId ||
        family.locationId != activeLocationId ||
        family.role.toLowerCase() != currentUserRole?.toLowerCase()) {
      throw StateError('History query scope no longer matches the session.');
    }
  }

  String _requireSessionToken() {
    final token = _sessionToken;
    if (token == null || token.isEmpty) {
      throw StateError('The application session is not authenticated.');
    }
    return token;
  }

  void _clearPaginatedHistoryState() {
    _historyCacheGeneration++;
    _invalidateProductTransactionHistory();
    _historyPageCache.clear();
    _historyPageRequests.clear();
    _historyDetailRequests.clear();
  }

  void _invalidatePaginatedHistory(
    HistoryInvalidationKind kind,
    String locationId,
  ) {
    final domains = switch (kind) {
      HistoryInvalidationKind.orderHistory => <HistoryDomain>{
        HistoryDomain.adminSales,
        HistoryDomain.cashierOrders,
        HistoryDomain.helperWork,
      },
      HistoryInvalidationKind.transactions => <HistoryDomain>{
        HistoryDomain.adminActivity,
        HistoryDomain.cashierRestocks,
      },
      HistoryInvalidationKind.scope => HistoryDomain.values.toSet(),
    };
    for (final domain in domains) {
      _historyDomainGenerations[domain] =
          (_historyDomainGenerations[domain] ?? 0) + 1;
    }
    _historyPageCache.markStale(locationId: locationId, domains: domains);
    _historyInvalidationsController.add(
      HistoryInvalidation(kind: kind, locationId: locationId),
    );
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
        .from('order_history')
        .select(
          'id:order_id, status, items, created_at, event_at, total_amount, '
          'discount_amount, created_by_id, created_by_name, '
          'assigned_helper_id, assigned_helper_name, assigned_at, '
          'prepared_by_id, prepared_by_name, prepared_at, '
          'completed_by_id, completed_by_name, completed_at, '
          'cancelled_by_id, cancelled_by_name, cancelled_at, '
          'returned_by_id, returned_by_name, returned_at',
        )
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
        'created_by_id',
        'prepared_by_id',
        'completed_by_id',
        'cancelled_by_id',
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
    required String discountMode,
    required double discountValue,
    required String checkoutToken,
    String? discountReason,
    String? discountApprovalRequestId,
    String? paymentMode,
    double? cashGiven,
    double? changeAmount,
    bool soloHandled = false,
    HelperAssignmentCandidate? assignedHelper,
  }) async {
    final locId = activeLocationId;
    if (locId == null) return null;

    try {
      final initialAssignment = soloHandled
          ? const <String, dynamic>{}
          : initialHelperAssignmentFields(
              helper: assignedHelper,
              assignedAt: DateTime.now().toUtc(),
            );
      final response = await supabase.rpc(
        'create_customer_order_v2',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_items': items.map((i) => i.toJson()).toList(growable: false),
          'p_total_amount': totalAmount,
          'p_discount_amount': discountAmount,
          'p_discount_mode': discountMode,
          'p_discount_value': discountValue,
          'p_discount_reason': discountReason?.trim(),
          'p_checkout_token': checkoutToken,
          'p_discount_approval_request_id': discountApprovalRequestId,
          'p_solo_handled': soloHandled,
          'p_assigned_helper_id': initialAssignment['assigned_helper_id'],
          'p_assigned_helper_name': initialAssignment['assigned_helper_name'],
          'p_assigned_at': initialAssignment['assigned_at'],
          'p_assigned_by_admin_id': initialAssignment['assigned_by_admin_id'],
          'p_assigned_by_admin_name':
              initialAssignment['assigned_by_admin_name'],
          'p_payment_mode': paymentMode ?? 'Cash',
          'p_cash_given': cashGiven,
          'p_change_amount': changeAmount,
        },
      );
      return CustomerOrder.fromJson(Map<String, dynamic>.from(response as Map));
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Transactional checkout failed',
        error,
        stackTrace,
      );
    }
  }

  Future<void> cancelOrder(CustomerOrder order) async {
    try {
      await supabase.rpc(
        'cancel_customer_order_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_order_id': order.id,
        },
      );
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Transactional order cancellation failed',
        error,
        stackTrace,
      );
    }
  }

  void bindRealtimeSync(RealtimeSyncService realtimeSync) {
    _orderChangesSubscription ??= realtimeSync.orderChanges.listen(
      (_) {
        _ordersAwaitingRealtimeInitial = false;
        unawaited(_refreshOrdersFromDatabase());
        _invalidateStaffPerformance();
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[InventoryController] Order realtime error: $error');
      },
    );

    _orderHistoryChangesSubscription ??= realtimeSync.orderHistoryChanges
        .listen(
          (_) {
            final locationId = activeLocationId;
            if (locationId != null) {
              _invalidatePaginatedHistory(
                HistoryInvalidationKind.orderHistory,
                locationId,
              );
              _invalidateStaffPerformance();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              '[InventoryController] Order history realtime error: $error',
            );
          },
        );

    _inventoryChangesSubscription ??= realtimeSync.inventoryChanges.listen(
      (_) {
        _inventoryAwaitingRealtimeInitial = false;
        _invalidateProductTransactionHistory();
        unawaited(_refreshInventoryFromDatabase());
        _invalidateApprovalPages(
          refreshVisible: isAdmin && _activeApprovalPageKey != null,
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[InventoryController] Inventory realtime error: $error');
      },
    );

    _transactionHistoryChangesSubscription ??= realtimeSync
        .transactionHistoryChanges
        .listen(
          (_) {
            final locationId = activeLocationId;
            if (locationId != null) {
              _invalidateProductTransactionHistory();
              _invalidatePaginatedHistory(
                HistoryInvalidationKind.transactions,
                locationId,
              );
            }
            _transactionHistoryInvalidationsController.add(null);
          },
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
            _invalidateStaffPerformance();
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

    _approvalRequestChangesSubscription ??= realtimeSync.approvalRequestChanges
        .listen(
          (_) {
            _approvalPageCache.markAllStale();
            _invalidateStaffPerformance();
            if (_activeApprovalPageKey != null && isAdmin) {
              unawaited(_refreshActiveApprovalPage());
            }
            if (_activeDiscountApprovalId != null) {
              unawaited(_refreshActiveDiscountApproval());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[InventoryController] Approval realtime error: $error');
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

  /// Emits after the shared operational Order snapshot changes. Durable
  /// History invalidation is driven separately by order_history changes.
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
    _ordersSnapshotError = null;
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
      _ordersSnapshotError = null;

      _ordersController.add(_ordersSnapshot);

      return;
    }

    try {
      final now = DateTime.now();
      final startOfToday = DateTime(now.year, now.month, now.day).toUtc();
      final dashboardLookbackStart = startOfToday.subtract(
        _operationalOrderLookback,
      );
      final operationalScope = <String>[
        'status.in.(pending,prepared,solo_picking)',
        'created_at.gte.${dashboardLookbackStart.toIso8601String()}',
        'prepared_at.gte.${startOfToday.toIso8601String()}',
        'completed_at.gte.${startOfToday.toIso8601String()}',
        'cancelled_at.gte.${startOfToday.toIso8601String()}',
        'returned_at.gte.${startOfToday.toIso8601String()}',
      ].join(',');
      final rows = await supabase
          .from('orders')
          .select()
          .eq('location_id', locationId)
          .or(operationalScope)
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
      _ordersSnapshotError = null;

      _ordersController.add(_ordersSnapshot);

      debugPrint(
        '[InventoryController] ORDERS REFRESHED '
        'location=$locationId count=${orders.length}',
      );
    } catch (error, stackTrace) {
      if (activeLocationId == locationId) {
        _ordersSnapshotError = error;
      } else {
        _ordersRefreshQueued = true;
      }
      debugPrint('[InventoryController] Failed to refresh orders: $error');

      debugPrintStack(stackTrace: stackTrace);
    }
  }

  List<CustomerOrder> get currentOrders =>
      List<CustomerOrder>.unmodifiable(_ordersSnapshot);

  bool get hasUsableOrdersSnapshot =>
      _ordersSnapshotLoaded && _ordersSnapshotLocationId == activeLocationId;

  Object? get ordersSnapshotError => _ordersSnapshotError;

  Future<void> retryOrdersSnapshot() => _refreshOrdersFromDatabase();

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

  Future<void> updateOrderStatus(
    String orderId,
    String newStatus, {
    String? expectedStatus,
  }) async {
    try {
      if (newStatus == 'prepared') {
        final authoritativeExpectedStatus =
            expectedStatus ?? orderById(orderId)?.status;
        if (authoritativeExpectedStatus == null) {
          throw const AppUserFacingException(
            'This order was updated by another user. Refresh and try again.',
          );
        }
        await supabase.rpc(
          'prepare_customer_order_v1',
          params: <String, dynamic>{
            'p_session_token': _requireSessionToken(),
            'p_order_id': orderId,
            'p_expected_status': authoritativeExpectedStatus,
          },
        );
        return;
      }

      final Map<String, dynamic> updateData = {'status': newStatus};

      await supabase
          .from('orders')
          .update(updateData)
          .eq('id', orderId)
          .neq('status', 'cancelled')
          .neq('status', 'completed');
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Order status transition failed',
        error,
        stackTrace,
      );
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

  /// Runs the database-owned, deterministic Helper assignment reconciliation.
  /// Identity and location are derived from the opaque app session in
  /// Postgres; the client does not submit either as an authorization claim.
  Future<List<AutomaticHelperAssignmentResult>>
  reconcileAutomaticHelperAssignments({
    required String expectedLocationId,
    required String expectedAccountId,
  }) async {
    final sessionToken = _sessionToken;
    if (sessionToken == null ||
        sessionToken.isEmpty ||
        currentUserId != expectedAccountId ||
        activeLocationId != expectedLocationId) {
      return const <AutomaticHelperAssignmentResult>[];
    }

    final response = await supabase.rpc(
      'auto_assign_pending_orders_v1',
      params: {'p_session_token': sessionToken},
    );
    if (response is! List) {
      return const <AutomaticHelperAssignmentResult>[];
    }
    return response
        .whereType<Map>()
        .map(
          (row) => AutomaticHelperAssignmentResult.fromJson(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList(growable: false);
  }

  Future<void> assignOrderToHelper({
    required String orderId,
    required String helperId,
    required String? expectedHelperId,
  }) async {
    try {
      await supabase.rpc(
        'assign_order_helper_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_order_id': orderId,
          'p_helper_id': helperId,
          'p_expected_helper_id': expectedHelperId,
        },
      );
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Manual Helper assignment failed',
        error,
        stackTrace,
      );
    }
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
      final normalizedPaymentReference =
          paymentMode?.trim().toLowerCase() == 'gcash'
          ? normalizeGcashReference(paymentReference)
          : null;
      final response = await supabase.rpc(
        'complete_customer_order_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_order_id': order.id,
          'p_payment_mode': paymentMode,
          'p_cash_given': cashGiven,
          'p_change_amount': changeAmount,
          'p_payment_reference': normalizedPaymentReference,
        },
      );
      final result = Map<String, dynamic>.from(response as Map);
      if (result['reused'] == true) return null;
      final row = Map<String, dynamic>.from(result['order'] as Map);
      final completedAt = DateTime.parse(row['completed_at'].toString());

      return (
        createdAt: DateTime.parse(row['created_at'].toString()).toLocal(),
        completedAt: completedAt.toLocal(),
      );
    } catch (error, stackTrace) {
      _throwCriticalOperationError(
        'Transactional payment completion failed',
        error,
        stackTrace,
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
      final targetId = int.tryParse(targetUserId);
      if (targetId == null) return false;
      final response = await supabase.rpc(
        'profile_admin_reset_password_v1',
        params: <String, dynamic>{
          'p_session_token': _requireSessionToken(),
          'p_target_profile_id': targetId,
          'p_new_password': newPassword,
        },
      );
      return response == true;
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
    required List<MapElement> baseline,
    required String baselineSignature,
    required String expectedLocationId,
    required String expectedUserId,
    bool clear = false,
  }) {
    final Future<MapLayoutSaveResult>? inFlight = _mapLayoutSaveInFlight;
    if (inFlight != null) return inFlight;

    final Future<MapLayoutSaveResult> save = _performMapLayoutSave(
      draft: _cloneMapLayout(draft),
      baseline: _cloneMapLayout(baseline),
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
    required List<MapElement> baseline,
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

    if (mapLayoutSignature(baseline) != baselineSignature) {
      throw StateError('The map baseline is inconsistent with this draft.');
    }

    final dynamic persistedValue = clear
        ? null
        : draft.map((MapElement element) => element.toJson()).toList();
    final dynamic expectedValue = baseline
        .map((MapElement element) => element.toJson())
        .toList();
    final response = Map<String, dynamic>.from(
      await supabase.rpc(
            'save_store_map_v1',
            params: <String, dynamic>{
              'p_session_token': _requireSessionToken(),
              'p_expected_layout': expectedValue,
              'p_new_layout': persistedValue,
            },
          )
          as Map,
    );
    if (activeLocationId != locId || currentUserId != expectedUserId) {
      throw StateError('The active session changed during the map save.');
    }

    final dynamic returnedValue = response['layout_data'];
    final List<MapElement> saved = returnedValue == null
        ? <MapElement>[]
        : _decodeMapLayoutValue(returnedValue);
    _acceptCanonicalMapLayout(locId, saved);
    if (response['status'] == 'conflict') {
      return MapLayoutSaveResult(
        status: MapLayoutSaveStatus.conflict,
        layout: currentMapLayout,
        signature: mapLayoutSignature(saved),
      );
    }
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
    DateTime? start,
    DateTime? endExclusive,
  }) {
    final locationId = activeLocationId;
    final userId = currentUserNumericId;

    if (locationId == null || userId == null) {
      return Future<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    if ((start == null) != (endExclusive == null)) {
      throw ArgumentError(
        'Restock history range requires both start and endExclusive.',
      );
    }
    final from = page * pageSize;
    final to = from + pageSize - 1;
    final rangeKey = start == null
        ? 'page:$page:$pageSize'
        : '${start.toUtc().toIso8601String()}:'
              '${endExclusive!.toUtc().toIso8601String()}';

    return _runSerializedHistoryQuery(
      'restock:$locationId:$userId:$rangeKey',
      () async {
        final query = supabase
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
            .gt('quantity_change', 0);
        final response = start == null
            ? await query.order('created_at', ascending: false).range(from, to)
            : await query
                  .gte('created_at', start.toUtc().toIso8601String())
                  .lt('created_at', endExclusive!.toUtc().toIso8601String())
                  .order('created_at', ascending: false);

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
