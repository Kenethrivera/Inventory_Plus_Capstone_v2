import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:math';
import '../login/auth_service.dart';
import '../logic/inventory_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});
  final InventoryController controller;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  final _passwordFocusNode = FocusNode();

  bool _isPasswordVisible = false;
  bool _isLoading = false;

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    setState(() => _isLoading = true);

    try {
      final userProfile = await _authService.login(username, password);

      if (userProfile != null) {
        final String? assignedLocationId = userProfile['location_id'];
        final String userId = userProfile['id'].toString();

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('isLoggedIn', true);
        await prefs.setString('userId', userId);

        widget.controller.setLoggedInUser(
          name: userProfile['name'] ?? username,
          id: userId,
          role: userProfile['role'] ?? 'staff',
          email: userProfile['email'],
        );

        if (assignedLocationId != null && assignedLocationId.isNotEmpty) {
          await widget.controller.loadAppData(assignedLocationId);
          if (mounted) Navigator.pushReplacementNamed(context, '/main');
        } else {
          _showError("Account Error: No store assigned to this user.");
          await prefs.clear();
        }
      } else {
        _showError("Invalid username or password");
      }
    } catch (e) {
      _showError("An unexpected error occurred during login.");
      debugPrint("Login Page Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    AppToast.error(context, message);
  }

  void _showForgotPasswordModal() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ForgotPasswordModal(),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }
void _showPolicyDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF151D2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Text(content, style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.5)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1423),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 380),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xFF151D2E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(LucideIcons.packageCheck,
                            color: Colors.orange, size: 48),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Center(
                      child: Text("Inventory Plus",
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 4),
                    const Center(
                      child: Text("Hardware Management System",
                          style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ),
                    const SizedBox(height: 32),

                    const Text("Username",
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _buildTextField(
                      _usernameController,
                      "Enter your username",
                      LucideIcons.user,
                      false,
                      onSubmitted: (_) =>
                          FocusScope.of(context).requestFocus(_passwordFocusNode),
                    ),

                    const SizedBox(height: 20),

                    const Text("Password",
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _buildTextField(
                      _passwordController,
                      "••••••••",
                      LucideIcons.lock,
                      true,
                      focusNode: _passwordFocusNode,
                      onSubmitted: (_) => _handleLogin(),
                      suffix: IconButton(
                        icon: Icon(
                          _isPasswordVisible ? LucideIcons.eye : LucideIcons.eyeOff,
                          color: Colors.grey,
                          size: 18,
                        ),
                        onPressed: () => setState(
                            () => _isPasswordVisible = !_isPasswordVisible),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _showForgotPasswordModal,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text("Forgot password?",
                            style:
                                TextStyle(color: Colors.orange, fontSize: 12)),
                      ),
                    ),

                    const SizedBox(height: 24),

                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleLogin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6)),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text("Sign In",
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                                  SizedBox(width: 8),
                                  Icon(LucideIcons.logIn, size: 18),
                                ],
                              ),
                      ),
                    ),

                    const SizedBox(height: 32),
                    const Divider(color: Colors.white10, height: 1),
                    const SizedBox(height: 24),

                    // NEW CODE
Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => _showPolicyDialog(
        "Terms of Service",
        "By accessing and using Inventory Plus, you accept and agree to be bound by the terms and provisions of this agreement.\n\nAny participation in this service will constitute acceptance of this agreement. These terms are governed by the laws of the Republic of the Philippines."
      ),
      child: const Text("Terms of Service", style: TextStyle(color: Colors.grey, fontSize: 12)),
    ),
    const Text("   •   ", style: TextStyle(color: Colors.grey, fontSize: 12)),
    TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => _showPolicyDialog(
        "Privacy Policy",
        "Inventory Plus is committed to protecting your personal information. \n\nWe process your data in accordance with the Data Privacy Act of 2012 (Republic Act No. 10173) of the Philippines. We collect, use, and store your data solely for inventory management and system authentication purposes."
      ),
      child: const Text("Privacy Policy", style: TextStyle(color: Colors.grey, fontSize: 12)),
    ),
  ],
),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String hint,
    IconData icon,
    bool isPassword, {
    FocusNode? focusNode,
    ValueChanged<String>? onSubmitted,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: isPassword && !_isPasswordVisible,
      focusNode: focusNode,
      style: const TextStyle(color: Colors.white, fontSize: 14),
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
        hintStyle: const TextStyle(color: Colors.white24),
        prefixIcon: Icon(icon, color: Colors.white54, size: 18),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF0F1423),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.white10)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.white10)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.orange, width: 1)),
        errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}

// ─── Forgot Password Modal ───────────────────────────────────────────────────

class ForgotPasswordModal extends StatefulWidget {
  const ForgotPasswordModal({super.key});

