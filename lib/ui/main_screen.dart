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
import '../logic/helper_assignment.dart';
import '../logic/staff_management.dart';
import '../navigation/main_section.dart';
import '../services/debug_clock.dart';
import '../services/export_period.dart';
import '../services/export_reminder_service.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import 'dashboard_page.dart';
import 'approval_center_page.dart';
import 'forecasting_page.dart';
import 'inventory_page.dart';
import 'item_detail_page.dart';
import 'map_editor_page.dart';
import 'order_queue_page.dart';
import 'pos_cart_page.dart';
import 'profile_info_page.dart';
import 'system_settings_page.dart';
import 'transaction_history_page.dart';
import 'cash_monitor_table_page.dart';
import 'queue_monitor_table_page.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/change_password_dialog.dart';
import 'widgets/startup_restoration_surface.dart';
import '../services/staff_presence_service.dart';
import '../services/order_auto_assignment_service.dart';
import 'widgets/active_staff_button.dart';
import '../services/store_access_service.dart';
import '../services/main_section_url.dart';
import 'staff_history_page.dart';
import 'staff_performance_page.dart';
import '../services/realtime/realtime_sync_service.dart';

class MainScreen extends StatefulWidget {
  final InventoryController controller;
  final RealtimeSyncService realtimeSync;
  final MainSection? initialSection;

