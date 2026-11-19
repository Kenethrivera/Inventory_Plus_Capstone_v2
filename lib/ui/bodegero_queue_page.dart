import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import '../logic/loading_proof_photo_picker_io.dart'
    if (dart.library.html) '../logic/loading_proof_photo_picker_web.dart'
    as loading_proof_photo;
import '../logic/order_work_progress.dart';
import '../logic/staff_availability.dart';
import '../notifications/models/app_notification.dart';
import '../notifications/models/notification_type.dart';
import '../notifications/notification_bell.dart';
import '../notifications/notification_provider.dart';
import '../services/staff_presence_service.dart';
import 'bodegero_history_page.dart';
import 'helper_me_page.dart';
import 'helper_request_page.dart';
import 'scanner_search_page.dart';
import 'store_map.dart';
import 'widgets/staff_role_header.dart';

const _ink = Color(0xFF171717);
const _orange = Color(0xFFC83D08);
const _muted = Color(0xFF756D67);
const _line = Color(0xFFE1DCD5);
const _background = Color(0xFFF6F5F2);
const _font = 'Hellix';

class BodegeroQueuePage extends StatefulWidget {
  const BodegeroQueuePage({
    super.key,
    required this.controller,
    required this.onLogout,
    this.approvalChanges,
    this.onModuleChanged,
    this.presenceService,
  });

  final InventoryController controller;
  final VoidCallback onLogout;
  final Stream<void>? approvalChanges;
  final ValueChanged<String>? onModuleChanged;
  final StaffPresenceService? presenceService;

  @override
  State<BodegeroQueuePage> createState() => _BodegeroQueuePageState();
}

class _BodegeroQueuePageState extends State<BodegeroQueuePage> {
  final _truckController = TextEditingController();
  final _searchController = TextEditingController();
  final _quantityControllers = <String, TextEditingController>{};
  late Stream<List<CustomerOrder>> _ordersStream;
  late Stream<List<CustomerOrder>> _availabilityOrdersStream;
  StreamSubscription<List<CustomerOrder>>? _autoClaimSubscription;
  bool _autoClaimInFlight = false;
  bool _autoClaimQueued = false;
  bool _autoClaimErrorShown = false;
  String? _selectedOrderId;
  String _search = '';
  Uint8List? _photoJpeg;
  CustomerOrder? _completedOrder;
  bool _busy = false;
  bool _photoPreparing = false;
  bool _clockBusy = false;
  bool _loadingPaused = false;
  bool _changingBreak = false;
  int _tabIndex = 0;
  int _lastMainTabIndex = 0;
  final Set<int> _visitedTabs = {0};

  @override
  void initState() {
    super.initState();
    _ordersStream = widget.controller.streamOrders();
    _availabilityOrdersStream = widget.controller.streamOrders();
    _bindAutoClaim();
    unawaited(_loadMap());
  }

  void _bindAutoClaim() {
    widget.presenceService?.addListener(_scheduleAutoClaim);
    _autoClaimSubscription = widget.controller.orderSnapshots.listen(
      (_) => _scheduleAutoClaim(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleAutoClaim());
  }

  void _scheduleAutoClaim() {
    if (!mounted) return;
    if (_autoClaimInFlight) {
      _autoClaimQueued = true;
      return;
    }
    final presence = widget.presenceService;
    if (presence == null ||
        !presence.isStarted ||
        presence.isOnBreak ||
        !widget.controller.hasUsableOrdersSnapshot ||
        widget.controller.currentUserId != presence.userId ||
        widget.controller.activeLocationId != presence.locationId) {
      return;
    }
    unawaited(_autoClaimPendingOrders());
  }

  Future<void> _autoClaimPendingOrders() async {
    _autoClaimInFlight = true;
    final attemptedOrderIds = <String>{};
    try {
      do {
        _autoClaimQueued = false;
        final orders =
            widget.controller.currentOrders
                .where(
                  (order) =>
                      !attemptedOrderIds.contains(order.id) &&
                      (order.status == 'pending' ||
                          order.status == 'solo_picking') &&
                      order.assignedBodegeroId == null &&
                      order.loadingVerifiedAt == null &&
                      order.items.any((item) => item.requiresLoading),
                )
                .toList()
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        for (final order in orders) {
          final presence = widget.presenceService;
          if (!mounted ||
              presence == null ||
              !presence.isStarted ||
              presence.isOnBreak) {
            break;
          }
          attemptedOrderIds.add(order.id);
          try {
            await widget.controller.claimOrderLoading(order.id);
          } catch (error) {
            // The database rejects claims that another Bodegero won first.
            debugPrint('[Bodegero queue] Automatic claim skipped: $error');
            if (!error.toString().contains('loading_claim_conflict') &&
                !_autoClaimErrorShown &&
                mounted) {
              _autoClaimErrorShown = true;
              _message('Automatic order assignment failed: $error');
            }
          }
        }
      } while (_autoClaimQueued && mounted);
    } finally {
      _autoClaimInFlight = false;
    }
  }

  Future<void> _loadMap() async {
    try {
      await widget.controller.fetchMapLayout();
      if (mounted) setState(() {});
    } catch (_) {
      // The loading checklist remains usable when no store map is configured.
    }
  }

  @override
  void didUpdateWidget(covariant BodegeroQueuePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.presenceService != widget.presenceService) {
      oldWidget.presenceService?.removeListener(_scheduleAutoClaim);
      unawaited(_autoClaimSubscription?.cancel());
      _ordersStream = widget.controller.streamOrders();
      _availabilityOrdersStream = widget.controller.streamOrders();
      _bindAutoClaim();
      unawaited(_loadMap());
    }
  }