  @override
  State<ForgotPasswordModal> createState() => _ForgotPasswordModalState();
}

class _ForgotPasswordModalState extends State<ForgotPasswordModal> {
  final _authService = AuthService();
  final _controller = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  int _step = 0; // 0: username, 1: OTP, 2: new password
  String? _email;
  String? _generatedOtp;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  final _stepTitles = ["Reset Password", "Enter OTP", "New Password"];
  final _stepSubtitles = [
    "Enter your admin username to receive an OTP",
    "Enter the 6-digit code sent to your email",
    "Choose a new password for your account",
  ];

  Future<void> _nextStep() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (_step == 0) {
  final isAdmin = await _authService.isAdminUser(input);
  if (!isAdmin) {
    if (mounted) {
      Navigator.pop(context); // close forgot password modal
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: const Color(0xFF151D2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(LucideIcons.userX, color: Colors.blue, size: 32),
                ),
                const SizedBox(height: 16),
                const Text("Contact Your Administrator",
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  "Staff accounts cannot reset their password here. Please contact your admin to reset your password.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text("Got it", style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return;
  }

 
        final email = await _authService.getEmailFromUsername(input);
        if (email == null) throw "Username not found.";

        final otp = (100000 + Random().nextInt(900000)).toString();
        await _authService.sendEmailJsOtp(email, otp);

        setState(() {
          _email = email;
          _generatedOtp = otp;
          _step = 1;
          _controller.clear();
        });
      } else if (_step == 1) {
        if (input != _generatedOtp) throw "Invalid OTP. Please try again.";
        setState(() {
          _step = 2;
          _controller.clear();
        });
      } else if (_step == 2) {
        final confirm = _confirmPasswordController.text.trim();
        if (input.length < 6) throw "Password must be at least 6 characters.";
        if (input != confirm) throw "Passwords do not match.";

        await _authService.resetPasswordForUser(_email!, input);

                if (mounted) {
          // Grab the overlay first: the modal is about to close.
          final overlay = Overlay.of(context, rootOverlay: true);
          Navigator.pop(context);
          AppToast.showOn(overlay, 'Password updated successfully!');
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF151D2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(LucideIcons.keyRound,
                      color: Colors.orange, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_stepTitles[_step],
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(_stepSubtitles[_step],
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey, size: 18),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Step indicator
            Row(
              children: List.generate(3, (i) {
                return Expanded(
                  child: Container(
                    margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
                    height: 3,
                    decoration: BoxDecoration(
                      color: i <= _step ? Colors.orange : Colors.white12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                );
              }),
            ),

            const SizedBox(height: 24),

            // Input fields
            if (_step == 0) ...[
              _buildModalField(
                controller: _controller,
                label: "Username",
                hint: "Enter admin username",
                icon: LucideIcons.user,
              ),
            ] else if (_step == 1) ...[
              _buildModalField(
                controller: _controller,
                label: "OTP Code",
                hint: "000000",
                icon: LucideIcons.shieldCheck,
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.grey, size: 13),
                  const SizedBox(width: 4),
                  Text("Code sent to ${_email ?? ''}",
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 11)),
                ],
              ),
            ] else if (_step == 2) ...[
              _buildModalField(
                controller: _controller,
                label: "New Password",
                hint: "Min. 6 characters",
                icon: LucideIcons.lock,
                obscure: _obscurePassword,
                suffix: IconButton(
                  icon: Icon(
                    _obscurePassword ? LucideIcons.eyeOff : LucideIcons.eye,
                    color: Colors.grey,
                    size: 16,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              const SizedBox(height: 16),
              _buildModalField(
                controller: _confirmPasswordController,
                label: "Confirm Password",
                hint: "Re-enter new password",
                icon: LucideIcons.lockKeyhole,
                obscure: _obscureConfirm,
                suffix: IconButton(
                  icon: Icon(
                    _obscureConfirm ? LucideIcons.eyeOff : LucideIcons.eye,
                    color: Colors.grey,
                    size: 16,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Buttons
            Row(
              children: [
                if (_step > 0)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isLoading
                          ? null
                          : () => setState(() {
                                _step--;
                                _controller.clear();
                                _confirmPasswordController.clear();
                              }),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey,
                        side: const BorderSide(color: Colors.white12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text("Back"),
                    ),
                  ),
                if (_step > 0) const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _nextStep,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : Text(
                            _step == 2 ? "Update Password" : "Continue",
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModalField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white24),
            prefixIcon: Icon(icon, color: Colors.white54, size: 16),
            suffixIcon: suffix,
            filled: true,
            fillColor: const Color(0xFF0F1423),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white10)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white10)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.orange, width: 1)),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
    );
  }
}