  const MainScreen({
    super.key,
    required this.controller,
    required this.realtimeSync,
    this.initialSection,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
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
  OrderAutoAssignmentService? _orderAutoAssignmentService;
  StoreAccessService? _storeAccessService;
  StreamSubscription<StoreAccessSettings>? _storeAccessSubscription;
  StreamSubscription<CurrentUserProfileSnapshot?>? _currentProfileSubscription;
  late final String _sessionRole;
  late final List<MainSection> _mainSections;
  CurrentUserProfileSnapshot? _currentProfile;
  int _currentProfileRevision = 0;
  bool _passwordGateProfileResolved = false;
  bool _passwordGateProfileLoadFailed = false;
  StreamSubscription<List<InventoryItem>>? _inventoryNotificationSubscription;
  final Completer<void> _deferredControllerData = Completer<void>();
  final Set<int> _mountedPageIndexes = <int>{};
  Timer? _storeAccessEndTimer;
  StoreAccessSettings? _scheduledStoreAccessSettings;
  StoreAccessWindow? _scheduledStoreAccessWindow;
  String? _storeAccessScheduleKey;
  final Set<_StoreAccessMilestone> _deliveredStoreAccessMilestones = {};
  bool _isForcingStoreLogout = false;
  bool _isInvalidatingSession = false;

  Timer? _storeLogoutCountdownTimer;
  DateTime? _storeLogoutDeadline;
  int _storeLogoutRemainingSeconds = 0;
  int _storeLogoutInitialSeconds = 60;
  bool _isStoreLogoutWarningVisible = false;
  bool _showStoreLogoutCountdownChip = false;
  bool _storeLogoutWarningShownForSchedule = false;
  int _storeLogoutDialogGeneration = 0;
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
    final userRole = widget.controller.currentUserRole;

    if (locationId == null ||
        locationId.isEmpty ||
        userId == null ||
        userId.isEmpty ||
        userRole == null ||
        userRole.isEmpty) {
      debugPrint(
        '[RealtimeSync] Not started: session identity is still incomplete.',
      );
      return;
    }

    await widget.realtimeSync.start(
      locationId: locationId,
      userId: userId,
      userRole: userRole,
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
    _mainSections = MainSection.forRole(_sessionRole);
    final initialSection = MainSection.resolveForRole(
      widget.initialSection,
      _sessionRole,
    );
    _currentIndex = _mainSections.indexOf(initialSection);
    _mountedPageIndexes.add(_currentIndex!);
    WidgetsBinding.instance.addObserver(this);

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

      widget.controller.onApprovalRequestChanged = (request) async {
        final controller = _notificationController;
        if (controller == null) {
          throw StateError('Notification controller not initialized.');
        }
        await controller.notifyInventoryApproval(request);
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
      replaceMainSectionPath(_currentMainSection.routePath);
      if (kDebugMode) debugPrint('[Startup] MainScreen first frame rendered');
      unawaited(_refreshPasswordGate());
      unawaited(_startSessionSynchronization());
      unawaited(_loadDeferredControllerData());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    _orderAutoAssignmentService?.dispose();
    _staffPresenceService?.dispose();
    widget.controller.onRestockRecorded = null;
    widget.controller.onApprovalRequestChanged = null;
    super.dispose();
  }

  MainSection get _currentMainSection {
    final index = (_currentIndex ?? 0).clamp(0, _mainSections.length - 1);
    return _mainSections[index];
  }

  bool _isMainSectionPath(String path) =>
      path == '/main' || path.startsWith('/main/');

  void _restoreMainSectionFromPath(String path) {
    if (!mounted || !_isMainSectionPath(path)) return;
    final requested = MainSection.fromPath(path);
    final resolved = MainSection.resolveForRole(requested, _sessionRole);
    final index = _mainSections.indexOf(resolved);
    if (requested != resolved || path != resolved.routePath) {
      replaceMainSectionPath(resolved.routePath);
    }
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
      _isDetailView = false;
      _selectedItemId = null;
    });
    unawaited(_updateStaffPresenceModule());
  }

  void _selectMainIndex(
    int index, {
    VoidCallback? updateState,
    bool replaceUrl = false,
  }) {
    if (index < 0 || index >= _mainSections.length) return;
    final changed = index != _currentIndex;
    if (changed || updateState != null) {
      setState(() {
        updateState?.call();
        _currentIndex = index;
        if (changed) {
          _isDetailView = false;
          _selectedItemId = null;
        }
      });
    }
    final path = _mainSections[index].routePath;
    if (replaceUrl) {
      replaceMainSectionPath(path);
    } else {
      pushMainSectionPath(path);
    }
    if (changed) unawaited(_updateStaffPresenceModule());
  }

  @override
  Future<bool> didPopRoute() async {
    final path = readMainSectionPath();
    if (!_isMainSectionPath(path)) return false;
    final requested = MainSection.fromPath(path);
    final resolved = MainSection.resolveForRole(requested, _sessionRole);
    if (resolved == _currentMainSection && path == resolved.routePath) {
      return false;
    }
    _restoreMainSectionFromPath(path);
    return true;
  }

  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final path = readMainSectionPath();
    if (!_isMainSectionPath(path)) return false;
    _restoreMainSectionFromPath(path);
    return true;
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
          return 'Cash Monitor';

        case 3:
          return 'Queue Monitor';

        case 4:
          return 'Inventory';

        case 5:
          return 'Approval Center';

        case 6:
          return 'Staff Performance';

        case 7:
          return 'Transactions';

        case 8:
          return 'Store Map';

        case 9:
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

  Future<void> _applyStoreAccessSettings(StoreAccessSettings settings) async {
    final role = widget.controller.currentUserRole?.toLowerCase();
    if (role == null || role.isEmpty) return;
    final accessService = _storeAccessService;
    if (accessService == null ||
        settings.locationId != accessService.locationId) {
      return;
    }

    final now = DateTime.now();
    _storeAccessEndTimer?.cancel();
    _storeAccessEndTimer = null;

    final isExempt =
        !settings.restrictStaffLogin ||
        (role == 'admin' && settings.allowAdminAnytime);
    if (isExempt) {
      _resolveObsoleteStoreAccessLifecycles();
      _clearStoreAccessScheduling();
      return;
    }

    final window = accessService.resolveAccessWindow(settings, now: now);
    final scheduleKey = window.scheduleKey(settings.locationId);
    final scheduleChanged = scheduleKey != _storeAccessScheduleKey;
    if (scheduleChanged) {
      _resolveObsoleteStoreAccessLifecycles(
        replacementSettings: settings,
        replacementWindow: window,
      );
      _cancelPendingStoreLogout();
      _deliveredStoreAccessMilestones.clear();
      _storeLogoutWarningShownForSchedule = false;
      _storeAccessScheduleKey = scheduleKey;
    }
    _scheduledStoreAccessSettings = settings;
    _scheduledStoreAccessWindow = window;

    final accessAllowed = accessService.isAccessAllowed(
      settings: settings,
      role: role,
      now: now,
    );
    if (!accessAllowed || !now.isBefore(window.accessEnd)) {
      await _completeForcedStoreLogout();
      return;
    }

    final remainingMilliseconds = window.accessEnd
        .difference(now)
        .inMilliseconds;
    if (remainingMilliseconds <= const Duration(minutes: 1).inMilliseconds) {
      final newlyDelivered = _deliveredStoreAccessMilestones.add(
        _StoreAccessMilestone.logoutWarning,
      );
      if (newlyDelivered) {
        _persistStoreAccessMilestone(
          _StoreAccessMilestone.logoutWarning,
          settings,
          window,
        );
      }
      _startStoreLogoutCountdown(window.accessEnd);
      _scheduleNextStoreAccessMilestone();
      return;
    }

    if (_isForcingStoreLogout) _cancelPendingStoreLogout();
    _scheduleNextStoreAccessMilestone();
  }

  void _resolveObsoleteStoreAccessLifecycles({
    StoreAccessSettings? replacementSettings,
    StoreAccessWindow? replacementWindow,
  }) {
    final controller = _notificationController;
    final previousSettings = _scheduledStoreAccessSettings;
    final previousWindow = _scheduledStoreAccessWindow;
    if (controller == null ||
        previousSettings == null ||
        previousWindow == null) {
      return;
    }

    final previousOpeningKey = previousWindow.openingLifecycleKey(
      previousSettings.locationId,
    );
    final nextOpeningKey =
        replacementSettings == null || replacementWindow == null
        ? null
        : replacementWindow.openingLifecycleKey(replacementSettings.locationId);
    if (previousOpeningKey != nextOpeningKey) {
      unawaited(
        controller.resolveStoreAccessLifecycle(
          lifecycleKind: 'opening',
          windowKey: previousOpeningKey,
        ),
      );
    }

    final previousAccessKey = previousWindow.accessLifecycleKey(
      previousSettings.locationId,
    );
    final nextAccessKey =
        replacementSettings == null || replacementWindow == null
        ? null
        : replacementWindow.accessLifecycleKey(replacementSettings.locationId);
    if (previousAccessKey != nextAccessKey) {
      unawaited(
        controller.resolveStoreAccessLifecycle(
          lifecycleKind: 'access',
          windowKey: previousAccessKey,
        ),
      );
    }
  }

  void _clearStoreAccessScheduling() {
    _storeAccessEndTimer?.cancel();
    _storeAccessEndTimer = null;
    _scheduledStoreAccessSettings = null;
    _scheduledStoreAccessWindow = null;
    _storeAccessScheduleKey = null;
    _deliveredStoreAccessMilestones.clear();
    _storeLogoutWarningShownForSchedule = false;
    _cancelPendingStoreLogout();
  }

  void _cancelPendingStoreLogout() {
    _isForcingStoreLogout = false;
    _storeLogoutCountdownTimer?.cancel();
    _storeLogoutCountdownTimer = null;
    _storeLogoutDeadline = null;
    _storeLogoutDialogGeneration++;
    final dialogContext = _storeLogoutDialogContext;
    _storeLogoutDialogContext = null;
    _storeLogoutDialogSetState = null;
    if (dialogContext != null && Navigator.canPop(dialogContext)) {
      Navigator.pop(dialogContext);
    }
    _isStoreLogoutWarningVisible = false;
    final needsRebuild =
        _showStoreLogoutCountdownChip || _storeLogoutRemainingSeconds != 0;
    _showStoreLogoutCountdownChip = false;
    _storeLogoutRemainingSeconds = 0;
    if (needsRebuild && mounted) setState(() {});
  }

  void _scheduleNextStoreAccessMilestone() {
    _storeAccessEndTimer?.cancel();
    _storeAccessEndTimer = null;
    final settings = _scheduledStoreAccessSettings;
    final window = _scheduledStoreAccessWindow;
    final scheduleKey = _storeAccessScheduleKey;
    if (settings == null || window == null || scheduleKey == null) return;

    final now = DateTime.now();
    if (!now.isBefore(window.accessEnd)) {
      unawaited(_completeForcedStoreLogout());
      return;
    }

    final candidates = <_ScheduledStoreAccessMilestone>[
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.openingSoon,
        window.opening.subtract(const Duration(minutes: 5)),
      ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.opened,
        window.opening,
      ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.shiftEnd30,
        window.shiftEnd.subtract(const Duration(minutes: 30)),
      ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.shiftEnd15,
        window.shiftEnd.subtract(const Duration(minutes: 15)),
      ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.shiftEnd5,
        window.shiftEnd.subtract(const Duration(minutes: 5)),
      ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.shiftEnded,
        window.shiftEnd,
      ),
      if (settings.staffAccessAfterMinutes > 5)
        _ScheduledStoreAccessMilestone(
          _StoreAccessMilestone.allowance5,
          window.accessEnd.subtract(const Duration(minutes: 5)),
        ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.logoutWarning,
        window.accessEnd.subtract(const Duration(minutes: 1)),
      ),
      _ScheduledStoreAccessMilestone(
        _StoreAccessMilestone.deadline,
        window.accessEnd,
      ),
    ]..sort((left, right) => left.at.compareTo(right.at));

    _ScheduledStoreAccessMilestone? next;
    for (final candidate in candidates) {
      if (_deliveredStoreAccessMilestones.contains(candidate.milestone)) {
        continue;
      }
      // Threshold notifications are intentionally not backfilled. The final
      // minute is reconciled separately when settings are applied.
      if (candidate.at.isAfter(now)) {
        next = candidate;
        break;
      }
    }
    if (next == null) return;
    final scheduled = next;

    _storeAccessEndTimer = Timer(scheduled.at.difference(now), () {
      if (!mounted || _storeAccessScheduleKey != scheduleKey) return;
      final firedLateBy = DateTime.now().difference(scheduled.at);
      final isEnforcementMilestone = candidates.any(
        (candidate) =>
            candidate.at == scheduled.at &&
            (candidate.milestone == _StoreAccessMilestone.logoutWarning ||
                candidate.milestone == _StoreAccessMilestone.deadline),
      );
      if (!isEnforcementMilestone && firedLateBy > const Duration(seconds: 5)) {
        _scheduleNextStoreAccessMilestone();
        return;
      }
      final dueMilestones = candidates
          .where(
            (candidate) =>
                candidate.at == scheduled.at &&
                (firedLateBy <= const Duration(seconds: 5) ||
                    candidate.milestone ==
                        _StoreAccessMilestone.logoutWarning ||
                    candidate.milestone == _StoreAccessMilestone.deadline) &&
                !_deliveredStoreAccessMilestones.contains(candidate.milestone),
          )
          .map((candidate) => candidate.milestone)
          .toList(growable: false);
      for (final milestone in dueMilestones) {
        _handleStoreAccessMilestone(milestone, settings, window);
      }
      if (!dueMilestones.contains(_StoreAccessMilestone.deadline)) {
        _scheduleNextStoreAccessMilestone();
      }
    });
  }

