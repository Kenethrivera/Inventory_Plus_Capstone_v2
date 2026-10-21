import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:inventory_plus/notifications/models/app_notification.dart';
import 'package:inventory_plus/notifications/models/notification_type.dart';
import 'package:inventory_plus/notifications/notification_bell.dart';
import 'package:inventory_plus/notifications/notification_bootstrap.dart';
import 'package:inventory_plus/notifications/notification_controller.dart';
import 'package:inventory_plus/notifications/notification_factory.dart';
import 'package:inventory_plus/notifications/notification_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import '../services/debug_clock.dart';
import '../services/export_period.dart';
import '../services/export_reminder_service.dart';
import 'dashboard_page.dart';
import 'forecasting_page.dart';
import 'inventory_page.dart';
import 'item_detail_page.dart';
import 'map_editor_page.dart';
import 'order_queue_page.dart';
import 'pos_cart_page.dart';
import 'profile_info_page.dart';
import 'system_settings_page.dart';
import 'transaction_history_page.dart';
import 'pos_monitor_page.dart';
import 'order_queue_monitor_page.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/change_password_dialog.dart';
import '../services/staff_presence_service.dart';
import 'widgets/active_staff_button.dart';
import '../services/store_access_service.dart';
import 'staff_history_page.dart';
import '../services/realtime/realtime_sync_service.dart';

class MainScreen extends StatefulWidget {
  final InventoryController controller;
  final RealtimeSyncService realtimeSync;

  const MainScreen({
    super.key,
    required this.controller,
    required this.realtimeSync,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int? _currentIndex;
  bool _isDetailView = false;
  String? _selectedItemId;
  String _txTargetTab = 'Sales History';
  String? _targetOrderId;
  String? _targetPosOrderId;

  NotificationController? _notificationController;

  bool _isCheckingStockAlerts = false;
  bool _isCheckingExportReminders = false;
  StaffPresenceService? _staffPresenceService;
  StoreAccessService? _storeAccessService;
  StreamSubscription<StoreAccessSettings>? _storeAccessSubscription;
  StreamSubscription<CurrentUserProfileSnapshot?>? _currentProfileSubscription;
  late final String _sessionRole;
  CurrentUserProfileSnapshot? _currentProfile;
  int _currentProfileRevision = 0;
  bool _helperProfileResolved = false;
  bool _helperProfileLoadFailed = false;
  StreamSubscription<List<InventoryItem>>? _inventoryNotificationSubscription;
  final Completer<void> _deferredControllerData = Completer<void>();
  final Set<int> _mountedPageIndexes = <int>{0};
  Timer? _storeAccessEndTimer;
  bool _isForcingStoreLogout = false;
  bool _isInvalidatingSession = false;

  Timer? _storeLogoutCountdownTimer;
  int _storeLogoutRemainingSeconds = 30;
  bool _isStoreLogoutWarningVisible = false;
  BuildContext? _storeLogoutDialogContext;
  StateSetter? _storeLogoutDialogSetState;

  static const Color _primaryBlue = Color(0xFF2563EB);
  static const Color _sidebarBg = Colors.white;
  static const Color _mainBg = Color(0xFFF4F6F8);
  static const Color _darkText = Color(0xFF0F172A);
  static const Color _inactiveText = Color(0xFF64748B);
  static const String _fontFam = 'Hellix';

  Future<void> _startRealtimeSync() async {
    final locationId = widget.controller.activeLocationId;
    final userId = widget.controller.currentUserId;

    if (locationId == null ||
        locationId.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      debugPrint('[RealtimeSync] Not started: missing location or user.');
      return;
    }

    await widget.realtimeSync.start(
      locationId: locationId,
      userId: userId,
      userRole: widget.controller.currentUserRole ?? 'staff',
    );
  }

  @override
  void initState() {
    super.initState();

    if (kDebugMode) debugPrint('[Startup] MainScreen initState');

    final locationId = widget.controller.activeLocationId;
    final userId = widget.controller.currentUserId;
    final role = widget.controller.currentUserRole?.toLowerCase();
    _sessionRole = role ?? 'staff';

    if (locationId != null && locationId.isNotEmpty) {
      final accessService = StoreAccessService(
        supabase: widget.controller.supabase,
        locationId: locationId,
      );
      accessService.bindRealtimeSync(widget.realtimeSync);
      _storeAccessService = accessService;
      _storeAccessSubscription = accessService.streamSettings().listen(
        (settings) => unawaited(_applyStoreAccessSettings(settings)),
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('[StoreAccess] Settings stream failed: $error');
        },
      );
    }

    _currentProfileSubscription = widget.controller.currentUserProfileSnapshots
        .listen(_handleCurrentProfileChange);

    if (locationId != null && userId != null && role != null) {
      _notificationController = NotificationBootstrap.create(
        locationId: locationId,
        userId: userId,
        userRole: role,
        // Order assignment payloads use profiles.id, which is the same ID
        // stored as currentUserId by the custom login flow.
        recipientId: userId,
        realtimeSync: widget.realtimeSync,
      );

      widget.controller.onRestockRecorded =
          ({
            required String locationId,
            required String transactionId,
            required String productId,
            required String productName,
            required String staffId,
            required String staffName,
            required double quantityAdded,
            required double newQuantity,
          }) async {
            final controller = _notificationController;

            if (controller == null) {
              throw StateError('Notification controller not initialized.');
            }

            await controller.notifyInventoryRestocked(
              locationId: locationId,
              transactionId: transactionId,
              productId: productId,
              productName: productName,
              staffId: staffId,
              staffName: staffName,
              quantityAdded: quantityAdded,
              newQuantity: newQuantity,
            );
          };

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scanExportReminderNotifications();
      });
    }

    _inventoryNotificationSubscription = widget.controller.inventorySnapshots
        .listen((_) => unawaited(_scanInventoryAfterDeferredData()));

