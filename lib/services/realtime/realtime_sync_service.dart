import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

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

  final Map<String, RealtimeChannel> _channels = <String, RealtimeChannel>{};

  Future<void> _lifecycleQueue = Future<void>.value();

  bool _isStarted = false;
  String? _locationId;
  String? _userId;

  bool get isStarted => _isStarted;
  String? get locationId => _locationId;
  String? get userId => _userId;
  Stream<void> get orderChanges => _orderChangesController.stream;

  /// Starts one realtime session for the currently authenticated user/location.
  ///
  /// Calling [start] repeatedly for the same user/location is intentionally a
  /// no-op. Starting for a different session first tears down channels owned
  /// by this service.
  Future<void> start({
    required String locationId,
    required String userId,
  }) {
    return _enqueue(() async {
      if (_isStarted && _locationId == locationId && _userId == userId) {
        return;
      }

      await _stopInternal();

      _locationId = locationId;
      _userId = userId;
      _isStarted = true;

      debugPrint(
        '[RealtimeSync] START location=$locationId user=$userId',
      );

      await _subscribeToOrderChanges();
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
        });

    _channels[channelKey] = channel;

    _orderChangesController.add(null);

    debugPrint(
      '[RealtimeSync] ORDER SNAPSHOT REQUESTED '
      'location=$locationId',
    );

    debugPrint('[RealtimeSync] ORDERS SUBSCRIBED location=$locationId');
  }

  Future<void> _stopInternal() async {
    final bool hadSession = _isStarted ||
        _locationId != null ||
        _userId != null ||
        _channels.isNotEmpty;

    if (!hadSession) {
      return;
    }

    debugPrint(
      '[RealtimeSync] STOP location=$_locationId user=$_userId',
    );

    final List<RealtimeChannel> ownedChannels =
        List<RealtimeChannel>.of(_channels.values);
    _channels.clear();

    for (final RealtimeChannel channel in ownedChannels) {
      await _safeRemoveChannel(channel);
    }

    _isStarted = false;
    _locationId = null;
    _userId = null;
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
