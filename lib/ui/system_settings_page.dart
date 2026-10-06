import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

// Data Models
class MeasurementUnit {
  String id;
  String name;
  String symbol;

  MeasurementUnit({required this.id, required this.name, required this.symbol});
}

class SystemSettingsPage extends StatefulWidget {
  final InventoryController controller;
  const SystemSettingsPage({super.key, required this.controller});

  @override
  State<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

class _SystemSettingsPageState extends State<SystemSettingsPage> {
  // Global Settings State
  bool _isLoadingSettings = true;
  List<MeasurementUnit> _measurements = [];

  // Staff State
  bool _isLoadingStaff = true;
  List<Map<String, dynamic>> _staffList = [];

  // Global Threshold State
  final TextEditingController _lowPercentCtrl = TextEditingController();
  final TextEditingController _criticalPercentCtrl = TextEditingController();
  String? _thresholdError;
  bool _isSavingThresholds = false;

  @override
  void initState() {
    super.initState();
    _fetchSettings();
    _loadStaff();
  }

  @override
  void dispose() {
    _lowPercentCtrl.dispose();
    _criticalPercentCtrl.dispose();
    super.dispose();
  }

  String _formatPct(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  List<MeasurementUnit> _measurementsFromController() {
    return widget.controller.availableMeasurements
        .map(
          (m) => MeasurementUnit(
            id: m['id'].toString(),
            name: m['name'] as String,
            symbol: m['symbol'] as String,
          ),
        )
        .toList();
  }

  Future<void> _fetchSettings() async {
    try {
      await widget.controller.loadSystemSettings();
      if (!mounted) return;

      _lowPercentCtrl.text = _formatPct(widget.controller.globalLowStockPct);
      _criticalPercentCtrl.text = _formatPct(
        widget.controller.globalCriticalPct,
      );

      setState(() {
        _measurements = _measurementsFromController();
        _isLoadingSettings = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingSettings = false);
        _showToast("Error loading settings: $e", isError: true);
      }
    }
  }

  Future<void> _loadStaff() async {
    setState(() => _isLoadingStaff = true);
    try {
      final staff = await widget.controller.fetchStaff();
      final currentUserId = widget.controller.currentUserId;
      final filteredStaff = staff
          .where((s) => s['id'].toString() != currentUserId)
          .toList();

      if (mounted) {
        setState(() {
          _staffList = filteredStaff;
          _isLoadingStaff = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingStaff = false);
        _showToast("Error loading staff: $e", isError: true);
      }
    }
  }

  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    isError
        ? AppToast.error(context, message)
        : AppToast.success(context, message);
  }

  // ─── THRESHOLD MANAGEMENT ──────────────────────────────────────────────────
  Future<void> _saveGlobalThresholds() async {
    setState(() => _thresholdError = null);

    final lowVal = double.tryParse(_lowPercentCtrl.text);
    final critVal = double.tryParse(_criticalPercentCtrl.text);

    if (lowVal == null || critVal == null) {
      setState(() => _thresholdError = "Percentages must be valid numbers.");
      return;
    }
    if (critVal <= 0 || lowVal > 100) {
      setState(
        () => _thresholdError =
            "Values must be between 0 and 100 (critical must be above 0).",
      );
      return;
    }

    setState(() => _isSavingThresholds = true);

    try {
      await widget.controller.updateGlobalThresholds(lowVal, critVal);

      if (mounted) {
        setState(() => _isSavingThresholds = false);
        _showToast("Global thresholds updated successfully");
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSavingThresholds = false;
          _thresholdError = "Failed to save: $e";
        });
      }
    }
  }

  // ─── MEASUREMENT MANAGEMENT ────────────────────────────────────────────────
  void _showMeasurementModal([MeasurementUnit? existing]) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final symbolCtrl = TextEditingController(text: existing?.symbol ?? '');
    String? nameError;
    String? symbolError;
    bool saving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> validateAndSave() async {
            final name = nameCtrl.text.trim();
            final symbol = symbolCtrl.text.trim();

            setModalState(() {
              nameError = name.isEmpty ? "Measurement name is required" : null;
              symbolError = symbol.isEmpty ? "Symbol/Unit is required" : null;
            });
            if (name.isEmpty || symbol.isEmpty) return;

            setModalState(() => saving = true);
            try {
              if (existing == null) {
                await widget.controller.addMeasurement(name, symbol);
                _showToast("Measurement added successfully");
              } else {
                await widget.controller.updateMeasurement(
                  existing.id,
                  name,
                  symbol,
                );
                _showToast("Measurement updated successfully");
              }

              if (mounted) {
                setState(() => _measurements = _measurementsFromController());
              }
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            } catch (e) {
              setModalState(() => saving = false);
              _showToast("Failed to save measurement: $e", isError: true);
            }
          }