    _configureStaffPresence();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (kDebugMode) debugPrint('[Startup] MainScreen first frame rendered');
      unawaited(_refreshHelperPasswordGate());
      unawaited(_startSessionSynchronization());
      unawaited(_loadDeferredControllerData());
    });
  }

  @override
  void dispose() {
    _storeAccessEndTimer?.cancel();
    _storeLogoutCountdownTimer?.cancel();
    _storeLogoutDialogSetState = null;
    unawaited(_inventoryNotificationSubscription?.cancel());
    unawaited(_storeAccessSubscription?.cancel());
    unawaited(_currentProfileSubscription?.cancel());
    unawaited(_storeAccessService?.dispose());
    if (!_deferredControllerData.isCompleted) {
      _deferredControllerData.complete();
    }
    _notificationController?.dispose();
    _staffPresenceService?.dispose();
    widget.controller.onRestockRecorded = null;
    super.dispose();
  }

  String _currentModuleName() {
    final role = widget.controller.currentUserRole?.toLowerCase();

    if (_currentIndex == null) {
      return 'Main Screen';
    }

    if (role == 'admin') {
      switch (_currentIndex) {
        case 0:
          return 'Dashboard';

        case 1:
          return 'Forecasting';

        case 2:
          return 'POS Monitor';

        case 3:
          return 'Queue Monitor';

        case 4:
          return 'Inventory';

        case 5:
          return 'Transactions';

        case 6:
          return 'Store Map';

        case 7:
          return 'System Settings';

        default:
          return 'Main Screen';
      }
    }

    if (role == 'helper') {
      switch (_currentIndex) {
        case 0:
          return 'Order Queue';

        case 1:
          return 'Inventory';

        case 2:
          return 'History';

        default:
          return 'Main Screen';
      }
    }

    // Staff / cashier.
    switch (_currentIndex) {
      case 0:
        return 'POS System';

      case 1:
        return 'Inventory';

      case 2:
        return 'History';

      default:
        return 'Main Screen';
    }
  }

  Future<void> _applyStoreAccessSettings(
    StoreAccessSettings settings,
  ) async {
    final role = widget.controller.currentUserRole?.toLowerCase();
    if (role == null || role.isEmpty) return;
    final accessService = _storeAccessService;
    if (accessService == null || settings.locationId != accessService.locationId) {
      return;
    }

    debugPrint('STORE ACCESS CHECK: role=$role');
    debugPrint('OPENING: ${settings.openingTime}');
    debugPrint('CLOSING: ${settings.closingTime}');
    debugPrint('AFTER ALLOWANCE: ${settings.staffAccessAfterMinutes} minutes');

    final now = DateTime.now();
    final accessAllowed = accessService.isAccessAllowed(
      settings: settings,
      role: role,
      now: now,
    );

    _storeAccessEndTimer?.cancel();
    _storeAccessEndTimer = null;

    if (!accessAllowed) {
      debugPrint('STORE ACCESS: current session is outside the new window');
      await _forceLogoutDueToStoreHours();
      return;
    }

    _cancelPendingStoreLogout();

    if (!settings.restrictStaffLogin) {
      debugPrint('STORE ACCESS: restriction is OFF');
      return;
    }

    if (role == 'admin' && settings.allowAdminAnytime) {
      debugPrint('STORE ACCESS: admin allowed anytime');
      return;
    }

    final endTime = accessService.accessEndDateTime(settings, now: now);
    final remaining = endTime.difference(now);

    debugPrint('NOW: $now');
    debugPrint('ACCESS ENDS AT: $endTime');
    debugPrint('REMAINING: ${remaining.inSeconds} seconds');

    if (remaining.isNegative || remaining.inSeconds <= 0) {
      debugPrint('STORE ACCESS: expired already, forcing logout');
      await _forceLogoutDueToStoreHours();
      return;
    }

    _storeAccessEndTimer = Timer(remaining, () async {
      debugPrint('STORE ACCESS: timer fired, rechecking access');
      try {
        await accessService.refreshSettings();
      } catch (error, stackTrace) {
        debugPrint('[StoreAccess] Deadline reconciliation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    });
  }

  void _cancelPendingStoreLogout() {
    if (!_isForcingStoreLogout) return;
    _isForcingStoreLogout = false;
    _storeLogoutCountdownTimer?.cancel();
    _storeLogoutCountdownTimer = null;
    final dialogContext = _storeLogoutDialogContext;
    _storeLogoutDialogContext = null;
    _storeLogoutDialogSetState = null;
    if (dialogContext != null && Navigator.canPop(dialogContext)) {
      Navigator.pop(dialogContext);
    }
    _isStoreLogoutWarningVisible = false;
  }

  Future<void> _forceLogoutDueToStoreHours() async {
    if (_isForcingStoreLogout) return;

    _isForcingStoreLogout = true;
    _storeLogoutRemainingSeconds = 30;

    _showStoreLogoutWarningModal();
    _startStoreLogoutCountdown();
  }

  void _startStoreLogoutCountdown() {
    _storeLogoutCountdownTimer?.cancel();

    _storeLogoutCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_storeLogoutRemainingSeconds <= 1) {
        timer.cancel();
        _completeForcedStoreLogout();
        return;
      }

      setState(() {
        _storeLogoutRemainingSeconds--;
      });
      if (_isStoreLogoutWarningVisible) {
        _storeLogoutDialogSetState?.call(() {});
      }
    });
  }

  void _showStoreLogoutWarningModal() {
    if (!mounted) return;
    if (_isStoreLogoutWarningVisible) return;

    _isStoreLogoutWarningVisible = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _storeLogoutDialogContext = dialogContext;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            _storeLogoutDialogSetState = setDialogState;

            final progress = _storeLogoutRemainingSeconds / 30;

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                width: 420,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.14),
                      blurRadius: 28,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _primaryBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            LucideIcons.clockAlert,
                            color: _primaryBlue,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Shift access ended',
                            style: TextStyle(
                              color: _darkText,
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              fontFamily: _fontFam,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            'Automatic logout in',
                            style: TextStyle(
                              color: _inactiveText,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFamily: _fontFam,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$_storeLogoutRemainingSeconds',
                            style: const TextStyle(
                              color: _primaryBlue,
                              fontSize: 44,
                              fontWeight: FontWeight.w900,
                              fontFamily: _fontFam,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'seconds',
                            style: TextStyle(
                              color: _inactiveText,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              fontFamily: _fontFam,
                            ),
                          ),
                          const SizedBox(height: 14),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: progress.clamp(0.0, 1.0),
                              minHeight: 7,
                              backgroundColor: const Color(0xFFE5E7EB),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                _primaryBlue,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              _isStoreLogoutWarningVisible = false;
                              _storeLogoutDialogContext = null;
                              _storeLogoutDialogSetState = null;

                              if (Navigator.canPop(dialogContext)) {
                                Navigator.pop(dialogContext);
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _darkText,
                              side: const BorderSide(color: Color(0xFFE5E7EB)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text(
                              'Wait',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontFamily: _fontFam,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _completeForcedStoreLogout,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primaryBlue,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text(
                              'Log out now',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontFamily: _fontFam,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      _isStoreLogoutWarningVisible = false;
      _storeLogoutDialogContext = null;
      _storeLogoutDialogSetState = null;
    });
  }

  Future<void> _completeForcedStoreLogout() async {
    _storeLogoutCountdownTimer?.cancel();
    _storeLogoutCountdownTimer = null;

    if (_storeLogoutDialogContext != null) {
      final dialogContext = _storeLogoutDialogContext!;

      if (Navigator.canPop(dialogContext)) {
        Navigator.pop(dialogContext);
      }

      _storeLogoutDialogContext = null;
      _storeLogoutDialogSetState = null;
    }

    await _staffPresenceService?.stop(logoutReason: 'store_hours_expired');

    final prefs = await SharedPreferences.getInstance();
    await widget.realtimeSync.stop();
    await prefs.clear();

    if (!mounted) return;

    AppToast.error(
      context,
      'Store access time has ended. You have been logged out.',
    );

    Navigator.pushReplacementNamed(context, '/login');
  }

  void _configureStaffPresence() {
    final locationId = widget.controller.activeLocationId;
    final userId = widget.controller.currentUserId;
    final userName = widget.controller.currentUserName;
    final userRole = widget.controller.currentUserRole;

    if (locationId == null ||
        locationId.isEmpty ||
        userId == null ||
        userId.isEmpty ||
        userName == null ||
        userName.isEmpty ||
        userRole == null ||
        userRole.isEmpty) {
      return;
    }

    final service = StaffPresenceService(
      supabase: widget.controller.supabase,
      locationId: locationId,
      userId: userId,
      userName: userName,
      userRole: userRole,
    );
    service.bindRealtimeSync(widget.realtimeSync);
    _staffPresenceService = service;
  }

  Future<void> _startStaffPresence() async {
    await _staffPresenceService?.start(currentModule: _currentModuleName());
  }

  Future<void> _startSessionSynchronization() async {
    try {
      if (kDebugMode) debugPrint('[Startup] Realtime start requested');
      await _startRealtimeSync();
    } catch (error, stackTrace) {
      debugPrint('[Startup] Realtime start failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      final accessService = _storeAccessService;
      if (accessService != null && accessService.currentSettings == null) {
        await accessService.refreshSettings();
      }
    } catch (error, stackTrace) {
      debugPrint('[Startup] Store access refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      await _startStaffPresence();
    } catch (error, stackTrace) {
      debugPrint('[Startup] Staff presence start failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

  }

  void _handleCurrentProfileChange(CurrentUserProfileSnapshot? profile) {
    if (!mounted) return;
    if (profile == null) {
      unawaited(
        _invalidateSessionForProfileChange(
          'Your staff account is no longer active for this store.',
        ),
      );
      return;
    }
    if (profile.role.toLowerCase() != _sessionRole) {
      unawaited(
        _invalidateSessionForProfileChange(
          'Your account role changed. Please sign in again.',
        ),
      );
      return;
    }
    if (identical(_currentProfile, profile) &&
        (_sessionRole != 'helper' || _helperProfileResolved)) {
      return;
    }
    setState(() {
      _currentProfile = profile;
      _currentProfileRevision++;
      if (_sessionRole == 'helper') {
        _helperProfileResolved = true;
        _helperProfileLoadFailed = false;
      }
    });
  }

  Future<void> _refreshHelperPasswordGate() async {
    if (_sessionRole != 'helper') return;
    if (mounted) {
      setState(() {
        _helperProfileResolved = false;
        _helperProfileLoadFailed = false;
      });
    }

    final profile = await widget.controller.refreshCurrentUserProfile();
    if (!mounted) return;
    if (profile == null) {
      setState(() {
        _helperProfileResolved = true;
        _helperProfileLoadFailed = true;
      });
      return;
    }
    _handleCurrentProfileChange(profile);
  }

  Future<void> _invalidateSessionForProfileChange(String message) async {
    if (_isInvalidatingSession) return;
    _isInvalidatingSession = true;
    _storeAccessEndTimer?.cancel();
    _storeLogoutCountdownTimer?.cancel();
    try {
      await _staffPresenceService?.stop(logoutReason: 'profile_changed');
      final prefs = await SharedPreferences.getInstance();
      await widget.realtimeSync.stop();
      await prefs.clear();
    } catch (error, stackTrace) {
      debugPrint('[Session] Profile invalidation cleanup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!mounted) return;
    AppToast.error(context, message);
    Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _loadDeferredControllerData() async {
    try {
      await widget.controller.loadDeferredAppData();
    } catch (error, stackTrace) {
      debugPrint('[Startup] Deferred controller data failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (!_deferredControllerData.isCompleted) {
        _deferredControllerData.complete();
      }
    }
  }

  Future<void> _scanInventoryAfterDeferredData() async {
    await _deferredControllerData.future;
    if (!mounted) return;
    await _scanInventoryStockAlerts();
  }

  List<Widget> _lazyPageChildren(List<Widget> pages) {
    final selectedIndex = _currentIndex ?? 0;
    _mountedPageIndexes.add(selectedIndex);

    return List<Widget>.generate(pages.length, (index) {
      if (!_mountedPageIndexes.contains(index)) {
        return const SizedBox.shrink();
      }

      return KeyedSubtree(
        key: ValueKey<String>('main-page-$index'),
        child: pages[index],
      );
    });
  }

  Future<void> _updateStaffPresenceModule() async {
    await _staffPresenceService?.updateModule(_currentModuleName());
  }

  void _handleSelectItem(InventoryItem item) {
    final isDesktop = MediaQuery.of(context).size.width >= 600;

    if (isDesktop) {
      showDialog(
        context: context,
        builder: (dialogContext) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 500,
            height: 700,
            child: ItemDetailPage(
              item: item,
              controller: widget.controller,
              onBack: () => Navigator.pop(dialogContext),
              onUpdate: (updatedItem) async {
                await _handleUpdateItem(updatedItem);
                if (mounted) setState(() {});
              },
              onDelete: (id) async {
                await widget.controller.deleteItem(id);
                await _scanInventoryStockAlerts();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) setState(() {});
              },
              onStatusChanged: () {
                if (mounted) setState(() {});
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _scanInventoryStockAlerts();
                });
              },
            ),
          ),
        ),
      );
    } else {
      setState(() {
        _selectedItemId = item.id;
        _isDetailView = true;
      });
    }
  }

  void _handleBackToMain() {
    setState(() {
      _isDetailView = false;
      _selectedItemId = null;
    });
  }

  String _formatQty(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value.toStringAsFixed(2);
  }

  String _stockStatusKey(StockStatus status) {
    switch (status) {
      case StockStatus.low:
        return 'low';
      case StockStatus.critical:
        return 'critical';
      case StockStatus.out:
        return 'dead';
      case StockStatus.ok:
        return 'ok';
    }
  }

  Future<void> _scanInventoryStockAlerts() async {
    if (_isCheckingStockAlerts) return;

    final notificationController = _notificationController;
    final locationId = widget.controller.activeLocationId;

    if (notificationController == null || locationId == null) return;

    _isCheckingStockAlerts = true;

    try {
      final items = widget.controller.filterInventory(
        query: '',
        category: 'All',
      );

      final previousStates = await notificationController
          .fetchStockNotificationStates();

      // Older builds created multi-item aggregate rows that cannot represent
      // one product lifecycle. Resolve them before publishing per-item state.
      await notificationController.resolveStockAlertNotifications();

      final statesToSave = <Map<String, dynamic>>[];
      final now = DateTime.now().toUtc().toIso8601String();

      for (final item in items) {
        final stockStatus = widget.controller.stockStatusFor(item);
        final currentStatus = _stockStatusKey(stockStatus);
        final previousStatus = previousStates[item.id];

        statesToSave.add({
          'location_id': locationId,
          'item_id': item.id,
          'last_status': currentStatus,
          'updated_at': now,
        });

        // First scan only records the state. It should not flood notifications.
        if (previousStatus == null) continue;

        // Healthy items need no lifecycle work. For an ongoing alert, an
        // idempotent transition updates quantity/content on the same row.
        if (previousStatus == currentStatus && currentStatus == 'ok') continue;

        if (currentStatus == 'ok') {
          await notificationController.resolveAllStockNotifications(
            itemId: item.id,
          );
          continue;
        }

        final triggeredByName =
            widget.controller.currentUserName ?? 'Unknown User';
        final triggeredAt = DateTime.now();

        switch (stockStatus) {
          case StockStatus.low:
            await notificationController.notifyLowStock(
              locationId: locationId,
              itemId: item.id,
              itemName: item.name,
              quantity: _formatQty(item.quantity),
              unit: item.unit,
              triggeredByName: triggeredByName,
              triggeredAt: triggeredAt,
            );
            break;
          case StockStatus.critical:
            await notificationController.notifyCriticalStock(
              locationId: locationId,
              itemId: item.id,
              itemName: item.name,
              quantity: _formatQty(item.quantity),
              unit: item.unit,
              triggeredByName: triggeredByName,
              triggeredAt: triggeredAt,
            );
            break;
          case StockStatus.out:
            await notificationController.notifyDeadStock(
              locationId: locationId,
              itemId: item.id,
              itemName: item.name,
              unit: item.unit,
              triggeredByName: triggeredByName,
              triggeredAt: triggeredAt,
            );
            break;
          case StockStatus.ok:
            break;
        }
      }

      final currentItemIds = items.map((item) => item.id).toSet();
      for (final missingItemId in previousStates.keys.where(
        (itemId) => !currentItemIds.contains(itemId),
      )) {
        await notificationController.resolveAllStockNotifications(
          itemId: missingItemId,
        );
      }

      await notificationController.upsertStockNotificationStates(statesToSave);
    } finally {
      _isCheckingStockAlerts = false;
    }
  }

  Future<void> _scanExportReminderNotifications() async {
    if (_isCheckingExportReminders) return;

    final notificationController = _notificationController;
    final locationId = widget.controller.activeLocationId;
    final role = widget.controller.currentUserRole?.toLowerCase();

    if (notificationController == null || locationId == null) return;
    if (role != 'admin') return;

    _isCheckingExportReminders = true;

    try {
      final service = ExportReminderService(
        supabase: widget.controller.supabase,
        locationId: locationId,
      );

      final inventoryDue = await service.dueReminders('inventory');
      final salesDue = await service.dueReminders('sales');

      for (final type in inventoryDue) {
        final period = ExportPeriod.current(type);

        await notificationController.notifyExportReminder(
          locationId: locationId,
          reportType: 'inventory',
          periodType: type.name,
          periodKey: period.key,
        );
      }

      for (final type in salesDue) {
        final period = ExportPeriod.current(type);

        await notificationController.notifyExportReminder(
          locationId: locationId,
          reportType: 'sales',
          periodType: type.name,
          periodKey: period.key,
        );
      }
    } finally {
      _isCheckingExportReminders = false;
    }
  }

  Future<String?> _validateNotificationTap(AppNotification notification) async {
    final orderId = notification.payload['orderId']?.toString();
    final currentRole = widget.controller.currentUserRole?.toLowerCase();

    switch (notification.type) {
      case NotificationType.newOrder:
      case NotificationType.orderAssigned:
        if (orderId == null || orderId.isEmpty) {
          return 'Order ID not found in notification.';
        }

        final orders = await widget.controller.streamOrders().first;
        final matches = orders.where((order) => order.id == orderId).toList();

        if (matches.isEmpty) {
          await _notificationController?.resolveOrderWorkflowNotification(
            orderId: orderId,
          );
          return 'This order no longer exists.';
        }

        final order = matches.first;

        if (order.status != 'pending') {
          await _notificationController?.resolveOrderWorkflowNotification(
            orderId: orderId,
          );
          return 'This order is already ${order.status}.';
        }

        final assignedHelperId = order.assignedHelperId?.toString();
        final currentHelperId = widget.controller.currentUserId;
        if (currentRole == 'helper' &&
            assignedHelperId != null &&
            assignedHelperId.isNotEmpty &&
            assignedHelperId != currentHelperId) {
          return 'This order is assigned to another helper.';
        }

        return null;

      case NotificationType.inventoryRestocked:
        final role = widget.controller.currentUserRole?.toLowerCase();

        if (role != 'admin') {
          return 'Only administrators can open restock notifications.';
        }

        final productId = notification.payload['productId']?.toString();

        if (productId == null || productId.isEmpty) {
          return 'Product ID not found in notification.';
        }

        final items = [
          ...widget.controller.filterInventory(query: '', category: 'All'),
          ...widget.controller.filterDisabled(query: '', category: 'All'),
        ];

        final exists = items.any((item) => item.id.toString() == productId);

        if (!exists) {
          return 'This product no longer exists.';
        }

        return null;

      case NotificationType.orderPrepared:
        if (orderId == null || orderId.isEmpty) {
          return 'Order ID not found in notification.';
        }

        final orders = await widget.controller.streamOrders().first;
        final matches = orders.where((order) => order.id == orderId).toList();

        if (matches.isEmpty) {
          await _notificationController?.resolveOrderWorkflowNotification(
            orderId: orderId,
          );
          return 'This order no longer exists.';
        }

        final order = matches.first;

        if (order.status != 'prepared') {
          if (order.status == 'completed' || order.status == 'cancelled') {
            await _notificationController?.resolveOrderWorkflowNotification(
              orderId: orderId,
            );
          }
          return 'This order is not ready for payment yet.';
        }

        return null;

      case NotificationType.orderCancelled:
        if (orderId != null && orderId.isNotEmpty) {
          await _notificationController?.resolveOrderWorkflowNotification(
            orderId: orderId,
          );
        }
        return 'This order has been cancelled.';

      case NotificationType.lowStock:
      case NotificationType.criticalStock:
      case NotificationType.deadStock:
      case NotificationType.stockAlert:
        String? itemId = notification.payload['itemId']?.toString();
        final rawItems = notification.payload['items'];
        if ((itemId == null || itemId.isEmpty) &&
            rawItems is List &&
            rawItems.isNotEmpty &&
            rawItems.first is Map) {
          itemId = (rawItems.first as Map)['itemId']?.toString();
        }

        if (itemId == null || itemId.isEmpty) {
          return 'Product information is missing.';
        }

        final stockItems = [
          ...widget.controller.filterInventory(query: '', category: 'All'),
          ...widget.controller.filterDisabled(query: '', category: 'All'),
        ];
        final matchingItems = stockItems.where((item) => item.id == itemId);
        if (matchingItems.isEmpty) {
          await _notificationController?.resolveAllStockNotifications(
            itemId: itemId,
          );
          return 'This product no longer exists.';
        }

        if (widget.controller.stockStatusFor(matchingItems.first) ==
            StockStatus.ok) {
          await _notificationController?.resolveAllStockNotifications(
            itemId: itemId,
          );
          return 'This stock alert has already been resolved.';
        }

        return null;

      default:
        return null;
    }
  }

  void _handleNotificationSelected(
    AppNotification notification, {
    required int orderQueueIndex,
    required int posIndex,
    required int transactionIndex,
    required int inventoryIndex,
  }) {
    final orderId = notification.payload['orderId']?.toString();

    switch (notification.type) {
      case NotificationType.newOrder:
      case NotificationType.orderAssigned:
        if (orderId == null || orderId.isEmpty) {
          AppToast.error(context, 'Order ID not found in notification.');
          return;
        }

        if (orderQueueIndex < 0) {
          AppToast.error(
            context,
            'Order Queue is not available for this role.',
          );
          return;
        }

        setState(() {
          _targetOrderId = orderId;
          _currentIndex = orderQueueIndex;
        });
        break;

      case NotificationType.orderPrepared:
        if (orderId == null || orderId.isEmpty) {
          AppToast.error(context, 'Order ID not found in notification.');
          return;
        }

        if (posIndex < 0) {
          AppToast.error(context, 'POS is not available for this role.');
          return;
        }

        setState(() {
          _targetPosOrderId = orderId;
          _currentIndex = posIndex;
        });
        break;

      case NotificationType.transaction:
        if (transactionIndex < 0) {
          AppToast.error(context, 'Transactions page is not available.');
          return;
        }

        setState(() {
          _txTargetTab = 'Sales History';
          _currentIndex = transactionIndex;
        });
        break;

      case NotificationType.exportReminder:
        final reportType = notification.payload['reportType']?.toString();

        if (reportType == 'inventory') {
          setState(() {
            _currentIndex = inventoryIndex;
          });
          break;
        }

        if (reportType == 'sales') {
          if (transactionIndex < 0) {
            AppToast.error(context, 'Transactions page is not available.');
            return;
          }

          setState(() {
            _txTargetTab = 'Sales History';
            _currentIndex = transactionIndex;
          });
          break;
        }

        AppToast.error(context, 'Unknown report type.');
        break;

      case NotificationType.stockAlert:
        final rawItems = notification.payload['items'];

        if (rawItems is! List || rawItems.isEmpty) {
          AppToast.error(context, 'Stock alert items not found.');
          return;
        }

        final firstItem = Map<String, dynamic>.from(rawItems.first);
        final itemId = firstItem['itemId']?.toString();

        if (itemId == null || itemId.isEmpty) {
          AppToast.error(context, 'Item ID not found in stock alert.');
          return;
        }

        final items = [
          ...widget.controller.filterInventory(query: '', category: 'All'),
          ...widget.controller.filterDisabled(query: '', category: 'All'),
        ];

        final matches = items.where((item) => item.id == itemId).toList();

        if (matches.isEmpty) {
          AppToast.error(context, 'This item no longer exists.');
          return;
        }

        setState(() {
          _currentIndex = inventoryIndex;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _handleSelectItem(matches.first);
        });
        break;

      case NotificationType.lowStock:
      case NotificationType.criticalStock:
      case NotificationType.deadStock:
        final itemId = notification.payload['itemId']?.toString();
        final items = [
          ...widget.controller.filterInventory(query: '', category: 'All'),
          ...widget.controller.filterDisabled(query: '', category: 'All'),
        ];
        final matches = items.where((item) => item.id == itemId).toList();
        if (matches.isEmpty) {
          AppToast.error(context, 'This product no longer exists.');
          return;
        }

        setState(() => _currentIndex = inventoryIndex);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleSelectItem(matches.first);
        });
        break;

      case NotificationType.inventoryRestocked:
        final productId = notification.payload['productId']?.toString();

        final role = widget.controller.currentUserRole?.toLowerCase();

        if (role != 'admin') {
          AppToast.error(
            context,
            'Restock monitoring is available to administrators only.',
          );
          return;
        }

        if (productId == null || productId.isEmpty) {
          AppToast.error(context, 'Product information is missing.');
          return;
        }

        final items = [
          ...widget.controller.filterInventory(query: '', category: 'All'),
          ...widget.controller.filterDisabled(query: '', category: 'All'),
        ];

        final matches = items
            .where((item) => item.id.toString() == productId)
            .toList();

        if (matches.isEmpty) {
          AppToast.error(context, 'This product no longer exists.');
          return;
        }

        setState(() {
          _currentIndex = inventoryIndex;
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _handleSelectItem(matches.first);
        });

        break;

      default:
        AppToast.success(context, notification.title);
        break;
    }
  }

  Future<void> _handleUpdateItem(InventoryItem item) async {
    await widget.controller.updateItem(item);
    await _scanInventoryStockAlerts();

    if (mounted) {
      setState(() {
        _selectedItemId = item.id;
      });
    }
  }

  Future<void> _handleDeleteItem(String id) async {
    await widget.controller.deleteItem(id);
    await _scanInventoryStockAlerts();

    if (!mounted) return;

    setState(() {
      _isDetailView = false;
      _selectedItemId = null;
    });
  }

  Future<void> _createTestNotification() async {
    final locationId = widget.controller.activeLocationId;

    if (locationId == null) {
      AppToast.error(context, 'No active location found.');
      return;
    }

    final controller = _notificationController;

    if (controller == null) {
      AppToast.error(context, 'Notification controller is not ready.');
      return;
    }

    final notification = NotificationFactory.system(
      locationId: locationId,
      targetRoles: const ['admin', 'helper', 'staff'],
      title: 'Test Notification',
      body: 'This is a test notification from Inventory Plus.',
    );

    await controller.createNotification(notification);

    if (mounted) {
      AppToast.success(context, 'Test notification created.');
    }
  }

  Widget _debugToolsButtons() {
    if (kReleaseMode) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'debugClockFab',
          backgroundColor: DebugClock.isOverridden ? Colors.red : Colors.grey,
          onPressed: _showDebugClockDialog,
          child: const Icon(Icons.schedule, color: Colors.white),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'testNotificationFab',
          backgroundColor: _primaryBlue,
          onPressed: _createTestNotification,
          child: const Icon(LucideIcons.bellPlus, color: Colors.white),
        ),
      ],
    );
  }

  void _rerunReminderScans() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scanExportReminderNotifications();
      _scanInventoryStockAlerts();
    });
  }

  void _showDebugClockDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        DateTime picked = DebugClock.now();

        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Debug clock'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Current fake "now": ${picked.toString()}'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _quickSet(
                      'Daily 5:01 PM',
                      () {
                        final n = DateTime.now();
                        return DateTime(n.year, n.month, n.day, 17, 1);
                      },
                      setD,
                      (d) => picked = d,
                    ),
                    _quickSet(
                      'Sunday 5:01 PM',
                      () {
                        final n = DateTime.now();
                        final sunday = n.add(Duration(days: 7 - n.weekday));
                        return DateTime(
                          sunday.year,
                          sunday.month,
                          sunday.day,
                          17,
                          1,
                        );
                      },
                      setD,
                      (d) => picked = d,
                    ),
                    _quickSet(
                      'Last day of month, 5:01 PM',
                      () {
                        final n = DateTime.now();
                        final lastDay = DateTime(n.year, n.month + 1, 0);
                        return DateTime(
                          lastDay.year,
                          lastDay.month,
                          lastDay.day,
                          17,
                          1,
                        );
                      },
                      setD,
                      (d) => picked = d,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate: picked,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );

                    if (date == null) return;

                    final time = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(picked),
                    );

                    if (time == null) return;

                    setD(() {
                      picked = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        time.hour,
                        time.minute,
                      );
                    });
                  },
                  child: const Text('Pick custom date/time'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  DebugClock.set(null);
                  Navigator.pop(dialogContext);
                  setState(() {});
                  _rerunReminderScans();
                },
                child: const Text('Reset to real time'),
              ),
              ElevatedButton(
                onPressed: () {
                  DebugClock.set(picked);
                  Navigator.pop(dialogContext);
                  setState(() {});
                  _rerunReminderScans();
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _quickSet(
    String label,
    DateTime Function() compute,
    void Function(void Function()) setD,
    void Function(DateTime) assign,
  ) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () => setD(() => assign(compute())),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.currentUserId == null) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator(color: _primaryBlue)),
      );
    }

    if (_sessionRole == 'helper') {
      if (!_helperProfileResolved) {
        return const Scaffold(
          backgroundColor: Colors.white,
          body: Center(child: CircularProgressIndicator(color: _primaryBlue)),
        );
      }
      if (_helperProfileLoadFailed) {
        return _buildHelperProfileLoadFailure();
      }
      if (_currentProfile?.mustChangePassword == true) {
        return _buildForcedPasswordChangeGate();
      }
    }

    final notificationController = _notificationController;

    if (notificationController == null) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator(color: _primaryBlue)),
      );
    }

    return NotificationProvider(
      controller: notificationController,
      child: _buildMainContent(),
    );
  }

  Widget _buildForcedPasswordChangeGate() {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: SafeArea(
        child: Center(
          child: ChangePasswordDialog(
            // Every canonical current-profile publication rotates this key.
            // A repeated Admin reset therefore discards verification against
            // the previous temporary password, even when the flag stays true.
            key: ValueKey<int>(_currentProfileRevision),
            controller: widget.controller,
            forced: true,
            onLogout: _logoutFromForcedPasswordChange,
          ),
        ),
      ),
    );
  }

  Widget _buildHelperProfileLoadFailure() {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.circleAlert, color: Colors.red.shade600),
              const SizedBox(height: 12),
              const Text(
                'Unable to verify your account status.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _logoutFromForcedPasswordChange,
                      child: const Text('Logout'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _refreshHelperPasswordGate,
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    final InventoryItem? selectedItem = widget.controller.findAnyItemById(
      _selectedItemId ?? '',
    );

    if (_isDetailView && selectedItem != null) {
      return ItemDetailPage(
        item: selectedItem,
        controller: widget.controller,
        onBack: _handleBackToMain,
        onUpdate: _handleUpdateItem,
        onDelete: _handleDeleteItem,
        onStatusChanged: () {
          if (mounted) setState(() {});
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _scanInventoryStockAlerts();
          });
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 600;
        final role =
            widget.controller.currentUserRole?.toLowerCase() ?? 'staff';

        final isAdmin = role == 'admin';
        final isHelper = role == 'helper';
        final isCashier = role == 'staff';

        _currentIndex ??= 0;

        int pageIndex = 0;

        final int dashboardIndex = isAdmin ? pageIndex++ : -1;

        final int forecastingIndex = isAdmin ? pageIndex++ : -1;

        final int posIndex = (isCashier || isAdmin) ? pageIndex++ : -1;

        final int orderQueueIndex = (isHelper || isAdmin) ? pageIndex++ : -1;

        final int inventoryIndex = pageIndex++;

        final int staffHistoryIndex = (isHelper || isCashier)
            ? pageIndex++
            : -1;

        final int transactionIndex = isAdmin ? pageIndex++ : -1;

        final int mapIndex = isAdmin ? pageIndex++ : -1;

        final int systemSettingsIndex = isAdmin ? pageIndex++ : -1;

        final pages = <Widget>[];

        if (isAdmin) {
          pages.add(
            DashboardPage(
              controller: widget.controller,
              isActive: _currentIndex == dashboardIndex,
              onViewTransactions: () {
                setState(() {
                  _txTargetTab = 'Sales History';
                  _currentIndex = transactionIndex;
                });
              },
              onOpenQueue: () {
                setState(() {
                  _currentIndex = orderQueueIndex;
                });
              },
              onViewActivity: () {
                setState(() {
                  _txTargetTab = 'Activity Log';
                  _currentIndex = transactionIndex;
                });
              },
              onOpenForecasting: () {
                setState(() {
                  _currentIndex = forecastingIndex;
                });
              },
            ),
          );

          pages.add(
            ForecastingPage(
              controller: widget.controller,
              isActive: _currentIndex == forecastingIndex,
            ),
          );
        }

        if (isAdmin) {
          pages.add(
            PosMonitorPage(
              controller: widget.controller,
              targetOrderId: _targetPosOrderId,
              onOrderOpened: () {
                if (mounted) {
                  setState(() => _targetPosOrderId = null);
                }
              },
            ),
          );
        } else if (isCashier) {
          pages.add(
            PosCartPage(
              controller: widget.controller,
              targetOrderId: _targetPosOrderId,
              onOrderOpened: () {
                if (mounted) {
                  setState(() => _targetPosOrderId = null);
                }
              },
            ),
          );
        }

        if (isAdmin) {
          pages.add(
            OrderQueueMonitorPage(
              controller: widget.controller,
              targetOrderId: _targetOrderId,
              onOrderOpened: () {
                if (mounted) {
                  setState(() => _targetOrderId = null);
                }
              },
            ),
          );
        } else if (isHelper) {
          pages.add(
            OrderQueuePage(
              controller: widget.controller,
              targetOrderId: _targetOrderId,
              onOrderOpened: () {
                if (mounted) {
                  setState(() => _targetOrderId = null);
                }
              },
            ),
          );
        }

        pages.add(
          InventoryPage(
            controller: widget.controller,
            onSelectItem: _handleSelectItem,
            onExported: () {
              _scanExportReminderNotifications();
            },
          ),
        );

        if (isHelper || isCashier) {
          pages.add(StaffHistoryPage(controller: widget.controller));
        }

        if (isAdmin) {
          pages.add(
            TransactionHistoryPage(
              controller: widget.controller,
              isActive: _currentIndex == transactionIndex,
              initialTab: _txTargetTab,
              onExported: () {
                _scanExportReminderNotifications();
              },
              onCompleteOrder: (orderId) {
                setState(() {
                  _targetOrderId = orderId;
                  _currentIndex = orderQueueIndex;
                });
              },
            ),
          );

          pages.add(MapEditorPage(controller: widget.controller));
          final accessService = _storeAccessService;
          if (accessService != null) {
            pages.add(
              SystemSettingsPage(
                controller: widget.controller,
                storeAccessService: accessService,
              ),
            );
          }
        }

        if ((isHelper || isCashier) && isDesktop) {
          if (_currentIndex! > 2) {
            _currentIndex = 0;
          }

          return Scaffold(
            backgroundColor: _mainBg,
            body: Column(
              children: [
                _buildTopNavBar(
                  isHelper: isHelper,
                  orderQueueIndex: orderQueueIndex,
                  posIndex: posIndex,
                  transactionIndex: transactionIndex,
                  inventoryIndex: inventoryIndex,
                  staffHistoryIndex: staffHistoryIndex,
                ),
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: _lazyPageChildren(pages),
                  ),
                ),
              ],
            ),
            floatingActionButton: _debugToolsButtons(),
          );
        }

        if (isDesktop) {
          return Scaffold(
            backgroundColor: _mainBg,
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSidebar(
                  dashboardIndex: dashboardIndex,
                  forecastingIndex: forecastingIndex,
                  posIndex: posIndex,
                  orderQueueIndex: orderQueueIndex,
                  inventoryIndex: inventoryIndex,
                  transactionIndex: transactionIndex,
                  mapIndex: mapIndex,
                  systemSettingsIndex: systemSettingsIndex,
                ),
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: _lazyPageChildren(pages),
                  ),
                ),
              ],
            ),
            floatingActionButton: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isAdmin && _staffPresenceService != null)
                  ActiveStaffButton(presenceService: _staffPresenceService!),

                if (!kReleaseMode) ...[
                  const SizedBox(height: 12),
                  _debugToolsButtons(),
                ],
              ],
            ),
          );
        }

        return Scaffold(
          backgroundColor: Colors.white,
          appBar: _buildMobileAppBar(
            orderQueueIndex: orderQueueIndex,
            posIndex: posIndex,
            transactionIndex: transactionIndex,
            inventoryIndex: inventoryIndex,
          ),
          body: IndexedStack(
            index: _currentIndex,
            children: _lazyPageChildren(pages),
          ),
          bottomNavigationBar: _buildMobileNavigationBar(
            isAdmin: isAdmin,
            isHelper: isHelper,
            isCashier: isCashier,
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildMobileAppBar({
    required int orderQueueIndex,
    required int posIndex,
    required int transactionIndex,
    required int inventoryIndex,
  }) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      toolbarHeight: 64,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 16,
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _primaryBlue,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              LucideIcons.package,
              color: Colors.white,
              size: 19,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Inventory Plus',
              style: TextStyle(
                color: _darkText,
                fontWeight: FontWeight.w900,
                fontSize: 18,
                fontFamily: _fontFam,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        NotificationBell(
          onValidateNotification: _validateNotificationTap,
          onNotificationSelected: (notification) {
            _handleNotificationSelected(
              notification,
              orderQueueIndex: orderQueueIndex,
              posIndex: posIndex,
              transactionIndex: transactionIndex,
              inventoryIndex: inventoryIndex,
            );
          },
        ),
        _buildMobileProfileButton(),
        const SizedBox(width: 8),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1.0),
        child: Container(color: Colors.grey.shade200, height: 1.0),
      ),
    );
  }

  Widget _buildMobileNavigationBar({
    required bool isAdmin,
    required bool isHelper,
    required bool isCashier,
  }) {
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        indicatorColor: _primaryBlue.withOpacity(0.1),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: _primaryBlue,
              fontWeight: FontWeight.bold,
              fontSize: 11,
              fontFamily: _fontFam,
            );
          }

          return const TextStyle(
            color: _inactiveText,
            fontSize: 11,
            fontFamily: _fontFam,
          );
        }),
      ),
      child: NavigationBar(
        height: 66,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        selectedIndex: _currentIndex!,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: [
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.layoutDashboard, color: _inactiveText),
              selectedIcon: Icon(
                LucideIcons.layoutDashboard,
                color: _primaryBlue,
              ),
              label: 'Home',
            ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.trendingUp, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.trendingUp, color: _primaryBlue),
              label: 'Forecast',
            ),
          if (isCashier || isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.shoppingCart, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.shoppingCart, color: _primaryBlue),
              label: 'POS',
            ),
          if (isHelper || isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.fileText, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.fileText, color: _primaryBlue),
              label: 'Queue',
            ),
          const NavigationDestination(
            icon: Icon(LucideIcons.box, color: _inactiveText),
            selectedIcon: Icon(LucideIcons.box, color: _primaryBlue),
            label: 'Inventory',
          ),
          if (isHelper || isCashier)
            const NavigationDestination(
              icon: Icon(LucideIcons.history, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.history, color: _primaryBlue),
              label: 'History',
            ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.history, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.history, color: _primaryBlue),
              label: 'Logs',
            ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.map, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.map, color: _primaryBlue),
              label: 'Map',
            ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.settings, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.settings, color: _primaryBlue),
              label: 'Settings',
            ),
        ],
      ),
    );
  }

  Widget _buildSidebar({
    required int dashboardIndex,
    required int forecastingIndex,
    required int posIndex,
    required int orderQueueIndex,
    required int inventoryIndex,
    required int transactionIndex,
    required int mapIndex,
    required int systemSettingsIndex,
  }) {
    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: _sidebarBg,
        border: Border(right: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 36.0,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: _primaryBlue,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            LucideIcons.package,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Tooltip(
                            message: 'Inventory Plus',
                            child: Text(
                              'Inventory Plus',
                              style: const TextStyle(
                                color: _darkText,
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                                fontFamily: _fontFam,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        NotificationBell(
                          placement: NotificationPanelPlacement.besideSidebar,
                          onValidateNotification: _validateNotificationTap,
                          onNotificationSelected: (notification) {
                            _handleNotificationSelected(
                              notification,
                              orderQueueIndex: orderQueueIndex,
                              posIndex: posIndex,
                              transactionIndex: transactionIndex,
                              inventoryIndex: inventoryIndex,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  _buildSidebarItem(
                    dashboardIndex,
                    LucideIcons.layoutDashboard,
                    'Dashboard',
                  ),
                  _buildSidebarItem(
                    forecastingIndex,
                    LucideIcons.trendingUp,
                    'Forecasting',
                  ),
                  _buildSidebarItem(
                    posIndex,
                    LucideIcons.shoppingCart,
                    'POS Monitor',
                  ),
                  _buildSidebarItem(
                    orderQueueIndex,
                    LucideIcons.fileText,
                    'Queue Monitor',
                  ),
                  _buildSidebarItem(
                    inventoryIndex,
                    LucideIcons.box,
                    'Inventory',
                  ),
                  _buildSidebarItem(
                    transactionIndex,
                    LucideIcons.history,
                    'Transactions',
                  ),
                  _buildSidebarItem(mapIndex, LucideIcons.map, 'Store Map'),
                  _buildSidebarItem(
                    systemSettingsIndex,
                    LucideIcons.settings,
                    'System Settings',
                  ),
                ],
              ),
            ),
          ),
          _buildProfileTile(),
        ],
      ),
    );
  }

  Widget _buildTopNavBar({
    required bool isHelper,
    required int orderQueueIndex,
    required int posIndex,
    required int transactionIndex,
    required int inventoryIndex,
    required int staffHistoryIndex,
  }) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _primaryBlue,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  LucideIcons.package,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Inventory Plus',
                style: TextStyle(
                  color: _darkText,
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),

          const SizedBox(width: 56),

          StreamBuilder<List<CustomerOrder>>(
            stream: widget.controller.streamOrders(),
            builder: (context, snapshot) {
              final currentUserId = widget.controller.currentUserId;

              final pendingCount = snapshot.hasData
                  ? snapshot.data!.where((order) {
                      if (order.status != 'pending') {
                        return false;
                      }

                      if (!isHelper) {
                        return true;
                      }

                      final assignedId = order.assignedHelperId?.toString();

                      // Helper sees unassigned orders
                      // and orders assigned to them.
                      return assignedId == null ||
                          assignedId.isEmpty ||
                          assignedId == currentUserId?.toString();
                    }).length
                  : 0;

              return Row(
                children: [
                  if (isHelper)
                    _buildTopNavTabItem(
                      index: orderQueueIndex,
                      icon: LucideIcons.fileText,
                      label: 'Order queue',
                      badgeCount: pendingCount,
                    )
                  else
                    _buildTopNavTabItem(
                      index: posIndex,
                      icon: LucideIcons.shoppingCart,
                      label: 'POS System',
                    ),

                  const SizedBox(width: 24),

                  _buildTopNavTabItem(
                    index: inventoryIndex,
                    icon: LucideIcons.box,
                    label: 'Inventory',
                  ),

                  const SizedBox(width: 24),

                  _buildTopNavTabItem(
                    index: staffHistoryIndex,
                    icon: LucideIcons.history,
                    label: 'History',
                  ),
                ],
              );
            },
          ),

          const Spacer(),

          NotificationBell(
            onValidateNotification: _validateNotificationTap,
            onNotificationSelected: (notification) {
              _handleNotificationSelected(
                notification,
                orderQueueIndex: orderQueueIndex,
                posIndex: posIndex,
                transactionIndex: transactionIndex,
                inventoryIndex: inventoryIndex,
              );
            },
          ),

          const SizedBox(width: 12),

          _buildTopProfileChip(),
        ],
      ),
    );
  }

  Widget _buildTopNavTabItem({
    required int index,
    required IconData icon,
    required String label,
    int? badgeCount,
  }) {
    final isSelected = _currentIndex == index;

    return InkWell(
      onTap: () => setState(() => _currentIndex = index),
      child: Container(
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: isSelected
              ? const Border(bottom: BorderSide(color: _primaryBlue, width: 3))
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: isSelected ? _primaryBlue : _inactiveText,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: _fontFam,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected ? _primaryBlue : _inactiveText,
              ),
            ),
            if (badgeCount != null && badgeCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _primaryBlue,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$badgeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMobileProfileButton() {
    final name = widget.controller.currentUserName ?? 'User';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';

    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: InkWell(
        onTap: _showProfileDialog,
        borderRadius: BorderRadius.circular(999),
        child: CircleAvatar(
          radius: 17,
          backgroundColor: _primaryBlue.withOpacity(0.12),
          child: Text(
            initial,
            style: const TextStyle(
              color: _primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: 13,
              fontFamily: _fontFam,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopProfileChip() {
    final name = widget.controller.currentUserName ?? 'User';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';

    return InkWell(
      onTap: _showProfileDialog,
      borderRadius: BorderRadius.circular(30),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: _primaryBlue,
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  fontFamily: _fontFam,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: _fontFam,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _darkText,
                  ),
                ),
                Text(
                  'On shift',
                  style: TextStyle(
                    fontFamily: _fontFam,
                    fontSize: 11,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(
                LucideIcons.logOut,
                size: 16,
                color: Colors.redAccent,
              ),
              onPressed: _handleLogout,
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  void _showProfileDialog() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 500,
          height: 600,
          child: ProfileInfoPage(
            controller: widget.controller,
            currentName: widget.controller.currentUserName ?? 'Unknown',
            currentEmail: widget.controller.loggedInUserEmail,
            userId: widget.controller.currentUserId ?? '',
            role: widget.controller.currentUserRole ?? 'staff',
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index;
    final contentColor = isSelected ? _primaryBlue : _inactiveText;
    final bgColor = isSelected
        ? _primaryBlue.withOpacity(0.08)
        : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() => _currentIndex = index);
            _updateStaffPresenceModule();
          },
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(icon, color: contentColor, size: 20),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: contentColor,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      fontSize: 15,
                      fontFamily: _fontFam,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileTile() {
    final name = widget.controller.currentUserName ?? 'Unknown User';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'U';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showProfileDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: _primaryBlue.withOpacity(0.1),
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: _primaryBlue,
                    fontWeight: FontWeight.bold,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: _darkText,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        fontFamily: _fontFam,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'ID: ${widget.controller.currentUserId}',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 11,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(
                  LucideIcons.logOut,
                  color: Colors.redAccent,
                  size: 20,
                ),
                onPressed: _handleLogout,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.logOut,
        color: Colors.red,
        title: 'Log out?',
        subtitle: widget.controller.currentUserName,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel', style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Log Out',
              style: TextStyle(color: Colors.white, fontFamily: _fontFam),
            ),
          ),
        ],
        child: const Text("You'll need to sign in again to continue."),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await _staffPresenceService?.stop(logoutReason: 'manual_logout');
      final prefs = await SharedPreferences.getInstance();
      await widget.realtimeSync.stop();
      await prefs.clear();

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Could not log out: $e');
      }
    }
  }

  Future<void> _logoutFromForcedPasswordChange() async {
    try {
      await _staffPresenceService?.stop(logoutReason: 'manual_logout');
      final prefs = await SharedPreferences.getInstance();
      await widget.realtimeSync.stop();
      await prefs.clear();

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Could not log out: $e');
      }
    }
  }
}
