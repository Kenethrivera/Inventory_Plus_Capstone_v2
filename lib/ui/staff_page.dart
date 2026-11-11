import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_controller.dart';
import '../logic/staff_management.dart';
import '../logic/staff_performance.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import '../services/staff_presence_service.dart';
import 'staff_performance_page.dart';
import 'widgets/app_toast.dart';

const _background = Color(0xFFF7F6F4);
const _ink = Color(0xFF171717);
const _muted = Color(0xFF817A75);
const _line = Color(0xFFE6E1DC);
const _orange = Color(0xFFC83D08);
const _green = Color(0xFF15803D);
const _red = Color(0xFFDC2626);

class StaffPage extends StatefulWidget {
  const StaffPage({
    super.key,
    required this.controller,
    required this.isActive,
    this.presence,
  });

  final InventoryController controller;
  final bool isActive;
  final StaffPresenceService? presence;

  @override
  State<StaffPage> createState() => _StaffPageState();
}

class _StaffPageState extends State<StaffPage> {
  List<Map<String, dynamic>> _staff = const [];
  final _search = TextEditingController();
  String _role = 'all';
  bool _showPerformance = false;
  bool _loading = true;
  String? _error;
  StaffPerformanceSnapshot? _cashierToday;
  StaffPerformanceSnapshot? _helperToday;
  StreamSubscription<List<Map<String, dynamic>>>? _staffSubscription;
  StreamSubscription<void>? _performanceSubscription;
  int _metricsGeneration = 0;

  @override
  void initState() {
    super.initState();
    _bind();
    _search.addListener(_rebuild);
    widget.presence?.addListener(_rebuild);
    if (widget.isActive) unawaited(_loadToday());
  }

