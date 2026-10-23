import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

enum RuntimeSettingsChangeKind { thresholds, measurements, payment }

/// Owns app-session realtime transport.
///
/// This service does not own business state and does not perform business
/// mutations. Supabase remains the source of truth; domain controllers and
/// services remain responsible for applying domain logic.
class RealtimeSyncService {
  RealtimeSyncService({SupabaseClient? supabase})
    : _supabase = supabase ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  final StreamController<void> _orderChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _orderHistoryChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _inventoryChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _notificationChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _staffPresenceChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _transactionHistoryChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _mapLayoutChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _storeAccessChangesController =
      StreamController<void>.broadcast();
  final StreamController<RuntimeSettingsChangeKind>
  _runtimeSettingsChangesController =
      StreamController<RuntimeSettingsChangeKind>.broadcast();
  final StreamController<void> _staffConfigurationChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _currentProfileChangesController =
      StreamController<void>.broadcast();
  final StreamController<void> _approvalRequestChangesController =
      StreamController<void>.broadcast();

  final Map<String, RealtimeChannel> _channels = <String, RealtimeChannel>{};

  Future<void> _lifecycleQueue = Future<void>.value();

  bool _isStarted = false;
  String? _locationId;
  String? _userId;
  String? _userRole;

  bool get isStarted => _isStarted;
  String? get locationId => _locationId;
  String? get userId => _userId;
  Stream<void> get orderChanges => _orderChangesController.stream;
  Stream<void> get orderHistoryChanges => _orderHistoryChangesController.stream;
  Stream<void> get inventoryChanges => _inventoryChangesController.stream;
  Stream<void> get notificationChanges => _notificationChangesController.stream;
  Stream<void> get staffPresenceChanges =>
      _staffPresenceChangesController.stream;
  Stream<void> get transactionHistoryChanges =>
      _transactionHistoryChangesController.stream;
  Stream<void> get mapLayoutChanges => _mapLayoutChangesController.stream;
  Stream<void> get storeAccessChanges => _storeAccessChangesController.stream;
  Stream<RuntimeSettingsChangeKind> get runtimeSettingsChanges =>
      _runtimeSettingsChangesController.stream;
  Stream<void> get staffConfigurationChanges =>
      _staffConfigurationChangesController.stream;
  Stream<void> get currentProfileChanges =>
      _currentProfileChangesController.stream;
  Stream<void> get approvalRequestChanges =>
      _approvalRequestChangesController.stream;

  /// Starts one realtime session for the currently authenticated user/location.
  ///
  /// Calling [start] repeatedly for the same user/location is intentionally a
  /// no-op. Starting for a different session first tears down channels owned
  /// by this service.
  Future<void> start({
    required String locationId,
    required String userId,
    required String userRole,
  }) {
    return _enqueue(() async {
      final normalizedRole = userRole.toLowerCase();
      if (_isStarted &&
          _locationId == locationId &&
          _userId == userId &&
          _userRole == normalizedRole) {
        return;
      }

      await _stopInternal();

      _locationId = locationId;
      _userId = userId;
      _userRole = normalizedRole;
      _isStarted = true;

      debugPrint(
        '[RealtimeSync] START location=$locationId user=$userId '
        'role=$normalizedRole',
      );

      await _subscribeToOrderChanges();
      await _subscribeToOrderHistoryChanges();
      await _subscribeToInventoryChanges();
      await _subscribeToNotificationChanges();
      await _subscribeToStaffPresenceChanges();
      await _subscribeToTransactionHistoryChanges();
      await _subscribeToMapLayoutChanges();
      await _subscribeToStoreAccessChanges();
      await _subscribeToRuntimeSettingsChanges();
      await _subscribeToStaffConfigurationChanges();
      await _subscribeToApprovalRequestChanges();
    });
  }

  /// Stops the current realtime session and removes only channels owned by
  /// this service.
  Future<void> stop() {
    return _enqueue(_stopInternal);
  }

