import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_controller.dart';
import '../services/store_access_service.dart';
import 'widgets/app_toast.dart';

class HelperMePage extends StatefulWidget {
  const HelperMePage({
    super.key,
    required this.controller,
    required this.onLogout,
    this.locationName,
    this.storeAccessSettings,
  });

  final InventoryController controller;
  final String? locationName;
  final StoreAccessSettings? storeAccessSettings;
  final VoidCallback onLogout;

  @override
  State<HelperMePage> createState() => _HelperMePageState();
}

class _HelperMePageState extends State<HelperMePage> {
  static const _ink = Color(0xFF211F1D);
  static const _muted = Color(0xFF756D67);
  static const _border = Color(0xFFE3DED7);
  static const _orange = Color(0xFFC83D08);

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  StreamSubscription<CurrentUserProfileSnapshot?>? _profileSubscription;
  bool _savingProfile = false;
  bool _savingPassword = false;
  String? _profileError;
  String? _passwordError;
  CurrentUserProfileSnapshot? _loadedProfile;

  @override
  void initState() {
    super.initState();
    _applyProfile(widget.controller.currentUserProfileSnapshot);
    _profileSubscription = widget.controller.currentUserProfileSnapshots.listen(
      (profile) {
        if (!mounted || profile == null) return;
        if (profile.id != widget.controller.currentUserId) return;
        if (_savingProfile || !_profileIsDirty) {
          setState(() => _applyProfile(profile));
        }
      },
    );
    if (_loadedProfile == null) unawaited(_refreshProfile());
  }

  bool get _profileIsDirty {
    final profile = _loadedProfile;
    if (profile == null) return false;
    return _name.text.trim() != profile.name ||
        _phone.text.trim() != (profile.phone ?? '') ||
        _email.text.trim() != (profile.email ?? '');
  }

  void _applyProfile(CurrentUserProfileSnapshot? profile) {
    if (profile == null) {
      _name.text = widget.controller.currentUserName ?? '';
      _email.text = widget.controller.loggedInUserEmail ?? '';
      return;
    }
    _loadedProfile = profile;
    _name.text = profile.name;
    _phone.text = profile.phone ?? '';
    _email.text = profile.email ?? '';
  }

