import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'dart:async';

class ProfileInfoPage extends StatefulWidget {
  final InventoryController controller;
  final String currentName;
  final String? currentEmail;
  final String userId;
  final String role;

  const ProfileInfoPage({
    super.key,
    required this.controller,
    required this.currentName,
    this.currentEmail,
    required this.userId,
    required this.role,
  });

  @override
  State<ProfileInfoPage> createState() => _ProfileInfoPageState();
}

class _ProfileInfoPageState extends State<ProfileInfoPage> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _locationController; 
  late TextEditingController _phoneController;
  bool _isLoading = false;
  bool _isFetching = true;

  // ADD STATE VARIABLE FOR EDIT MODE
  bool _isEditing = false;
  StreamSubscription<CurrentUserProfileSnapshot?>? _profileSubscription;
  CurrentUserProfileSnapshot? _pendingRemoteProfile;
  bool _conflictNotified = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _emailController = TextEditingController(text: widget.currentEmail ?? "");
    _locationController = TextEditingController(); 
    _phoneController = TextEditingController();
    _profileSubscription = widget.controller.currentUserProfileSnapshots.listen(
      _handleProfileSnapshot,
    );
    // Fetch latest data from database immediately on load
    _loadLatestDataFromDatabase();
  }

  Future<void> _loadLatestDataFromDatabase() async {
    try {
      final snapshot = await widget.controller.refreshCurrentUserProfile();

      if (snapshot != null && mounted) {
        setState(() {
          _applyProfileSnapshot(snapshot);
          _isFetching = false;
        });
      } else if (mounted) {
        setState(() {
          _isFetching = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching latest profile data: $e");
      if (mounted) {
        setState(() {
          _isFetching = false;
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_profileSubscription?.cancel());
    _nameController.dispose();
    _emailController.dispose();
    _locationController.dispose(); 
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (_pendingRemoteProfile != null) {
      await _showProfileConflict();
      return;
    }
    setState(() => _isLoading = true);

    try {
      final newName = _nameController.text.trim();
      final newEmail = _emailController.text.trim();
      final newAddress = _locationController.text.trim(); 
      final newPhone = _phoneController.text.trim();

      if (newName.isEmpty) {
        throw Exception("Name cannot be empty.");
      }

      await widget.controller.updateProfile(
        userId: widget.userId,
        name: newName,
        email: newEmail,
        location: newAddress, 
        phone: newPhone,      
      );

      if (mounted) {
        setState(() {
          _isEditing = false;
          _pendingRemoteProfile = null;
          _conflictNotified = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Profile updated successfully!"),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error updating profile: $e"),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _handleProfileSnapshot(CurrentUserProfileSnapshot? snapshot) {
    if (!mounted || snapshot == null || snapshot.id != widget.userId) return;
    final matchesDraft =
        _nameController.text.trim() == snapshot.name &&
        _emailController.text.trim() == (snapshot.email ?? '') &&
        _locationController.text.trim() == (snapshot.address ?? '') &&
        _phoneController.text.trim() == (snapshot.phone ?? '');
    if (_isEditing && !_isLoading && !matchesDraft) {
      _pendingRemoteProfile = snapshot;
      if (!_conflictNotified) {
        _conflictNotified = true;
        AppToast.error(
          context,
          'Your profile changed elsewhere. Your unsaved edits were kept.',
        );
      }
      return;
    }
    setState(() => _applyProfileSnapshot(snapshot));
  }

  void _applyProfileSnapshot(CurrentUserProfileSnapshot snapshot) {
    _nameController.text = snapshot.name;
    _emailController.text = snapshot.email ?? '';
    _locationController.text = snapshot.address ?? '';
    _phoneController.text = snapshot.phone ?? '';
    _pendingRemoteProfile = null;
    _conflictNotified = false;
  }

  Future<void> _showProfileConflict() async {
    final latest = _pendingRemoteProfile;
    if (latest == null) return;
    final reload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.triangleAlert,
        color: Colors.orange,
        title: 'Profile changed',
        subtitle: 'A newer saved profile is available.',
        child: const Text(
          'Your unsaved fields have not been overwritten. Reload the latest '
          'saved profile, or keep editing.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep Editing'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reload Latest'),
          ),
        ],
      ),
    );
    if (reload == true && mounted) {
      setState(() {
        _applyProfileSnapshot(latest);
        _isEditing = false;
      });
    }
  }

  void _showChangePasswordDialog(BuildContext context) {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    bool isSaving = false;
    String? errorMessage;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (stateContext, setState) {
            final text = newPasswordController.text;
            final bool hasMinLength = text.length >= 8;
            final bool hasUppercase = text.contains(RegExp(r'[A-Z]'));
            final bool hasLowercase = text.contains(RegExp(r'[a-z]'));
            final bool hasDigit = text.contains(RegExp(r'[0-9]'));
            final bool hasSymbol = text.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));

            Widget buildRequirementRow(String label, bool met) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      met ? Icons.check_circle : Icons.circle_outlined,
                      size: 14,
                      color: met ? Colors.blue.shade700 : Colors.grey.shade400,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: met ? Colors.blue.shade900 : Colors.grey.shade600,
                        fontWeight: met ? FontWeight.w500 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              );
            }

            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              contentPadding: const EdgeInsets.all(24),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(LucideIcons.keyRound, color: Colors.blue.shade600, size: 24),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        "New Password",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        "Choose a new password for your account",
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 20),

                      if (errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            errorMessage!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 12,
                            ),
                          ),
                        ),

                      const Text("Current Password", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.black87)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: currentPasswordController,
                        obscureText: obscureCurrent,
                        decoration: InputDecoration(
                          hintText: "Enter current password",
                          hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
                          prefixIcon: Icon(LucideIcons.lock, size: 18, color: Colors.blue.shade300),
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureCurrent ? LucideIcons.eyeOff : LucideIcons.eye,
                              size: 18,
                              color: Colors.grey,
                            ),
                            onPressed: () => setState(() => obscureCurrent = !obscureCurrent),
                          ),
                          filled: true,
                          fillColor: Colors.blue.shade50.withOpacity(0.3),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.blue.shade400, width: 1),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Text("New Password", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.black87)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: newPasswordController,
                        obscureText: obscureNew,
                        onChanged: (val) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: "Min. 8 characters",
                          hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
                          prefixIcon: Icon(LucideIcons.lock, size: 18, color: Colors.blue.shade300),
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureNew ? LucideIcons.eyeOff : LucideIcons.eye,
                              size: 18,
                              color: Colors.grey,
                            ),
                            onPressed: () => setState(() => obscureNew = !obscureNew),
                          ),
                          filled: true,
                          fillColor: Colors.blue.shade50.withOpacity(0.3),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.blue.shade400, width: 1),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.blue.shade100),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            buildRequirementRow("At least 8 characters", hasMinLength),
                            buildRequirementRow("At least one uppercase letter (A-Z)", hasUppercase),
                            buildRequirementRow("At least one lowercase letter (a-z)", hasLowercase),
                            buildRequirementRow("At least one number (0-9)", hasDigit),
                            buildRequirementRow("At least one special symbol (!@#\$%^&*)", hasSymbol),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Text("Confirm Password", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.black87)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: confirmPasswordController,
                        obscureText: obscureConfirm,
                        decoration: InputDecoration(
                          hintText: "Re-enter new password",
                          hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
                          prefixIcon: Icon(LucideIcons.lock, size: 18, color: Colors.blue.shade300),
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscureConfirm ? LucideIcons.eyeOff : LucideIcons.eye,
                              size: 18,
                              color: Colors.grey,
                            ),
                            onPressed: () => setState(() => obscureConfirm = !obscureConfirm),
                          ),
                          filled: true,
                          fillColor: Colors.blue.shade50.withOpacity(0.3),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.blue.shade400, width: 1),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                side: BorderSide(color: Colors.blue.shade200),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () => Navigator.pop(context),
                              child: Text("Back", style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue.shade600,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: isSaving
                                  ? null
                                  : () async {
                                      if (currentPasswordController.text.isEmpty ||
                                          newPasswordController.text.isEmpty ||
                                          confirmPasswordController.text.isEmpty) {
                                        setState(() => errorMessage = "Please fill in all fields.");
                                        return;
                                      }
                                      if (!hasMinLength || !hasUppercase || !hasLowercase || !hasDigit || !hasSymbol) {
                                        setState(() => errorMessage = "Password does not meet all security requirements.");
                                        return;
                                      }
                                      if (newPasswordController.text != confirmPasswordController.text) {
                                        setState(() => errorMessage = "New passwords do not match.");
                                        return;
                                      }

                                      setState(() {
                                        isSaving = true;
                                        errorMessage = null;
                                      });

                                      final error = await widget.controller.changePassword(
                                        currentPasswordController.text,
                                        newPasswordController.text,
                                      );

                                      if (error != null) {
                                        setState(() {
                                          errorMessage = error;
                                          isSaving = false;
                                        });
                                      } else {
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text("Password changed successfully!"),
                                              backgroundColor: Colors.blue,
                                            ),
                                          );
                                        }
                                      }
                                    },
                              child: isSaving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text("Update", style: TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Profile Info",
          style: TextStyle(
            color: Colors.black87,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isLoading
                ? null
                : () {
                    if (_isEditing) {
                      _saveProfile();
                    } else {
                      setState(() => _isEditing = true);
                    }
                  },
            child: _isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                  )
                : Text(
                    _isEditing ? "Save" : "Edit",
                    style: TextStyle(
                      color: Colors.blue.shade600,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
      body: _isFetching
          ? const Center(child: CircularProgressIndicator(color: Colors.blue))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: CircleAvatar(
                      radius: 40,
                      backgroundColor: Colors.blue.shade50,
                      child: Icon(
                        LucideIcons.user,
                        color: Colors.blue.shade600,
                        size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  _buildField(
                    "Role",
                    null,
                    TextEditingController(text: widget.role.toUpperCase()),
                    readOnly: true,
                  ),
                  _buildField(
                    "Full Name",
                    null,
                    _nameController,
                    icon: LucideIcons.user,
                  ),
                  _buildField(
                    "Email Address",
                    null,
                    _emailController,
                    icon: LucideIcons.mail,
                    type: TextInputType.emailAddress,
                  ),
                  _buildField(
                    "Location",
                    null,
                    _locationController,
                    icon: LucideIcons.mapPin,
                  ),
                  _buildField(
                    "Phone Number",
                    null,
                    _phoneController,
                    icon: LucideIcons.phone,
                    type: TextInputType.phone,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: () => _showChangePasswordDialog(context),
                      icon: Icon(LucideIcons.lock, size: 18, color: Colors.blue.shade700),
                      label: Text("Change Password", style: TextStyle(color: Colors.blue.shade700, fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.blue.shade50.withOpacity(0.3),
                        side: BorderSide(color: Colors.blue.shade200),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // Helper to build consistent fields with clean blue/white styling
  Widget _buildField(
    String label,
    String? staticValue,
    TextEditingController? controller, {
    IconData? icon,
    bool readOnly = false,
    TextInputType type = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade700,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          readOnly: readOnly || !_isEditing,
          keyboardType: type,
          decoration: InputDecoration(
            hintText: "Enter $label",
            hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
            filled: true,
            fillColor: _isEditing && !readOnly
                ? Colors.blue.shade50.withOpacity(0.3)
                : Colors.grey.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.blue.shade400, width: 1),
            ),
            prefixIcon: icon != null
                ? Icon(icon, size: 18, color: Colors.blue.shade300)
                : null,
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
