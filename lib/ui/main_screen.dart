import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';

// Your UI Pages
import 'profile_info_page.dart';
import 'inventory_page.dart';
import 'item_detail_page.dart';
import 'dashboard_page.dart';
import 'pos_cart_page.dart';
import 'order_queue_page.dart';
import 'transaction_history_page.dart';
import 'system_settings_page.dart';
import 'map_editor_page.dart';
import '../services/export_reminder_service.dart';
import '../services/export_period.dart';
import '../services/debug_clock.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'forecasting_page.dart';

class MainScreen extends StatefulWidget {
  final InventoryController controller;
  const MainScreen({super.key, required this.controller});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int? _currentIndex;
  bool _isDetailView = false;
  InventoryItem? _selectedItem;
  String _txTargetTab = 'Sales History';
  String? _targetOrderId;
  
  // --- THEME PALETTE ---
  static const Color _primaryBlue = Color(0xFF2563EB);
  static const Color _sidebarBg = Colors.white;
  static const Color _mainBg = Color(0xFFF4F6F8);
  static const Color _darkText = Color(0xFF0F172A);
  static const Color _inactiveText = Color(0xFF64748B);
  static const String _fontFam = 'Hellix';

  bool _inventoryExportDue = false;
  bool _salesExportDue = false;

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
                await widget.controller.updateItem(updatedItem);
                if (mounted) setState(() {});
              },
              onDelete: (id) async {
                await widget.controller.deleteItem(id);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) setState(() {});
              },
              onStatusChanged: () {
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
      );
    } else {
      setState(() {
        _selectedItem = item;
        _isDetailView = true;
      });
    }
  }

  void _handleBackToMain() {
    setState(() {
      _isDetailView = false;
      _selectedItem = null;
    });
  }

  Future<void> _debugClearExportLog() async {
    final locId = widget.controller.activeLocationId;
    if (locId == null) return;
    final service = ExportReminderService(
      supabase: widget.controller.supabase,
      locationId: locId,
    );
    await service.clearExportLog();
    await _checkExportReminders();
  }

  @override
  void initState() {
    super.initState();
    _checkExportReminders();
  }

  Future<void> _checkExportReminders() async {
    final locId = widget.controller.activeLocationId;
    if (locId == null) return;

    final service = ExportReminderService(
      supabase: widget.controller.supabase,
      locationId: locId,
    );

    final results = await Future.wait([
      service.dueReminders('inventory'),
      service.dueReminders('sales'),
    ]);

    if (!mounted) return;
    setState(() {
      _inventoryExportDue = results[0].isNotEmpty;
      _salesExportDue = results[1].isNotEmpty;
    });
  }

  Future<void> _handleUpdateItem(InventoryItem item) async {
    await widget.controller.updateItem(item);
    if (mounted) {
      setState(() {
        _selectedItem = item;
      });
    }
  }

  Future<void> _handleDeleteItem(String id) async {
    await widget.controller.deleteItem(id);
    if (!mounted) return;
    setState(() {
      _isDetailView = false;
      _selectedItem = null;
    });
  }

  Widget _debugClockButton() {
    return FloatingActionButton.small(
      backgroundColor: DebugClock.isOverridden ? Colors.red : Colors.grey,
      onPressed: _showDebugClockDialog,
      child: const Icon(Icons.schedule, color: Colors.white),
    );
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
                      'Sunday 5:01 PM (week due)',
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
                onPressed: () async {
                  await _debugClearExportLog();
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: const Text(
                  'Clear export log',
                  style: TextStyle(color: Colors.red),
                ),
              ),
              TextButton(
                onPressed: () {
                  DebugClock.set(null);
                  Navigator.pop(dialogContext);
                  setState(() {});
                  _checkExportReminders();
                },
                child: const Text('Reset to real time'),
              ),
              ElevatedButton(
                onPressed: () {
                  DebugClock.set(picked);
                  Navigator.pop(dialogContext);
                  setState(() {});
                  _checkExportReminders();
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

    if (_isDetailView && _selectedItem != null) {
      return ItemDetailPage(
        item: _selectedItem!,
        controller: widget.controller,
        onBack: _handleBackToMain,
        onUpdate: _handleUpdateItem,
        onDelete: _handleDeleteItem,
        onStatusChanged: () {
          if (mounted) setState(() {});
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 600;
        final role = widget.controller.currentUserRole?.toLowerCase() ?? 'staff';
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
        final int transactionIndex = isAdmin ? pageIndex++ : -1;
        final int mapIndex = isAdmin ? pageIndex++ : -1;
        final int systemSettingsIndex = isAdmin ? pageIndex++ : -1;

        final pages = <Widget>[];

        if (isAdmin) {
          pages.add(
            DashboardPage(
              controller: widget.controller,
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
          pages.add(ForecastingPage(controller: widget.controller));
        }

        if (isCashier || isAdmin) {
          pages.add(PosCartPage(controller: widget.controller));
        }

        if (isHelper || isAdmin) {
          pages.add(
            OrderQueuePage(
              controller: widget.controller,
              targetOrderId: _targetOrderId,
              onOrderOpened: () {
                if (mounted) setState(() => _targetOrderId = null);
              },
            ),
          );
        }

        pages.add(
          InventoryPage(
            controller: widget.controller,
            onSelectItem: _handleSelectItem,
            exportDue: _inventoryExportDue,
            onExported: () => setState(() => _inventoryExportDue = false),
          ),
        );

        if (isAdmin) {
          pages.add(
            TransactionHistoryPage(
              controller: widget.controller,
              initialTab: _txTargetTab,
              exportDue: _salesExportDue,
              onExported: () => setState(() => _salesExportDue = false),
              onCompleteOrder: (orderId) {
                setState(() {
                  _targetOrderId = orderId;
                  _currentIndex = orderQueueIndex;
                });
              },
            ),
          );
          pages.add(MapEditorPage(controller: widget.controller));
          pages.add(SystemSettingsPage(controller: widget.controller));
        }

        // ══════════════════════════════════════════════════════════════════════
        // 1. HELPER & CASHIER DESKTOP VIEW (Top Navigation Header)
        // ══════════════════════════════════════════════════════════════════════
        if ((isHelper || isCashier) && isDesktop) {
          if (_currentIndex! > 1) _currentIndex = 0;

          return Scaffold(
            backgroundColor: _mainBg,
            body: Column(
              children: [
                _buildTopNavBar(isHelper: isHelper),
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: pages, // Since Cashier/Helper only have 2 pages max in the array
                  ),
                ),
              ],
            ),
            floatingActionButton: kReleaseMode ? null : _debugClockButton(),
          );
        }

        // ══════════════════════════════════════════════════════════════════════
        // 2. ADMIN DESKTOP VIEW (Left Sidebar Navigation)
        // ══════════════════════════════════════════════════════════════════════
        if (isDesktop) {
          return Scaffold(
            backgroundColor: _mainBg,
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 250,
                  decoration: BoxDecoration(
                    color: _sidebarBg,
                    border: Border(
                      right: BorderSide(color: Colors.grey.shade200),
                    ),
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
                                  horizontal: 24.0,
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
                                      child: const Icon(LucideIcons.package, color: Colors.white, size: 18),
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
                              ),
                              if (isAdmin)
                                _buildSidebarItem(
                                  dashboardIndex,
                                  LucideIcons.layoutDashboard,
                                  'Dashboard',
                                ),
                              if (isAdmin)
                                _buildSidebarItem(
                                  forecastingIndex,
                                  LucideIcons.trendingUp,
                                  'Forecasting',
                                ),
                              if (isAdmin)
                                _buildSidebarItem(
                                  posIndex,
                                  LucideIcons.shoppingCart,
                                  'POS System',
                                ),
                              if (isAdmin)
                                _buildSidebarItem(
                                  orderQueueIndex,
                                  LucideIcons.fileText,
                                  'Order Queue',
                                ),
                              _buildSidebarItem(
                                inventoryIndex,
                                LucideIcons.box,
                                'Inventory',
                                showDot: _inventoryExportDue,
                              ),
                              if (isAdmin)
                                _buildSidebarItem(
                                  transactionIndex,
                                  LucideIcons.history,
                                  'Transactions',
                                  showDot: _salesExportDue,
                                ),
                              if (isAdmin)
                                _buildSidebarItem(
                                  mapIndex,
                                  LucideIcons.map,
                                  'Store Map',
                                ),
                              if (isAdmin)
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
                ),
                Expanded(
                  child: IndexedStack(index: _currentIndex, children: pages),
                ),
              ],
            ),
            floatingActionButton: kReleaseMode ? null : _debugClockButton(),
          );
        }

        // ══════════════════════════════════════════════════════════════════════
        // 3. MOBILE VIEW (Bottom Navigation)
        // ══════════════════════════════════════════════════════════════════════
        return Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            toolbarHeight: 70,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
            titleSpacing: 0,
            title: _buildProfileTile(),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1.0),
              child: Container(
                color: Colors.grey.shade200,
                height: 1.0,
              ),
            ),
          ),
          body: IndexedStack(index: _currentIndex, children: pages),
          bottomNavigationBar: NavigationBarTheme(
            data: NavigationBarThemeData(
              indicatorColor: _primaryBlue.withOpacity(0.1),
              labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((
                Set<WidgetState> states,
              ) {
                if (states.contains(WidgetState.selected)) {
                  return const TextStyle(
                    color: _primaryBlue,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    fontFamily: _fontFam,
                  );
                }
                return const TextStyle(color: _inactiveText, fontSize: 12, fontFamily: _fontFam);
              }),
            ),
            child: NavigationBar(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              selectedIndex: _currentIndex!,
              onDestinationSelected: (index) {
                setState(() {
                  _currentIndex = index;
                });
                _checkExportReminders();
              },
              destinations: [
                if (isAdmin)
                  const NavigationDestination(
                    icon: Icon(LucideIcons.layoutDashboard, color: _inactiveText),
                    selectedIcon: Icon(LucideIcons.layoutDashboard, color: _primaryBlue),
                    label: 'Dashboard',
                  ),
                if (isAdmin)
                  const NavigationDestination(
                    icon: Icon(LucideIcons.trendingUp, color: _inactiveText),
                    selectedIcon: Icon(
                      LucideIcons.trendingUp,
                      color: _primaryBlue,
                    ),
                    label: 'Forecasting',
                  ),
                if (isCashier || isAdmin)
                  const NavigationDestination(
                    icon: Icon(
                      LucideIcons.shoppingCart,
                      color: _inactiveText,
                    ),
                    selectedIcon: Icon(
                      LucideIcons.shoppingCart,
                      color: _primaryBlue,
                    ),
                    label: 'POS',
                  ),
                if (isHelper || isAdmin)
                  const NavigationDestination(
                    icon: Icon(LucideIcons.fileText, color: _inactiveText),
                    selectedIcon: Icon(LucideIcons.fileText, color: _primaryBlue),
                    label: 'Queue',
                  ),
                NavigationDestination(
                  icon: _navIcon(
                    LucideIcons.box,
                    _inactiveText,
                    _inventoryExportDue,
                  ),
                  selectedIcon: _navIcon(
                    LucideIcons.box,
                    _primaryBlue,
                    _inventoryExportDue,
                  ),
                  label: 'Inventory',
                ),
                if (isAdmin)
                  NavigationDestination(
                    icon: _navIcon(
                      LucideIcons.history,
                      _inactiveText,
                      _salesExportDue,
                    ),
                    selectedIcon: _navIcon(
                      LucideIcons.history,
                      _primaryBlue,
                      _salesExportDue,
                    ),
                    label: 'History',
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
          ),
        );
      },
    );
  }

  // ─── TOP NAVIGATION BAR (For Cashier & Helper) ───────────────
  Widget _buildTopNavBar({required bool isHelper}) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          // App Logo
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _primaryBlue,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(LucideIcons.package, color: Colors.white, size: 18),
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

          // Stream for pending badge (Safe to run for both, only visual for Helper)
          StreamBuilder<List<CustomerOrder>>(
            stream: widget.controller.streamOrders(),
            builder: (context, snapshot) {
              final pendingCount = snapshot.hasData
                  ? snapshot.data!.where((o) => o.status == 'pending').length
                  : 0;

              return Row(
                children: [
                  if (isHelper)
                    _buildTopNavTabItem(
                      index: 0,
                      icon: LucideIcons.fileText,
                      label: "Order queue",
                      badgeCount: pendingCount,
                    )
                  else
                    _buildTopNavTabItem(
                      index: 0,
                      icon: LucideIcons.shoppingCart,
                      label: "POS System",
                    ),
                  
                  const SizedBox(width: 24),
                  
                  _buildTopNavTabItem(
                    index: 1,
                    icon: LucideIcons.box,
                    label: "Inventory",
                  ),
                ],
              );
            },
          ),

          const Spacer(),

          // Profile Chip
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
              ? const Border(
                  bottom: BorderSide(color: _primaryBlue, width: 3),
                )
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
                  "$badgeCount",
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

  Widget _buildTopProfileChip() {
    final name = widget.controller.currentUserName ?? "User";
    final initial = name.isNotEmpty ? name[0].toUpperCase() : "U";

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
                  "On shift",
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
              icon: const Icon(LucideIcons.logOut, size: 16, color: Colors.redAccent),
              onPressed: _handleLogout,
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _navIcon(IconData icon, Color color, bool showDot) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, color: color),
        if (showDot)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
      ],
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
            currentName: widget.controller.currentUserName ?? "Unknown",
            currentEmail: widget.controller.loggedInUserEmail,
            userId: widget.controller.currentUserId ?? "",
            role: widget.controller.currentUserRole ?? "staff",
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarItem(
    int index,
    IconData icon,
    String label, {
    bool showDot = false,
  }) {
    final isSelected = _currentIndex == index;
    final contentColor = isSelected ? _primaryBlue : _inactiveText;
    final bgColor = isSelected ? _primaryBlue.withOpacity(0.08) : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() => _currentIndex = index);
            _checkExportReminders();
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
                Text(
                  label,
                  style: TextStyle(
                    color: contentColor,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    fontSize: 15,
                    fontFamily: _fontFam,
                  ),
                ),
                if (showDot) ...[
                  const Spacer(),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileTile() {
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
                  widget.controller.currentUserName?[0].toUpperCase() ?? 'U',
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
                      widget.controller.currentUserName ?? "Unknown User",
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
                      "ID: ${widget.controller.currentUserId}",
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
                icon: const Icon(LucideIcons.logOut, color: Colors.redAccent, size: 20),
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
            child: const Text('Log Out', style: TextStyle(color: Colors.white, fontFamily: _fontFam)),
          ),
        ],
        child: const Text("You'll need to sign in again to continue."),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (e) {
      if (mounted) AppToast.error(context, 'Could not log out: $e');
    }
  }
}