  void _handleStoreAccessMilestone(
    _StoreAccessMilestone milestone,
    StoreAccessSettings settings,
    StoreAccessWindow window,
  ) {
    if (_deliveredStoreAccessMilestones.contains(milestone)) return;
    _deliveredStoreAccessMilestones.add(milestone);

    if (milestone == _StoreAccessMilestone.logoutWarning) {
      _startStoreLogoutCountdown(window.accessEnd);
    } else if (milestone == _StoreAccessMilestone.deadline) {
      unawaited(_completeForcedStoreLogout());
    }
    _persistStoreAccessMilestone(milestone, settings, window);
  }

  void _persistStoreAccessMilestone(
    _StoreAccessMilestone milestone,
    StoreAccessSettings settings,
    StoreAccessWindow window,
  ) {
    final controller = _notificationController;
    if (controller == null || milestone == _StoreAccessMilestone.deadline) {
      if (milestone == _StoreAccessMilestone.deadline) {
        unawaited(
          controller?.resolveStoreAccessLifecycle(
                lifecycleKind: 'access',
                windowKey: window.accessLifecycleKey(settings.locationId),
              ) ??
              Future<void>.value(),
        );
      }
      return;
    }

    final targetRoles = <String>[
      'helper',
      'staff',
      if (!settings.allowAdminAnytime) 'admin',
    ];
    late final String lifecycleKind;
    late final String windowKey;
    late final String stage;
    late final String title;
    late final String body;

    switch (milestone) {
      case _StoreAccessMilestone.openingSoon:
        lifecycleKind = 'opening';
        windowKey = window.openingLifecycleKey(settings.locationId);
        stage = 'openingSoon';
        title = 'Store opening soon';
        body = 'Store hours begin in 5 minutes.';
      case _StoreAccessMilestone.opened:
        lifecycleKind = 'opening';
        windowKey = window.openingLifecycleKey(settings.locationId);
        stage = 'opened';
        title = 'Store hours started';
        body = 'Store hours are now active.';
      case _StoreAccessMilestone.shiftEnd30:
        lifecycleKind = 'access';
        windowKey = window.accessLifecycleKey(settings.locationId);
        stage = 'shiftEnd30';
        title = 'Shift ending soon';
        body = 'Your shift ends in 30 minutes.';
      case _StoreAccessMilestone.shiftEnd15:
        lifecycleKind = 'access';
        windowKey = window.accessLifecycleKey(settings.locationId);
        stage = 'shiftEnd15';
        title = 'Shift ending soon';
        body = 'Your shift ends in 15 minutes.';
      case _StoreAccessMilestone.shiftEnd5:
        lifecycleKind = 'access';
        windowKey = window.accessLifecycleKey(settings.locationId);
        stage = 'shiftEnd5';
        title = 'Shift ending soon';
        body = 'Your shift ends in 5 minutes.';
      case _StoreAccessMilestone.shiftEnded:
        unawaited(
          controller.resolveStoreAccessLifecycle(
            lifecycleKind: 'opening',
            windowKey: window.openingLifecycleKey(settings.locationId),
          ),
        );
        lifecycleKind = 'access';
        windowKey = window.accessLifecycleKey(settings.locationId);
        stage = 'shiftEnded';
        title = 'Shift ended';
        final allowance = settings.staffAccessAfterMinutes;
        body = allowance == 0
            ? 'Your shift has ended. Store access is ending now.'
            : 'Your shift has ended. You have $allowance minutes to finish '
                  'your remaining work.';
      case _StoreAccessMilestone.allowance5:
        lifecycleKind = 'access';
        windowKey = window.accessLifecycleKey(settings.locationId);
        stage = 'allowance5';
        title = 'Store access ending soon';
        body = '5 minutes of your post-shift allowance remain.';
      case _StoreAccessMilestone.logoutWarning:
        lifecycleKind = 'access';
        windowKey = window.accessLifecycleKey(settings.locationId);
        stage = 'logoutWarning';
        title = 'Session ending soon';
        body = 'Store access ends in less than 1 minute.';
      case _StoreAccessMilestone.deadline:
        return;
    }

    unawaited(
      controller.notifyStoreAccessLifecycle(
        locationId: settings.locationId,
        targetRoles: targetRoles,
        lifecycleKind: lifecycleKind,
        windowKey: windowKey,
        stage: stage,
        title: title,
        body: body,
        openingAt: window.opening,
        shiftEndAt: window.shiftEnd,
        accessEndAt: window.accessEnd,
      ),
    );
  }

