import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/change_password_dialog.dart';
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

  Future<void> _showChangePasswordDialog(BuildContext context) async {
    await showChangePasswordDialog(
      context: context,
      controller: widget.controller,
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