  void _bind() {
    _staffSubscription = widget.controller.streamStaffConfiguration().listen(
      (rows) {
        if (!mounted) return;
        setState(() {
          _staff = rows;
          _loading = false;
          _error = widget.controller.staffConfigurationLoadFailed
              ? 'Could not load staff. Try again.'
              : null;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          'Staff list load failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (mounted)
          setState(() {
            _loading = false;
            _error = 'Could not load staff. Try again.';
          });
      },
    );
    _performanceSubscription = widget.controller.staffPerformanceInvalidations
        .listen((_) {
          if (widget.isActive) unawaited(_loadToday(force: true));
        });
  }

  @override
  void didUpdateWidget(covariant StaffPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(_staffSubscription?.cancel());
      unawaited(_performanceSubscription?.cancel());
      _staff = const [];
      _loading = true;
      _cashierToday = null;
      _helperToday = null;
      _bind();
    }
    if (oldWidget.presence != widget.presence) {
      oldWidget.presence?.removeListener(_rebuild);
      widget.presence?.addListener(_rebuild);
    }
    if ((!oldWidget.isActive && widget.isActive) ||
        oldWidget.controller != widget.controller) {
      unawaited(_loadToday(force: true));
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadToday({bool force = false}) async {
    final generation = ++_metricsGeneration;
    final controller = widget.controller;
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    try {
      final results = await Future.wait([
        controller.loadStaffPerformance(
          role: StaffPerformanceRole.cashiers,
          periodStart: start,
          periodEnd: end,
          forceRefresh: force,
        ),
        controller.loadStaffPerformance(
          role: StaffPerformanceRole.helpers,
          periodStart: start,
          periodEnd: end,
          forceRefresh: force,
        ),
      ]);
      if (!mounted ||
          generation != _metricsGeneration ||
          controller != widget.controller)
        return;
      setState(() {
        _cashierToday = results[0];
        _helperToday = results[1];
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Staff today metrics failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _metricsGeneration++;
    unawaited(_staffSubscription?.cancel());
    unawaited(_performanceSubscription?.cancel());
    widget.presence?.removeListener(_rebuild);
    _search.removeListener(_rebuild);
    _search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filtered {
    final query = _search.text.trim().toLowerCase();
    return _staff
        .where((person) {
          final role = person['role']?.toString().toLowerCase() ?? 'staff';
          if (_role != 'all' && role != _role) return false;
          if (query.isEmpty) return true;
          return (person['name']?.toString().toLowerCase().contains(query) ??
                  false) ||
              (person['email']?.toString().toLowerCase().contains(query) ??
                  false) ||
              (person['username']?.toString().toLowerCase().contains(query) ??
                  false);
        })
        .toList(growable: false)
      ..sort((a, b) => _sortStaff(a, b));
  }

  int _sortStaff(Map<String, dynamic> a, Map<String, dynamic> b) {
    final aRole = a['role']?.toString() ?? '';
    final bRole = b['role']?.toString() ?? '';
    if (aRole == 'admin' && bRole != 'admin') return -1;
    if (bRole == 'admin' && aRole != 'admin') return 1;
    return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
  }

  Widget _buildPageHeader(int online) => LayoutBuilder(
    builder: (context, limits) {
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Staff',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${_staff.length} accounts · $online online now',
            style: const TextStyle(fontSize: 14, color: _muted),
          ),
        ],
      );
      final add = FilledButton.icon(
        onPressed: () => _openEditor(),
        style: FilledButton.styleFrom(
          backgroundColor: _orange,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
        icon: const Icon(LucideIcons.userRoundPlus, size: 17),
        label: const Text('Add staff'),
      );
      return limits.maxWidth < 620
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 16), add],
            )
          : Row(
              children: [
                Expanded(child: heading),
                add,
              ],
            );
    },
  );

  Widget _buildViewTabs() => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _line)),
    ),
    child: LayoutBuilder(
      builder: (context, limits) {
        final compact = limits.maxWidth < 420;
        return Row(
          children: [
            _viewTab('Staff list', showPerformance: false, compact: compact),
            _viewTab('Performance', showPerformance: true, compact: compact),
          ],
        );
      },
    ),
  );

  Widget _viewTab(
    String label, {
    required bool showPerformance,
    bool compact = false,
  }) {
    final selected = _showPerformance == showPerformance;
    return InkWell(
      onTap: selected
          ? null
          : () => setState(() => _showPerformance = showPerformance),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          compact ? 8 : 14,
          12,
          compact ? 8 : 14,
          13,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? _orange : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _ink : _muted,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.presence?.activeStaff.length ?? 0;
    final rows = _filtered;
    if (_showPerformance) {
      return ColoredBox(
        color: _background,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPageHeader(online),
                    const SizedBox(height: 28),
                    _buildViewTabs(),
                  ],
                ),
              ),
              Expanded(
                child: StaffPerformancePage(
                  controller: widget.controller,
                  isActive: widget.isActive,
                  embedded: true,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ColoredBox(
      color: _background,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPageHeader(online),
              const SizedBox(height: 28),
              _buildViewTabs(),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, limits) => Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: min(400, limits.maxWidth),
                      height: 44,
                      child: TextField(
                        controller: _search,
                        style: const TextStyle(fontSize: 14),
                        decoration: _inputDecoration('Search name or email')
                            .copyWith(
                              prefixIcon: const Icon(
                                LucideIcons.search,
                                size: 18,
                                color: _muted,
                              ),
                            ),
                      ),
                    ),
                    _roleFilter(),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (_loading && _staff.isEmpty)
                const SizedBox(
                  height: 260,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null && _staff.isEmpty)
                Center(
                  child: Column(
                    children: [
                      Text(_error!),
                      TextButton(onPressed: _retry, child: const Text('Retry')),
                    ],
                  ),
                )
              else if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: Text('No staff match your search.')),
                )
              else
                LayoutBuilder(
                  builder: (context, limits) => limits.maxWidth < 900
                      ? Column(children: rows.map(_mobileCard).toList())
                      : _table(rows),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleFilter() {
    const roles = [
      ('all', 'All roles'),
      ('admin', 'Administrator'),
      ('staff', 'Cashier'),
      ('helper', 'Order helper'),
    ];
    final selectedLabel = roles.firstWhere((role) => role.$1 == _role).$2;

    return SizedBox(
      width: 180,
      height: 44,
      child: PopupMenuButton<String>(
        tooltip: 'Filter staff by role',
        position: PopupMenuPosition.under,
        offset: const Offset(0, 6),
        padding: EdgeInsets.zero,
        menuPadding: const EdgeInsets.symmetric(vertical: 5),
        constraints: const BoxConstraints(minWidth: 180, maxWidth: 180),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shadowColor: const Color(0x33000000),
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _line),
        ),
        onSelected: (value) => setState(() => _role = value),
        itemBuilder: (context) => [
          for (final role in roles)
            PopupMenuItem<String>(
              value: role.$1,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: _role == role.$1
                      ? const Color(0xFFFFF1E9)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        role.$2,
                        style: TextStyle(
                          color: _role == role.$1 ? _orange : _ink,
                          fontSize: 13,
                          fontWeight: _role == role.$1
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (_role == role.$1)
                      const Icon(LucideIcons.check, size: 16, color: _orange),
                  ],
                ),
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selectedLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _ink, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(LucideIcons.chevronDown, size: 16, color: _muted),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.controller.fetchStaff();
      if (mounted)
        setState(() {
          _staff = rows;
          _loading = false;
        });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Staff retry failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Could not load staff. Try again.';
        });
    }
  }

  Widget _table(List<Map<String, dynamic>> rows) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(14),
    ),
    clipBehavior: Clip.antiAlias,
    child: Table(
      columnWidths: const {
        0: FlexColumnWidth(2.2),
        1: FlexColumnWidth(1.05),
        2: FlexColumnWidth(1.5),
        3: FlexColumnWidth(1.05),
        4: FlexColumnWidth(1.45),
        5: FlexColumnWidth(0.85),
        6: FixedColumnWidth(160),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: const BoxDecoration(color: _background),
          children: [
            for (final label in [
              'Staff',
              'Role',
              'Home address',
              'Availability',
              'Today',
              'Account',
              'Actions',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Text(
                  label,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ),
          ],
        ),
        for (final person in rows)
          TableRow(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _line)),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: _identity(person),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _roleLabel(person['role']?.toString()),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _homeAddress(person),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: _availability(person),
              ),
              Padding(padding: const EdgeInsets.all(16), child: _today(person)),
              Padding(
                padding: const EdgeInsets.all(16),
                child: _status(person),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: _actions(person),
              ),
            ],
          ),
      ],
    ),
  );

  Widget _mobileCard(Map<String, dynamic> person) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _identity(person),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _roleLabel(person['role']?.toString()),
              style: const TextStyle(fontSize: 13),
            ),
            _availability(person),
            _status(person),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _homeAddress(person),
          style: const TextStyle(fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 10),
        _today(person),
        Align(alignment: Alignment.centerRight, child: _actions(person)),
      ],
    ),
  );

  Widget _identity(Map<String, dynamic> person) {
    final name = person['name']?.toString() ?? 'Staff';
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: const Color(0xFFFFF1E8),
          child: Text(
            _initials(name),
            style: const TextStyle(
              color: _orange,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                person['email']?.toString().isNotEmpty == true
                    ? person['email'].toString()
                    : person['username']?.toString() ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _availability(Map<String, dynamic> person) {
    final id = person['id']?.toString() ?? '';
    final online =
        widget.presence?.activeStaff.any(
          (row) => row['user_id']?.toString() == id,
        ) ??
        false;
    final helper = person['role']?.toString() == 'helper';
    final record = _findRecord(_helperToday, id);
    final busy = online && helper && (record?.currentWorkload ?? 0) > 0;
    final label = online
        ? busy
              ? 'Busy'
              : 'Available'
        : 'Offline';
    final color = online
        ? busy
              ? const Color(0xFF1D4ED8)
              : _green
        : _muted;
    return _pill(label, color);
  }

  Widget _today(Map<String, dynamic> person) {
    final role = person['role']?.toString();
    if (role == 'admin')
      return const Text(
        'Administrator',
        style: TextStyle(color: _muted, fontSize: 12),
      );
    final record = _findRecord(
      role == 'helper' ? _helperToday : _cashierToday,
      person['id']?.toString() ?? '',
    );
    if (record == null)
      return const Text('—', style: TextStyle(color: _muted, fontSize: 12));
    final primary = role == 'helper'
        ? '${record.completedCount} handled'
        : '${record.completedCount} orders';
    final secondary = role == 'helper'
        ? '${record.averageMinutes == null ? '—' : '${record.averageMinutes!.round()} min'} avg · ${record.currentWorkload} active'
        : _money(record.salesHandled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          primary,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(secondary, style: const TextStyle(color: _muted, fontSize: 12)),
      ],
    );
  }

  StaffPerformanceRecord? _findRecord(
    StaffPerformanceSnapshot? snapshot,
    String id,
  ) {
    if (snapshot == null) return null;
    for (final record in snapshot.records) {
      if (record.employeeId == id) return record;
    }
    return null;
  }

  Widget _status(Map<String, dynamic> person) {
    final active = person['is_active'] != false;
    return _pill(active ? 'Active' : 'Disabled', active ? _green : _red);
  }

  Widget _actions(Map<String, dynamic> person) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Edit ${person['name']}',
        onPressed: () => _openEditor(person),
        icon: const Icon(LucideIcons.pencil, size: 17, color: _ink),
      ),
      IconButton(
        tooltip: 'Reset password for ${person['name']}',
        onPressed: () => _resetPassword(person),
        icon: const Icon(LucideIcons.keyRound, size: 17, color: _ink),
      ),
      IconButton(
        tooltip: person['is_active'] == false
            ? 'Enable ${person['name']}'
            : 'Disable ${person['name']}',
        onPressed: person['id']?.toString() == widget.controller.currentUserId
            ? null
            : () => _toggleActive(person),
        icon: Icon(
          person['is_active'] == false
              ? LucideIcons.rotateCcw
              : LucideIcons.circleOff,
          size: 17,
          color: person['is_active'] == false ? _green : _red,
        ),
      ),
    ],
  );

  Future<void> _openEditor([Map<String, dynamic>? person]) async {
    final result = await showDialog<_StaffEditorResult>(
      context: context,
      barrierColor: Colors.black26,
      builder: (context) =>
          _StaffEditor(controller: widget.controller, person: person),
    );
    if (!mounted || result == null) return;
    if (result.password != null) {
      await _showIssuedPassword(result.name, result.password!);
    } else {
      AppToast.success(context, 'Staff account updated.');
    }
    unawaited(_loadToday(force: true));
  }

  Future<void> _toggleActive(Map<String, dynamic> person) async {
    final active = person['is_active'] != false;
    final name = person['name']?.toString() ?? 'this staff member';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: const TextStyle(
          color: _ink,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(
          color: _muted,
          fontSize: 14,
          height: 1.4,
        ),
        title: Text('${active ? 'Disable' : 'Enable'} account?'),
        content: Text(
          active
              ? '$name will be signed out and unable to sign in. Their history is kept.'
              : '$name will be able to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: _muted),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: active ? _red : _orange,
            ),
            child: Text(active ? 'Disable' : 'Enable'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final saved = await widget.controller.updateStaffAccount(
        id: person['id'].toString(),
        name: name,
        email: person['email']?.toString() ?? '',
        phone: person['phone']?.toString() ?? '',
        address: person['address']?.toString() ?? '',
        role: person['role']?.toString() ?? 'staff',
        isActive: !active,
      );
      if (!mounted) return;
      if (saved)
        AppToast.success(
          context,
          active ? 'Account disabled.' : 'Account enabled.',
        );
      else
        AppToast.error(context, 'Could not change this account.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Staff status update failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted)
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
    }
  }

  Future<void> _resetPassword(Map<String, dynamic> person) async {
    final name = person['name']?.toString() ?? 'this staff member';
    final mustChange = roleRequiresForcedPasswordChange(
      person['role']?.toString(),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Reset password?',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$name will be signed out everywhere.${mustChange ? ' They must choose their own password after signing in.' : ''}',
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: _muted,
                  ),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _orange),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Reset password'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final password = generateStaffPassword(
      name: name,
      role: person['role']?.toString() ?? 'staff',
    );
    if (password.isEmpty) {
      AppToast.error(
        context,
        'Add a staff name before resetting the password.',
      );
      return;
    }
    try {
      final saved = await widget.controller.adminResetUserPassword(
        person['id'].toString(),
        password,
      );
      if (!mounted) return;
      if (saved)
        await _showIssuedPassword(name, password);
      else
        AppToast.error(context, 'Could not reset the password.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Staff password reset failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted)
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
    }
  }

  Future<void> _showIssuedPassword(
    String name,
    String password,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titleTextStyle: const TextStyle(
        color: _ink,
        fontSize: 19,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: const TextStyle(
        color: _muted,
        fontSize: 14,
        height: 1.4,
      ),
      title: const Text('Password issued'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Share this with $name in person.'),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _background,
              border: Border.all(color: _line),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SelectableText(
                  password,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: password));
                    if (context.mounted)
                      AppToast.success(context, 'Password copied.');
                  },
                  icon: const Icon(LucideIcons.copy, size: 16),
                  label: const Text('Copy'),
                  style: TextButton.styleFrom(foregroundColor: _orange),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: _orange),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _StaffEditorResult {
  const _StaffEditorResult(this.name, this.password);
  final String name;
  final String? password;
}

class _StaffEditor extends StatefulWidget {
  const _StaffEditor({required this.controller, this.person});
  final InventoryController controller;
  final Map<String, dynamic>? person;

  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late String _role;
  late bool _active;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final person = widget.person;
    _name = TextEditingController(text: person?['name']?.toString() ?? '');
    _username = TextEditingController(
      text: person?['username']?.toString() ?? '',
    );
    _email = TextEditingController(text: person?['email']?.toString() ?? '');
    _phone = TextEditingController(text: person?['phone']?.toString() ?? '');
    _address = TextEditingController(
      text: person?['address']?.toString() ?? '',
    );
    _role = person?['role']?.toString() ?? 'staff';
    _active = person?['is_active'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      if (widget.person == null) {
        final password = generateStaffPassword(name: _name.text, role: _role);
        final result = await widget.controller.createStaff(
          name: _name.text.trim(),
          username: _username.text.trim(),
          password: password,
          role: _role,
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          address: _address.text.trim(),
        );
        if (!mounted) return;
        if (!result.success) {
          setState(() => _saveError = _creationError(result.failure));
          return;
        }
        Navigator.pop(context, _StaffEditorResult(_name.text.trim(), password));
      } else {
        final saved = await widget.controller.updateStaffAccount(
          id: widget.person!['id'].toString(),
          name: _name.text.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          address: _address.text.trim(),
          role: _role,
          isActive: _active,
        );
        if (!mounted) return;
        if (!saved) {
          setState(
            () => _saveError =
                'Could not save changes. Check account permissions.',
          );
          return;
        }
        Navigator.pop(context, _StaffEditorResult(_name.text.trim(), null));
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Staff save failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted)
        setState(
          () => _saveError = AppErrorMapper.message(
            error,
            fallback: AppErrorCategory.dataSave,
          ),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.person != null;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final width = screenWidth >= 1200
        ? screenWidth / 3
        : min(520.0, screenWidth * .96);
    return Dialog(
      alignment: Alignment.centerRight,
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: SizedBox(
        key: const Key('staff-editor-panel'),
        width: width,
        height: MediaQuery.sizeOf(context).height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 18, 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          editing
                              ? 'Edit ${widget.person!['name']}'
                              : 'Add staff',
                          style: const TextStyle(
                            fontSize: 18,
                            color: _ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (editing)
                          Text(
                            widget.person!['email']?.toString() ?? '',
                            style: const TextStyle(color: _muted, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, size: 19),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _line),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _field('Full name', _name, required: true),
                      const SizedBox(height: 18),
                      if (!editing) ...[
                        _field('Username', _username, required: true),
                        const SizedBox(height: 18),
                      ],
                      _field('Work email', _email, email: true),
                      const SizedBox(height: 18),
                      _field('Mobile', _phone),
                      const SizedBox(height: 18),
                      _field('Home address', _address),
                      const SizedBox(height: 22),
                      const Text(
                        'Role',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, limits) {
                          final stacked = limits.maxWidth < 380;
                          final buttons = _roleButtons(stacked: stacked);
                          return stacked
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: buttons,
                                )
                              : Row(
                                  children: buttons
                                      .map((button) => Expanded(child: button))
                                      .toList(),
                                );
                        },
                      ),
                      if (editing) ...[
                        const SizedBox(height: 28),
                        const Divider(color: _line),
                        const SizedBox(height: 12),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Account active',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: const Text(
                            'Disabled accounts cannot sign in. Their history is kept.',
                            style: TextStyle(fontSize: 12),
                          ),
                          activeTrackColor: _orange,
                          value: _active,
                          onChanged:
                              widget.person!['id']?.toString() ==
                                  widget.controller.currentUserId
                              ? null
                              : (value) => setState(() => _active = value),
                        ),
                      ],
                      if (_saveError != null) ...[
                        const SizedBox(height: 18),
                        Text(
                          _saveError!,
                          style: const TextStyle(color: _red, fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: _line),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: _orange),
                    child: Text(
                      _saving
                          ? 'Saving…'
                          : editing
                          ? 'Save changes'
                          : 'Add staff',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool required = false,
    bool email = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: _ink,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 7),
      TextFormField(
        controller: controller,
        style: const TextStyle(fontSize: 14),
        keyboardType: email ? TextInputType.emailAddress : TextInputType.text,
        decoration: _inputDecoration(null),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (required && text.isEmpty) return '$label is required.';
          if (email &&
              text.isNotEmpty &&
              !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text))
            return 'Enter a valid email address.';
          return null;
        },
      ),
    ],
  );

  List<Widget> _roleButtons({bool stacked = false}) => [
    for (final entry in const [
      ('admin', 'Administrator'),
      ('staff', 'Cashier'),
      ('helper', 'Order helper'),
    ])
      Padding(
        padding: EdgeInsets.only(right: stacked ? 0 : 8, bottom: 8),
        child: OutlinedButton(
          onPressed:
              widget.person?['id']?.toString() ==
                      widget.controller.currentUserId &&
                  entry.$1 != 'admin'
              ? null
              : () => setState(() => _role = entry.$1),
          style: OutlinedButton.styleFrom(
            backgroundColor: _role == entry.$1
                ? const Color(0xFFFFF0E8)
                : Colors.white,
            foregroundColor: _role == entry.$1 ? _orange : _ink,
            side: BorderSide(color: _role == entry.$1 ? _orange : _line),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 9),
          ),
          child: Text(
            entry.$2,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
  ];
}

InputDecoration _inputDecoration(String? hint) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: Color(0xFFA9A29E), fontSize: 13),
  filled: true,
  fillColor: Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(9),
    borderSide: const BorderSide(color: _line),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(9),
    borderSide: const BorderSide(color: _line),
  ),
);

Widget _pill(String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .09),
    border: Border.all(color: color.withValues(alpha: .22)),
    borderRadius: BorderRadius.circular(7),
  ),
  child: Text(
    label,
    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
  ),
);

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : ''))
      .toUpperCase();
}

String _roleLabel(String? role) => switch (role) {
  'admin' => 'Administrator',
  'helper' => 'Order helper',
  _ => 'Cashier',
};

String _homeAddress(Map<String, dynamic> person) {
  final address = person['address']?.toString().trim() ?? '';
  return address.isEmpty ? '—' : address;
}

String _money(double value) => '₱${value.toStringAsFixed(2)}';

String _creationError(StaffCreationFailure? failure) => switch (failure) {
  StaffCreationFailure.duplicateUsername => 'That username is already in use.',
  StaffCreationFailure.duplicateEmail => 'That email is already in use.',
  StaffCreationFailure.duplicatePhone => 'That phone number is already in use.',
  StaffCreationFailure.unauthorized => 'You are not authorized to add staff.',
  _ => 'Could not create staff. Please try again.',
};
