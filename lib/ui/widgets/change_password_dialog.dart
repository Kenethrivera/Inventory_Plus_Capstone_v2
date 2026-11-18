import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../logic/inventory_controller.dart';
import 'app_toast.dart';

enum _CurrentPasswordState { empty, pending, correct, incorrect }

Future<bool?> showChangePasswordDialog({
  required BuildContext context,
  required InventoryController controller,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => ChangePasswordDialog(controller: controller),
  );
}

class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({
    super.key,
    required this.controller,
    this.forced = false,
    this.onLogout,
  });

  final InventoryController controller;
  final bool forced;
  final Future<void> Function()? onLogout;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  static const Duration _verificationDebounce = Duration(milliseconds: 600);
  static const _brand = Color(0xFFC83D08);
  static const _brandDark = Color(0xFF9D320F);

  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  Timer? _verificationTimer;
  int _verificationGeneration = 0;
  _CurrentPasswordState _currentPasswordState = _CurrentPasswordState.empty;
  String? _lastValidatedCurrentPassword;
  _CurrentPasswordState? _lastValidationResult;
  String? _lastVerificationErrorValue;
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;
  bool _isLoggingOut = false;
  bool _domainNewPasswordInvalid = false;

  bool get _hasMinLength => _newPasswordController.text.length >= 8;
  bool get _hasUppercase =>
      _newPasswordController.text.contains(RegExp(r'[A-Z]'));
  bool get _hasLowercase =>
      _newPasswordController.text.contains(RegExp(r'[a-z]'));
  bool get _hasDigit => _newPasswordController.text.contains(RegExp(r'[0-9]'));
  bool get _hasSymbol =>
      _newPasswordController.text.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));

  bool get _meetsPolicy =>
      _hasMinLength &&
      _hasUppercase &&
      _hasLowercase &&
      _hasDigit &&
      _hasSymbol;

  int get _metCount => [
    _hasMinLength,
    _hasUppercase,
    _hasLowercase,
    _hasDigit,
    _hasSymbol,
  ].where((met) => met).length;

  bool get _currentPasswordIsVerified =>
      _currentPasswordState == _CurrentPasswordState.correct;

  bool get _differsFromVerifiedCurrent =>
      _currentPasswordIsVerified &&
      _newPasswordController.text != _currentPasswordController.text;

  bool get _newPasswordIsInvalid {
    final value = _newPasswordController.text;
    if (value.isEmpty) return false;
    if (_domainNewPasswordInvalid) return true;
    if (!_meetsPolicy) return true;
    return _currentPasswordIsVerified && !_differsFromVerifiedCurrent;
  }

  bool get _confirmPasswordIsInvalid {
    final value = _confirmPasswordController.text;
    return value.isNotEmpty && value != _newPasswordController.text;
  }

  bool get _canSubmit =>
      !_isSaving &&
      !_isLoggingOut &&
      _currentPasswordIsVerified &&
      _meetsPolicy &&
      _differsFromVerifiedCurrent &&
      _confirmPasswordController.text.isNotEmpty &&
      !_confirmPasswordIsInvalid;

  @override
  void dispose() {
    _verificationTimer?.cancel();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _onCurrentPasswordChanged(String value) {
    _verificationTimer?.cancel();
    final generation = ++_verificationGeneration;

    if (value.isEmpty) {
      setState(() => _currentPasswordState = _CurrentPasswordState.empty);
      return;
    }

    if (value == _lastValidatedCurrentPassword &&
        (_lastValidationResult == _CurrentPasswordState.correct ||
            _lastValidationResult == _CurrentPasswordState.incorrect)) {
      setState(() => _currentPasswordState = _lastValidationResult!);
      return;
    }

    setState(() => _currentPasswordState = _CurrentPasswordState.pending);
    _verificationTimer = Timer(
      _verificationDebounce,
      () => _verifyCurrentPassword(value, generation),
    );
  }

  Future<void> _verifyCurrentPassword(String value, int generation) async {
    final result = await widget.controller.verifyCurrentPassword(value);
    if (!mounted ||
        generation != _verificationGeneration ||
        _currentPasswordController.text != value) {
      return;
    }

    switch (result) {
      case CurrentPasswordVerificationResult.correct:
        setState(() {
          _currentPasswordState = _CurrentPasswordState.correct;
          _lastValidatedCurrentPassword = value;
          _lastValidationResult = _CurrentPasswordState.correct;
          _lastVerificationErrorValue = null;
        });
      case CurrentPasswordVerificationResult.incorrect:
        setState(() {
          _currentPasswordState = _CurrentPasswordState.incorrect;
          _lastValidatedCurrentPassword = value;
          _lastValidationResult = _CurrentPasswordState.incorrect;
          _lastVerificationErrorValue = null;
        });
      case CurrentPasswordVerificationResult.rateLimited:
        setState(() {
          _currentPasswordState = _CurrentPasswordState.empty;
          _lastValidatedCurrentPassword = null;
          _lastValidationResult = null;
        });
        _showVerificationErrorOnce(
          value,
          'Too many incorrect password attempts. Please try again later.',
        );
      case CurrentPasswordVerificationResult.notAuthenticated:
        setState(() => _currentPasswordState = _CurrentPasswordState.empty);
        _showVerificationErrorOnce(
          value,
          'Your session is no longer active. Please log in again.',
        );
      case CurrentPasswordVerificationResult.unexpectedFailure:
        setState(() => _currentPasswordState = _CurrentPasswordState.empty);
        _showVerificationErrorOnce(
          value,
          'Unable to verify your current password. Please try again.',
        );
    }
  }

  void _showVerificationErrorOnce(String value, String message) {
    if (_lastVerificationErrorValue == value) return;
    _lastVerificationErrorValue = value;
    AppToast.error(context, message);
  }

  void _onNewPasswordChanged(String _) {
    setState(() => _domainNewPasswordInvalid = false);
  }

  void _onConfirmPasswordChanged(String _) {
    setState(() {});
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;

    _verificationTimer?.cancel();
    setState(() => _isSaving = true);

    final result = await widget.controller.changePassword(
      _currentPasswordController.text,
      _newPasswordController.text,
    );
    if (!mounted) return;

    switch (result) {
      case ChangePasswordResult.success:
        final overlay = Overlay.of(context, rootOverlay: true);
        AppToast.showOn(overlay, 'Password changed successfully.');
        if (!widget.forced) Navigator.pop(context, true);
      case ChangePasswordResult.incorrectCurrentPassword:
        setState(() {
          _currentPasswordState = _CurrentPasswordState.incorrect;
          _lastValidatedCurrentPassword = _currentPasswordController.text;
          _lastValidationResult = _CurrentPasswordState.incorrect;
          _isSaving = false;
        });
      case ChangePasswordResult.sameAsCurrentPassword:
        setState(() {
          _currentPasswordState = _CurrentPasswordState.correct;
          _isSaving = false;
        });
        AppToast.error(
          context,
          'Your new password must be different from your current password.',
        );
      case ChangePasswordResult.invalidNewPassword:
        setState(() {
          _domainNewPasswordInvalid = true;
          _isSaving = false;
        });
      case ChangePasswordResult.concurrentChange:
        setState(() {
          _currentPasswordState = _CurrentPasswordState.empty;
          _lastValidatedCurrentPassword = null;
          _lastValidationResult = null;
          _isSaving = false;
        });
        AppToast.error(
          context,
          'Your password changed elsewhere. Re-enter your current password.',
        );
      case ChangePasswordResult.notAuthenticated:
        setState(() => _isSaving = false);
        AppToast.error(
          context,
          'Your session is no longer active. Please log in again.',
        );
      case ChangePasswordResult.unexpectedFailure:
        setState(() => _isSaving = false);
        AppToast.error(context, 'Unable to change password. Please try again.');
    }
  }

  Future<void> _logout() async {
    final onLogout = widget.onLogout;
    if (onLogout == null || _isSaving || _isLoggingOut) return;
    setState(() => _isLoggingOut = true);
    await onLogout();
    if (mounted) setState(() => _isLoggingOut = false);
  }

  OutlineInputBorder _fieldBorder({
    required bool invalid,
    required bool focused,
  }) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: invalid
          ? BorderSide(color: Colors.red.shade600, width: 1.5)
          : focused
          ? BorderSide(color: Colors.blue.shade400, width: 1)
          : BorderSide.none,
    );
  }

  InputDecoration _fieldDecoration({
    required String hint,
    required bool obscure,
    required bool invalid,
    required VoidCallback toggleVisibility,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
      prefixIcon: Icon(
        LucideIcons.lock,
        size: 18,
        color: invalid ? Colors.red.shade400 : Colors.blue.shade300,
      ),
      suffixIcon: IconButton(
        icon: Icon(
          obscure ? LucideIcons.eyeOff : LucideIcons.eye,
          size: 18,
          color: Colors.grey,
        ),
        onPressed: toggleVisibility,
      ),
      filled: true,
      fillColor: invalid
          ? Colors.red.shade50.withValues(alpha: 0.55)
          : Colors.blue.shade50.withValues(alpha: 0.3),
      border: _fieldBorder(invalid: invalid, focused: false),
      enabledBorder: _fieldBorder(invalid: invalid, focused: false),
      focusedBorder: _fieldBorder(invalid: invalid, focused: true),
    );
  }

  Widget _requirementRow(String label, bool? met) {
    final color = met == true
        ? Colors.blue.shade700
        : met == false
        ? Colors.red.shade600
        : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met == true
                ? Icons.check_circle
                : met == false
                ? Icons.cancel
                : Icons.circle_outlined,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: met == true ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions({required bool canDismiss}) {
    final secondaryAction = OutlinedButton(
      onPressed: canDismiss
          ? () => Navigator.pop(context, false)
          : widget.forced && !_isSaving && !_isLoggingOut
          ? _logout
          : null,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        side: BorderSide(
          color: widget.forced ? Colors.red.shade200 : Colors.blue.shade200,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _isLoggingOut
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              widget.forced ? 'Logout' : 'Back',
              style: TextStyle(
                color: widget.forced
                    ? Colors.red.shade700
                    : Colors.blue.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
    final primaryAction = ElevatedButton(
      onPressed: _canSubmit ? _submit : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _isSaving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            )
          : Text(
              widget.forced ? 'Update Password' : 'Update',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          return Column(
            children: [
              SizedBox(width: double.infinity, child: primaryAction),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: secondaryAction),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: secondaryAction),
            const SizedBox(width: 12),
            Expanded(child: primaryAction),
          ],
        );
      },
    );
  }

  Widget _forcedRequirementRow(String label, bool met) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 15,
            color: met ? Colors.white : Colors.white.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: met ? 1 : 0.75),
                fontSize: 12,
                fontWeight: met ? FontWeight.w700 : FontWeight.w400,
                fontFamily: 'Outfit',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _forcedCompactRequirementRow(String label, bool met) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 14,
            color: met ? const Color(0xFF15803D) : const Color(0xFF817A75),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF675A52),
                fontSize: 11,
                fontFamily: 'Outfit',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForcedInfoPanel({bool compact = false}) {
    return Container(
      color: _brandDark,
      padding: EdgeInsets.all(compact ? 24 : 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Icon(LucideIcons.lockKeyhole, color: _brand, size: 23),
          ),
          SizedBox(height: compact ? 16 : 30),
          Text(
            'Reset password',
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 24 : 30,
              fontWeight: FontWeight.w800,
              fontFamily: 'Outfit',
            ),
          ),
          SizedBox(height: compact ? 8 : 14),
          Text(
            'Your password was reset by an administrator. Enter the temporary password, then set a new one.',
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 13 : 16,
              height: 1.55,
              fontFamily: 'Outfit',
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 50),
            Row(
              children: [
                Container(
                  width: 31,
                  height: 31,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.white),
                    shape: BoxShape.circle,
                  ),
                  child: const Text(
                    '3',
                    style: TextStyle(
                      color: _brandDark,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Set new password',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'YOUR PASSWORD NEEDS',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                fontFamily: 'Outfit',
              ),
            ),
            const SizedBox(height: 10),
            _forcedRequirementRow('At least 8 characters', _hasMinLength),
            _forcedRequirementRow('One uppercase letter (A-Z)', _hasUppercase),
            _forcedRequirementRow('One lowercase letter (a-z)', _hasLowercase),
            _forcedRequirementRow('One number (0-9)', _hasDigit),
            _forcedRequirementRow('One symbol (!@#\$%^&*)', _hasSymbol),
            _forcedRequirementRow(
              'Different from temporary password',
              _differsFromVerifiedCurrent,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildForcedStrengthMeter() {
    const labels = ['', 'Weak', 'Weak', 'Fair', 'Almost there', 'Strong'];
    final met = _metCount;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: List.generate(5, (index) {
              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: index < 4 ? 4 : 0),
                  height: 4,
                  decoration: BoxDecoration(
                    color: index < met ? _brand : const Color(0xFFF1EAE4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 78,
          child: Text(
            labels[met],
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: _brand,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'Outfit',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForcedField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool obscure,
    required ValueChanged<String> onChanged,
    required VoidCallback toggleVisibility,
    bool invalid = false,
  }) {
    final borderColor = invalid
        ? const Color(0xFFDC2626)
        : const Color(0xFFD8D0C9);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: 'Outfit',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey(label),
          controller: controller,
          obscureText: obscure,
          enabled: !_isSaving && !_isLoggingOut,
          onChanged: onChanged,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 14,
            fontFamily: 'Outfit',
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              color: Color(0xFF9A948E),
              fontFamily: 'Outfit',
            ),
            prefixIcon: Icon(icon, color: const Color(0xFF817A75), size: 18),
            suffixIcon: IconButton(
              icon: Icon(
                obscure ? LucideIcons.eyeOff : LucideIcons.eye,
                color: const Color(0xFF817A75),
                size: 18,
              ),
              onPressed: toggleVisibility,
            ),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: invalid ? borderColor : _brand,
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ],
    );
  }

  Widget _buildForcedFormPanel({bool compact = false}) {
    final currentInvalid =
        _currentPasswordState == _CurrentPasswordState.incorrect;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 24 : 50,
        24,
        compact ? 24 : 50,
        42,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 46),
          const Text(
            'SET NEW PASSWORD',
            style: TextStyle(
              color: Color(0xFF675A52),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Set new password',
            style: TextStyle(
              color: Color(0xFF171717),
              fontSize: 25,
              fontWeight: FontWeight.w800,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 30),
          _buildForcedField(
            controller: _currentPasswordController,
            label: 'Temporary password',
            hint: 'Enter temporary password',
            icon: LucideIcons.lock,
            obscure: _obscureCurrent,
            invalid: currentInvalid,
            onChanged: _onCurrentPasswordChanged,
            toggleVisibility: () =>
                setState(() => _obscureCurrent = !_obscureCurrent),
          ),
          if (_currentPasswordState != _CurrentPasswordState.empty) ...[
            const SizedBox(height: 8),
            Text(
              switch (_currentPasswordState) {
                _CurrentPasswordState.pending =>
                  'Verifying temporary password…',
                _CurrentPasswordState.correct => 'Temporary password verified.',
                _CurrentPasswordState.incorrect =>
                  'Incorrect temporary password.',
                _CurrentPasswordState.empty => '',
              },
              style: TextStyle(
                color: currentInvalid
                    ? const Color(0xFFB42318)
                    : _currentPasswordIsVerified
                    ? const Color(0xFF15803D)
                    : const Color(0xFF756D67),
                fontSize: 12,
                fontFamily: 'Outfit',
              ),
            ),
          ],
          const SizedBox(height: 20),
          _buildForcedField(
            controller: _newPasswordController,
            label: 'New password',
            hint: 'Min. 8 characters',
            icon: LucideIcons.lock,
            obscure: _obscureNew,
            invalid:
                _domainNewPasswordInvalid ||
                (_currentPasswordIsVerified &&
                    _newPasswordController.text.isNotEmpty &&
                    !_differsFromVerifiedCurrent),
            onChanged: _onNewPasswordChanged,
            toggleVisibility: () => setState(() => _obscureNew = !_obscureNew),
          ),
          const SizedBox(height: 10),
          _buildForcedStrengthMeter(),
          if (compact) ...[
            const SizedBox(height: 10),
            _forcedCompactRequirementRow(
              'At least 8 characters',
              _hasMinLength,
            ),
            _forcedCompactRequirementRow(
              'Uppercase and lowercase letters',
              _hasUppercase && _hasLowercase,
            ),
            _forcedCompactRequirementRow(
              'One number and one symbol',
              _hasDigit && _hasSymbol,
            ),
            _forcedCompactRequirementRow(
              'Different from temporary password',
              _differsFromVerifiedCurrent,
            ),
          ],
          const SizedBox(height: 18),
          _buildForcedField(
            controller: _confirmPasswordController,
            label: 'Confirm new password',
            hint: 'Re-enter new password',
            icon: LucideIcons.lockKeyhole,
            obscure: _obscureConfirm,
            invalid: _confirmPasswordIsInvalid,
            onChanged: _onConfirmPasswordChanged,
            toggleVisibility: () =>
                setState(() => _obscureConfirm = !_obscureConfirm),
          ),
          if (_confirmPasswordIsInvalid) ...[
            const SizedBox(height: 8),
            const Text(
              'Passwords do not match.',
              style: TextStyle(
                color: Color(0xFFB42318),
                fontSize: 12,
                fontFamily: 'Outfit',
              ),
            ),
          ],
          const SizedBox(height: 40),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 14,
            runSpacing: 10,
            children: [
              OutlinedButton(
                onPressed: widget.onLogout == null || _isSaving || _isLoggingOut
                    ? null
                    : _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF171717),
                  side: const BorderSide(color: Color(0xFFD8D0C9)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                ),
                child: _isLoggingOut
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'Logout',
                        style: TextStyle(
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              ElevatedButton(
                onPressed: _canSubmit ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 30,
                    vertical: 16,
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Update password',
                        style: TextStyle(
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildForcedPasswordDialog(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final wide = screenWidth >= 960;
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: EdgeInsets.all(screenWidth < 600 ? 12 : 20),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wide ? 900 : min(560.0, screenWidth - 24),
        ),
        child: SingleChildScrollView(
          child: wide
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 375, child: _buildForcedInfoPanel()),
                      Expanded(child: _buildForcedFormPanel()),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildForcedInfoPanel(compact: true),
                    _buildForcedFormPanel(compact: true),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.forced) {
      return PopScope(
        canPop: false,
        child: _buildForcedPasswordDialog(context),
      );
    }
    final newPasswordHasInput = _newPasswordController.text.isNotEmpty;
    final currentInvalid =
        _currentPasswordState == _CurrentPasswordState.incorrect;
    final canDismiss = !widget.forced && !_isSaving && !_isLoggingOut;

    return PopScope(
      canPop: canDismiss,
      child: AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: EdgeInsets.all(widget.forced ? 28 : 24),
        content: SingleChildScrollView(
          child: SizedBox(
            width: widget.forced ? 420 : 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.all(widget.forced ? 14 : 12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(
                      widget.forced ? 14 : 12,
                    ),
                  ),
                  child: Icon(
                    widget.forced
                        ? LucideIcons.shieldCheck
                        : LucideIcons.keyRound,
                    color: Colors.blue.shade600,
                    size: widget.forced ? 28 : 24,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.forced ? 'Password update required' : 'New Password',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.forced
                      ? 'Your password was reset by an administrator. Create '
                            'a new password before continuing.'
                      : 'Choose a new password for your account',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Colors.grey.shade600,
                  ),
                ),
                if (widget.forced) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          LucideIcons.info,
                          size: 18,
                          color: Color(0xFF2563EB),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Administrator reset detected',
                                style: TextStyle(
                                  color: Color(0xFF1E3A8A),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Use the temporary password provided by your '
                                'administrator as your current password.',
                                style: TextStyle(
                                  color: Colors.blue.shade800,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                const Text(
                  'Current Password',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _currentPasswordController,
                  obscureText: _obscureCurrent,
                  onChanged: _onCurrentPasswordChanged,
                  decoration: _fieldDecoration(
                    hint: widget.forced
                        ? 'Enter temporary password'
                        : 'Enter current password',
                    obscure: _obscureCurrent,
                    invalid: currentInvalid,
                    toggleVisibility: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'New Password',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _newPasswordController,
                  obscureText: _obscureNew,
                  onChanged: _onNewPasswordChanged,
                  decoration: _fieldDecoration(
                    hint: 'Min. 8 characters',
                    obscure: _obscureNew,
                    invalid: _newPasswordIsInvalid,
                    toggleVisibility: () =>
                        setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Password requirements',
                        style: TextStyle(
                          color: Color(0xFF334155),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _requirementRow(
                        'At least 8 characters',
                        newPasswordHasInput ? _hasMinLength : null,
                      ),
                      _requirementRow(
                        'At least one uppercase letter (A-Z)',
                        newPasswordHasInput ? _hasUppercase : null,
                      ),
                      _requirementRow(
                        'At least one lowercase letter (a-z)',
                        newPasswordHasInput ? _hasLowercase : null,
                      ),
                      _requirementRow(
                        'At least one number (0-9)',
                        newPasswordHasInput ? _hasDigit : null,
                      ),
                      _requirementRow(
                        'At least one special symbol (!@#\$%^&*)',
                        newPasswordHasInput ? _hasSymbol : null,
                      ),
                      _requirementRow(
                        'Different from current password',
                        _currentPasswordIsVerified && newPasswordHasInput
                            ? _differsFromVerifiedCurrent
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Confirm Password',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureConfirm,
                  onChanged: _onConfirmPasswordChanged,
                  decoration: _fieldDecoration(
                    hint: 'Re-enter new password',
                    obscure: _obscureConfirm,
                    invalid: _confirmPasswordIsInvalid,
                    toggleVisibility: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
                const SizedBox(height: 24),
                _buildActions(canDismiss: canDismiss),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