  void _startStoreLogoutCountdown(DateTime deadline) {
    if (_isForcingStoreLogout && _storeLogoutDeadline == deadline) return;

    _isForcingStoreLogout = true;
    _storeLogoutDeadline = deadline;
    final remaining = _remainingStoreLogoutSeconds();
    if (remaining <= 0) {
      unawaited(_completeForcedStoreLogout());
      return;
    }
    _storeLogoutInitialSeconds = remaining;
    if (mounted) {
      setState(() {
        _storeLogoutRemainingSeconds = remaining;
        _showStoreLogoutCountdownChip = false;
      });
    }

    if (!_storeLogoutWarningShownForSchedule) {
      _storeLogoutWarningShownForSchedule = true;
      _showStoreLogoutWarningModal();
    }
    _runStoreLogoutCountdownTimer();
  }

  int _remainingStoreLogoutSeconds() {
    final deadline = _storeLogoutDeadline;
    if (deadline == null) return 0;
    final milliseconds = deadline.difference(DateTime.now()).inMilliseconds;
    if (milliseconds <= 0) return 0;
    return (milliseconds / Duration.millisecondsPerSecond).ceil();
  }

  void _runStoreLogoutCountdownTimer() {
    _storeLogoutCountdownTimer?.cancel();

    _storeLogoutCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final remaining = _remainingStoreLogoutSeconds();
      if (remaining <= 0) {
        timer.cancel();
        unawaited(_completeForcedStoreLogout());
        return;
      }

      if (_storeLogoutRemainingSeconds != remaining) {
        setState(() => _storeLogoutRemainingSeconds = remaining);
      }
      if (_isStoreLogoutWarningVisible) {
        _storeLogoutDialogSetState?.call(() {});
      }
    });
  }

  void _showStoreLogoutWarningModal() {
    if (!mounted) return;
    if (_isStoreLogoutWarningVisible) return;

    _isStoreLogoutWarningVisible = true;
    final dialogGeneration = ++_storeLogoutDialogGeneration;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _storeLogoutDialogContext = dialogContext;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            _storeLogoutDialogSetState = setDialogState;

            final progress =
                _storeLogoutRemainingSeconds / _storeLogoutInitialSeconds;

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
                      color: Colors.black.withValues(alpha: 0.14),
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
                            color: _primaryBlue.withValues(alpha: 0.1),
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
                            'Session ending soon',
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
                            'Store access ends in less than 1 minute.',
                            style: TextStyle(
                              color: _inactiveText,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFamily: _fontFam,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _formatStoreLogoutCountdown(
                              _storeLogoutRemainingSeconds,
                            ),
                            style: const TextStyle(
                              color: _primaryBlue,
                              fontSize: 44,
                              fontWeight: FontWeight.w900,
                              fontFamily: _fontFam,
                              height: 1,
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
                              if (mounted) {
                                setState(() {
                                  _showStoreLogoutCountdownChip = true;
                                });
                              }

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
                              'Logout Now',
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
      if (_storeLogoutDialogGeneration == dialogGeneration) {
        _isStoreLogoutWarningVisible = false;
        _storeLogoutDialogContext = null;
        _storeLogoutDialogSetState = null;
      }
    });
  }

  Future<void> _completeForcedStoreLogout() async {
    if (_isInvalidatingSession) return;
    _isInvalidatingSession = true;
    _storeAccessEndTimer?.cancel();
    _storeAccessEndTimer = null;
    _storeLogoutCountdownTimer?.cancel();
    _storeLogoutCountdownTimer = null;
    if (mounted && _storeLogoutRemainingSeconds != 0) {
      setState(() => _storeLogoutRemainingSeconds = 0);
      _storeLogoutDialogSetState?.call(() {});
    }

    final settings = _scheduledStoreAccessSettings;
    final window = _scheduledStoreAccessWindow;
    if (settings != null && window != null) {
      unawaited(
        _notificationController?.resolveStoreAccessLifecycle(
              lifecycleKind: 'access',
              windowKey: window.accessLifecycleKey(settings.locationId),
            ) ??
            Future<void>.value(),
      );
    }

    if (_storeLogoutDialogContext != null) {
      final dialogContext = _storeLogoutDialogContext!;

      if (Navigator.canPop(dialogContext)) {
        Navigator.pop(dialogContext);
      }

      _storeLogoutDialogContext = null;
      _storeLogoutDialogSetState = null;
    }

    await _staffPresenceService?.stop(logoutReason: 'store_hours_expired');
    await widget.controller.revokeCurrentSession();

    final prefs = await SharedPreferences.getInstance();
    await widget.realtimeSync.stop();
    await prefs.clear();

    if (!mounted) return;

    AppToast.error(
      context,
      'Store access time has ended. You have been logged out.',
    );

    Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
  }

  String _formatStoreLogoutCountdown(int totalSeconds) {
    final safeSeconds = totalSeconds.clamp(0, 5999);
    final minutes = safeSeconds ~/ 60;
    final seconds = safeSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
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
    final autoAssignmentService = OrderAutoAssignmentService(
      inventoryController: widget.controller,
      presenceService: service,
      locationId: locationId,
      onAssignments: _notifyAutomaticHelperAssignments,
    );
    autoAssignmentService.start();
    _orderAutoAssignmentService = autoAssignmentService;
  }

  Future<void> _notifyAutomaticHelperAssignments(
    List<AutomaticHelperAssignmentResult> assignments,
  ) async {
    final controller = _notificationController;
    final locationId = widget.controller.activeLocationId;
    if (controller == null || locationId == null) return;

    for (final assignment in assignments) {
      await controller.notifyOrderAssigned(
        locationId: locationId,
        orderId: assignment.orderId,
        helperId: assignment.helperId,
        helperName: assignment.helperName,
        assignedByName: 'Automatic assignment',
        assignedAt: assignment.assignedAt,
      );
    }
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
    final requiresPasswordGate = roleRequiresForcedPasswordChange(_sessionRole);
    if (identical(_currentProfile, profile) &&
        (!requiresPasswordGate || _passwordGateProfileResolved)) {
      return;
    }
    setState(() {
      _currentProfile = profile;
      _currentProfileRevision++;
      if (requiresPasswordGate) {
        _passwordGateProfileResolved = true;
        _passwordGateProfileLoadFailed = false;
      }
    });
  }

  Future<void> _refreshPasswordGate() async {
    if (!roleRequiresForcedPasswordChange(_sessionRole)) return;
    if (mounted) {
      setState(() {
        _passwordGateProfileResolved = false;
        _passwordGateProfileLoadFailed = false;
      });
    }

    final profile = await widget.controller.refreshCurrentUserProfile();
    if (!mounted) return;
    if (profile == null) {
      setState(() {
        _passwordGateProfileResolved = true;
        _passwordGateProfileLoadFailed = true;
      });
      return;
    }
    _handleCurrentProfileChange(profile);
  }

  Future<void> _invalidateSessionForProfileChange(String message) async {
    if (_isInvalidatingSession) return;
    _isInvalidatingSession = true;
    _clearStoreAccessScheduling();
    try {
      await _staffPresenceService?.stop(logoutReason: 'profile_changed');
      await widget.controller.revokeCurrentSession();
      final prefs = await SharedPreferences.getInstance();
      await widget.realtimeSync.stop();
      await prefs.clear();
    } catch (error, stackTrace) {
      debugPrint('[Session] Profile invalidation cleanup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    if (!mounted) return;
    AppToast.error(context, message);
    Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
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

  bool _isNotificationActionable(
    AppNotification notification, {
    required int orderQueueIndex,
    required int posIndex,
    required int transactionIndex,
    required int inventoryIndex,
  }) {
    final payload = notification.payload;
    switch (notification.type) {
      case NotificationType.newOrder:
      case NotificationType.orderAssigned:
        return orderQueueIndex >= 0 &&
            (payload['orderId']?.toString().isNotEmpty ?? false);
      case NotificationType.orderPrepared:
        return posIndex >= 0 &&
            (payload['orderId']?.toString().isNotEmpty ?? false);
      case NotificationType.transaction:
        return transactionIndex >= 0;
      case NotificationType.exportReminder:
        final reportType = payload['reportType']?.toString();
        return reportType == 'inventory'
            ? inventoryIndex >= 0
            : reportType == 'sales' && transactionIndex >= 0;
      case NotificationType.stockAlert:
        final items = payload['items'];
        return inventoryIndex >= 0 && items is List && items.isNotEmpty;
      case NotificationType.lowStock:
      case NotificationType.criticalStock:
      case NotificationType.deadStock:
        return inventoryIndex >= 0 &&
            (payload['itemId']?.toString().isNotEmpty ?? false);
      case NotificationType.inventoryRestocked:
        return inventoryIndex >= 0 &&
            widget.controller.currentUserRole?.toLowerCase() == 'admin' &&
            (payload['productId']?.toString().isNotEmpty ?? false);
      case NotificationType.system:
        if (payload['category'] != 'inventoryApproval') return false;
        if (payload['status'] == 'pending') {
          return widget.controller.currentUserRole?.toLowerCase() == 'admin' &&
              _mainSections.contains(MainSection.approvals);
        }
        final role = widget.controller.currentUserRole?.toLowerCase();
        return payload['requestType'] == 'discount' &&
            (role == 'staff' || role == 'cashier') &&
            posIndex >= 0;
      case NotificationType.orderCancelled:
      case NotificationType.inventoryAdded:
      case NotificationType.inventoryUpdated:
      case NotificationType.inventoryDeleted:
        return false;
    }
  }

  bool _handleNotificationSelected(
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
          return false;
        }

        if (orderQueueIndex < 0) {
          AppToast.error(
            context,
            'Order Queue is not available for this role.',
          );
          return false;
        }

        _selectMainIndex(
          orderQueueIndex,
          updateState: () => _targetOrderId = orderId,
        );
        return true;

      case NotificationType.orderPrepared:
        if (orderId == null || orderId.isEmpty) {
          AppToast.error(context, 'Order ID not found in notification.');
          return false;
        }

        if (posIndex < 0) {
          AppToast.error(context, 'POS is not available for this role.');
          return false;
        }

        _selectMainIndex(
          posIndex,
          updateState: () => _targetPosOrderId = orderId,
        );
        return true;

      case NotificationType.transaction:
        if (transactionIndex < 0) {
          AppToast.error(context, 'Transactions page is not available.');
          return false;
        }

        _selectMainIndex(
          transactionIndex,
          updateState: () => _txTargetTab = 'Sales History',
        );
        return true;

      case NotificationType.exportReminder:
        final reportType = notification.payload['reportType']?.toString();

        if (reportType == 'inventory') {
          _selectMainIndex(inventoryIndex);
          return true;
        }

        if (reportType == 'sales') {
          if (transactionIndex < 0) {
            AppToast.error(context, 'Transactions page is not available.');
            return false;
          }

          _selectMainIndex(
            transactionIndex,
            updateState: () => _txTargetTab = 'Sales History',
          );
          return true;
        }

        AppToast.error(context, 'Unknown report type.');
        return false;

      case NotificationType.stockAlert:
        final rawItems = notification.payload['items'];

        if (rawItems is! List || rawItems.isEmpty) {
          AppToast.error(context, 'Stock alert items not found.');
          return false;
        }

        final firstItem = Map<String, dynamic>.from(rawItems.first);
        final itemId = firstItem['itemId']?.toString();

        if (itemId == null || itemId.isEmpty) {
          AppToast.error(context, 'Item ID not found in stock alert.');
          return false;
        }

        final items = [
          ...widget.controller.filterInventory(query: '', category: 'All'),
          ...widget.controller.filterDisabled(query: '', category: 'All'),
        ];

        final matches = items.where((item) => item.id == itemId).toList();

        if (matches.isEmpty) {
          AppToast.error(context, 'This item no longer exists.');
          return false;
        }

        _selectMainIndex(inventoryIndex);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _handleSelectItem(matches.first);
        });
        return true;

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
          return false;
        }

        _selectMainIndex(inventoryIndex);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleSelectItem(matches.first);
        });
        return true;

      case NotificationType.inventoryRestocked:
        final productId = notification.payload['productId']?.toString();

        final role = widget.controller.currentUserRole?.toLowerCase();

        if (role != 'admin') {
          AppToast.error(
            context,
            'Restock monitoring is available to administrators only.',
          );
          return false;
        }

        if (productId == null || productId.isEmpty) {
          AppToast.error(context, 'Product information is missing.');
          return false;
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
          return false;
        }

        _selectMainIndex(inventoryIndex);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _handleSelectItem(matches.first);
        });

        return true;

      case NotificationType.system:
        if (notification.payload['category'] != 'inventoryApproval') {
          return false;
        }
        if (notification.payload['requestType'] == 'discount' &&
            notification.payload['status'] != 'pending' &&
            posIndex >= 0) {
          _selectMainIndex(posIndex);
          return true;
        }
        if (notification.payload['status'] != 'pending') return false;
        final approvalsIndex = _mainSections.indexOf(MainSection.approvals);
        if (approvalsIndex < 0) {
          AppToast.error(context, 'Pending Approvals is Admin-only.');
          return false;
        }
        _selectMainIndex(approvalsIndex);
        return true;

      default:
        return false;
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
      return const StartupRestorationSurface();
    }

    if (roleRequiresForcedPasswordChange(_sessionRole)) {
      if (!_passwordGateProfileResolved) {
        return const StartupRestorationSurface();
      }
      if (_passwordGateProfileLoadFailed) {
        return _buildPasswordGateProfileLoadFailure();
      }
      if (_currentProfile?.mustChangePassword == true) {
        return _buildForcedPasswordChangeGate();
      }
    }

    final notificationController = _notificationController;

    if (notificationController == null) {
      return const StartupRestorationSurface();
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

  Widget _buildPasswordGateProfileLoadFailure() {
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
                      onPressed: _refreshPasswordGate,
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
        final isCashier = role == 'staff' || role == 'cashier';

        int pageIndex = 0;

        final int dashboardIndex = isAdmin ? pageIndex++ : -1;

        final int forecastingIndex = isAdmin ? pageIndex++ : -1;

        final int posIndex = (isCashier || isAdmin) ? pageIndex++ : -1;

        final int orderQueueIndex = (isHelper || isAdmin) ? pageIndex++ : -1;

        final int inventoryIndex = pageIndex++;

        final int approvalsIndex = isAdmin ? pageIndex++ : -1;

        final int performanceIndex = isAdmin ? pageIndex++ : -1;

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
                _selectMainIndex(
                  transactionIndex,
                  updateState: () => _txTargetTab = 'Sales History',
                );
              },
              onOpenQueue: () {
                _selectMainIndex(orderQueueIndex);
              },
              onViewActivity: () {
                _selectMainIndex(
                  transactionIndex,
                  updateState: () => _txTargetTab = 'Activity Log',
                );
              },
              onOpenForecasting: () {
                _selectMainIndex(forecastingIndex);
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
              presenceService: _staffPresenceService,
              autoAssignmentService: _orderAutoAssignmentService,
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

        if (isAdmin) {
          pages.add(ApprovalCenterPage(controller: widget.controller));
          pages.add(StaffPerformancePage(controller: widget.controller));
        }

        if (isHelper || isCashier) {
          pages.add(
            StaffHistoryPage(
              controller: widget.controller,
              isActive: _currentIndex == staffHistoryIndex,
            ),
          );
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
                _selectMainIndex(
                  orderQueueIndex,
                  updateState: () => _targetOrderId = orderId,
                );
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
                  approvalsIndex: approvalsIndex,
                  performanceIndex: performanceIndex,
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

  Widget _buildNotificationControls({
    required int orderQueueIndex,
    required int posIndex,
    required int transactionIndex,
    required int inventoryIndex,
    NotificationPanelPlacement placement = NotificationPanelPlacement.belowBell,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showStoreLogoutCountdownChip &&
            _storeLogoutRemainingSeconds > 0) ...[
          Tooltip(
            message: 'Auto logout in $_storeLogoutRemainingSeconds seconds',
            child: Semantics(
              label: 'Auto logout in $_storeLogoutRemainingSeconds seconds',
              liveRegion: true,
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFF97316)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      LucideIcons.timer,
                      size: 15,
                      color: Color(0xFFC2410C),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _formatStoreLogoutCountdown(_storeLogoutRemainingSeconds),
                      style: const TextStyle(
                        color: Color(0xFF9A3412),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        fontFamily: _fontFam,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        NotificationBell(
          placement: placement,
          isActionable: (notification) => _isNotificationActionable(
            notification,
            orderQueueIndex: orderQueueIndex,
            posIndex: posIndex,
            transactionIndex: transactionIndex,
            inventoryIndex: inventoryIndex,
          ),
          onValidateNotification: _validateNotificationTap,
          onNotificationSelected: (notification) => _handleNotificationSelected(
            notification,
            orderQueueIndex: orderQueueIndex,
            posIndex: posIndex,
            transactionIndex: transactionIndex,
            inventoryIndex: inventoryIndex,
          ),
        ),
      ],
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
        _buildNotificationControls(
          orderQueueIndex: orderQueueIndex,
          posIndex: posIndex,
          transactionIndex: transactionIndex,
          inventoryIndex: inventoryIndex,
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
        onDestinationSelected: _selectMainIndex,
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
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.clipboardCheck, color: _inactiveText),
              selectedIcon: Icon(
                LucideIcons.clipboardCheck,
                color: _primaryBlue,
              ),
              label: 'Approvals',
            ),
          if (isHelper || isCashier)
            const NavigationDestination(
              icon: Icon(LucideIcons.history, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.history, color: _primaryBlue),
              label: 'History',
            ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(LucideIcons.barChart2, color: _inactiveText),
              selectedIcon: Icon(LucideIcons.barChart2, color: _primaryBlue),
              label: 'Performance',
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
    required int approvalsIndex,
    required int performanceIndex,
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
                        _buildNotificationControls(
                          placement: NotificationPanelPlacement.besideSidebar,
                          orderQueueIndex: orderQueueIndex,
                          posIndex: posIndex,
                          transactionIndex: transactionIndex,
                          inventoryIndex: inventoryIndex,
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
                    'Cash Monitor',
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
                    approvalsIndex,
                    LucideIcons.clipboardCheck,
                    'Approval Center',
                  ),
                  _buildSidebarItem(
                    performanceIndex,
                    LucideIcons.barChart2,
                    'Staff Performance',
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

          _buildNotificationControls(
            orderQueueIndex: orderQueueIndex,
            posIndex: posIndex,
            transactionIndex: transactionIndex,
            inventoryIndex: inventoryIndex,
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
      onTap: () => _selectMainIndex(index),
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
            _selectMainIndex(index);
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
      _clearStoreAccessScheduling();
      await _staffPresenceService?.stop(logoutReason: 'manual_logout');
      await widget.controller.revokeCurrentSession();
      final prefs = await SharedPreferences.getInstance();
      await widget.realtimeSync.stop();
      await prefs.clear();

      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
      }
    } catch (e, stackTrace) {
      AppLogger.error('Logout failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(e, fallback: AppErrorCategory.server),
        );
      }
    }
  }

  Future<void> _logoutFromForcedPasswordChange() async {
    try {
      _clearStoreAccessScheduling();
      await _staffPresenceService?.stop(logoutReason: 'manual_logout');
      await widget.controller.revokeCurrentSession();
      final prefs = await SharedPreferences.getInstance();
      await widget.realtimeSync.stop();
      await prefs.clear();

      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        'Forced-password-change logout failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(e, fallback: AppErrorCategory.server),
        );
      }
    }
  }
}

enum _StoreAccessMilestone {
  openingSoon,
  opened,
  shiftEnd30,
  shiftEnd15,
  shiftEnd5,
  shiftEnded,
  allowance5,
  logoutWarning,
  deadline,
}

class _ScheduledStoreAccessMilestone {
  final _StoreAccessMilestone milestone;
  final DateTime at;

  const _ScheduledStoreAccessMilestone(this.milestone, this.at);
}
