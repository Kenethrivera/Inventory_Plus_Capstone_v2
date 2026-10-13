import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _darkText = Color(0xFF0F172A);
const Color _mutedText = Color(0xFF64748B);
const String _fontFam = 'Hellix';

class ActiveStaffButton extends StatefulWidget {
  final SupabaseClient supabase;
  final String locationId;

  const ActiveStaffButton({
    super.key,
    required this.supabase,
    required this.locationId,
  });

  @override
  State<ActiveStaffButton> createState() => _ActiveStaffButtonState();
}

class _ActiveStaffButtonState extends State<ActiveStaffButton> {
  final LayerLink _layerLink = LayerLink();

  OverlayEntry? _overlayEntry;
  Timer? _refreshTimer;

  List<Map<String, dynamic>> _activeStaff = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadActiveStaff();

    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _loadActiveStaff();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  Future<void> _loadActiveStaff() async {
    try {
      final staffResponse = await widget.supabase
          .from('profiles')
          .select('id, name, role, location_id')
          .eq('location_id', widget.locationId)
          .inFilter('role', ['staff', 'helper'])
          .order('role', ascending: true)
          .order('name', ascending: true);

      final presenceResponse = await widget.supabase
          .from('staff_presence')
          .select()
          .eq('location_id', widget.locationId);

      final staffRows = List<Map<String, dynamic>>.from(staffResponse);
      final presenceRows = List<Map<String, dynamic>>.from(presenceResponse);

      final presenceByUserId = {
        for (final row in presenceRows) row['user_id'].toString(): row,
      };

      final merged = staffRows.map((staff) {
        final userId = staff['id'].toString();
        final presence = presenceByUserId[userId];

        return {
          'user_id': userId,
          'user_name': staff['name']?.toString() ?? 'Unknown Staff',
          'user_role': staff['role']?.toString() ?? 'staff',
          'current_module': presence?['current_module'],
          'is_online': presence?['is_online'] == true,
          'last_seen_at': presence?['last_seen_at'],
          'logged_in_at': presence?['logged_in_at'],
          'logged_out_at': presence?['logged_out_at'],
        };
      }).toList();

      if (!mounted) return;

      setState(() {
        _activeStaff = merged;
        _isLoading = false;
      });

      _overlayEntry?.markNeedsBuild();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _activeStaff = [];
        _isLoading = false;
      });

      _overlayEntry?.markNeedsBuild();
    }
  }

  List<Map<String, dynamic>> get _cashiers {
    return _activeStaff.where((user) {
      final role = user['user_role']?.toString().toLowerCase() ?? '';
      return role == 'staff' || role == 'cashier';
    }).toList();
  }

  List<Map<String, dynamic>> get _helpers {
    return _activeStaff.where((user) {
      final role = user['user_role']?.toString().toLowerCase() ?? '';
      return role == 'helper';
    }).toList();
  }

  int get _activeCount {
    return _activeStaff.where(_isActuallyActive).length;
  }

  void _toggleOverlay() {
    if (_overlayEntry == null) {
      _showOverlay();
    } else {
      _removeOverlay();
    }
  }

  void _showOverlay() {
    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _removeOverlay,
                child: Container(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.bottomRight,
              offset: const Offset(0, -14),
              child: Material(color: Colors.transparent, child: _buildPanel()),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          FloatingActionButton(
            heroTag: 'active_staff_button',
            backgroundColor: _primaryBlue,
            foregroundColor: Colors.white,
            elevation: 8,
            onPressed: _toggleOverlay,
            child: const Icon(LucideIcons.users, size: 22),
          ),
          if (_activeCount > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Text(
                  _activeCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      width: 360,
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.16),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(),
          const Divider(height: 1),
          Flexible(
            child: _isLoading
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: CircularProgressIndicator(color: _primaryBlue),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        _buildStaffSection(
                          title: 'Active Cashiers',
                          icon: LucideIcons.monitor,
                          users: _cashiers,
                          emptyMessage: 'No cashier is active right now.',
                        ),
                        const SizedBox(height: 16),
                        _buildStaffSection(
                          title: 'Active Helpers',
                          icon: LucideIcons.clipboardList,
                          users: _helpers,
                          emptyMessage: 'No helper is active right now.',
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _primaryBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(LucideIcons.users, color: _primaryBlue, size: 19),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active Staff',
                  style: TextStyle(
                    color: _darkText,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Currently online in the system',
                  style: TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _removeOverlay,
            icon: const Icon(LucideIcons.x, color: _mutedText, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildStaffSection({
    required String title,
    required IconData icon,
    required List<Map<String, dynamic>> users,
    required String emptyMessage,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: _primaryBlue),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: _darkText,
                fontSize: 14,
                fontWeight: FontWeight.w900,
                fontFamily: _fontFam,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _primaryBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                users.where(_isActuallyActive).length.toString(),
                style: const TextStyle(
                  color: _primaryBlue,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (users.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              emptyMessage,
              style: const TextStyle(
                color: _mutedText,
                fontSize: 12,
                fontFamily: _fontFam,
              ),
            ),
          )
        else
          ...users.map(_buildStaffTile),
      ],
    );
  }

  Widget _buildStaffTile(Map<String, dynamic> user) {
    final name = user['user_name']?.toString() ?? 'Unknown Staff';
    final role = user['user_role']?.toString().toUpperCase() ?? 'STAFF';
    final module = user['current_module']?.toString() ?? 'In system';
    final isActuallyActive = _isActuallyActive(user);
    final lastSeenText = _lastSeenText(user['last_seen_at'], isActuallyActive);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: _primaryBlue.withOpacity(0.12),
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: _primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
              if (isActuallyActive)
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _darkText,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  module,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                role,
                style: const TextStyle(
                  color: _primaryBlue,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  fontFamily: _fontFam,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                lastSeenText,
                style: const TextStyle(
                  color: _mutedText,
                  fontSize: 10,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _isActuallyActive(Map<String, dynamic> user) {
    if (user['is_online'] != true) return false;

    final value = user['last_seen_at'];
    if (value == null) return false;

    try {
      final date = DateTime.parse(value.toString()).toLocal();
      final diff = DateTime.now().difference(date);

      return diff.inMinutes < 2;
    } catch (_) {
      return false;
    }
  }

  String _lastSeenText(dynamic value, bool isOnline) {
    if (value == null) {
      return 'Never active';
    }

    try {
      final date = DateTime.parse(value.toString()).toLocal();
      final diff = DateTime.now().difference(date);

      if (isOnline && diff.inSeconds < 60) {
        return 'Active now';
      }

      if (isOnline && diff.inMinutes < 2) {
        return '${diff.inMinutes}m ago';
      }

      return 'Last seen ${_formatClockTime(date)}';
    } catch (_) {
      return isOnline ? 'Active now' : 'Last seen unknown';
    }
  }

  String _formatClockTime(DateTime date) {
    final hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');

    final suffix = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;

    return '$hour12:$minute $suffix';
  }
}