  Future<void> _refreshProfile() async {
    try {
      final profile = await widget.controller.refreshCurrentUserProfile();
      if (mounted && !_profileIsDirty && profile != null) {
        setState(() => _applyProfile(profile));
      }
    } catch (_) {
      // The fields can still show the locally cached profile.
    }
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (_savingProfile) return;
    if (_loadedProfile == null) {
      setState(() => _profileError = 'Profile is still loading. Try again.');
      return;
    }
    final userId = widget.controller.currentUserId;
    if (userId == null || userId.isEmpty) {
      setState(() => _profileError = 'Your session has ended. Sign in again.');
      return;
    }
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty) {
      setState(() => _profileError = 'Enter your full name.');
      return;
    }
    if (email.isNotEmpty &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _profileError = 'Enter a valid work email.');
      return;
    }
    setState(() {
      _savingProfile = true;
      _profileError = null;
    });
    try {
      await widget.controller.updateProfile(
        userId: userId,
        name: name,
        email: email,
        location: _loadedProfile?.address ?? '',
        phone: _phone.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _loadedProfile = widget.controller.currentUserProfileSnapshot;
      });
      AppToast.success(context, 'Personal details saved.');
    } catch (_) {
      if (mounted) {
        setState(
          () => _profileError = 'Could not save your details. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  bool get _hasLength => _newPassword.text.length >= 8;
  bool get _hasUppercase => RegExp(r'[A-Z]').hasMatch(_newPassword.text);
  bool get _hasLowercase => RegExp(r'[a-z]').hasMatch(_newPassword.text);
  bool get _hasNumber => RegExp(r'[0-9]').hasMatch(_newPassword.text);
  bool get _hasSymbol =>
      RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(_newPassword.text);
  bool get _passwordsMatch =>
      _confirmPassword.text.isNotEmpty &&
      _confirmPassword.text == _newPassword.text;

  Future<void> _updatePassword() async {
    if (_savingPassword) return;
    if (_currentPassword.text.isEmpty) {
      setState(() => _passwordError = 'Enter your current password.');
      return;
    }
    if (!_hasLength ||
        !_hasUppercase ||
        !_hasLowercase ||
        !_hasNumber ||
        !_hasSymbol ||
        !_passwordsMatch) {
      setState(() => _passwordError = 'Check the new password requirements.');
      return;
    }
    setState(() {
      _savingPassword = true;
      _passwordError = null;
    });
    final result = await widget.controller.changePassword(
      _currentPassword.text,
      _newPassword.text,
    );
    if (!mounted) return;
    setState(() {
      _savingPassword = false;
      _passwordError = switch (result) {
        ChangePasswordResult.success => null,
        ChangePasswordResult.incorrectCurrentPassword =>
          'Current password is incorrect.',
        ChangePasswordResult.sameAsCurrentPassword =>
          'Choose a password you have not used here.',
        ChangePasswordResult.invalidNewPassword =>
          'The new password does not meet the requirements.',
        ChangePasswordResult.concurrentChange =>
          'Your password changed elsewhere. Re-enter your current password.',
        ChangePasswordResult.notAuthenticated =>
          'Your session has ended. Sign in again.',
        ChangePasswordResult.unexpectedFailure =>
          'Could not update your password. Try again.',
      };
      if (result == ChangePasswordResult.success) {
        _currentPassword.clear();
        _newPassword.clear();
        _confirmPassword.clear();
      }
    });
    if (result == ChangePasswordResult.success) {
      AppToast.success(context, 'Password updated.');
    }
  }

  String _initials(String name) => name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2)
      .map((part) => part[0].toUpperCase())
      .join();

  String _formatTime(String raw) {
    final parts = raw.split(':');
    final hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$hour12:${minute.toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
  }

  List<String> _scheduleLines(StoreAccessSettings settings) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final lines = <String>[];
    var start = 0;
    while (start < 7) {
      final hours = settings.hoursForWeekday(start + 1);
      var end = start;
      while (end + 1 < 7) {
        final next = settings.hoursForWeekday(end + 2);
        if (next.openingTime != hours.openingTime ||
            next.closingTime != hours.closingTime ||
            next.closed != hours.closed) {
          break;
        }
        end++;
      }
      final label = start == end ? days[start] : '${days[start]}–${days[end]}';
      lines.add(
        '$label · ${hours.closed ? 'Closed' : '${_formatTime(hours.openingTime)} – ${_formatTime(hours.closingTime)}'}',
      );
      start = end + 1;
    }
    return lines;
  }

  InputDecoration _decoration() => InputDecoration(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _orange),
    ),
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    TextInputType? keyboardType,
    bool obscure = false,
    ValueChanged<String>? onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 13, color: _ink)),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscure,
        onChanged: onChanged,
        decoration: _decoration(),
        style: const TextStyle(fontSize: 14, color: _ink),
      ),
    ],
  );

  Widget _passwordRule(String label, bool met) => Row(
    children: [
      Icon(
        met ? LucideIcons.circleCheck : LucideIcons.circle,
        size: 14,
        color: met ? const Color(0xFF16834D) : _muted,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: met ? const Color(0xFF16834D) : _muted,
            fontSize: 12,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final profile = _loadedProfile;
    final name = profile?.name ?? widget.controller.currentUserName ?? 'Helper';
    final location = widget.locationName;
    final settings = widget.storeAccessSettings;
    return ColoredBox(
      color: const Color(0xFFF6F5F2),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 30),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 34,
                backgroundColor: _ink,
                child: Text(
                  _initials(name),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      location == null
                          ? 'Order helper'
                          : 'Order helper · $location',
                      style: const TextStyle(fontSize: 13, color: _muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          const Divider(color: _border),
          const SizedBox(height: 12),
          const Text('Schedule', style: TextStyle(fontSize: 12, color: _muted)),
          const SizedBox(height: 5),
          if (settings == null)
            const Text(
              'Store hours unavailable',
              style: TextStyle(fontSize: 14, color: _ink),
            )
          else
            for (final line in _scheduleLines(settings))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  line,
                  style: const TextStyle(fontSize: 14, color: _ink),
                ),
              ),
          const SizedBox(height: 16),
          const Divider(color: _border),
          const SizedBox(height: 4),
          Text(
            settings?.restrictStaffLogin == true
                ? 'Role, location, and schedule are managed by your administrator. You can only sign in during scheduled hours.'
                : 'Role, location, and schedule are managed by your administrator.',
            style: const TextStyle(fontSize: 12, color: _muted, height: 1.4),
          ),
          const SizedBox(height: 30),
          const Text(
            'Personal details',
            style: TextStyle(
              fontSize: 17,
              color: _ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _field('Full name', _name)),
              const SizedBox(width: 16),
              Expanded(
                child: _field(
                  'Mobile number',
                  _phone,
                  keyboardType: TextInputType.phone,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _field(
            'Work email',
            _email,
            keyboardType: TextInputType.emailAddress,
          ),
          if (_profileError != null) ...[
            const SizedBox(height: 8),
            Text(
              _profileError!,
              style: const TextStyle(color: Color(0xFFB42318), fontSize: 12),
            ),
          ],
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton(
              onPressed: _savingProfile ? null : _saveProfile,
              style: ElevatedButton.styleFrom(
                backgroundColor: _ink,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 15,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: Text(_savingProfile ? 'Saving…' : 'Save changes'),
            ),
          ),
          const SizedBox(height: 30),
          const Divider(color: _border),
          const SizedBox(height: 26),
          const Text(
            'Change password',
            style: TextStyle(
              fontSize: 17,
              color: _ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),
          _field('Current password', _currentPassword, obscure: true),
          const SizedBox(height: 20),
          _field(
            'New password',
            _newPassword,
            obscure: true,
            onChanged: (_) => setState(() => _passwordError = null),
          ),
          const SizedBox(height: 20),
          _field(
            'Confirm new password',
            _confirmPassword,
            obscure: true,
            onChanged: (_) => setState(() => _passwordError = null),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _passwordRule('At least 8 characters', _hasLength),
              ),
              Expanded(child: _passwordRule('Contains a number', _hasNumber)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _passwordRule(
                  'Contains an uppercase letter',
                  _hasUppercase,
                ),
              ),
              Expanded(
                child: _passwordRule(
                  'Contains a lowercase letter',
                  _hasLowercase,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _passwordRule('Contains a symbol', _hasSymbol)),
              Expanded(
                child: _passwordRule('Passwords match', _passwordsMatch),
              ),
            ],
          ),
          if (_passwordError != null) ...[
            const SizedBox(height: 12),
            Text(
              _passwordError!,
              style: const TextStyle(color: Color(0xFFB42318), fontSize: 12),
            ),
          ],
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: _savingPassword ? null : _updatePassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: _orange,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: Text(_savingPassword ? 'Updating…' : 'Update password'),
            ),
          ),
          const SizedBox(height: 28),
          const Divider(color: _border),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: widget.onLogout,
            icon: const Icon(LucideIcons.logOut, size: 17),
            label: const Text('Sign out'),
            style: TextButton.styleFrom(foregroundColor: _muted),
          ),
        ],
      ),
    );
  }
}