  /// Registers ownership of a subscribed Supabase channel.
  ///
  /// Domain adapters added in later phases must register every channel here so
  /// logout/location changes can cleanly tear them down.
  Future<void> registerChannel({
    required String key,
    required RealtimeChannel channel,
  }) {
    return _enqueue(() async {
      if (!_isStarted) {
        throw StateError(
          'RealtimeSyncService must be started before registering channels.',
        );
      }

      final RealtimeChannel? previous = _channels.remove(key);
      if (previous != null && !identical(previous, channel)) {
        await _safeRemoveChannel(previous);
      }

      _channels[key] = channel;
    });
  }

  /// Removes one owned channel without affecting realtime channels created by
  /// existing modules that have not yet been migrated.
  Future<void> removeChannel(String key) {
    return _enqueue(() async {
      final RealtimeChannel? channel = _channels.remove(key);
      if (channel != null) {
        await _safeRemoveChannel(channel);
      }
    });
  }

  Future<void> _subscribeToOrderChanges() async {
    final String? locationId = _locationId;

    if (!_isStarted || locationId == null || locationId.isEmpty) {
      return;
    }

    const String channelKey = 'orders';

    final RealtimeChannel? previous = _channels.remove(channelKey);

    if (previous != null) {
      await _safeRemoveChannel(previous);
    }

    bool hasSubscribed = false;
    final RealtimeChannel channel = _supabase
        .channel('inventory-plus:orders:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (PostgresChangePayload payload) {
            if (!_isStarted || _locationId != locationId) {
              return;
            }

            debugPrint(
              '[RealtimeSync] ORDER CHANGE '
              'location=$locationId',
            );

            _orderChangesController.add(null);
          },
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] ORDERS STATUS=$status '
            'error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed && _isStarted && _locationId == locationId) {
              _orderChangesController.add(null);
            }
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;

    _orderChangesController.add(null);

    debugPrint(
      '[RealtimeSync] ORDER SNAPSHOT REQUESTED '
      'location=$locationId',
    );

    debugPrint('[RealtimeSync] ORDERS SUBSCRIBED location=$locationId');
  }

  Future<void> _subscribeToInventoryChanges() async {
    final String? locationId = _locationId;

    if (!_isStarted || locationId == null || locationId.isEmpty) {
      return;
    }

    const String channelKey = 'inventory';
    final RealtimeChannel? previous = _channels.remove(channelKey);

    if (previous != null) {
      await _safeRemoveChannel(previous);
    }

    bool hasSubscribed = false;
    final RealtimeChannel channel = _supabase
        .channel('inventory-plus:inventory:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'products',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (PostgresChangePayload payload) {
            if (!_isStarted || _locationId != locationId) {
              return;
            }

            debugPrint('[RealtimeSync] INVENTORY CHANGE location=$locationId');
            _inventoryChangesController.add(null);
          },
        )
        .subscribe((status, error) {
          debugPrint('[RealtimeSync] INVENTORY STATUS=$status error=$error');
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed && _isStarted && _locationId == locationId) {
              _inventoryChangesController.add(null);
            }
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    _inventoryChangesController.add(null);

    debugPrint(
      '[RealtimeSync] INVENTORY SNAPSHOT REQUESTED location=$locationId',
    );
    debugPrint('[RealtimeSync] INVENTORY SUBSCRIBED location=$locationId');
  }

  Future<void> _subscribeToOrderHistoryChanges() async {
    final String? locationId = _locationId;

    if (!_isStarted || locationId == null || locationId.isEmpty) {
      return;
    }

    const String channelKey = 'order_history';
    final RealtimeChannel? previous = _channels.remove(channelKey);

    if (previous != null) {
      await _safeRemoveChannel(previous);
    }

    void signalChange(String source) {
      if (!_isStarted || _locationId != locationId) return;

      debugPrint(
        '[RealtimeSync] ORDER HISTORY CHANGE '
        'location=$locationId source=$source',
      );
      _orderHistoryChangesController.add(null);
    }

    bool hasSubscribed = false;
    final RealtimeChannel channel = _supabase
        .channel('inventory-plus:order-history:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          // order_history itself is intentionally unreadable by anon. This
          // safe, location-only signal is maintained by an order_history
          // trigger and contains no order, customer, item, or payment data.
          table: 'order_history_realtime_signals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (_) => signalChange('order_history'),
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] ORDER HISTORY STATUS=$status error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed) signalChange('order_history_resubscribed');
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    debugPrint('[RealtimeSync] ORDER HISTORY SUBSCRIBED location=$locationId');
  }

  Future<void> _subscribeToApprovalRequestChanges() async {
    final String? locationId = _locationId;
    if (!_isStarted || locationId == null || locationId.isEmpty) return;

    const String channelKey = 'approval_requests';
    final previous = _channels.remove(channelKey);
    if (previous != null) await _safeRemoveChannel(previous);

    void signalChange(String source) {
      if (!_isStarted || _locationId != locationId) return;
      debugPrint(
        '[RealtimeSync] APPROVAL REQUEST CHANGE '
        'location=$locationId source=$source',
      );
      _approvalRequestChangesController.add(null);
    }

    bool hasSubscribed = false;
    final channel = _supabase
        .channel('inventory-plus:approval-requests:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'approval_request_realtime_signals',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (_) => signalChange('approval_requests'),
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] APPROVAL REQUESTS STATUS=$status error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed) signalChange('approval_requests_resubscribed');
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    _approvalRequestChangesController.add(null);
    debugPrint(
      '[RealtimeSync] APPROVAL REQUESTS SNAPSHOT REQUESTED '
      'location=$locationId',
    );
  }

  Future<void> _subscribeToNotificationChanges() async {
    final String? locationId = _locationId;
    final String? userId = _userId;

    if (!_isStarted ||
        locationId == null ||
        locationId.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return;
    }

    const String notificationsKey = 'notifications';
    const String readsKey = 'notification_reads';

    for (final key in <String>[notificationsKey, readsKey]) {
      final previous = _channels.remove(key);
      if (previous != null) {
        await _safeRemoveChannel(previous);
      }
    }

    void signalChange(String source) {
      if (!_isStarted || _locationId != locationId || _userId != userId) {
        return;
      }

      debugPrint(
        '[RealtimeSync] NOTIFICATION CHANGE '
        'location=$locationId source=$source',
      );
      _notificationChangesController.add(null);
    }

    bool notificationsSubscribed = false;
    final RealtimeChannel notificationsChannel = _supabase
        .channel('inventory-plus:notifications:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (_) => signalChange('notifications'),
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] NOTIFICATIONS STATUS=$status error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (notificationsSubscribed) {
              signalChange('notifications_resubscribed');
            }
            notificationsSubscribed = true;
          }
        });

    bool readsSubscribed = false;
    final RealtimeChannel readsChannel = _supabase
        .channel('inventory-plus:notification-reads:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notification_reads',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => signalChange('notification_reads'),
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] NOTIFICATION READS STATUS=$status error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (readsSubscribed) {
              signalChange('notification_reads_resubscribed');
            }
            readsSubscribed = true;
          }
        });

    _channels[notificationsKey] = notificationsChannel;
    _channels[readsKey] = readsChannel;
    _notificationChangesController.add(null);

    debugPrint(
      '[RealtimeSync] NOTIFICATION SNAPSHOT REQUESTED location=$locationId',
    );
    debugPrint(
      '[RealtimeSync] NOTIFICATIONS SUBSCRIBED location=$locationId user=$userId',
    );
  }

  Future<void> _subscribeToStaffPresenceChanges() async {
    final String? locationId = _locationId;

    if (!_isStarted || locationId == null || locationId.isEmpty) {
      return;
    }

    const String channelKey = 'staff_presence';
    final RealtimeChannel? previous = _channels.remove(channelKey);

    if (previous != null) {
      await _safeRemoveChannel(previous);
    }

    void signalChange(String source) {
      if (!_isStarted || _locationId != locationId) {
        return;
      }

      debugPrint(
        '[RealtimeSync] PRESENCE CHANGE '
        'location=$locationId source=$source',
      );
      _staffPresenceChangesController.add(null);
    }

    bool hasSubscribed = false;
    final RealtimeChannel channel = _supabase
        .channel('inventory-plus:staff-presence:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'staff_presence',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (_) => signalChange('staff_presence'),
        )
        .subscribe((status, error) {
          debugPrint('[RealtimeSync] PRESENCE STATUS=$status error=$error');
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed) {
              signalChange('staff_presence_resubscribed');
            }
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    _staffPresenceChangesController.add(null);

    debugPrint(
      '[RealtimeSync] PRESENCE SNAPSHOT REQUESTED location=$locationId',
    );
    debugPrint('[RealtimeSync] PRESENCE SUBSCRIBED location=$locationId');
  }

  Future<void> _subscribeToTransactionHistoryChanges() async {
    final String? locationId = _locationId;

    if (!_isStarted || locationId == null || locationId.isEmpty) {
      return;
    }

    const String channelKey = 'transaction_history';
    final RealtimeChannel? previous = _channels.remove(channelKey);

    if (previous != null) {
      await _safeRemoveChannel(previous);
    }

    void signalChange(String source) {
      if (!_isStarted || _locationId != locationId) {
        return;
      }

      debugPrint(
        '[RealtimeSync] TRANSACTION HISTORY CHANGE '
        'location=$locationId source=$source',
      );
      _transactionHistoryChangesController.add(null);
    }

    bool hasSubscribed = false;
    final RealtimeChannel channel = _supabase
        .channel('inventory-plus:transaction-history:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'transaction_history',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (_) => signalChange('transaction_history'),
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] TRANSACTION HISTORY STATUS=$status error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed) {
              signalChange('transaction_history_resubscribed');
            }
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    _transactionHistoryChangesController.add(null);

    debugPrint(
      '[RealtimeSync] TRANSACTION HISTORY SNAPSHOT REQUESTED '
      'location=$locationId',
    );
    debugPrint(
      '[RealtimeSync] TRANSACTION HISTORY SUBSCRIBED location=$locationId',
    );
  }

  Future<void> _subscribeToMapLayoutChanges() async {
    final String? locationId = _locationId;

    if (!_isStarted || locationId == null || locationId.isEmpty) {
      return;
    }

    const String channelKey = 'map_layout';
    final RealtimeChannel? previous = _channels.remove(channelKey);

    if (previous != null) {
      await _safeRemoveChannel(previous);
    }

    void signalChange(String source) {
      if (!_isStarted || _locationId != locationId) {
        return;
      }

      debugPrint(
        '[RealtimeSync] MAP LAYOUT CHANGE '
        'location=$locationId source=$source',
      );
      _mapLayoutChangesController.add(null);
    }

    bool hasSubscribed = false;
    final RealtimeChannel channel = _supabase
        .channel('inventory-plus:map-layout:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'locations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: locationId,
          ),
          callback: (_) => signalChange('locations'),
        )
        .subscribe((status, error) {
          debugPrint('[RealtimeSync] MAP LAYOUT STATUS=$status error=$error');
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed) {
              signalChange('locations_resubscribed');
            }
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    _mapLayoutChangesController.add(null);

    debugPrint(
      '[RealtimeSync] MAP LAYOUT SNAPSHOT REQUESTED location=$locationId',
    );
    debugPrint('[RealtimeSync] MAP LAYOUT SUBSCRIBED location=$locationId');
  }

  Future<void> _subscribeToStoreAccessChanges() async {
    final String? locationId = _locationId;
    if (!_isStarted || locationId == null || locationId.isEmpty) return;

    const String channelKey = 'store_access_settings';
    final previous = _channels.remove(channelKey);
    if (previous != null) await _safeRemoveChannel(previous);

    void signal(String source) {
      if (!_isStarted || _locationId != locationId) return;
      debugPrint(
        '[RealtimeSync] STORE ACCESS CHANGE '
        'location=$locationId source=$source',
      );
      _storeAccessChangesController.add(null);
    }

    bool hasSubscribed = false;
    final channel = _supabase
        .channel('inventory-plus:store-access:$locationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'store_access_settings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'location_id',
            value: locationId,
          ),
          callback: (_) => signal('store_access_settings'),
        )
        .subscribe((status, error) {
          debugPrint('[RealtimeSync] STORE ACCESS STATUS=$status error=$error');
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (hasSubscribed) signal('store_access_resubscribed');
            hasSubscribed = true;
          }
        });

    _channels[channelKey] = channel;
    _storeAccessChangesController.add(null);
    debugPrint(
      '[RealtimeSync] STORE ACCESS SNAPSHOT REQUESTED location=$locationId',
    );
    debugPrint('[RealtimeSync] STORE ACCESS SUBSCRIBED location=$locationId');
  }

  Future<void> _subscribeToRuntimeSettingsChanges() async {
    if (!_isStarted) return;
    final role = _userRole;

    const keys = <String>[
      'threshold_settings',
      'measurement_settings',
      'payment_settings',
    ];
    for (final key in keys) {
      final previous = _channels.remove(key);
      if (previous != null) await _safeRemoveChannel(previous);
    }

    void signal(RuntimeSettingsChangeKind kind, String source) {
      if (!_isStarted) return;
      debugPrint(
        '[RealtimeSync] RUNTIME SETTINGS CHANGE '
        'kind=${kind.name} source=$source',
      );
      _runtimeSettingsChangesController.add(kind);
    }

    RealtimeChannel buildChannel({
      required String key,
      required String table,
      required RuntimeSettingsChangeKind kind,
      PostgresChangeFilter? filter,
    }) {
      bool hasSubscribed = false;
      return _supabase
          .channel('inventory-plus:$key')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            filter: filter,
            callback: (_) => signal(kind, table),
          )
          .subscribe((status, error) {
            debugPrint(
              '[RealtimeSync] ${kind.name.toUpperCase()} SETTINGS '
              'STATUS=$status error=$error',
            );
            if (status == RealtimeSubscribeStatus.subscribed) {
              if (hasSubscribed) signal(kind, '${table}_resubscribed');
              hasSubscribed = true;
            }
          });
    }

    _channels['threshold_settings'] = buildChannel(
      key: 'threshold-settings',
      table: 'threshold',
      kind: RuntimeSettingsChangeKind.thresholds,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: 1,
      ),
    );
    if (role == 'admin') {
      _channels['measurement_settings'] = buildChannel(
        key: 'measurement-settings',
        table: 'measurements',
        kind: RuntimeSettingsChangeKind.measurements,
      );
      _runtimeSettingsChangesController.add(
        RuntimeSettingsChangeKind.measurements,
      );
    }
    if (role != 'helper') {
      _channels['payment_settings'] = buildChannel(
        key: 'payment-settings',
        table: 'store_settings',
        kind: RuntimeSettingsChangeKind.payment,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: 1,
        ),
      );
      _runtimeSettingsChangesController.add(RuntimeSettingsChangeKind.payment);
    }
    _runtimeSettingsChangesController.add(RuntimeSettingsChangeKind.thresholds);
    debugPrint('[RealtimeSync] RUNTIME SETTINGS SNAPSHOT REQUESTED');
    debugPrint('[RealtimeSync] RUNTIME SETTINGS SUBSCRIBED');
  }

  Future<void> _subscribeToStaffConfigurationChanges() async {
    final String? locationId = _locationId;
    final String? userId = _userId;
    if (!_isStarted ||
        locationId == null ||
        locationId.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return;
    }

    const String locationKey = 'staff_configuration';
    const String currentUserKey = 'current_profile';
    for (final key in <String>[locationKey, currentUserKey]) {
      final previous = _channels.remove(key);
      if (previous != null) await _safeRemoveChannel(previous);
    }

    void signalStaffConfiguration(String source) {
      if (!_isStarted || _locationId != locationId) return;
      debugPrint(
        '[RealtimeSync] STAFF CONFIGURATION CHANGE '
        'location=$locationId source=$source',
      );
      _staffConfigurationChangesController.add(null);
    }

    void signalCurrentProfile(String source) {
      if (!_isStarted || _locationId != locationId || _userId != userId) return;
      debugPrint(
        '[RealtimeSync] CURRENT PROFILE CHANGE user=$userId source=$source',
      );
      _currentProfileChangesController.add(null);
    }

    if (_userRole == 'admin') {
      bool locationSubscribed = false;
      final locationChannel = _supabase
          .channel('inventory-plus:staff-configuration:$locationId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'profiles',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'location_id',
              value: locationId,
            ),
            callback: (_) => signalStaffConfiguration('profiles'),
          )
          .subscribe((status, error) {
            debugPrint(
              '[RealtimeSync] STAFF CONFIGURATION STATUS=$status error=$error',
            );
            if (status == RealtimeSubscribeStatus.subscribed) {
              if (locationSubscribed) {
                signalStaffConfiguration('profiles_resubscribed');
              }
              locationSubscribed = true;
            }
          });
      _channels[locationKey] = locationChannel;
      _staffConfigurationChangesController.add(null);
    }

    bool currentUserSubscribed = false;
    final currentUserChannel = _supabase
        .channel('inventory-plus:current-profile:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'profiles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: (_) => signalCurrentProfile('current_profile'),
        )
        .subscribe((status, error) {
          debugPrint(
            '[RealtimeSync] CURRENT PROFILE STATUS=$status error=$error',
          );
          if (status == RealtimeSubscribeStatus.subscribed) {
            if (currentUserSubscribed) {
              signalCurrentProfile('current_profile_resubscribed');
            }
            currentUserSubscribed = true;
          }
        });

    _channels[currentUserKey] = currentUserChannel;
    _currentProfileChangesController.add(null);
    debugPrint(
      '[RealtimeSync] STAFF CONFIGURATION SNAPSHOT REQUESTED '
      'location=$locationId',
    );
    debugPrint(
      '[RealtimeSync] STAFF CONFIGURATION SUBSCRIBED location=$locationId',
    );
  }

  Future<void> _stopInternal() async {
    final bool hadSession =
        _isStarted ||
        _locationId != null ||
        _userId != null ||
        _channels.isNotEmpty;

    if (!hadSession) {
      return;
    }

    debugPrint('[RealtimeSync] STOP location=$_locationId user=$_userId');

    final List<RealtimeChannel> ownedChannels = List<RealtimeChannel>.of(
      _channels.values,
    );
    _channels.clear();

    for (final RealtimeChannel channel in ownedChannels) {
      await _safeRemoveChannel(channel);
    }

    _isStarted = false;
    _locationId = null;
    _userId = null;
    _userRole = null;
  }

  Future<void> _safeRemoveChannel(RealtimeChannel channel) async {
    try {
      await _supabase.removeChannel(channel);
    } catch (error, stackTrace) {
      debugPrint('[RealtimeSync] Failed to remove owned channel: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final Future<void> next = _lifecycleQueue.then((_) => operation());

    _lifecycleQueue = next.catchError((Object error, StackTrace stackTrace) {
      debugPrint('[RealtimeSync] lifecycle error: $error');
      debugPrintStack(stackTrace: stackTrace);
    });

    return next;
  }
}
