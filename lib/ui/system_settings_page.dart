import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../logic/inventory_controller.dart';
import '../logic/staff_management.dart';
import '../services/store_access_service.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart'
    show debugPrint, debugPrintStack, kIsWeb;
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

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
  final StoreAccessService storeAccessService;
  const SystemSettingsPage({
    super.key,
    required this.controller,
    required this.storeAccessService,
  });

  @override
  State<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

class _SystemSettingsPageState extends State<SystemSettingsPage> {
  // Global Settings State
  bool _isLoadingSettings = true;
  List<MeasurementUnit> _measurements = [];

  // Staff State
  bool _isLoadingStaff = true;
  String? _staffLoadError;
  List<Map<String, dynamic>> _staffList = [];
  StreamSubscription<List<Map<String, dynamic>>>? _staffSubscription;
  StreamSubscription<InventoryRuntimeSettingsSnapshot>?
  _runtimeSettingsSubscription;
  StreamSubscription<StoreAccessSettings>? _storeAccessSubscription;

  // Store Hours & Staff Access State
  bool _isLoadingStoreAccess = true;
  bool _isSavingStoreAccess = false;
  TimeOfDay _openingTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _closingTime = const TimeOfDay(hour: 21, minute: 0);
  final TextEditingController _beforeMinutesCtrl = TextEditingController(
    text: '30',
  );
  final TextEditingController _afterMinutesCtrl = TextEditingController(
    text: '30',
  );
  bool _restrictStaffLogin = true;
  bool _allowAdminAnytime = true;
  String? _storeAccessError;
  StoreAccessSettings? _storeAccessBaseline;
  bool _storeAccessConflictNotified = false;

  // Global Threshold State
  final TextEditingController _lowPercentCtrl = TextEditingController();
  final TextEditingController _criticalPercentCtrl = TextEditingController();
  String? _thresholdError;
  bool _isSavingThresholds = false;
  StockThresholdSettings? _thresholdBaseline;
  bool _thresholdConflictNotified = false;

  // Cashier discount approval threshold state.
  final TextEditingController _discountLimitCtrl = TextEditingController();
  double? _discountLimitBaseline;
  String? _discountLimitError;
  bool _isSavingDiscountLimit = false;
  bool _discountLimitConflictNotified = false;

  //QR Uploader
  bool _isUploadingQr = false;

  @override
  void initState() {
    super.initState();
    _runtimeSettingsSubscription = widget.controller
        .streamRuntimeSettings()
        .listen(_handleRuntimeSettingsSnapshot);
    _storeAccessSubscription = widget.storeAccessService
        .streamSettings()
        .listen(_handleStoreAccessSnapshot);
    _staffSubscription = widget.controller.streamStaffConfiguration().listen(
      _handleStaffSnapshot,
      onError: (Object _) => _handleStaffLoadFailure(),
    );
    _fetchSettings();
    _fetchStoreAccessSettings();
  }

