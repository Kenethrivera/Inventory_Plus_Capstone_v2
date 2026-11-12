import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:async';
import 'dart:math';
import '../login/auth_service.dart';
import '../login/session_storage.dart';
import '../logic/inventory_controller.dart';
import '../navigation/main_section.dart';
import '../services/store_access_service.dart';
import '../services/staff_presence_service.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import 'widgets/app_toast.dart';
import 'package:flutter/services.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});
  final InventoryController controller;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _brand = Color(0xFFC83D08);
  static const _brandDark = Color(0xFF9D320F);
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  String? _loginError;
  Timer? _loginLimitTimer;
  int _loginRetryAfterSeconds = 0;
  String? _limitedNormalizedUsername;

  bool get _isLoginLimited =>
      _loginRetryAfterSeconds > 0 &&
      _limitedNormalizedUsername == _usernameController.text.trim();

  @override
  void initState() {
    super.initState();
    // Add listeners to trigger rebuilds for the focus/unfocus fill color changes
    _usernameFocusNode.addListener(() => setState(() {}));
    _passwordFocusNode.addListener(() => setState(() {}));
    _usernameController.addListener(_handleUsernameChanged);
    _passwordController.addListener(_handlePasswordChanged);
  }

  @override
  void dispose() {
    _loginLimitTimer?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (_isLoading || _isLoginLimited) return;
    if (_loginError != null) setState(() => _loginError = null);
    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    setState(() => _isLoading = true);
    String? issuedSessionToken;

    try {
      final userProfile = await _authService.login(username, password);

      if (userProfile == null) {
        _showLoginError(AppErrorMapper.invalidCredentials);
        return;
      }

      final String? assignedLocationId = userProfile['location_id'];
      final String userId = userProfile['id'].toString();
      final String userName = userProfile['name'] ?? username;
      final String userRole = (userProfile['role'] ?? 'staff').toString();
      final String? userEmail = userProfile['email'];
      final String? sessionToken = userProfile['session_token']?.toString();
      issuedSessionToken = sessionToken;

      if (assignedLocationId == null ||
          assignedLocationId.isEmpty ||
          sessionToken == null ||
          sessionToken.isEmpty) {
        if (sessionToken != null && sessionToken.isNotEmpty) {
          await _authService.logout(sessionToken);
        }
        _showLoginError(AppErrorMapper.permission);
        return;
      }

      final accessService = StoreAccessService(
        supabase: widget.controller.supabase,
        locationId: assignedLocationId,
      );

      final accessResult = await accessService.canLogin(role: userRole);

      if (!accessResult.allowed) {
        final reason =
            accessResult.reason ??
            'Staff login is not allowed outside store hours.';

        await StaffPresenceService.logBlockedLogin(
          supabase: widget.controller.supabase,
          locationId: assignedLocationId,
          userId: userId,
          userName: userName,
          userRole: userRole,
          reason: reason,
        );

        await _authService.logout(sessionToken);

        _showLoginError(reason);
        return;
      }

      await AppSessionStorage().persistLogin(
        sessionToken: sessionToken,
        userId: userId,
      );

      widget.controller.setLoggedInUser(
        name: userName,
        id: userId,
        role: userRole,
        email: userEmail,
        sessionToken: sessionToken,
      );

      widget.controller.setActiveLocation(assignedLocationId);

      if (mounted) {
        issuedSessionToken = null;
        Navigator.pushReplacementNamed(
          context,
          MainSection.defaultForRole(userRole).routePath,
          arguments: const AuthenticatedMainRoute(),
        );
      }
    } on LoginRateLimitedException catch (error) {
      final retryAfterSeconds = error.retryAfterSeconds;
      if (retryAfterSeconds == null) {
        _showLoginError(AppErrorMapper.loginRateLimited);
      } else {
        _startLoginLimitCountdown(username, retryAfterSeconds);
      }
      AppLogger.debug('Login temporarily limited after repeated failures');
    } catch (e, stackTrace) {
      final sessionToken = issuedSessionToken;
      if (sessionToken != null && sessionToken.isNotEmpty) {
        try {
          await _authService.logout(sessionToken);
        } catch (logoutError, logoutStackTrace) {
          AppLogger.error(
            'Failed to revoke the partially issued login session',
            error: logoutError,
            stackTrace: logoutStackTrace,
          );
        }
      }
      _showLoginError(AppErrorMapper.loginUnavailable);
      AppLogger.error('Login failed', error: e, stackTrace: stackTrace);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showLoginError(String message) {
    if (!mounted) return;
    setState(() => _loginError = message);
  }

  void _clearLoginError() {
    if (mounted && _loginError != null) setState(() => _loginError = null);
  }

  void _handleUsernameChanged() {
    final limitedUsername = _limitedNormalizedUsername;
    if (limitedUsername != null &&
        _usernameController.text.trim() != limitedUsername) {
      _clearLoginLimitCountdown();
      return;
    }
    if (!_isLoginLimited) _clearLoginError();
  }

  void _handlePasswordChanged() {
    if (!_isLoginLimited) _clearLoginError();
  }

  String _loginLimitMessage(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = (seconds % 60).toString().padLeft(2, '0');
    return 'Too many sign-in attempts. Try again in '
        '$minutes:$remainingSeconds.';
  }

  void _startLoginLimitCountdown(String normalizedUsername, int seconds) {
    if (!mounted || _usernameController.text.trim() != normalizedUsername) {
      return;
    }
    _loginLimitTimer?.cancel();
    setState(() {
      _limitedNormalizedUsername = normalizedUsername;
      _loginRetryAfterSeconds = seconds;
      _loginError = _loginLimitMessage(seconds);
    });
    _loginLimitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_usernameController.text.trim() != _limitedNormalizedUsername) {
        _clearLoginLimitCountdown();
        return;
      }
      final next = _loginRetryAfterSeconds - 1;
      if (next <= 0) {
        _clearLoginLimitCountdown();
        return;
      }
      setState(() {
        _loginRetryAfterSeconds = next;
        _loginError = _loginLimitMessage(next);
      });
    });
  }

  void _clearLoginLimitCountdown() {
    _loginLimitTimer?.cancel();
    _loginLimitTimer = null;
    if (!mounted) return;
    setState(() {
      _limitedNormalizedUsername = null;
      _loginRetryAfterSeconds = 0;
      _loginError = null;
    });
  }

  void _showForgotPasswordModal() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ForgotPasswordModal(),
    );
  }

  void _showPolicyDialog({required bool isPrivacy}) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xCC292420),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 12 : 24,
        ),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 18 : 24),
        ),
        child: SizedBox(
          width: 700,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 20 : 34,
                    compact ? 20 : 28,
                    compact ? 20 : 34,
                    compact ? 18 : 26,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: compact ? 44 : 54,
                        height: compact ? 44 : 54,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEEE5),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          isPrivacy
                              ? LucideIcons.shieldCheck
                              : LucideIcons.fileText,
                          color: _brand,
                          size: 23,
                        ),
                      ),
                      SizedBox(width: compact ? 12 : 18),
                      Expanded(
                        child: Text(
                          isPrivacy ? 'Privacy Policy' : 'Terms of Service',
                          style: TextStyle(
                            color: Color(0xFF171717),
                            fontSize: compact ? 20 : 25,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'Outfit',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(dialogContext),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFF5F3F1),
                          fixedSize: Size.square(compact ? 44 : 54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                        icon: const Icon(
                          LucideIcons.x,
                          color: Color(0xFF292522),
                          size: 19,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFEDE8E3)),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 20 : 34,
                    compact ? 24 : 30,
                    compact ? 20 : 34,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isPrivacy
                            ? 'Inventory Plus is committed to protecting your personal information.'
                            : 'By accessing and using Inventory Plus, you accept and agree to be bound by the terms and provisions of this agreement.',
                        style: TextStyle(
                          color: Color(0xFF171717),
                          fontSize: compact ? 17 : 20,
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                          fontFamily: 'Outfit',
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        isPrivacy
                            ? 'We process your data in accordance with the Data Privacy Act of 2012 (Republic Act No. 10173) of the Philippines.'
                            : 'Any participation in this service will constitute acceptance of this agreement.',
                        style: TextStyle(
                          color: Color(0xFF292522),
                          fontSize: compact ? 15 : 18,
                          height: 1.55,
                          fontFamily: 'Outfit',
                        ),
                      ),
                      const SizedBox(height: 22),
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(compact ? 16 : 20),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBF8F5),
                          border: Border.all(color: const Color(0xFFEDE6DF)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: isPrivacy
                            ? Text.rich(
                                const TextSpan(
                                  children: [
                                    TextSpan(
                                      text: 'How we use it: ',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    TextSpan(
                                      text:
                                          'We collect, use, and store your data solely for inventory management and system authentication purposes.',
                                    ),
                                  ],
                                ),
                                style: TextStyle(
                                  color: Color(0xFF292522),
                                  fontSize: compact ? 15 : 17,
                                  height: 1.5,
                                  fontFamily: 'Outfit',
                                ),
                              )
                            : Text(
                                'These terms are governed by the laws of the Republic of the Philippines.',
                                style: TextStyle(
                                  color: Color(0xFF292522),
                                  fontSize: compact ? 15 : 17,
                                  height: 1.5,
                                  fontFamily: 'Outfit',
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 20 : 34,
                    compact ? 32 : 48,
                    compact ? 20 : 34,
                    compact ? 20 : 30,
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 120,
                      height: 56,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: FilledButton.styleFrom(
                          backgroundColor: _brand,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text(
                          'Close',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'Outfit',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Welcome back',
            style: TextStyle(
              color: Color(0xFF171717),
              fontSize: 27,
              fontWeight: FontWeight.w800,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Sign in to manage your store.',
            style: TextStyle(
              color: Color(0xFF756F69),
              fontSize: 13,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 28),

          if (_loginError != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                border: Border.all(color: const Color(0xFFFECACA)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      LucideIcons.circleAlert,
                      color: Color(0xFFDC2626),
                      size: 17,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _loginError!,
                      style: const TextStyle(
                        color: Color(0xFF991B1B),
                        fontSize: 12.5,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Outfit',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          const Text(
            "Username",
            style: TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _usernameController,
            hint: "Enter your username",
            icon: LucideIcons.user,
            isPassword: false,
            focusNode: _usernameFocusNode,
            onSubmitted: (_) =>
                FocusScope.of(context).requestFocus(_passwordFocusNode),
          ),

          const SizedBox(height: 20),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Password',
                style: TextStyle(
                  color: Color(0xFF171717),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Outfit',
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _showForgotPasswordModal,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Forgot password?',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _brand,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Outfit',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _passwordController,
            hint: "Enter your password",
            icon: LucideIcons.lock,
            isPassword: true,
            focusNode: _passwordFocusNode,
            onSubmitted: _isLoginLimited ? null : (_) => _handleLogin(),
            suffix: IconButton(
              icon: Icon(
                _isPasswordVisible ? LucideIcons.eyeOff : LucideIcons.eye,
                color: Colors.grey.shade500,
                size: 18,
              ),
              onPressed: () =>
                  setState(() => _isPasswordVisible = !_isPasswordVisible),
            ),
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isLoading || _isLoginLimited ? null : _handleLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: _brand,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'Sign in',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Outfit',
                      ),
                    ),
            ),
          ),

          const SizedBox(height: 32),
          Divider(color: Colors.grey.shade200, height: 1),
          const SizedBox(height: 24),

          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showPolicyDialog(isPrivacy: false),
                child: Text(
                  "Terms of Service",
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                    fontFamily: 'Outfit',
                  ),
                ),
              ),
              Text(
                "   •   ",
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showPolicyDialog(isPrivacy: true),
                child: Text(
                  "Privacy Policy",
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                    fontFamily: 'Outfit',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7F5),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 800;
            return SingleChildScrollView(
              child: SizedBox(
                width: constraints.maxWidth,
                height: wide ? max(620.0, constraints.maxHeight) : null,
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _buildBrandPanel()),
                          Expanded(child: _buildLoginFormPanel(form)),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildBrandPanel(),
                          _buildLoginFormPanel(form),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBrandPanel() {
    final compact = MediaQuery.sizeOf(context).width < 800;
    return Container(
      color: _brandDark,
      padding: EdgeInsets.all(compact ? 24 : 40),
      child: Column(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(LucideIcons.box, color: _brand, size: 17),
              ),
              const SizedBox(width: 9),
              const Text(
                'Inventory Plus',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Outfit',
                ),
              ),
            ],
          ),
          if (compact) const SizedBox(height: 48) else const Spacer(),
          Text(
            'Every item, counted.\nEvery sale, tracked.',
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 25 : 34,
              fontWeight: FontWeight.w800,
              height: 1.08,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Stock, orders and payments for your hardware store\nin one place.',
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 12 : 14,
              height: 1.45,
              fontFamily: 'Outfit',
            ),
          ),
          if (compact) const SizedBox(height: 36) else const Spacer(),
          const Text(
            'Hardware Management System',
            style: TextStyle(
              color: Color(0xFFFFE7DA),
              fontSize: 11,
              fontFamily: 'Outfit',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginFormPanel(Widget form) {
    final compact = MediaQuery.sizeOf(context).width < 380;
    return Container(
      color: const Color(0xFFF8F7F5),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 20 : 32,
        vertical: compact ? 32 : 48,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390),
        child: form,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required bool isPassword,
    required FocusNode focusNode,
    ValueChanged<String>? onSubmitted,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: isPassword && !_isPasswordVisible,
      focusNode: focusNode,
      style: const TextStyle(
        color: Color(0xFF0F172A),
        fontSize: 14,
        fontFamily: 'Outfit',
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        if (text.isEmpty) {
          return isPassword ? 'Password is required' : 'Username is required';
        }
        if (isPassword && text.length < 6) {
          return 'Password must be at least 6 characters';
        }
        if (!isPassword && text.length < 3) {
          return 'Username must be at least 3 characters';
        }
        return null;
      },
      onFieldSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade400, fontFamily: 'Outfit'),
        prefixIcon: Icon(icon, color: Colors.grey.shade400, size: 18),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _brand, width: 1.5),
        ),
        errorStyle: const TextStyle(
          color: Colors.redAccent,
          fontSize: 12,
          fontFamily: 'Outfit',
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}

// ─── Forgot Password Modal (Updated for Light Theme) ─────────────────────────

// class ForgotPasswordModal extends StatefulWidget {
//   const ForgotPasswordModal({super.key});

//   @override
//   State<ForgotPasswordModal> createState() => _ForgotPasswordModalState();
// }

// class _ForgotPasswordModalState extends State<ForgotPasswordModal> {
//   final _authService = AuthService();
//   final _controller = TextEditingController();
//   final _confirmPasswordController = TextEditingController();

//   final _focusNode1 = FocusNode();
//   final _focusNode2 = FocusNode();

//   int _step = 0; // 0: username, 1: OTP, 2: new password
//   String? _email;
//   String? _generatedOtp;
//   bool _isLoading = false;
//   bool _obscurePassword = true;
//   bool _obscureConfirm = true;

//   final _stepTitles = ["Reset Password", "Enter OTP", "New Password"];
//   final _stepSubtitles = [
//     "Enter your admin username to receive an OTP",
//     "Enter the 6-digit code sent to your email",
//     "Choose a new password for your account",
//   ];

//   @override
//   void initState() {
//     super.initState();
//     _focusNode1.addListener(() => setState(() {}));
//     _focusNode2.addListener(() => setState(() {}));
//   }

//   @override
//   void dispose() {
//     _controller.dispose();
//     _confirmPasswordController.dispose();
//     _focusNode1.dispose();
//     _focusNode2.dispose();
//     super.dispose();
//   }

//   String _maskEmail(String? email) {
//     if (email == null || !email.contains('@')) return '';

//     final parts = email.split('@');
//     final username = parts[0];
//     final domain = parts[1];

//     if (username.isEmpty) return '*@$domain';
//     if (username.length <= 2) return '${username[0]}*@$domain';

//     final masked =
//         username[0] +
//         '*' * (username.length - 2) +
//         username[username.length - 1];

//     return '$masked@$domain';
//   }

//   Future<void> _nextStep() async {
//     final input = _controller.text.trim();
//     if (input.isEmpty) return;

//     setState(() => _isLoading = true);

//     try {
//       if (_step == 0) {
//         final isAdmin = await _authService.isAdminUser(input);
//         if (!isAdmin) {
//           if (mounted) {
//             Navigator.pop(context); // close forgot password modal
//             showDialog(
//               context: context,
//               builder: (context) => Dialog(
//                 backgroundColor: Colors.white,
//                 surfaceTintColor: Colors.transparent,
//                 shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//                 child: Container(
//                   width: 360,
//                   padding: const EdgeInsets.all(28),
//                   child: Column(
//                     mainAxisSize: MainAxisSize.min,
//                     children: [
//                       Container(
//                         padding: const EdgeInsets.all(16),
//                         decoration: BoxDecoration(
//                           color: Colors.blue.shade50,
//                           shape: BoxShape.circle,
//                         ),
//                         child: Icon(LucideIcons.userX, color: Colors.blue.shade600, size: 32),
//                       ),
//                       const SizedBox(height: 16),
//                       const Text("Contact Your Administrator",
//                           style: TextStyle(color: Color(0xFF0F172A), fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'Outfit')),
//                       const SizedBox(height: 8),
//                       Text(
//                         "Staff accounts cannot reset their password here. Please contact your admin to reset your password.",
//                         textAlign: TextAlign.center,
//                         style: TextStyle(color: Colors.grey.shade600, fontSize: 13, height: 1.5, fontFamily: 'Outfit'),
//                       ),
//                       const SizedBox(height: 24),
//                       SizedBox(
//                         width: double.infinity,
//                         child: ElevatedButton(
//                           onPressed: () => Navigator.pop(context),
//                           style: ElevatedButton.styleFrom(
//                             backgroundColor: const Color(0xFF2563EB),
//                             foregroundColor: Colors.white,
//                             shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
//                             elevation: 0,
//                             padding: const EdgeInsets.symmetric(vertical: 14),
//                           ),
//                           child: const Text("Got it", style: TextStyle(fontWeight: FontWeight.w600, fontFamily: 'Outfit')),
//                         ),
//                       ),
//                     ],
//                   ),
//                 ),
//               ),
//             );
//           }
//           return;
//         }

//         The retired implementation looked up contact details client-side.

//         It also generated and delivered verification codes in the client.

//         setState(() {
//           _email = email;
//           _generatedOtp = otp;
//           _step = 1;
//           _controller.clear();
//         });
//       } else if (_step == 1) {
//         if (input != _generatedOtp) throw "Invalid OTP. Please try again.";
//         setState(() {
//           _step = 2;
//           _controller.clear();
//         });
//       } else if (_step == 2) {
//         final confirm = _confirmPasswordController.text.trim();
//         if (input.length < 6) throw "Password must be at least 6 characters.";
//         if (input != confirm) throw "Passwords do not match.";

//         Password updates now remain behind the server-side recovery flow.

//         if (mounted) {
//           final overlay = Overlay.of(context, rootOverlay: true);
//           Navigator.pop(context);
//           AppToast.showOn(overlay, 'Password updated successfully!');
//         }
//       }
//     } catch (e) {
//       if (mounted) {
//         AppToast.error(context, e.toString().replaceFirst('Exception: ', ''));
//       }
//     } finally {
//       if (mounted) setState(() => _isLoading = false);
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Dialog(
//       backgroundColor: Colors.white,
//       surfaceTintColor: Colors.transparent,
//       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
//       child: Container(
//         width: 360,
//         padding: const EdgeInsets.all(32),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           crossAxisAlignment: CrossAxisAlignment.start,
//           children: [
//             // Header
//             Row(
//               children: [
//                 Container(
//                   padding: const EdgeInsets.all(10),
//                   decoration: BoxDecoration(
//                     color: Colors.blue.shade50,
//                     borderRadius: BorderRadius.circular(12),
//                   ),
//                   child: Icon(LucideIcons.keyRound,
//                       color: Colors.blue.shade600, size: 20),
//                 ),
//                 const SizedBox(width: 16),
//                 Expanded(
//                   child: Column(
//                     crossAxisAlignment: CrossAxisAlignment.start,
//                     children: [
//                       Text(_stepTitles[_step],
//                           style: const TextStyle(
//                               color: Color(0xFF0F172A),
//                               fontSize: 18,
//                               fontWeight: FontWeight.bold,
//                               fontFamily: 'Outfit')),
//                       const SizedBox(height: 4),
//                       Text(_stepSubtitles[_step],
//                           style: TextStyle(
//                               color: Colors.grey.shade500, fontSize: 12, fontFamily: 'Outfit')),
//                     ],
//                   ),
//                 ),
//               ],
//             ),

//             const SizedBox(height: 24),

//             // Step indicator
//             Row(
//               children: List.generate(3, (i) {
//                 return Expanded(
//                   child: Container(
//                     margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
//                     height: 4,
//                     decoration: BoxDecoration(
//                       color: i <= _step ? const Color(0xFF2563EB) : Colors.grey.shade200,
//                       borderRadius: BorderRadius.circular(2),
//                     ),
//                   ),
//                 );
//               }),
//             ),

//             const SizedBox(height: 32),

//             // Input fields
//             if (_step == 0) ...[
//               _buildModalField(
//                 controller: _controller,
//                 focusNode: _focusNode1,
//                 label: "Username",
//                 hint: "Enter admin username",
//                 icon: LucideIcons.user,
//               ),
//             ] else if (_step == 1) ...[
//               _buildModalField(
//                 controller: _controller,
//                 focusNode: _focusNode1,
//                 label: "OTP Code",
//                 hint: "000000",
//                 icon: LucideIcons.shieldCheck,
//                 keyboardType: TextInputType.number,
//               ),
//               const SizedBox(height: 8),
//               Row(
//                 children: [
//                   Icon(Icons.info_outline, color: Colors.grey.shade500, size: 14),
//                   const SizedBox(width: 6),
//                   Text("Code sent to ${_maskEmail(_email)}",
//     style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontFamily: 'Outfit')),
//                 ],
//               ),
//             ] else if (_step == 2) ...[
//               _buildModalField(
//                 controller: _controller,
//                 focusNode: _focusNode1,
//                 label: "New Password",
//                 hint: "Min. 6 characters",
//                 icon: LucideIcons.lock,
//                 obscure: _obscurePassword,
//                 suffix: IconButton(
//                   icon: Icon(
//                     _obscurePassword ? LucideIcons.eyeOff : LucideIcons.eye,
//                     color: Colors.grey.shade400,
//                     size: 18,
//                   ),
//                   onPressed: () =>
//                       setState(() => _obscurePassword = !_obscurePassword),
//                 ),
//               ),
//               const SizedBox(height: 20),
//               _buildModalField(
//                 controller: _confirmPasswordController,
//                 focusNode: _focusNode2,
//                 label: "Confirm Password",
//                 hint: "Re-enter new password",
//                 icon: LucideIcons.lockKeyhole,
//                 obscure: _obscureConfirm,
//                 suffix: IconButton(
//                   icon: Icon(
//                     _obscureConfirm ? LucideIcons.eyeOff : LucideIcons.eye,
//                     color: Colors.grey.shade400,
//                     size: 18,
//                   ),
//                   onPressed: () =>
//                       setState(() => _obscureConfirm = !_obscureConfirm),
//                 ),
//               ),
//             ],

//             const SizedBox(height: 32),

//             // Buttons
//             Row(
//               children: [
//                 if (_step > 0)
//                   Expanded(
//                     child: OutlinedButton(
//                       onPressed: _isLoading
//                           ? null
//                           : () => setState(() {
//                                 _step--;
//                                 _controller.clear();
//                                 _confirmPasswordController.clear();
//                               }),
//                       style: OutlinedButton.styleFrom(
//                         foregroundColor: const Color(0xFF0F172A),
//                         side: BorderSide(color: Colors.grey.shade300),
//                         shape: RoundedRectangleBorder(
//                             borderRadius: BorderRadius.circular(12)),
//                         padding: const EdgeInsets.symmetric(vertical: 16),
//                       ),
//                       child: const Text("Back", style: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600)),
//                     ),
//                   ),
//                 if (_step > 0) const SizedBox(width: 12),
//                 Expanded(
//                   flex: 2,
//                   child: ElevatedButton(
//                     onPressed: _isLoading ? null : _nextStep,
//                     style: ElevatedButton.styleFrom(
//                       backgroundColor: const Color(0xFF2563EB),
//                       foregroundColor: Colors.white,
//                       shape: RoundedRectangleBorder(
//                           borderRadius: BorderRadius.circular(12)),
//                       elevation: 0,
//                       padding: const EdgeInsets.symmetric(vertical: 16),
//                     ),
//                     child: _isLoading
//                         ? const SizedBox(
//                             height: 18,
//                             width: 18,
//                             child: CircularProgressIndicator(
//                                 color: Colors.white, strokeWidth: 2))
//                         : Text(
//                             _step == 2 ? "Update Password" : "Continue",
//                             style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
//                           ),
//                   ),
//                 ),
//               ],
//             ),
//             if (_step == 0)
//               Padding(
//                 padding: const EdgeInsets.only(top: 16),
//                 child: SizedBox(
//                   width: double.infinity,
//                   child: TextButton(
//                     onPressed: () => Navigator.pop(context),
//                     child: Text("Cancel", style: TextStyle(color: Colors.grey.shade600, fontFamily: 'Outfit')),
//                   ),
//                 ),
//               )
//           ],
//         ),
//       ),
//     );
//   }
// ─── Forgot Password Modal ───────────────────────────────────────────────────

class ForgotPasswordModal extends StatefulWidget {
  const ForgotPasswordModal({super.key, this.authService, this.now});

  final AuthService? authService;
  final DateTime Function()? now;

  @override
  State<ForgotPasswordModal> createState() => _ForgotPasswordModalState();
}

class _ForgotPasswordModalState extends State<ForgotPasswordModal> {
  late final AuthService _authService = widget.authService ?? AuthService();
  final _controller = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final _focusNode1 = FocusNode();
  final _focusNode2 = FocusNode();

  int _step = 0; // 0: username, 1: OTP, 2: new password
  String _recoveryChannel = 'email';
  String? _recoveryChallengeId;
  String? _recoveryResetToken;
  String? _recoveryUsername;
  DateTime? _otpExpiresAt;
  DateTime? _resendAvailableAt;
  Timer? _otpTimer;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  static const _blue = Color(0xFFC83D08);
  static const _otpLifetime = Duration(minutes: 10);
  static const _resendCooldown = Duration(minutes: 1);

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  int _secondsUntil(DateTime? deadline) {
    if (deadline == null) return 0;
    final milliseconds = deadline.difference(_now).inMilliseconds;
    return milliseconds <= 0 ? 0 : (milliseconds + 999) ~/ 1000;
  }

  String _clockText(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';

  void _startOtpClock(DateTime requestedAt) {
    _otpTimer?.cancel();
    _otpExpiresAt = requestedAt.add(_otpLifetime);
    _resendAvailableAt = requestedAt.add(_resendCooldown);
    _otpTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _step == 1) setState(() {});
    });
  }

  Future<void> _resendOtp() async {
    final username = _recoveryUsername;
    if (_isLoading ||
        _step != 1 ||
        _secondsUntil(_resendAvailableAt) > 0 ||
        username == null) {
      return;
    }
    setState(() => _isLoading = true);
    final requestedAt = _now;
    try {
      final challengeId = await _authService.requestPasswordRecovery(
        username,
        _recoveryChannel,
      );
      if (!mounted) return;
      setState(() {
        _recoveryChallengeId = challengeId;
        _recoveryResetToken = null;
        _controller.clear();
        _startOtpClock(requestedAt);
      });
      AppToast.success(context, 'If eligible, a new code has been sent.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Password recovery resend failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.server),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  final _stepTitles = [
    'Find your account',
    'Enter the code',
    'Set new password',
  ];

  // ── Password rules (only meaningful on step 2) ──
  bool get _hasMinLength => _controller.text.length >= 8;
  bool get _hasUppercase => _controller.text.contains(RegExp(r'[A-Z]'));
  bool get _hasLowercase => _controller.text.contains(RegExp(r'[a-z]'));
  bool get _hasDigit => _controller.text.contains(RegExp(r'[0-9]'));
  bool get _hasSymbol =>
      _controller.text.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));

  int get _metCount => [
    _hasMinLength,
    _hasUppercase,
    _hasLowercase,
    _hasDigit,
    _hasSymbol,
  ].where((e) => e).length;

  bool get _allMet => _metCount == 5;

  @override
  void initState() {
    super.initState();
    // WidgetsBinding.instance.addObserver(this);
    _focusNode1.addListener(() => setState(() {}));
    _focusNode2.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _otpTimer?.cancel();
    // WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _confirmPasswordController.dispose();
    _focusNode1.dispose();
    _focusNode2.dispose();
    super.dispose();
  }

  // Fixes the text field not accepting input after Alt+Tab
  // @override
  // void didChangeAppLifecycleState(AppLifecycleState state) {
  //   if (state == AppLifecycleState.resumed) {
  //     _focusNode1.unfocus();
  //     WidgetsBinding.instance.addPostFrameCallback((_) {
  //       if (mounted) _focusNode1.requestFocus();
  //     });
  //   }
  // }

  String _maskEmail(String? email) {
    if (email == null || !email.contains('@')) return '';
    final parts = email.split('@');
    final username = parts[0];
    final domain = parts[1];

    if (username.isEmpty) return '*@$domain';
    if (username.length <= 2) return '${username[0]}*@$domain';

    final masked =
        username[0] +
        '*' * (username.length - 2) +
        username[username.length - 1];
    return '$masked@$domain';
  }

  void _showContactAdminDialog(BuildContext navContext) {
    showDialog(
      context: navContext,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  LucideIcons.userX,
                  color: Colors.blue.shade600,
                  size: 32,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "Contact Your Administrator",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Outfit',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Staff accounts cannot reset their password here. Please contact your admin to reset your password.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 13,
                  height: 1.5,
                  fontFamily: 'Outfit',
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    "Got it",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _nextStep() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (_step == 0) {
        final requestedAt = _now;
        final challengeId = await _authService.requestPasswordRecovery(
          input,
          _recoveryChannel,
        );
        if (!mounted) return;
        setState(() {
          _recoveryChallengeId = challengeId;
          _recoveryResetToken = null;
          _recoveryUsername = input;
          _step = 1;
          _controller.clear();
          _startOtpClock(requestedAt);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode1.requestFocus();
        });
      } else if (_step == 1) {
        if (_secondsUntil(_otpExpiresAt) == 0) {
          AppToast.error(context, 'Code expired. Request a new code.');
          return;
        }
        final challengeId = _recoveryChallengeId;
        if (challengeId == null || challengeId.isEmpty) {
          AppToast.error(context, 'Recovery session expired. Start again.');
          return;
        }
        final token = await _authService.verifyPasswordRecovery(
          challengeId,
          input,
        );
        if (!mounted) return;
        if (token == null || token.isEmpty) {
          AppToast.error(context, 'Invalid or expired code. Please try again.');
          return;
        }
        _recoveryResetToken = token;
        setState(() {
          _step = 2;
          _controller.clear();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode1.requestFocus();
        });
      } else {
        final password = _controller.text;
        final confirm = _confirmPasswordController.text;

        if (!_allMet) {
          AppToast.error(
            context,
            'Password does not meet all security requirements.',
          );
          return;
        }
        if (password != confirm) {
          AppToast.error(context, 'Passwords do not match.');
          return;
        }

        final resetToken = _recoveryResetToken;
        if (resetToken == null || resetToken.isEmpty) {
          AppToast.error(context, 'Recovery session expired. Start again.');
          return;
        }
        final saved = await _authService.completePasswordRecovery(
          resetToken,
          password,
        );
        if (!mounted) return;
        if (!saved) {
          AppToast.error(
            context,
            'The reset session expired. Please request a new code.',
          );
          return;
        }

        if (mounted) {
          final overlay = Overlay.of(context, rootOverlay: true);
          Navigator.pop(context);
          AppToast.showOn(overlay, 'Password updated successfully!');
        }
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        'Password reset failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(e, fallback: AppErrorCategory.server),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _goBackOrCancel() {
    if (_step == 0) {
      Navigator.pop(context);
    } else {
      setState(() {
        _step -= 1;
        if (_step == 0) {
          _otpTimer?.cancel();
          _otpExpiresAt = null;
          _resendAvailableAt = null;
          _recoveryUsername = null;
        }
        _recoveryChallengeId = null;
        _recoveryResetToken = null;
        _controller.clear();
        _confirmPasswordController.clear();
      });
    }
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
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
                      SizedBox(width: 375, child: _buildInfoPanel()),
                      Expanded(child: _buildFormPanel()),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildInfoPanel(compact: true),
                    _buildFormPanel(compact: true),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildInfoPanel({bool compact = false}) {
    return Container(
      color: const Color(0xFF9D320F),
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
            child: const Icon(LucideIcons.lockKeyhole, color: _blue, size: 23),
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
            "We'll send a code to verify it's you, then you can choose a new password.",
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 13 : 16,
              height: 1.55,
              fontFamily: 'Outfit',
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 50),
            for (var i = 0; i < _stepTitles.length; i++) ...[
              Row(
                children: [
                  Container(
                    width: 31,
                    height: 31,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == _step ? Colors.white : Colors.transparent,
                      border: Border.all(color: Colors.white),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: i == _step
                            ? const Color(0xFF9D320F)
                            : Colors.white,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Outfit',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _stepTitles[i],
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: i == _step
                            ? FontWeight.w700
                            : FontWeight.w400,
                        fontFamily: 'Outfit',
                      ),
                    ),
                  ),
                ],
              ),
              if (i < _stepTitles.length - 1) const SizedBox(height: 16),
            ],
          ],
          if (_step == 2 && !compact) ...[
            const SizedBox(height: 24),
            Text(
              "YOUR PASSWORD NEEDS",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                fontFamily: 'Outfit',
              ),
            ),
            const SizedBox(height: 10),
            _requirementRow("At least 8 characters", _hasMinLength),
            _requirementRow("One uppercase letter (A-Z)", _hasUppercase),
            _requirementRow("One lowercase letter (a-z)", _hasLowercase),
            _requirementRow("One number (0-9)", _hasDigit),
            _requirementRow("One symbol (!@#\$%^&*)", _hasSymbol),
          ],
        ],
      ),
    );
  }

  Widget _requirementRow(String label, bool met) {
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

  Widget _compactRequirementRow(String label, bool met) => Padding(
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

  Widget _buildFormPanel({bool compact = false}) {
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
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: _isLoading ? null : () => Navigator.pop(context),
              icon: const Icon(
                LucideIcons.x,
                size: 18,
                color: Color(0xFF292522),
              ),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFF4F1EE),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'STEP ${_step + 1} OF 3',
            style: const TextStyle(
              color: Color(0xFF675A52),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _stepTitles[_step],
            style: const TextStyle(
              color: Color(0xFF171717),
              fontSize: 25,
              fontWeight: FontWeight.w800,
              fontFamily: 'Outfit',
            ),
          ),
          const SizedBox(height: 30),

          if (_step == 0) ...[
            _buildModalField(
              controller: _controller,
              focusNode: _focusNode1,
              label: "Admin username",
              hint: "Enter admin username",
              icon: LucideIcons.user,
            ),
            const SizedBox(height: 26),
            const Text(
              'Send code by',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (MediaQuery.sizeOf(context).width < 380)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _recoveryChannelOption('email', 'Email'),
                  const SizedBox(height: 10),
                  _recoveryChannelOption('sms', 'SMS'),
                ],
              )
            else
              Row(
                children: [
                  Expanded(child: _recoveryChannelOption('email', 'Email')),
                  const SizedBox(width: 14),
                  Expanded(child: _recoveryChannelOption('sms', 'SMS')),
                ],
              ),
          ] else if (_step == 1) ...[
            _buildModalField(
              controller: _controller,
              focusNode: _focusNode1,
              label: "OTP code",
              hint: "000000",
              icon: LucideIcons.shieldCheck,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.grey.shade500, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "Enter the verification code if you received one.",
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 12,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              _secondsUntil(_otpExpiresAt) > 0
                  ? 'Code expires in ${_clockText(_secondsUntil(_otpExpiresAt))}'
                  : 'Code expired',
              style: TextStyle(
                color: _secondsUntil(_otpExpiresAt) > 0
                    ? const Color(0xFF64748B)
                    : const Color(0xFFDC2626),
                fontSize: 12,
                fontFamily: 'Outfit',
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _isLoading || _secondsUntil(_resendAvailableAt) > 0
                  ? null
                  : _resendOtp,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                foregroundColor: _blue,
                alignment: Alignment.centerLeft,
              ),
              child: Text(
                _secondsUntil(_resendAvailableAt) > 0
                    ? 'Resend OTP in ${_clockText(_secondsUntil(_resendAvailableAt))}'
                    : 'Resend OTP',
              ),
            ),
          ] else ...[
            _buildModalField(
              controller: _controller,
              focusNode: _focusNode1,
              label: "New password",
              hint: "Min. 8 characters",
              icon: LucideIcons.lock,
              obscure: _obscurePassword,
              onChanged: (_) => setState(() {}),
              suffix: IconButton(
                icon: Icon(
                  _obscurePassword ? LucideIcons.eyeOff : LucideIcons.eye,
                  color: Colors.grey.shade500,
                  size: 18,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            const SizedBox(height: 10),
            _buildStrengthMeter(),
            if (compact) ...[
              const SizedBox(height: 10),
              _compactRequirementRow('At least 8 characters', _hasMinLength),
              _compactRequirementRow(
                'Uppercase and lowercase letters',
                _hasUppercase && _hasLowercase,
              ),
              _compactRequirementRow(
                'One number and one symbol',
                _hasDigit && _hasSymbol,
              ),
            ],
            const SizedBox(height: 18),
            _buildModalField(
              controller: _confirmPasswordController,
              focusNode: _focusNode2,
              label: "Confirm new password",
              hint: "Re-enter new password",
              icon: LucideIcons.lockKeyhole,
              obscure: _obscureConfirm,
              suffix: IconButton(
                icon: Icon(
                  _obscureConfirm ? LucideIcons.eyeOff : LucideIcons.eye,
                  color: Colors.grey.shade500,
                  size: 18,
                ),
                onPressed: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
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
                onPressed: _isLoading ? null : _goBackOrCancel,
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
                child: Text(
                  _step == 0 ? "Cancel" : "Back",
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: _isLoading ? null : _nextStep,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _blue,
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
                child: _isLoading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        _step == 0
                            ? 'Send code'
                            : _step == 1
                            ? 'Verify code'
                            : 'Update password',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Outfit',
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recoveryChannelOption(String channel, String label) {
    final selected = _recoveryChannel == channel;
    return InkWell(
      onTap: _isLoading
          ? null
          : () => setState(() => _recoveryChannel = channel),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 68,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF1E8) : Colors.white,
          border: Border.all(
            color: selected ? _blue : const Color(0xFFE5DED8),
            width: selected ? 2 : 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 17,
              color: selected ? _blue : const Color(0xFF817A75),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF171717),
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFamily: 'Outfit',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStrengthMeter() {
    const labels = ["", "Weak", "Weak", "Fair", "Almost there", "Strong"];
    final met = _metCount;

    return Row(
      children: [
        Expanded(
          child: Row(
            children: List.generate(5, (i) {
              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < met ? _blue : const Color(0xFFF1EAE4),
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
              color: _blue,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'Outfit',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModalField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    ValueChanged<String>? onChanged,
  }) {
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
          controller: controller,
          key: ValueKey(label),
          focusNode: focusNode,
          obscureText: obscure,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          onChanged: onChanged,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 14,
            fontFamily: 'Outfit',
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: Colors.grey.shade400,
              fontFamily: 'Outfit',
            ),
            prefixIcon: Icon(icon, color: const Color(0xFF817A75), size: 18),
            suffixIcon: suffix,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFD8D0C9)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFD8D0C9)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _blue, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ],
    );
  }
}

Widget _buildModalField({
  required TextEditingController controller,
  required FocusNode focusNode,
  required String label,
  required String hint,
  required IconData icon,
  bool obscure = false,
  Widget? suffix,
  TextInputType? keyboardType,
}) {
  final isFocused = focusNode.hasFocus;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 13,
          fontWeight: FontWeight.w700,
          fontFamily: 'Outfit',
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscure,
        keyboardType: keyboardType,
        style: const TextStyle(
          color: Color(0xFF0F172A),
          fontSize: 14,
          fontFamily: 'Outfit',
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: Colors.grey.shade400,
            fontFamily: 'Outfit',
          ),
          prefixIcon: Icon(icon, color: Colors.grey.shade400, size: 18),
          suffixIcon: suffix,
          filled: true,
          fillColor: isFocused ? Colors.white : Colors.grey.shade50,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade200),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade200),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    ],
  );
}