          InputDecoration deco(String label, String? error) => InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(fontFamily: _fontFam),
            errorText: error,
            errorStyle: const TextStyle(fontFamily: _fontFam),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: _primaryBlue, width: 2),
            ),
          );

          return AppDialog(
            icon: LucideIcons.ruler,
            color: _primaryBlue,
            title: existing == null ? "Add Measurement" : "Edit Measurement",
            subtitle: existing?.name,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(fontFamily: _fontFam),
                  decoration: deco("Measurement Name (e.g. Pieces)", nameError),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: symbolCtrl,
                  style: const TextStyle(fontFamily: _fontFam),
                  decoration: deco("Symbol / Unit (e.g. pcs)", symbolError),
                ),
              ],
            ),
            actions: [
              OutlinedButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
              ),
              ElevatedButton(
                onPressed: saving ? null : validateAndSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "Save",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontFamily: _fontFam,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _confirmDeleteMeasurement(MeasurementUnit item) {
    showDialog(
      context: context,
      builder: (ctx) => AppDialog(
        icon: LucideIcons.trash2,
        color: Colors.red.shade600,
        title: "Delete Measurement?",
        subtitle: item.name,
        child: Text(
          "Are you sure you want to remove '${item.name}'? Existing inventory using this unit will not be altered.",
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontFamily: _fontFam),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await widget.controller.deleteMeasurement(item.id);
                if (mounted) {
                  setState(() => _measurements = _measurementsFromController());
                }
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast("Measurement deleted");
              } catch (e) {
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast("Failed to delete measurement: $e", isError: true);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              "Delete",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── STAFF MANAGEMENT ──────────────────────────────────────────────────────
  String _getInitials(String? name) {
    if (name == null || name.trim().isEmpty) return "??";
    List<String> parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return "${parts[0][0]}${parts[1][0]}".toUpperCase();
  }

  String _generateDefaultPassword(String name) {
    if (name.trim().isEmpty) return "default123";
    List<String> parts = name.trim().toLowerCase().split(RegExp(r'\s+'));
    String first = parts.first;
    String initials = parts.length > 1
        ? parts.sublist(1).map((p) => p[0]).join()
        : "";
    return "$first${initials}123";
  }

  Widget _buildDarkField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF4A5568),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(color: Color(0xFF1A1F36), fontSize: 14, fontFamily: _fontFam),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xFFB0B7C3), fontFamily: _fontFam),
            prefixIcon: Icon(icon, color: const Color(0xFF8892A4), size: 16),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: _primaryBlue, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
    );
  }

  void _showAddStaffDialog() {
    final nameCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String selectedRole = 'staff';
    bool isSaving = false;
    String defaultPassword = "";

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) {
          nameCtrl.addListener(() {
            setModalState(() {
              defaultPassword = _generateDefaultPassword(nameCtrl.text);
            });
          });

          return AppDialog(
            icon: LucideIcons.userPlus,
            color: _primaryBlue,
            title: "Add New Staff",
            subtitle: "Fill in the details to create an account",
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDarkField(
                  controller: nameCtrl,
                  label: "Full Name",
                  hint: "Enter full name",
                  icon: LucideIcons.user,
                ),
                const SizedBox(height: 16),
                _buildDarkField(
                  controller: userCtrl,
                  label: "Username",
                  hint: "Enter username",
                  icon: LucideIcons.atSign,
                ),
                const SizedBox(height: 16),
                _buildDarkField(
                  controller: emailCtrl,
                  label: "Email Address",
                  hint: "Enter email (optional)",
                  icon: LucideIcons.mail,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                _buildDarkField(
                  controller: phoneCtrl,
                  label: "Phone Number",
                  hint: "Enter phone (optional)",
                  icon: LucideIcons.phone,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                _buildDarkField(
                  controller: addressCtrl,
                  label: "Address",
                  hint: "Enter address (optional)",
                  icon: LucideIcons.mapPin,
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Role",
                      style: TextStyle(
                        color: Color(0xFF4A5568),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: _fontFam,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,
                      dropdownColor: Colors.white,
                      style: const TextStyle(
                        color: Color(0xFF1A1F36),
                        fontSize: 14,
                        fontFamily: _fontFam,
                      ),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          LucideIcons.shield,
                          color: Color(0xFF8892A4),
                          size: 16,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: _primaryBlue,
                            width: 2,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'staff', child: Text('Staff', style: TextStyle(fontFamily: _fontFam))),
                        DropdownMenuItem(value: 'admin', child: Text('Admin', style: TextStyle(fontFamily: _fontFam))),
                        DropdownMenuItem(
                          value: 'helper',
                          child: Text('Helper', style: TextStyle(fontFamily: _fontFam)),
                        ),
                      ],
                      onChanged: (val) =>
                          setModalState(() => selectedRole = val!),
                    ),
                  ],
                ),
                if (defaultPassword.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFBBF7D0)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons.keyRound,
                          color: Color(0xFF16A34A),
                          size: 16,
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "Default Password",
                              style: TextStyle(
                                color: Color(0xFF4A5568),
                                fontSize: 11,
                                fontFamily: _fontFam,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              defaultPassword,
                              style: const TextStyle(
                                color: Color(0xFF15803D),
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                letterSpacing: 1,
                                fontFamily: _fontFam,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF4A5568),
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        if (nameCtrl.text.trim().isEmpty ||
                            userCtrl.text.trim().isEmpty) {
                          _showToast(
                            "Name and username are required.",
                            isError: true,
                          );
                          return;
                        }
                        setModalState(() => isSaving = true);
                        try {
                          final success = await widget.controller.createStaff(
                            name: nameCtrl.text.trim(),
                            username: userCtrl.text.trim(),
                            password: defaultPassword,
                            email: emailCtrl.text.trim(),
                            phone: phoneCtrl.text.trim(),
                            address: addressCtrl.text.trim(),
                            role: selectedRole,
                          );
                          if (success) {
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            _loadStaff();
                            _showToast("Staff created successfully.");
                          } else {
                            setModalState(() => isSaving = false);
                            _showToast(
                              "Failed to create staff. Username may already exist.",
                              isError: true,
                            );
                          }
                        } catch (e) {
                          setModalState(() => isSaving = false);
                          _showToast("Error creating staff: $e", isError: true);
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "Create Account",
                        style: TextStyle(fontWeight: FontWeight.w600, fontFamily: _fontFam),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditStaffRole(Map<String, dynamic> staff) {
    String selectedRole = staff['role'] ?? 'staff';
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) {
          return AppDialog(
            icon: LucideIcons.shield,
            color: _primaryBlue,
            title: "Change Role",
            subtitle: staff['name'],
            child: DropdownButtonFormField<String>(
              initialValue: selectedRole,
              style: const TextStyle(fontFamily: _fontFam, color: Colors.black87, fontSize: 14),
              decoration: InputDecoration(
                labelText: "Role",
                labelStyle: const TextStyle(fontFamily: _fontFam),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _primaryBlue, width: 2),
                ),
                prefixIcon: const Icon(LucideIcons.shield),
              ),
              items: const [
                DropdownMenuItem(value: 'staff', child: Text('Staff', style: TextStyle(fontFamily: _fontFam))),
                DropdownMenuItem(value: 'admin', child: Text('Admin', style: TextStyle(fontFamily: _fontFam))),
                DropdownMenuItem(value: 'helper', child: Text('Helper', style: TextStyle(fontFamily: _fontFam))),
              ],
              onChanged: (val) => setModalState(() => selectedRole = val!),
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        setModalState(() => isSaving = true);
                        try {
                          final success = await widget.controller
                              .updateStaffRole(
                                staff['id'].toString(),
                                selectedRole,
                              );
                          if (success) {
                            if (dialogContext.mounted)
                              Navigator.pop(dialogContext);
                            _loadStaff();
                            _showToast("Role updated successfully.");
                          } else {
                            setModalState(() => isSaving = false);
                            _showToast("Error updating role", isError: true);
                          }
                        } catch (e) {
                          setModalState(() => isSaving = false);
                          _showToast("Error updating role: $e", isError: true);
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text("Save Changes", style: TextStyle(fontFamily: _fontFam)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showResetPasswordDialog(Map<String, dynamic> staff) {
    final newPass = _generateDefaultPassword(staff['name'] ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AppDialog(
        icon: LucideIcons.refreshCw,
        color: _primaryBlue,
        title: "Reset Password",
        subtitle: staff['name'],
        child: Text.rich(
          TextSpan(
            text: "Are you sure you want to reset the password for ",
            style: const TextStyle(fontFamily: _fontFam),
            children: [
              TextSpan(
                text: "${staff['name']}",
                style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
              ),
              const TextSpan(text: "?\n\nIt will be updated to: ", style: TextStyle(fontFamily: _fontFam)),
              TextSpan(
                text: newPass,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _primaryBlue,
                  fontSize: 16,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                final success = await widget.controller.adminResetUserPassword(
                  staff['id'].toString(),
                  newPass,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (success && mounted) {
                  _showToast('Password successfully reset to $newPass');
                } else if (mounted) {
                  _showToast(
                    'Failed to reset password. Please try again.',
                    isError: true,
                  );
                }
              } catch (e) {
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast("Error resetting password: $e", isError: true);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryBlue,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Confirm Reset", style: TextStyle(fontFamily: _fontFam)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteStaff(Map<String, dynamic> staff) {
    showDialog(
      context: context,
      builder: (ctx) => AppDialog(
        icon: LucideIcons.trash2,
        color: Colors.red.shade600,
        title: "Delete Account?",
        subtitle: staff['name'],
        child: Text(
          "Are you sure you want to completely remove this staff account? This action cannot be undone.",
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontFamily: _fontFam),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                final success = await widget.controller.deleteStaff(
                  staff['id'].toString(),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (success) {
                  _loadStaff();
                  _showToast("Staff account deleted");
                } else {
                  _showToast("Failed to delete staff account.", isError: true);
                }
              } catch (e) {
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast("Error deleting staff: $e", isError: true);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              "Delete",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showStaffDetailsModal(Map<String, dynamic> staff) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        child: LayoutBuilder(
          builder: (context, constraints) {
            bool isMobile = constraints.maxWidth < 650;

            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 750),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              LucideIcons.x,
                              color: _primaryBlue,
                            ),
                            onPressed: () => Navigator.pop(context),
                            splashRadius: 20,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            "Staff Profile Details",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _primaryBlue,
                              fontFamily: _fontFam,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Flex(
                        direction: isMobile ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            flex: isMobile ? 0 : 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 24,
                                        backgroundColor: _primaryBlue,
                                        child: Text(
                                          _getInitials(staff['name']),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: _fontFam,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              spacing: 8,
                                              children: [
                                                Text(
                                                  (staff['name'] ??
                                                          'Unknown User')
                                                      .toUpperCase(),
                                                  style: const TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                    fontFamily: _fontFam,
                                                  ),
                                                ),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.blue
                                                        .withOpacity(0.1),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    (staff['role'] ?? 'staff')
                                                        .toString()
                                                        .toUpperCase(),
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      color: Colors.blue,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontFamily: _fontFam,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Row(
                                              children: [
                                                const Icon(
                                                  LucideIcons.mapPin,
                                                  size: 14,
                                                  color: Colors.grey,
                                                ),
                                                const SizedBox(width: 4),
                                                Expanded(
                                                  child: Text(
                                                    staff['address'] ??
                                                        "No address provided",
                                                    style: const TextStyle(
                                                      color: Colors.grey,
                                                      fontSize: 12,
                                                      fontFamily: _fontFam,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                if (isMobile)
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _buildInfoTile(
                                        "USERNAME",
                                        staff['username'] ?? 'N/A',
                                        LucideIcons.user,
                                        fullWidth: true,
                                      ),
                                      const SizedBox(height: 12),
                                      _buildInfoTile(
                                        "EMAIL ADDRESS",
                                        staff['email'] ?? 'Not provided',
                                        LucideIcons.mail,
                                        fullWidth: true,
                                      ),
                                      const SizedBox(height: 12),
                                      _buildInfoTile(
                                        "FULL LEGAL NAME",
                                        staff['name'] ?? 'N/A',
                                        LucideIcons.clipboardList,
                                        fullWidth: true,
                                      ),
                                      const SizedBox(height: 12),
                                      _buildInfoTile(
                                        "JOINED AT",
                                        staff['created_at'] != null
                                            ? "Joined ${staff['created_at'].toString().substring(0, 10)}"
                                            : 'N/A',
                                        LucideIcons.calendar,
                                        fullWidth: true,
                                      ),
                                      const SizedBox(height: 12),
                                      _buildInfoTile(
                                        "PHONE NUMBER",
                                        staff['phone'] ?? 'Not provided',
                                        LucideIcons.phone,
                                        fullWidth: true,
                                      ),
                                    ],
                                  )
                                else
                                  Wrap(
                                    spacing: 16,
                                    runSpacing: 16,
                                    children: [
                                      _buildInfoTile(
                                        "USERNAME",
                                        staff['username'] ?? 'N/A',
                                        LucideIcons.user,
                                      ),
                                      _buildInfoTile(
                                        "EMAIL ADDRESS",
                                        staff['email'] ?? 'Not provided',
                                        LucideIcons.mail,
                                      ),
                                      _buildInfoTile(
                                        "FULL LEGAL NAME",
                                        staff['name'] ?? 'N/A',
                                        LucideIcons.clipboardList,
                                        fullWidth: true,
                                      ),
                                      _buildInfoTile(
                                        "JOINED AT",
                                        staff['created_at'] != null
                                            ? "Joined ${staff['created_at'].toString().substring(0, 10)}"
                                            : 'N/A',
                                        LucideIcons.calendar,
                                        fullWidth: true,
                                      ),
                                      _buildInfoTile(
                                        "PHONE NUMBER",
                                        staff['phone'] ?? 'Not provided',
                                        LucideIcons.phone,
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                          if (!isMobile) const SizedBox(width: 24),
                          if (isMobile) const SizedBox(height: 24),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: isMobile ? double.infinity : 220,
                            ),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: const [
                                      Icon(
                                        LucideIcons.shieldAlert,
                                        size: 16,
                                        color: _primaryBlue,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        "Account Actions",
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _showEditStaffRole(staff);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _primaryBlue,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      icon: const Icon(
                                        LucideIcons.pencil,
                                        size: 16,
                                      ),
                                      label: const Text("Change Role", style: TextStyle(fontFamily: _fontFam)),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _showResetPasswordDialog(staff);
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.black87,
                                        side: BorderSide(
                                          color: Colors.grey.shade300,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      icon: const Icon(
                                        LucideIcons.refreshCw,
                                        size: 16,
                                      ),
                                      label: const Text("Reset Password", style: TextStyle(fontFamily: _fontFam)),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _confirmDeleteStaff(staff);
                                      },
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red,
                                        side: BorderSide(
                                          color: Colors.red.shade200,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      icon: const Icon(
                                        LucideIcons.trash2,
                                        size: 16,
                                      ),
                                      label: const Text("Delete Account", style: TextStyle(fontFamily: _fontFam)),
                                    ),
                                  ),
                                ],
                              ),
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
        ),
      ),
    );
  }

  Widget _buildInfoTile(
    String label,
    String value,
    IconData icon, {
    bool fullWidth = false,
  }) {
    return Container(
      width: fullWidth ? double.infinity : 217,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.grey,
              fontWeight: FontWeight.bold,
              fontFamily: _fontFam,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.grey.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    fontFamily: _fontFam,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── UI BUILDER ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: (_isLoadingSettings)
          ? const Center(child: CircularProgressIndicator(color: _primaryBlue))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "System Settings",
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0F172A),
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Manage global configurations, units, and user accounts",
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontFamily: _fontFam),
                  ),
                  const SizedBox(height: 32),

                  // ─── SECTION 1: GLOBAL STOCK THRESHOLDS ─────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                LucideIcons.triangleAlert,
                                color: Colors.red.shade600,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 16),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Global Stock Thresholds",
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF0F172A),
                                    fontFamily: _fontFam,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  "Set the percentage of an item's usual stock level that triggers stock alerts.",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (_thresholdError != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12.0),
                            child: Text(
                              _thresholdError!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                fontFamily: _fontFam,
                              ),
                            ),
                          ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Low Stock Level (%)",
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _lowPercentCtrl,
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(fontFamily: _fontFam),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'^\d*\.?\d*'),
                                      ),
                                    ],
                                    decoration: InputDecoration(
                                      suffixText: '%',
                                      filled: true,
                                      fillColor: const Color(0xFFF8FAFC),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                          color: Colors.grey.shade300,
                                        ),
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Critical Stock Level (%)",
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _criticalPercentCtrl,
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(fontFamily: _fontFam),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'^\d*\.?\d*'),
                                      ),
                                    ],
                                    decoration: InputDecoration(
                                      suffixText: '%',
                                      filled: true,
                                      fillColor: const Color(0xFFF8FAFC),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(
                                          color: Colors.grey.shade300,
                                        ),
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            SizedBox(
                              height: 48,
                              child: ElevatedButton(
                                onPressed: _isSavingThresholds
                                    ? null
                                    : _saveGlobalThresholds,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF0F172A),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                ),
                                child: _isSavingThresholds
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text(
                                        "Save Thresholds",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ─── SECTION 2: MEASUREMENT UNITS ────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      LucideIcons.ruler,
                                      color: Colors.blue.shade600,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "Measurement Units",
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF0F172A),
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        "Manage available units for inventory items.",
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              ElevatedButton.icon(
                                onPressed: () => _showMeasurementModal(),
                                icon: const Icon(
                                  LucideIcons.plus,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                label: const Text(
                                  "Add Unit",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _primaryBlue,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (_measurements.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(40.0),
                            child: Center(
                              child: Text(
                                "No measurement units found.",
                                style: TextStyle(color: Colors.grey, fontFamily: _fontFam),
                              ),
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _measurements.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = _measurements[index];
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24.0,
                                  vertical: 16.0,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15,
                                              color: Color(0xFF0F172A),
                                              fontFamily: _fontFam,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.grey.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              "Symbol: ${item.symbol}",
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.grey.shade700,
                                                fontFamily: _fontFam,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            LucideIcons.pencil,
                                            size: 18,
                                            color: Colors.grey.shade600,
                                          ),
                                          onPressed: () =>
                                              _showMeasurementModal(item),
                                          tooltip: "Edit",
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            LucideIcons.trash2,
                                            size: 18,
                                            color: Colors.red.shade400,
                                          ),
                                          onPressed: () =>
                                              _confirmDeleteMeasurement(item),
                                          tooltip: "Delete",
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ─── SECTION 3: STAFF MANAGEMENT ───────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.purple.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      LucideIcons.users,
                                      color: Colors.purple.shade600,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  const Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "Staff Management",
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF0F172A),
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        "Manage system access and user roles.",
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                          fontFamily: _fontFam,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              ElevatedButton.icon(
                                onPressed: () => _showAddStaffDialog(),
                                icon: const Icon(
                                  LucideIcons.userPlus,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                label: const Text(
                                  "Add Staff",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _primaryBlue,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (_isLoadingStaff)
                          const Padding(
                            padding: EdgeInsets.all(40.0),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: _primaryBlue,
                              ),
                            ),
                          )
                        else if (_staffList.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(40.0),
                            child: Center(
                              child: Text(
                                "No other staff members found.",
                                style: TextStyle(color: Colors.grey, fontFamily: _fontFam),
                              ),
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _staffList.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final staff = _staffList[index];
                              final isAdmin = staff['role'] == 'admin';
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24.0,
                                  vertical: 12.0,
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 20,
                                      backgroundColor: isAdmin
                                          ? _primaryBlue.withOpacity(0.1)
                                          : Colors.blue.withOpacity(0.1),
                                      child: Icon(
                                        isAdmin
                                            ? LucideIcons.shieldCheck
                                            : LucideIcons.user,
                                        color: isAdmin
                                            ? _primaryBlue
                                            : Colors.blue,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            staff['name'] ?? 'Unknown User',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 15,
                                              color: Color(0xFF0F172A),
                                              fontFamily: _fontFam,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            (staff['role'] ?? 'staff')
                                                .toString()
                                                .toUpperCase(),
                                            style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              fontFamily: _fontFam,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            LucideIcons.eye,
                                            size: 18,
                                            color: Colors.blue,
                                          ),
                                          onPressed: () =>
                                              _showStaffDetailsModal(staff),
                                          tooltip: "View Details",
                                        ),
                                        
                                        IconButton(
                                          icon: Icon(
                                            LucideIcons.trash2,
                                            size: 18,
                                            color: Colors.red.shade400,
                                          ),
                                          onPressed: () =>
                                              _confirmDeleteStaff(staff),
                                          tooltip: "Delete",
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}