  @override
  void dispose() {
    unawaited(_runtimeSettingsSubscription?.cancel());
    unawaited(_storeAccessSubscription?.cancel());
    unawaited(_staffSubscription?.cancel());
    _beforeMinutesCtrl.dispose();
    _afterMinutesCtrl.dispose();
    _lowPercentCtrl.dispose();
    _criticalPercentCtrl.dispose();
    _discountLimitCtrl.dispose();
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

  bool get _thresholdDraftDirty {
    final baseline = _thresholdBaseline;
    if (baseline == null) return false;
    return double.tryParse(_lowPercentCtrl.text) != baseline.low ||
        double.tryParse(_criticalPercentCtrl.text) != baseline.critical;
  }

  bool get _discountLimitDraftDirty {
    final baseline = _discountLimitBaseline;
    if (baseline == null) return false;
    return double.tryParse(_discountLimitCtrl.text) != baseline;
  }

  bool get _storeAccessDraftDirty {
    final baseline = _storeAccessBaseline;
    if (baseline == null) return false;
    return _formatClockTime(_openingTime) != baseline.openingTime ||
        _formatClockTime(_closingTime) != baseline.closingTime ||
        int.tryParse(_beforeMinutesCtrl.text) !=
            baseline.staffAccessBeforeMinutes ||
        int.tryParse(_afterMinutesCtrl.text) !=
            baseline.staffAccessAfterMinutes ||
        _restrictStaffLogin != baseline.restrictStaffLogin ||
        _allowAdminAnytime != baseline.allowAdminAnytime;
  }

  bool _sameStoreAccess(StoreAccessSettings left, StoreAccessSettings right) {
    return left.locationId == right.locationId &&
        left.openingTime == right.openingTime &&
        left.closingTime == right.closingTime &&
        left.staffAccessBeforeMinutes == right.staffAccessBeforeMinutes &&
        left.staffAccessAfterMinutes == right.staffAccessAfterMinutes &&
        left.restrictStaffLogin == right.restrictStaffLogin &&
        left.allowAdminAnytime == right.allowAdminAnytime;
  }

  void _handleRuntimeSettingsSnapshot(
    InventoryRuntimeSettingsSnapshot snapshot,
  ) {
    if (!mounted) return;
    _applyDiscountLimitSnapshot(snapshot);
    if (!snapshot.thresholdsLoaded) {
      setState(() {
        if (snapshot.measurementsLoaded) {
          _measurements = _measurementsFromController();
        }
        _isLoadingSettings = true;
      });
      return;
    }
    final incomingThresholds = StockThresholdSettings(
      low: snapshot.lowStockPercent,
      critical: snapshot.criticalStockPercent,
    );
    final thresholdChanged =
        _thresholdBaseline != null &&
        (_thresholdBaseline!.low != incomingThresholds.low ||
            _thresholdBaseline!.critical != incomingThresholds.critical);
    final incomingMatchesDraft =
        double.tryParse(_lowPercentCtrl.text) == incomingThresholds.low &&
        double.tryParse(_criticalPercentCtrl.text) ==
            incomingThresholds.critical;
    final protectDraft =
        _thresholdDraftDirty && !(_isSavingThresholds && incomingMatchesDraft);
    setState(() {
      if (snapshot.measurementsLoaded) {
        _measurements = _measurementsFromController();
      }
      _isLoadingSettings = !snapshot.measurementsLoaded;
      if (!protectDraft) {
        _lowPercentCtrl.text = _formatPct(incomingThresholds.low);
        _criticalPercentCtrl.text = _formatPct(incomingThresholds.critical);
        _thresholdBaseline = incomingThresholds;
        _thresholdConflictNotified = false;
      } else if (thresholdChanged) {
        // Keep the local draft; the conflict toast is emitted below.
      }
    });
    if (protectDraft && thresholdChanged && !_thresholdConflictNotified) {
      _thresholdConflictNotified = true;
      _showConflictToast(
        'Stock thresholds changed elsewhere. Your unsaved values were kept.',
      );
    }
  }

  void _applyDiscountLimitSnapshot(InventoryRuntimeSettingsSnapshot snapshot) {
    if (!snapshot.paymentLoaded) return;
    final incoming = snapshot.cashierAutoApprovedDiscountLimitPct;
    final changed =
        _discountLimitBaseline != null && _discountLimitBaseline != incoming;
    final incomingMatchesDraft =
        double.tryParse(_discountLimitCtrl.text) == incoming;
    final protectDraft =
        _discountLimitDraftDirty &&
        !(_isSavingDiscountLimit && incomingMatchesDraft);
    setState(() {
      if (!protectDraft) {
        _discountLimitCtrl.text = _formatPct(incoming);
        _discountLimitBaseline = incoming;
        _discountLimitConflictNotified = false;
      }
    });
    if (protectDraft && changed && !_discountLimitConflictNotified) {
      _discountLimitConflictNotified = true;
      _showConflictToast(
        'The cashier discount limit changed elsewhere. '
        'Your unsaved value was kept.',
      );
    }
  }

  void _handleStoreAccessSnapshot(StoreAccessSettings settings) {
    if (!mounted || settings.locationId != widget.controller.activeLocationId) {
      return;
    }
    final changed =
        _storeAccessBaseline != null &&
        !_sameStoreAccess(_storeAccessBaseline!, settings);
    final incomingMatchesDraft =
        _formatClockTime(_openingTime) == settings.openingTime &&
        _formatClockTime(_closingTime) == settings.closingTime &&
        int.tryParse(_beforeMinutesCtrl.text) ==
            settings.staffAccessBeforeMinutes &&
        int.tryParse(_afterMinutesCtrl.text) ==
            settings.staffAccessAfterMinutes &&
        _restrictStaffLogin == settings.restrictStaffLogin &&
        _allowAdminAnytime == settings.allowAdminAnytime;
    final protectDraft =
        _storeAccessDraftDirty &&
        !(_isSavingStoreAccess && incomingMatchesDraft);
    if (protectDraft) {
      if (changed) {
        if (!_storeAccessConflictNotified) {
          _storeAccessConflictNotified = true;
          _showConflictToast(
            'Store access settings changed elsewhere. Your unsaved values were kept.',
          );
        }
      }
      return;
    }
    _applyStoreAccessToForm(settings);
  }

  void _applyStoreAccessToForm(StoreAccessSettings settings) {
    if (!mounted) return;
    setState(() {
      _storeAccessBaseline = settings;
      _openingTime = _parseClockTime(settings.openingTime);
      _closingTime = _parseClockTime(settings.closingTime);
      _beforeMinutesCtrl.text = settings.staffAccessBeforeMinutes.toString();
      _afterMinutesCtrl.text = settings.staffAccessAfterMinutes.toString();
      _restrictStaffLogin = settings.restrictStaffLogin;
      _allowAdminAnytime = settings.allowAdminAnytime;
      _storeAccessConflictNotified = false;
      _isLoadingStoreAccess = false;
      _storeAccessError = null;
    });
  }

  void _showConflictToast(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppToast.error(context, message);
    });
  }

  void _handleStaffSnapshot(List<Map<String, dynamic>> staff) {
    if (!mounted) return;
    final currentUserId = widget.controller.currentUserId;
    setState(() {
      _staffList = staff
          .where((row) => row['id'].toString() != currentUserId)
          .map(Map<String, dynamic>.from)
          .toList();
      _isLoadingStaff = false;
      _staffLoadError = widget.controller.staffConfigurationLoadFailed
          ? 'Unable to load staff accounts.'
          : null;
    });
  }

  void _handleStaffLoadFailure() {
    if (!mounted) return;
    setState(() {
      _isLoadingStaff = false;
      _staffLoadError = 'Unable to load staff accounts.';
    });
  }

  Future<void> _retryStaffLoad() async {
    setState(() {
      _isLoadingStaff = true;
      _staffLoadError = null;
    });
    final staff = await widget.controller.fetchStaff();
    if (!mounted) return;
    _handleStaffSnapshot(staff);
  }

  Future<void> _uploadGcashQr() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);

    if (file == null) return;

    setState(() => _isUploadingQr = true);

    try {
      String? uploadedUrl;
      final String fileName =
          'gcash_qr_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final path = 'public/$fileName';

      // --- NEW: Upload explicitly to the 'store_assets' bucket ---
      if (kIsWeb) {
        final bytes = await file.readAsBytes();
        await widget.controller.supabase.storage
            .from(
              'store_assets',
            ) // Change to 'store_asset' if you didn't add the 's'
            .uploadBinary(path, bytes);
      } else {
        await widget.controller.supabase.storage
            .from(
              'store_assets',
            ) // Change to 'store_asset' if you didn't add the 's'
            .upload(path, File(file.path));
      }

      // Fetch the public URL from the bucket
      uploadedUrl = widget.controller.supabase.storage
          .from('store_assets')
          .getPublicUrl(path);
      // -----------------------------------------------------------

      if (uploadedUrl.isNotEmpty) {
        await widget.controller.updateGcashQrUrl(uploadedUrl);
        if (mounted) {
          AppToast.success(context, "GCash QR Code updated successfully!");
        }
      } else {
        if (mounted) AppToast.error(context, "Failed to generate image link.");
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        'GCash QR upload failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(e, fallback: AppErrorCategory.upload),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingQr = false);
    }
  }

  Future<void> _fetchSettings() async {
    try {
      await widget.controller.loadSystemSettings();
      if (!mounted) return;
    } catch (e, stackTrace) {
      AppLogger.error(
        'System settings load failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _isLoadingSettings = false);
        _showToast(
          AppErrorMapper.message(e, fallback: AppErrorCategory.dataLoad),
          isError: true,
        );
      }
    }
  }

  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    isError
        ? AppToast.error(context, message)
        : AppToast.success(context, message);
  }

  Future<void> _saveDiscountLimit() async {
    final value = double.tryParse(_discountLimitCtrl.text.trim());
    if (value == null || value < 0 || value > 100) {
      setState(() {
        _discountLimitError = 'Enter a percentage from 0 to 100.';
      });
      return;
    }
    setState(() {
      _discountLimitError = null;
      _isSavingDiscountLimit = true;
    });
    try {
      await widget.controller.updateCashierAutoApprovedDiscountLimit(value);
      if (!mounted) return;
      setState(() {
        _discountLimitBaseline = value;
        _discountLimitConflictNotified = false;
        _isSavingDiscountLimit = false;
      });
      _showToast('Cashier discount limit updated');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Cashier discount limit save failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _isSavingDiscountLimit = false;
        _discountLimitError = AppErrorMapper.message(
          error,
          fallback: AppErrorCategory.dataSave,
        );
      });
    }
  }

  Widget _buildPaymentSettings() {
    final qrUrl = widget.controller.gcashQrUrl;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Payment Settings",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0F172A),
              fontFamily: 'Hellix',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Cashier auto-approved discount limit",
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontFamily: 'Hellix',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _discountLimitCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                  ],
                  onChanged: (_) => setState(() => _discountLimitError = null),
                  decoration: InputDecoration(
                    suffixText: '%',
                    errorText: _discountLimitError,
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _isSavingDiscountLimit ? null : _saveDiscountLimit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: _isSavingDiscountLimit
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Cashier discounts above this effective percentage require Admin approval.',
            style: TextStyle(
              color: Color(0xFF64748B),
              fontSize: 12,
              fontFamily: _fontFam,
            ),
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            "Store GCash QR Code",
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontFamily: 'Hellix',
            ),
          ),
          const SizedBox(height: 12),

          // --- QR Code Display Area ---
          Container(
            height: 240,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: qrUrl.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(qrUrl, fit: BoxFit.contain),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        LucideIcons.qrCode,
                        size: 40,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "No QR code uploaded",
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontFamily: 'Hellix',
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),

          // --- Upload Button ---
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isUploadingQr ? null : _uploadGcashQr,
              icon: _isUploadingQr
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.blue,
                      ),
                    )
                  : const Icon(
                      LucideIcons.uploadCloud,
                      size: 18,
                      color: Colors.blue,
                    ),
              label: Text(
                _isUploadingQr ? "Uploading..." : "Upload GCash QR",
                style: const TextStyle(
                  fontFamily: 'Hellix',
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: Colors.blue.shade100),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── STORE HOURS & STAFF ACCESS ─────────────────────────────────────────────
  Future<void> _fetchStoreAccessSettings() async {
    final locationId = widget.controller.activeLocationId;

    if (locationId == null || locationId.isEmpty) {
      if (mounted) {
        setState(() {
          _isLoadingStoreAccess = false;
          _storeAccessError = 'No active store location found.';
        });
      }
      return;
    }

    try {
      final settings = widget.storeAccessService.currentSettings ??
          await widget.storeAccessService.refreshSettings();

      if (!mounted) return;
      if (_storeAccessBaseline == null) _applyStoreAccessToForm(settings);
    } catch (e, stackTrace) {
      AppLogger.error(
        'Store access settings load failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;

      setState(() {
        _isLoadingStoreAccess = false;
        _storeAccessError = AppErrorMapper.message(
          e,
          fallback: AppErrorCategory.dataLoad,
        );
      });
    }
  }

  Future<void> _saveStoreAccessSettings() async {
    final locationId = widget.controller.activeLocationId;

    if (locationId == null || locationId.isEmpty) {
      _showToast('No active store location found.', isError: true);
      return;
    }

    final beforeMinutes = int.tryParse(_beforeMinutesCtrl.text.trim());
    final afterMinutes = int.tryParse(_afterMinutesCtrl.text.trim());

    if (beforeMinutes == null || afterMinutes == null) {
      setState(() {
        _storeAccessError = 'Allowance minutes must be valid whole numbers.';
      });
      return;
    }

    if (beforeMinutes < 0 ||
        beforeMinutes > 240 ||
        afterMinutes < 0 ||
        afterMinutes > 240) {
      setState(() {
        _storeAccessError = 'Allowance must be between 0 and 240 minutes.';
      });
      return;
    }

    setState(() {
      _isSavingStoreAccess = true;
      _storeAccessError = null;
    });

    try {
      final settings = StoreAccessSettings(
        locationId: locationId,
        openingTime: _formatClockTime(_openingTime),
        closingTime: _formatClockTime(_closingTime),
        staffAccessBeforeMinutes: beforeMinutes,
        staffAccessAfterMinutes: afterMinutes,
        restrictStaffLogin: _restrictStaffLogin,
        allowAdminAnytime: _allowAdminAnytime,
      );

      final latest = await widget.storeAccessService.refreshSettings();
      if (_storeAccessBaseline != null &&
          !_sameStoreAccess(_storeAccessBaseline!, latest)) {
        await _showStoreAccessConflict(latest);
        if (mounted) setState(() => _isSavingStoreAccess = false);
        return;
      }

      await widget.storeAccessService.saveSettings(settings);

      if (!mounted) return;

      setState(() {
        _storeAccessBaseline = settings;
        _storeAccessConflictNotified = false;
        _isSavingStoreAccess = false;
      });

      _showToast('Store hours and access settings updated.');
    } catch (e, stackTrace) {
      AppLogger.error(
        'Store access settings save failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;

      setState(() {
        _isSavingStoreAccess = false;
        _storeAccessError = AppErrorMapper.message(
          e,
          fallback: AppErrorCategory.dataSave,
        );
      });
    }
  }

  Future<void> _showStoreAccessConflict(StoreAccessSettings latest) async {
    final reload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.triangleAlert,
        color: Colors.orange,
        title: 'Store access settings changed',
        subtitle: 'Another client saved a newer version.',
        child: const Text(
          'Your unsaved values are still intact. Reload the latest saved '
          'settings, or keep editing without overwriting them.',
          style: TextStyle(fontFamily: _fontFam),
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
    if (reload == true && mounted) _applyStoreAccessToForm(latest);
  }

  Future<void> _pickStoreTime({required bool isOpening}) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: isOpening ? _openingTime : _closingTime,
      helpText: isOpening ? 'Opening Time' : 'Closing Time',
      cancelText: 'Cancel',
      confirmText: 'Apply',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _primaryBlue,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Color(0xFF0F172A),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
            ),
            timePickerTheme: TimePickerThemeData(
              backgroundColor: Colors.white,
              hourMinuteShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              hourMinuteColor: const Color(0xFFF8FAFC),
              hourMinuteTextColor: const Color(0xFF0F172A),
              dialHandColor: _primaryBlue,
              dialBackgroundColor: const Color(0xFFF1F5F9),
              entryModeIconColor: _primaryBlue,
              dayPeriodColor: WidgetStateColor.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return _primaryBlue;
                }
                return const Color(0xFFF8FAFC);
              }),
              dayPeriodTextColor: WidgetStateColor.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Colors.white;
                }
                return const Color(0xFF0F172A);
              }),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              helpTextStyle: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.w900,
                fontSize: 18,
                fontFamily: _fontFam,
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: _primaryBlue,
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (selected == null) return;

    setState(() {
      if (isOpening) {
        _openingTime = selected;
      } else {
        _closingTime = selected;
      }
    });
  }

  TimeOfDay _parseClockTime(String value) {
    final parts = value.split(':');

    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 8,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  String _formatClockTime(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:00';
  }

  String _formatDisplayTime(TimeOfDay time) {
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    return '$hour12:${time.minute.toString().padLeft(2, '0')} $suffix';
  }

  String _allowedWindowPreview() {
    final before = int.tryParse(_beforeMinutesCtrl.text.trim()) ?? 0;
    final after = int.tryParse(_afterMinutesCtrl.text.trim()) ?? 0;

    final start = _toMinutes(_openingTime) - before;
    final end = _toMinutes(_closingTime) + after;

    return '${_formatMinutes(start)} to ${_formatMinutes(end)}';
  }

  int _toMinutes(TimeOfDay time) {
    return time.hour * 60 + time.minute;
  }

  String _formatMinutes(int totalMinutes) {
    var normalized = totalMinutes % (24 * 60);

    if (normalized < 0) {
      normalized += 24 * 60;
    }

    final hour = normalized ~/ 60;
    final minute = normalized % 60;
    final suffix = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;

    return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }

  Widget _buildStoreAccessSection() {
    return Container(
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
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.schedule,
                  color: Colors.green.shade600,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Store Hours & Staff Access',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        fontFamily: _fontFam,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Control when staff and helpers can access the system.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_isLoadingStoreAccess)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: CircularProgressIndicator(color: _primaryBlue),
              ),
            )
          else ...[
            if (_storeAccessError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Text(
                  _storeAccessError!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    fontFamily: _fontFam,
                  ),
                ),
              ),
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 760;

                final openingField = _buildTimePickerBox(
                  label: 'Opening Time',
                  value: _formatDisplayTime(_openingTime),
                  icon: Icons.wb_sunny_outlined,
                  onTap: () => _pickStoreTime(isOpening: true),
                );
                final closingField = _buildTimePickerBox(
                  label: 'Closing Time',
                  value: _formatDisplayTime(_closingTime),
                  icon: Icons.nights_stay_outlined,
                  onTap: () => _pickStoreTime(isOpening: false),
                );

                return Column(
                  children: [
                    if (isNarrow)
                      Column(
                        children: [
                          openingField,
                          const SizedBox(height: 16),
                          closingField,
                        ],
                      )
                    else
                      Row(
                        children: [
                          Expanded(child: openingField),
                          const SizedBox(width: 16),
                          Expanded(child: closingField),
                        ],
                      ),
                    const SizedBox(height: 16),
                    if (isNarrow)
                      Column(
                        children: [
                          _buildMinutesField(
                            controller: _beforeMinutesCtrl,
                            label: 'Before Opening Allowance',
                            hint: '30',
                          ),
                          const SizedBox(height: 16),
                          _buildMinutesField(
                            controller: _afterMinutesCtrl,
                            label: 'After Closing Allowance',
                            hint: '30',
                          ),
                        ],
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: _buildMinutesField(
                              controller: _beforeMinutesCtrl,
                              label: 'Before Opening Allowance',
                              hint: '30',
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildMinutesField(
                              controller: _afterMinutesCtrl,
                              label: 'After Closing Allowance',
                              hint: '30',
                            ),
                          ),
                        ],
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text(
                'Current staff access window: ${_allowedWindowPreview()}',
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.w700,
                  fontFamily: _fontFam,
                ),
              ),
            ),
            const SizedBox(height: 18),
            SwitchListTile.adaptive(
              value: _restrictStaffLogin,
              contentPadding: EdgeInsets.zero,
              activeColor: _primaryBlue,
              title: const Text(
                'Restrict staff/helper login to store hours',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
              subtitle: const Text(
                'When enabled, staff and helpers can only login within the allowed access window.',
                style: TextStyle(fontFamily: _fontFam),
              ),
              onChanged: (value) {
                setState(() => _restrictStaffLogin = value);
              },
            ),
            SwitchListTile.adaptive(
              value: _allowAdminAnytime,
              contentPadding: EdgeInsets.zero,
              activeColor: _primaryBlue,
              title: const Text(
                'Allow admin login anytime',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
              ),
              subtitle: const Text(
                'Recommended: keep this on so admin can access settings outside store hours.',
                style: TextStyle(fontFamily: _fontFam),
              ),
              onChanged: (value) {
                setState(() => _allowAdminAnytime = value);
              },
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _isSavingStoreAccess
                    ? null
                    : _saveStoreAccessSettings,
                icon: _isSavingStoreAccess
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.save_outlined,
                        size: 16,
                        color: Colors.white,
                      ),
                label: const Text(
                  'Save Access Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
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
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimePickerBox({
    required String label,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFF8892A4), size: 16),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontWeight: FontWeight.w700,
                      fontFamily: _fontFam,
                    ),
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down, size: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMinutesField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontFamily: _fontFam),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: hint,
            suffixText: 'minutes',
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
        ),
      ],
    );
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
      final latest = await widget.controller.fetchStockThresholdSettings();
      final baseline = _thresholdBaseline;
      if (baseline != null &&
          (baseline.low != latest.low ||
              baseline.critical != latest.critical)) {
        setState(() {
          _isSavingThresholds = false;
        });
        await _showThresholdConflict(latest);
        return;
      }

      await widget.controller.updateGlobalThresholds(lowVal, critVal);

      if (mounted) {
        setState(() {
          _thresholdBaseline = StockThresholdSettings(
            low: lowVal,
            critical: critVal,
          );
          _thresholdConflictNotified = false;
          _isSavingThresholds = false;
        });
        _showToast("Global thresholds updated successfully");
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        'Inventory threshold save failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _isSavingThresholds = false;
          _thresholdError = AppErrorMapper.message(
            e,
            fallback: AppErrorCategory.dataSave,
          );
        });
      }
    }
  }

  Future<void> _showThresholdConflict(StockThresholdSettings latest) async {
    final reload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.triangleAlert,
        color: Colors.orange,
        title: 'Stock thresholds changed',
        subtitle: 'Another client saved newer threshold values.',
        child: const Text(
          'Your unsaved values are still intact. Reload the latest saved '
          'thresholds, or keep editing.',
          style: TextStyle(fontFamily: _fontFam),
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
        _lowPercentCtrl.text = _formatPct(latest.low);
        _criticalPercentCtrl.text = _formatPct(latest.critical);
        _thresholdBaseline = latest;
        _thresholdConflictNotified = false;
      });
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
                final latest = await widget.controller.fetchMeasurement(
                  existing.id,
                );
                if (latest == null) {
                  setModalState(() => saving = false);
                  _showToast(
                    'This measurement was deleted elsewhere.',
                    isError: true,
                  );
                  return;
                }
                final latestName = latest['name']?.toString() ?? '';
                final latestSymbol = latest['symbol']?.toString() ?? '';
                if (latestName != existing.name ||
                    latestSymbol != existing.symbol) {
                  if (!dialogContext.mounted) return;
                  final reload = await showDialog<bool>(
                    context: dialogContext,
                    builder: (conflictContext) => AppDialog(
                      icon: LucideIcons.triangleAlert,
                      color: Colors.orange,
                      title: 'Measurement changed',
                      subtitle: 'A newer saved value is available.',
                      child: const Text(
                        'Your unsaved values were kept. Reload the latest '
                        'measurement, or keep editing.',
                        style: TextStyle(fontFamily: _fontFam),
                      ),
                      actions: [
                        OutlinedButton(
                          onPressed: () =>
                              Navigator.pop(conflictContext, false),
                          child: const Text('Keep Editing'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(conflictContext, true),
                          child: const Text('Reload Latest'),
                        ),
                      ],
                    ),
                  );
                  if (reload == true) {
                    existing.name = latestName;
                    existing.symbol = latestSymbol;
                    nameCtrl.text = latestName;
                    symbolCtrl.text = latestSymbol;
                  }
                  if (dialogContext.mounted) {
                    setModalState(() => saving = false);
                  }
                  return;
                }
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
            } catch (e, stackTrace) {
              AppLogger.error(
                'Measurement save failed',
                error: e,
                stackTrace: stackTrace,
              );
              setModalState(() => saving = false);
              _showToast(
                AppErrorMapper.message(
                  e,
                  fallback: AppErrorCategory.dataSave,
                ),
                isError: true,
              );
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
                child: const Text(
                  "Cancel",
                  style: TextStyle(fontFamily: _fontFam),
                ),
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
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 13,
            fontFamily: _fontFam,
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
                await widget.controller.deleteMeasurement(item.id);
                if (mounted) {
                  setState(() => _measurements = _measurementsFromController());
                }
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast("Measurement deleted");
              } catch (e, stackTrace) {
                AppLogger.error(
                  'Measurement delete failed',
                  error: e,
                  stackTrace: stackTrace,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast(
                  AppErrorMapper.message(
                    e,
                    fallback: AppErrorCategory.dataSave,
                  ),
                  isError: true,
                );
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
          style: const TextStyle(
            color: Color(0xFF1A1F36),
            fontSize: 14,
            fontFamily: _fontFam,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              color: Color(0xFFB0B7C3),
              fontFamily: _fontFam,
            ),
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

  String _staffCreationFailureMessage(StaffCreationFailure? failure) {
    return switch (failure) {
      StaffCreationFailure.duplicateUsername =>
        'That username is already in use.',
      StaffCreationFailure.duplicateEmail =>
        'That email address is already assigned to another account.',
      StaffCreationFailure.duplicatePhone =>
        'That phone number is already assigned to another account.',
      StaffCreationFailure.backendUnavailable =>
        'Staff creation is temporarily unavailable. Please try again later.',
      StaffCreationFailure.unauthorized =>
        'Your session is not authorized to create staff accounts.',
      StaffCreationFailure.databaseConflict ||
      StaffCreationFailure.unexpected ||
      null => 'Could not create staff. Please try again.',
    };
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
                        DropdownMenuItem(
                          value: 'staff',
                          child: Text(
                            'Staff',
                            style: TextStyle(fontFamily: _fontFam),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'admin',
                          child: Text(
                            'Admin',
                            style: TextStyle(fontFamily: _fontFam),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'helper',
                          child: Text(
                            'Helper',
                            style: TextStyle(fontFamily: _fontFam),
                          ),
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
                child: const Text(
                  "Cancel",
                  style: TextStyle(fontFamily: _fontFam),
                ),
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
                          final result = await widget.controller.createStaff(
                            name: nameCtrl.text.trim(),
                            username: userCtrl.text.trim(),
                            password: defaultPassword,
                            email: emailCtrl.text.trim(),
                            phone: phoneCtrl.text.trim(),
                            address: addressCtrl.text.trim(),
                            role: selectedRole,
                          );
                          if (result.success) {
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            _showToast("Staff created successfully.");
                          } else {
                            setModalState(() => isSaving = false);
                            _showToast(
                              _staffCreationFailureMessage(result.failure),
                              isError: true,
                            );
                          }
                        } catch (error, stackTrace) {
                          setModalState(() => isSaving = false);
                          debugPrint(
                            '[StaffCreation] unexpected UI failure '
                            'type=${error.runtimeType}',
                          );
                          debugPrintStack(stackTrace: stackTrace);
                          _showToast(
                            'Could not create staff. Please try again.',
                            isError: true,
                          );
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
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
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
              key: ValueKey<String>(selectedRole),
              initialValue: selectedRole,
              style: const TextStyle(
                fontFamily: _fontFam,
                color: Colors.black87,
                fontSize: 14,
              ),
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
                DropdownMenuItem(
                  value: 'staff',
                  child: Text('Staff', style: TextStyle(fontFamily: _fontFam)),
                ),
                DropdownMenuItem(
                  value: 'admin',
                  child: Text('Admin', style: TextStyle(fontFamily: _fontFam)),
                ),
                DropdownMenuItem(
                  value: 'helper',
                  child: Text('Helper', style: TextStyle(fontFamily: _fontFam)),
                ),
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
                child: const Text(
                  "Cancel",
                  style: TextStyle(fontFamily: _fontFam),
                ),
              ),
              ElevatedButton(
                onPressed: isSaving
                    ? null
                    : () async {
                        setModalState(() => isSaving = true);
                        try {
                          final latest = await widget.controller
                              .fetchStaffProfile(staff['id'].toString());
                          if (latest == null) {
                            setModalState(() => isSaving = false);
                            _showToast(
                              'This staff account was removed elsewhere.',
                              isError: true,
                            );
                            return;
                          }
                          final latestRole =
                              latest['role']?.toString() ?? 'staff';
                          final baselineRole =
                              staff['role']?.toString() ?? 'staff';
                          if (latestRole != baselineRole) {
                            if (!dialogContext.mounted) return;
                            final reload = await showDialog<bool>(
                              context: dialogContext,
                              builder: (conflictContext) => AppDialog(
                                icon: LucideIcons.triangleAlert,
                                color: Colors.orange,
                                title: 'Staff role changed',
                                subtitle: 'Another admin saved a newer role.',
                                child: const Text(
                                  'Your unsaved selection was kept. Reload '
                                  'the latest role, or keep editing.',
                                  style: TextStyle(fontFamily: _fontFam),
                                ),
                                actions: [
                                  OutlinedButton(
                                    onPressed: () =>
                                        Navigator.pop(conflictContext, false),
                                    child: const Text('Keep Editing'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () =>
                                        Navigator.pop(conflictContext, true),
                                    child: const Text('Reload Latest'),
                                  ),
                                ],
                              ),
                            );
                            if (reload == true) {
                              staff['role'] = latestRole;
                              selectedRole = latestRole;
                            }
                            if (dialogContext.mounted) {
                              setModalState(() => isSaving = false);
                            }
                            return;
                          }
                          final success = await widget.controller
                              .updateStaffRole(
                                staff['id'].toString(),
                                selectedRole,
                              );
                          if (success) {
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            _showToast("Role updated successfully.");
                          } else {
                            setModalState(() => isSaving = false);
                            _showToast("Error updating role", isError: true);
                          }
                        } catch (e, stackTrace) {
                          AppLogger.error(
                            'Staff role update failed',
                            error: e,
                            stackTrace: stackTrace,
                          );
                          setModalState(() => isSaving = false);
                          _showToast(
                            AppErrorMapper.message(
                              e,
                              fallback: AppErrorCategory.dataSave,
                            ),
                            isError: true,
                          );
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
                    : const Text(
                        "Save Changes",
                        style: TextStyle(fontFamily: _fontFam),
                      ),
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
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: _fontFam,
                ),
              ),
              const TextSpan(
                text: "?\n\nIt will be updated to: ",
                style: TextStyle(fontFamily: _fontFam),
              ),
              TextSpan(
                text: newPass,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _primaryBlue,
                  fontSize: 16,
                  fontFamily: _fontFam,
                ),
              ),
              if (roleRequiresForcedPasswordChange(staff['role']?.toString()))
                const TextSpan(
                  text:
                      "\n\nThe staff member will be required to change this password before continuing.",
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
                  _showToast('Password reset successfully.');
                } else if (mounted) {
                  _showToast(
                    'Failed to reset password. Please try again.',
                    isError: true,
                  );
                }
              } catch (e, stackTrace) {
                AppLogger.error(
                  'Admin password reset failed',
                  error: e,
                  stackTrace: stackTrace,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast(
                  AppErrorMapper.message(
                    e,
                    fallback: AppErrorCategory.dataSave,
                  ),
                  isError: true,
                );
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
            child: const Text(
              "Confirm Reset",
              style: TextStyle(fontFamily: _fontFam),
            ),
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
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 13,
            fontFamily: _fontFam,
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
                final success = await widget.controller.deleteStaff(
                  staff['id'].toString(),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (success) {
                  _showToast("Staff account deleted");
                } else {
                  _showToast("Failed to delete staff account.", isError: true);
                }
              } catch (e, stackTrace) {
                AppLogger.error(
                  'Staff deletion failed',
                  error: e,
                  stackTrace: stackTrace,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _showToast(
                  AppErrorMapper.message(
                    e,
                    fallback: AppErrorCategory.dataSave,
                  ),
                  isError: true,
                );
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
                                      label: const Text(
                                        "Change Role",
                                        style: TextStyle(fontFamily: _fontFam),
                                      ),
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
                                      label: const Text(
                                        "Reset Password",
                                        style: TextStyle(fontFamily: _fontFam),
                                      ),
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
                                      label: const Text(
                                        "Delete Account",
                                        style: TextStyle(fontFamily: _fontFam),
                                      ),
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
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 13,
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ─── SECTION 1: STORE HOURS & STAFF ACCESS ─────────────────────
                  _buildStoreAccessSection(),
                  const SizedBox(height: 24),

                  // ─── SECTION 2: STAFF MANAGEMENT ───────────────────────────────
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
                        else if (_staffLoadError != null)
                          Padding(
                            padding: const EdgeInsets.all(40.0),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _staffLoadError!,
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    onPressed: _retryStaffLoad,
                                    icon: const Icon(LucideIcons.refreshCw),
                                    label: const Text('Retry'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else if (_staffList.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(40.0),
                            child: Center(
                              child: Text(
                                "No other staff members found.",
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontFamily: _fontFam,
                                ),
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
                  const SizedBox(height: 24),

                  // ─── SECTION 3: GLOBAL STOCK THRESHOLDS ─────────────────────
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
                                    style: const TextStyle(
                                      fontFamily: _fontFam,
                                    ),
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
                                    style: const TextStyle(
                                      fontFamily: _fontFam,
                                    ),
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

                  // ─── SECTION 4: MEASUREMENT UNITS ────────────────────────────
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
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontFamily: _fontFam,
                                ),
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
                  // --- ADD THESE TWO LINES ---
                  _buildPaymentSettings(),
                  const SizedBox(height: 48),
                  // ---------------------------
                ],
              ),
            ),
    );
  }
}