  @override
  void dispose() {
    if (_selectedOrderId != null) {
      final presence = widget.presenceService;
      if (presence != null) {
        unawaited(presence.setWorkMode(null));
      }
    }
    widget.presenceService?.removeListener(_scheduleAutoClaim);
    unawaited(_autoClaimSubscription?.cancel());
    _truckController.dispose();
    _searchController.dispose();
    for (final controller in _quantityControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _toggleBreak() async {
    final presence = widget.presenceService;
    if (presence == null || !presence.isStarted || _changingBreak) return;
    setState(() => _changingBreak = true);
    try {
      await presence.setOnBreak(!presence.isOnBreak);
    } catch (_) {
      _message('Could not update your availability.');
    } finally {
      if (mounted) setState(() => _changingBreak = false);
    }
  }

  Widget _availabilityChip(StaffPresenceService presence) => AnimatedBuilder(
    animation: presence,
    builder: (context, _) => StreamBuilder<List<CustomerOrder>>(
      stream: _availabilityOrdersStream,
      initialData: widget.controller.currentOrders,
      builder: (context, snapshot) {
        final activeOrders =
            activeLoadingWorkloads(
              snapshot.data ?? widget.controller.currentOrders,
            )[widget.controller.currentUserId] ??
            0;
        final availability = resolveStaffAvailability(
          isOnline: presence.isStarted,
          isOnBreak: presence.isOnBreak,
          isHelper: false,
          isBodegero: true,
          activeOrders: activeOrders,
          currentModule: presence.workMode,
        );
        final label = switch (availability) {
          StaffAvailability.offline => 'Offline',
          StaffAvailability.onBreak => 'On break',
          StaffAvailability.preparing => 'Preparing',
          StaffAvailability.loading => 'Loading',
          StaffAvailability.available => 'Available',
        };
        final background = switch (availability) {
          StaffAvailability.preparing => _orange,
          StaffAvailability.loading => _orange,
          StaffAvailability.available => const Color(0xFF168047),
          _ => const Color(0xFF45413E),
        };
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ActionChip(
            tooltip: presence.isOnBreak
                ? 'Switch to Available'
                : 'Switch to On break',
            onPressed: _changingBreak || !presence.isStarted
                ? null
                : _toggleBreak,
            backgroundColor: background,
            disabledColor: const Color(0xFF45413E),
            side: BorderSide.none,
            shape: const StadiumBorder(),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: _font,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Future<bool> _open(CustomerOrder order) async {
    if (_busy || _clockBusy) return false;
    if (widget.presenceService?.isOnBreak == true) {
      _message('Switch to Available before loading an order.');
      return false;
    }
    order = widget.controller.orderById(order.id) ?? order;
    if ((order.status != 'pending' && order.status != 'solo_picking') ||
        order.loadingVerifiedAt != null ||
        !order.items.any((item) => item.requiresLoading)) {
      _message('This loading order is no longer available.');
      return false;
    }
    if (order.assignedBodegeroId != null &&
        order.assignedBodegeroId != widget.controller.currentUserId) {
      _message('This order is already assigned to another Bodegero.');
      return false;
    }
    if (order.assignedBodegeroId == null) {
      if (widget.presenceService?.isOnBreak == true) {
        _message('Switch to Available before opening a new order.');
        return false;
      }
      setState(() => _busy = true);
      try {
        order = await widget.controller.claimOrderLoading(order.id);
        if (!mounted) return false;
      } catch (error) {
        _message(
          error.toString().contains('loading_claim_conflict')
              ? 'This order was just assigned to another Bodegero.'
              : 'Could not open this order: $error',
        );
        try {
          await widget.controller.retryOrdersSnapshot();
        } catch (_) {
          // Realtime can still refresh the queue after a claim conflict.
        }
        return false;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    setState(() => _clockBusy = true);
    try {
      final clock = await widget.controller.startOrderLoadingClock(order.id);
      if (!mounted) return false;
      _loadingPaused = clock['paused'] == true;
    } catch (error) {
      _message('Could not start the loading timer: $error');
      return false;
    } finally {
      if (mounted) setState(() => _clockBusy = false);
    }
    for (final controller in _quantityControllers.values) {
      controller.dispose();
    }
    _quantityControllers.clear();
    for (final item in order.items.where((item) => item.requiresLoading)) {
      _quantityControllers[item.productId] = TextEditingController();
    }
    _truckController.clear();
    setState(() {
      _selectedOrderId = order.id;
      _completedOrder = null;
      _photoJpeg = null;
    });

    final presence = widget.presenceService;
    if (presence != null) {
      unawaited(presence.setWorkMode(staffLoadingModule));
    }

    return true;
  }

  void _closeLoadingChecklist() {
    setState(() {
      _selectedOrderId = null;
    });

    final presence = widget.presenceService;
    if (presence != null) {
      unawaited(presence.setWorkMode(null));
    }
  }

  Future<void> _toggleLoadingPause(CustomerOrder order) async {
    if (_clockBusy) return;
    setState(() => _clockBusy = true);
    try {
      final clock = await widget.controller.setOrderLoadingPause(
        order.id,
        paused: !_loadingPaused,
      );
      if (mounted) setState(() => _loadingPaused = clock['paused'] == true);
    } catch (error) {
      _message('Could not update loading timer: $error');
    } finally {
      if (mounted) setState(() => _clockBusy = false);
    }
  }

  CustomerOrder? _notifiedLoadingOrder(AppNotification notification) {
    if (notification.type != NotificationType.newOrder &&
        notification.type != NotificationType.orderAssigned) {
      return null;
    }
    final orderId = notification.payload['orderId']?.toString();
    if (orderId == null || orderId.isEmpty) return null;
    for (final order in widget.controller.currentOrders) {
      if (order.id == orderId &&
          (order.status == 'pending' || order.status == 'solo_picking') &&
          order.loadingVerifiedAt == null &&
          (order.assignedBodegeroId == null ||
              order.assignedBodegeroId == widget.controller.currentUserId) &&
          order.items.any((item) => item.requiresLoading)) {
        return order;
      }
    }
    return null;
  }

  Future<bool> _openNotifiedLoadingOrder(AppNotification notification) async {
    await widget.controller.retryOrdersSnapshot();
    if (!mounted) return false;
    final order = _notifiedLoadingOrder(notification);
    if (order == null) {
      _message('This loading order is no longer available.');
      return false;
    }
    setState(() => _tabIndex = 0);
    widget.onModuleChanged?.call('Heavy loading');
    return _open(order);
  }

  Future<void> _scan(CustomerOrder order, CustomerOrderItem expected) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (scannerContext) => ScannerSearchPage(
          controller: widget.controller,
          onSelectItem: (scanned) async {
            Navigator.pop(scannerContext);
            if (scanned.id != expected.productId) {
              _message('Wrong product. Scan ${expected.productName}.');
              return;
            }
            setState(() => _busy = true);
            try {
              await widget.controller.verifyHeavyOrderItem(
                order.id,
                expected.productId,
              );
              _message('${expected.productName} verified. Count the quantity.');
            } catch (error) {
              _message('Could not verify this item: $error');
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
        ),
      ),
    );
  }

  Future<void> _capturePhoto() async {
    if (_photoPreparing) return;
    setState(() => _photoPreparing = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: kIsWeb ? null : 960,
        maxHeight: kIsWeb ? null : 960,
        imageQuality: kIsWeb ? null : 65,
      );
      if (image == null) return;
      final bytes = await loading_proof_photo
          .prepareLoadingProofPhotoFromPicker(image);
      if (mounted) setState(() => _photoJpeg = bytes);
    } catch (error) {
      _message('Photo capture failed: $error');
    } finally {
      if (mounted) setState(() => _photoPreparing = false);
    }
  }

  Future<void> _finish(CustomerOrder order) async {
    if (_photoPreparing) return;
    if (_loadingPaused) {
      _message('Resume loading before confirming the truck proof.');
      return;
    }
    final heavyItems = order.items
        .where((item) => item.requiresLoading)
        .toList();
    if (heavyItems.any((item) => !item.heavyVerified)) {
      _message('Scan every heavy product first.');
      return;
    }
    final plate = _truckController.text.trim();
    if (plate.isEmpty || _photoJpeg == null) {
      _message('Enter the truck plate and capture a loading photo.');
      return;
    }
    final quantities = <String, double>{};
    for (final item in heavyItems) {
      final count = double.tryParse(
        _quantityControllers[item.productId]?.text.trim() ?? '',
      );
      if (count == null || !count.isFinite || count != item.quantity) {
        _message(
          'Confirm exactly ${item.quantity} ${item.unit ?? ''} of ${item.productName}.',
        );
        return;
      }
      quantities[item.productId] = count;
    }
    setState(() => _busy = true);
    try {
      final updated = await widget.controller.finishOrderLoading(
        orderId: order.id,
        truckPlate: plate,
        loadedQuantities: quantities,
        photoJpeg: _photoJpeg!,
      );
      if (!mounted) return;
      final notifications = NotificationProvider.maybeOf(context);
      if (notifications != null) {
        unawaited(
          notifications.resolveBodegeroLoadingNotification(orderId: order.id),
        );
      }
      setState(() {
        _selectedOrderId = null;
        _completedOrder = updated;
        _photoJpeg = null;
      });
      final presence = widget.presenceService;
      if (presence != null) {
        unawaited(presence.setWorkMode(null));
      }
      _message(
        updated.status == 'prepared'
            ? 'Loading verified. Order is ready for payment.'
            : 'Loading verified. Waiting for light items.',
      );
    } catch (error) {
      _message('Could not save loading proof: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shortId(CustomerOrder order) {
    final id = order.id.trim();
    return '#${(id.length <= 8 ? id : id.substring(0, 8)).toUpperCase()}';
  }

  List<CustomerOrderItem> _heavyItems(CustomerOrder order) =>
      order.items.where((item) => item.requiresLoading).toList(growable: false);

  String _location(CustomerOrderItem orderItem) {
    final product = widget.controller.findAnyItemById(orderItem.productId);
    if (product == null) return 'Find item in store';
    final matching = widget.controller.storeLayout.where(
      (element) => element.id == product.locationId,
    );
    final fixture = matching.isEmpty || matching.first.label.trim().isEmpty
        ? 'Store shelf'
        : matching.first.label.trim();
    final level = product.shelfLevel?.trim();
    return level == null || level.isEmpty ? fixture : '$fixture · Level $level';
  }

  PreferredSizeWidget _header() {
    final name = widget.controller.currentUserName?.trim() ?? 'Bodegero';
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    return PreferredSize(
      preferredSize: const Size.fromHeight(67),
      child: StaffRoleHeader(
        userName: name,
        tabs: const ['Queue', 'Map', 'History', 'Request'],
        selectedTab: _tabIndex,
        onTabSelected: _selectTab,
        onProfile: () {
          setState(() {
            _tabIndex = 4;
            _visitedTabs.add(4);
          });
          widget.onModuleChanged?.call('Profile');
          final presence = widget.presenceService;
          if (presence != null) {
            unawaited(presence.setWorkMode(null));
          }
        },
        onLogout: widget.onLogout,
        availability: widget.presenceService == null
            ? null
            : _availabilityChip(widget.presenceService!),
        notifications: NotificationProvider.maybeOf(context) == null
            ? null
            : NotificationBell(
                iconColor: _ink,
                helperMobilePanel: true,
                isActionable: (notification) =>
                    (notification.type == NotificationType.newOrder ||
                        notification.type == NotificationType.orderAssigned) &&
                    (notification.payload['orderId']?.toString().isNotEmpty ??
                        false),
                onNotificationSelected: _openNotifiedLoadingOrder,
              ),
        showTabs: desktop,
      ),
    );
  }

  void _selectTab(int index) {
    setState(() {
      _tabIndex = index;
      _lastMainTabIndex = index;
      _visitedTabs.add(index);
    });
    widget.onModuleChanged?.call(
      const [
        'Heavy loading',
        'Store map',
        'Loading history',
        'Stock request',
        'Profile',
      ][index],
    );
    final presence = widget.presenceService;
    if (presence != null) {
      final mode = index == 0 && _selectedOrderId != null
          ? staffLoadingModule
          : null;

      unawaited(presence.setWorkMode(mode));
    }
  }

  Widget _statusPill(String label, {bool active = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: active ? const Color(0xFFE4EFFD) : const Color(0xFFF0EEEA),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: active ? const Color(0xFF245C9E) : _muted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        fontFamily: _font,
      ),
    ),
  );

  Widget _assignedCard(CustomerOrder order) {
    final items = _heavyItems(order);
    final scanned = items.where((item) => item.heavyVerified).length;
    final sharedProgress = OrderWorkProgress.fromOrder(order);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => unawaited(_open(order)),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _shortId(order),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                  ),
                  _statusPill(
                    scanned > 0 ? 'Loading' : 'Assigned',
                    active: true,
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                items.map((item) => item.productName).join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 14,
                  fontFamily: _font,
                ),
              ),
              if (sharedProgress.isMixed) ...[
                const SizedBox(height: 8),
                Text(
                  'Shared order · Helper: ${sharedProgress.helperSummary}',
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontFamily: _font,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: items.isEmpty ? 0 : scanned / items.length,
                        minHeight: 7,
                        backgroundColor: const Color(0xFFECEAE6),
                        valueColor: const AlwaysStoppedAnimation(_orange),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$scanned/${items.length} QR verified',
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      fontFamily: _font,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      scanned > 0 ? 'Continue loading' : 'Start loading',
                      style: const TextStyle(
                        color: _orange,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: _font,
                      ),
                    ),
                  ),
                  const Icon(
                    LucideIcons.chevronRight,
                    size: 18,
                    color: _orange,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _openCard(CustomerOrder order) {
    final items = _heavyItems(order);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: _busy || _clockBusy || widget.presenceService?.isOnBreak == true
            ? null
            : () => unawaited(_open(order)),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _shortId(order),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${items.length} heavy ${items.length == 1 ? 'item' : 'items'} · ${items.map((item) => item.productName).join(', ')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const Icon(LucideIcons.chevronRight, size: 18, color: _orange),
            ],
          ),
        ),
      ),
    );
  }

  Widget _queue(List<CustomerOrder> orders) {
    final myId = widget.controller.currentUserId;
    final matching = orders
        .where((order) {
          if (_search.trim().isEmpty) return true;
          final query = _search.trim().toLowerCase();
          return order.id.toLowerCase().contains(query) ||
              _heavyItems(
                order,
              ).any((item) => item.productName.toLowerCase().contains(query));
        })
        .toList(growable: false);
    final assigned = matching
        .where((order) => order.assignedBodegeroId == myId)
        .toList(growable: false);
    final open = matching
        .where((order) => order.assignedBodegeroId == null)
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          return _desktopQueue(assigned, open);
        }
        final compact = constraints.maxWidth < 600;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 20 : 32,
            compact ? 24 : 32,
            compact ? 20 : 32,
            32,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.presenceService case final presence?)
                      AnimatedBuilder(
                        animation: presence,
                        builder: (context, _) => presence.isOnBreak
                            ? Container(
                                margin: const EdgeInsets.only(bottom: 20),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF2D0),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(
                                      LucideIcons.coffee,
                                      color: Color(0xFFA65A00),
                                      size: 18,
                                    ),
                                    SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        "You're on break. New heavy orders won't be assigned or claimed until you switch back to Available.",
                                        style: TextStyle(
                                          color: _ink,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Your loading orders',
                            style: TextStyle(
                              color: _ink,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              fontFamily: _font,
                            ),
                          ),
                        ),
                        Text(
                          '${assigned.length} assigned',
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 13,
                            fontFamily: _font,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _search = value),
                      decoration: InputDecoration(
                        hintText: 'Search order # or product',
                        prefixIcon: const Icon(LucideIcons.search, size: 18),
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _search = '');
                                },
                                icon: const Icon(Icons.close, size: 18),
                              ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _line),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (assigned.isEmpty)
                      _emptyCard(
                        _search.isNotEmpty
                            ? 'No assigned orders match your search.'
                            : 'No heavy loading tasks assigned.',
                        detail: _search.isEmpty
                            ? 'A new cashier order with a Heavy product will appear here.'
                            : null,
                      ),
                    for (final order in assigned) ...[
                      _assignedCard(order),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        const Text(
                          'Open orders',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            fontFamily: _font,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '${open.length}',
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 17,
                            fontFamily: _font,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Open an unassigned heavy order to start loading.',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 13,
                        fontFamily: _font,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (open.isEmpty)
                      _emptyCard(
                        _search.isNotEmpty
                            ? 'No open orders match your search.'
                            : 'No open orders.',
                      ),
                    for (final order in open) ...[
                      _openCard(order),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _desktopQueue(
    List<CustomerOrder> assigned,
    List<CustomerOrder> open,
  ) => ListView(
    padding: const EdgeInsets.fromLTRB(48, 48, 48, 64),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.presenceService?.isOnBreak == true) ...[
                const Text(
                  "You're on break. Switch to Available for new loading orders.",
                  style: TextStyle(color: _muted, fontSize: 15),
                ),
                const SizedBox(height: 24),
              ],
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Your loading orders',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                  ),
                  Text(
                    '${assigned.length} assigned',
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 16,
                      fontFamily: _font,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _search = value),
                decoration: InputDecoration(
                  hintText: 'Search order # or product',
                  prefixIcon: const Icon(LucideIcons.search),
                  suffixIcon: _search.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _search = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: _line),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (assigned.isEmpty)
                _emptyCard('No heavy loading tasks assigned.'),
              if (assigned.isNotEmpty)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cardWidth = (constraints.maxWidth - 20) / 2;
                    return Wrap(
                      spacing: 20,
                      runSpacing: 20,
                      children: [
                        for (final order in assigned)
                          SizedBox(
                            width: cardWidth,
                            child: _assignedCard(order),
                          ),
                      ],
                    );
                  },
                ),
              if (open.isNotEmpty) ...[
                const SizedBox(height: 40),
                Text(
                  'Open orders ${open.length}',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    fontFamily: _font,
                  ),
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cardWidth = (constraints.maxWidth - 20) / 2;
                    return Wrap(
                      spacing: 20,
                      runSpacing: 20,
                      children: [
                        for (final order in open)
                          SizedBox(width: cardWidth, child: _openCard(order)),
                      ],
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    ],
  );

  Widget _emptyCard(String title, {String? detail}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        const Icon(LucideIcons.package, color: _muted, size: 24),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _ink,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            fontFamily: _font,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 5),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontFamily: _font,
            ),
          ),
        ],
      ],
    ),
  );

  String _quantity(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  Widget _itemCard(CustomerOrder order, CustomerOrderItem item, int position) {
    final product = widget.controller.findAnyItemById(item.productId);
    final verified = item.heavyVerified;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: verified ? const Color(0xFF168047) : _ink,
                child: verified
                    ? const Icon(
                        LucideIcons.circleCheck,
                        color: Colors.white,
                        size: 18,
                      )
                    : Text(
                        '$position',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0EEEA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: product != null && product.imageUrl.isNotEmpty
                    ? Image.network(
                        product.imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const Icon(LucideIcons.package, color: _muted),
                      )
                    : const Icon(LucideIcons.package, color: _muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _location(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                    Text(
                      item.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 13,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Load exactly ${_quantity(item.quantity)} ${item.unit ?? 'pcs'}',
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFamily: _font,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!verified)
                FilledButton.icon(
                  onPressed: _busy || _loadingPaused
                      ? null
                      : () => _scan(order, item),
                  icon: const Icon(LucideIcons.scanLine, size: 17),
                  label: const Text('Scan shelf QR'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _ink,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                )
              else
                const Row(
                  children: [
                    Icon(
                      LucideIcons.circleCheck,
                      size: 18,
                      color: Color(0xFF168047),
                    ),
                    SizedBox(width: 7),
                    Text(
                      'QR verified',
                      style: TextStyle(
                        color: Color(0xFF168047),
                        fontWeight: FontWeight.w700,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _quantityControllers[item.productId],
            enabled: verified && !_busy && !_loadingPaused,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantity loaded (${item.unit ?? 'pcs'})',
              hintText: verified ? 'Enter counted quantity' : 'Scan QR first',
              filled: true,
              fillColor: const Color(0xFFFAF9F7),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _proofCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(LucideIcons.truck, size: 20, color: _orange),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Truck loading proof',
                style: TextStyle(
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  fontFamily: _font,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Record the truck and photograph the goods after loading.',
          style: TextStyle(color: _muted, fontSize: 13, fontFamily: _font),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _truckController,
          maxLength: 32,
          enabled: !_busy && !_loadingPaused,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Truck plate / identifier',
            prefixIcon: const Icon(LucideIcons.truck, size: 18),
            filled: true,
            fillColor: const Color(0xFFFAF9F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _busy || _photoPreparing || _loadingPaused
              ? null
              : _capturePhoto,
          icon: const Icon(LucideIcons.camera, size: 18),
          label: Text(
            _photoPreparing
                ? 'Preparing photo…'
                : _photoJpeg == null
                ? 'Capture loaded goods'
                : 'Retake photo',
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: _orange,
            side: const BorderSide(color: _line),
          ),
        ),
        if (_photoJpeg != null) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              _photoJpeg!,
              height: 190,
              width: double.infinity,
              fit: BoxFit.contain,
            ),
          ),
        ],
      ],
    ),
  );

  bool _countsMatch(List<CustomerOrderItem> items) => items.every((item) {
    final count = double.tryParse(
      _quantityControllers[item.productId]?.text.trim() ?? '',
    );
    return count != null && count.isFinite && count == item.quantity;
  });

  Widget _checklist(CustomerOrder order) {
    final items = _heavyItems(order);
    final sharedProgress = OrderWorkProgress.fromOrder(order);
    final scanned = items.where((item) => item.heavyVerified).length;
    final allScanned = scanned == items.length;
    final countsMatch = _countsMatch(items);
    final truckReady = _truckController.text.trim().isNotEmpty;
    final photoReady = _photoJpeg != null;
    final canFinish =
        order.assignedBodegeroId != null &&
        !_photoPreparing &&
        !_loadingPaused &&
        allScanned &&
        countsMatch &&
        truckReady &&
        photoReady;
    final nextLabel = _busy
        ? 'Saving loading proof…'
        : _photoPreparing
        ? 'Preparing photo…'
        : _loadingPaused
        ? 'Resume loading to finish'
        : !allScanned
        ? 'Scan ${items.length - scanned} more ${items.length - scanned == 1 ? 'item' : 'items'}'
        : !countsMatch
        ? 'Confirm loaded quantities'
        : !truckReady || !photoReady
        ? 'Add truck and photo'
        : 'Confirm loaded onto truck';
    final markers = <PickStopMarker>[];
    for (var i = 0; i < items.length; i++) {
      final locationId = widget.controller
          .findAnyItemById(items[i].productId)
          ?.locationId;
      if (locationId != null && locationId.isNotEmpty) {
        markers.add(
          PickStopMarker(
            locationId: locationId,
            number: i + 1,
            label: _location(items[i]),
          ),
        );
      }
    }
    final nextItem = items.where((item) => !item.heavyVerified);
    final highlightId = nextItem.isEmpty
        ? null
        : widget.controller
              .findAnyItemById(nextItem.first.productId)
              ?.locationId;

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 12, 20, 14),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to queue',
                onPressed: _busy
                    ? null
                    : _closeLoadingChecklist,
                icon: const Icon(LucideIcons.arrowLeft, color: _muted),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _shortId(order),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                    const Text(
                      'Load onto truck',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$scanned/${items.length}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  fontFamily: _font,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _busy || _clockBusy
                      ? null
                      : () => _toggleLoadingPause(order),
                  icon: Icon(_loadingPaused ? Icons.play_arrow : Icons.pause),
                  label: Text(
                    _loadingPaused ? 'Resume loading' : 'Pause loading',
                  ),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (sharedProgress.isMixed) ...[
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Shared order · Helper: ${sharedProgress.helperSummary}',
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: _font,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (markers.isNotEmpty &&
                          widget.controller.storeLayout.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Store map · heavy item locations',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  fontFamily: _font,
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 260,
                                child: StoreMap(
                                  controller: widget.controller,
                                  mode: MapMode.view,
                                  viewStyle: MapViewStyle.twoD,
                                  highlightId: highlightId,
                                  pickStopMarkers: markers,
                                  showProductCounts: false,
                                  showItemPopup: false,
                                  showMobileToolbar: false,
                                  showZoomControls: true,
                                  compactZoomControls: true,
                                  miniZoomControls: true,
                                  zoomAccentColor: _orange,
                                  itemAssignmentEnabled: false,
                                  fitEntireMap: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      const Text(
                        'Loading list · scan and count',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          fontFamily: _font,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (var i = 0; i < items.length; i++)
                        _itemCard(order, items[i], i + 1),
                      const SizedBox(height: 8),
                      _proofCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: _line)),
          ),
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    onPressed: canFinish && !_busy
                        ? () => _finish(order)
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: _orange,
                      disabledBackgroundColor: const Color(0xFFE9B79F),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      nextLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _desktopChecklist(CustomerOrder order) {
    final items = _heavyItems(order);
    final progress = OrderWorkProgress.fromOrder(order);
    final scanned = items.where((item) => item.heavyVerified).length;
    final allScanned = scanned == items.length;
    final canFinish =
        order.assignedBodegeroId != null &&
        !_photoPreparing &&
        !_loadingPaused &&
        allScanned &&
        _countsMatch(items) &&
        _truckController.text.trim().isNotEmpty &&
        _photoJpeg != null;
    final nextLabel = _busy
        ? 'Saving loading proof…'
        : _photoPreparing
        ? 'Preparing photo…'
        : _loadingPaused
        ? 'Resume loading to finish'
        : !allScanned
        ? 'Scan ${items.length - scanned} more ${items.length - scanned == 1 ? 'item' : 'items'}'
        : !_countsMatch(items)
        ? 'Confirm loaded quantities'
        : _truckController.text.trim().isEmpty || _photoJpeg == null
        ? 'Add truck and photo'
        : 'Confirm loaded onto truck';
    final markers = <PickStopMarker>[];
    for (var i = 0; i < items.length; i++) {
      final locationId = widget.controller
          .findAnyItemById(items[i].productId)
          ?.locationId;
      if (locationId != null && locationId.isNotEmpty) {
        markers.add(
          PickStopMarker(
            locationId: locationId,
            number: i + 1,
            label: _location(items[i]),
          ),
        );
      }
    }
    final unverified = items.where((item) => !item.heavyVerified);
    final highlightId = unverified.isEmpty
        ? null
        : widget.controller
              .findAnyItemById(unverified.first.productId)
              ?.locationId;

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(40, 22, 40, 22),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to queue',
                onPressed: _busy
                    ? null
                    : _closeLoadingChecklist,
                icon: const Icon(LucideIcons.arrowLeft),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _shortId(order),
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                        fontFamily: _font,
                      ),
                    ),
                    const Text(
                      'Load onto truck',
                      style: TextStyle(color: _muted, fontSize: 16),
                    ),
                  ],
                ),
              ),
              Text(
                '$scanned/${items.length}',
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 24),
              OutlinedButton(
                onPressed: _busy || _clockBusy
                    ? null
                    : () => _toggleLoadingPause(order),
                child: Text(
                  _loadingPaused ? 'Resume loading' : 'Pause loading',
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(40, 32, 40, 48),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1600),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Store map · heavy item locations',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                height: 560,
                                child: widget.controller.storeLayout.isEmpty
                                    ? const Center(
                                        child: Text('Store map unavailable.'),
                                      )
                                    : StoreMap(
                                        controller: widget.controller,
                                        mode: MapMode.view,
                                        viewStyle: MapViewStyle.twoD,
                                        highlightId: highlightId,
                                        pickStopMarkers: markers,
                                        showProductCounts: false,
                                        showItemPopup: false,
                                        showMobileToolbar: false,
                                        showZoomControls: true,
                                        zoomAccentColor: _orange,
                                        itemAssignmentEnabled: false,
                                        fitEntireMap: true,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'Loading list · scan and count',
                              style: TextStyle(
                                color: _ink,
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 20),
                            if (progress.isMixed) ...[
                              Text(
                                'Shared order · Helper: ${progress.helperSummary}',
                                style: const TextStyle(color: _muted),
                              ),
                              const SizedBox(height: 16),
                            ],
                            for (var i = 0; i < items.length; i++)
                              _itemCard(order, items[i], i + 1),
                            const SizedBox(height: 8),
                            _proofCard(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(40, 16, 40, 20),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: _line)),
          ),
          child: FilledButton(
            onPressed: canFinish && !_busy ? () => _finish(order) : null,
            style: FilledButton.styleFrom(
              backgroundColor: _orange,
              disabledBackgroundColor: const Color(0xFFE9B79F),
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(nextLabel),
          ),
        ),
      ],
    );
  }

  Widget _completion(CustomerOrder order) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(
              radius: 34,
              backgroundColor: Color(0xFFE8F5EC),
              child: Icon(
                LucideIcons.packageCheck,
                color: Color(0xFF168047),
                size: 32,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '${_shortId(order)} loading verified',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _ink,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                fontFamily: _font,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              order.status == 'prepared'
                  ? 'The order is ready for cashier release.'
                  : 'The Helper is finishing the light items.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _muted,
                fontSize: 14,
                fontFamily: _font,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () => setState(() => _completedOrder = null),
                style: FilledButton.styleFrom(backgroundColor: _orange),
                child: const Text('Back to queue'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _queueBody() => StreamBuilder<List<CustomerOrder>>(
    stream: _ordersStream,
    initialData: widget.controller.currentOrders,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unable to load assigned orders.'),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () =>
                    unawaited(widget.controller.retryOrdersSnapshot()),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      }
      if (snapshot.connectionState == ConnectionState.waiting &&
          (snapshot.data?.isEmpty ?? true)) {
        return const Center(child: CircularProgressIndicator(color: _orange));
      }
      if (_completedOrder != null) return _completion(_completedOrder!);

      final orders =
          (snapshot.data ?? const <CustomerOrder>[])
              .where(
                (order) =>
                    (order.status == 'pending' ||
                        order.status == 'solo_picking') &&
                    order.loadingVerifiedAt == null &&
                    (order.assignedBodegeroId == null ||
                        order.assignedBodegeroId ==
                            widget.controller.currentUserId) &&
                    order.items.any((item) => item.requiresLoading),
              )
              .toList()
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      CustomerOrder? selected;
      for (final order in orders) {
        if (order.id == _selectedOrderId) selected = order;
      }
      if (selected == null && _selectedOrderId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _selectedOrderId == null) return;
          _closeLoadingChecklist();
        });
      }
      return selected == null
          ? _queue(orders)
          : MediaQuery.sizeOf(context).width >= 900
          ? _desktopChecklist(selected)
          : _checklist(selected);
    },
  );

  Widget _mapPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 22, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Store map',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 4),
            Text(
              'Find heavy products on the store floor.',
              style: TextStyle(fontSize: 13, color: _muted),
            ),
          ],
        ),
      ),
      Expanded(
        child: StoreMap(
          controller: widget.controller,
          mode: MapMode.view,
          viewStyle: MapViewStyle.twoD,
          itemAssignmentEnabled: false,
          fitEntireMap: true,
        ),
      ),
    ],
  );

  Widget _bottomNavigation() => BottomNavigationBar(
    currentIndex: _tabIndex == 4 ? _lastMainTabIndex : _tabIndex,
    type: BottomNavigationBarType.fixed,
    backgroundColor: Colors.white,
    selectedItemColor: _orange,
    unselectedItemColor: _muted,
    selectedFontSize: 11,
    unselectedFontSize: 11,
    showUnselectedLabels: true,
    onTap: _selectTab,
    items: const [
      BottomNavigationBarItem(
        icon: Icon(LucideIcons.listChecks),
        label: 'Queue',
      ),
      BottomNavigationBarItem(icon: Icon(LucideIcons.map), label: 'Map'),
      BottomNavigationBarItem(
        icon: Icon(LucideIcons.history),
        label: 'History',
      ),
      BottomNavigationBarItem(
        icon: Icon(LucideIcons.clipboardPlus),
        label: 'Request',
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    appBar: _header(),
    body: IndexedStack(
      index: _tabIndex,
      children: [
        _queueBody(),
        _visitedTabs.contains(1) ? _mapPage() : const SizedBox.shrink(),
        _visitedTabs.contains(2)
            ? BodegeroHistoryPage(
                controller: widget.controller,
                isActive: _tabIndex == 2,
              )
            : const SizedBox.shrink(),
        _visitedTabs.contains(3)
            ? HelperRequestPage(
                controller: widget.controller,
                approvalChanges: widget.approvalChanges,
              )
            : const SizedBox.shrink(),
        _visitedTabs.contains(4)
            ? HelperMePage(controller: widget.controller)
            : const SizedBox.shrink(),
      ],
    ),
    bottomNavigationBar:
        MediaQuery.sizeOf(context).width >= 900 ||
            (_tabIndex == 0 && _selectedOrderId != null)
        ? null
        : _bottomNavigation(),
  );
}
