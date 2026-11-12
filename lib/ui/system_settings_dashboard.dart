// The extension keeps the dashboard layout separate from the existing page.
// ignore_for_file: invalid_use_of_protected_member
part of 'system_settings_page.dart';

typedef _DashboardExtrasBaseline = ({
  bool autoAssignOrders,
  String maxHelperOrders,
  String maxApprovedDiscount,
  bool gcashEnabled,
  String gcashAccountName,
  String gcashNumber,
});

enum _SettingsSection { stock, hours, pos }

extension _SettingsDashboard on _SystemSettingsPageState {
  static const _ink = Color(0xFF171717);
  static const _muted = Color(0xFF83776F);
  static const _line = Color(0xFFE9E2DC);
  static const _orange = Color(0xFFC94008);

  void _captureDashboardExtrasBaseline({
    required bool autoAssignOrders,
    required String maxHelperOrders,
  }) {
    _dashboardExtrasBaseline = (
      autoAssignOrders: autoAssignOrders,
      maxHelperOrders: maxHelperOrders,
      maxApprovedDiscount: _maxApprovedDiscountCtrl.text.trim(),
      gcashEnabled: _gcashEnabled,
      gcashAccountName: _gcashAccountCtrl.text.trim(),
      gcashNumber: _gcashNumberCtrl.text.trim(),
    );
  }

  bool get _dashboardSectionDirty {
    return switch (_selectedSettingsSection) {
      _SettingsSection.stock => _thresholdDraftDirty,
      _SettingsSection.hours => _storeAccessDraftDirty,
      _SettingsSection.pos => _posDetailsDirty || _pendingGcashQrBytes != null,
    };
  }

  bool get _posDetailsDirty {
    final baseline = _dashboardExtrasBaseline;
    return baseline != null &&
        (_discountLimitDraftDirty ||
            _maxApprovedDiscountCtrl.text.trim() !=
                baseline.maxApprovedDiscount ||
            _gcashDetailsDirty);
  }

  bool get _gcashDetailsDirty {
    final baseline = _dashboardExtrasBaseline;
    return baseline != null &&
        (_gcashEnabled != baseline.gcashEnabled ||
            _gcashAccountCtrl.text.trim() != baseline.gcashAccountName ||
            _gcashNumberCtrl.text.trim() != baseline.gcashNumber);
  }

  bool get _dashboardSaving =>
      _isSavingDashboard ||
      _isSavingThresholds ||
      _isSavingStoreAccess ||
      _isSavingDiscountLimit ||
      _isUploadingQr;

  Future<void> _loadDashboardExtras() async {
    final locationId = widget.controller.activeLocationId;
    if (locationId == null) {
      if (mounted) setState(() => _isLoadingDashboardExtras = false);
      return;
    }
    try {
      final row = await widget.controller.supabase
          .from('store_settings')
          .select(
            'auto_assign_orders, max_active_orders_per_helper, '
            'max_approved_discount_pct, gcash_enabled, gcash_account_name, '
            'gcash_number',
          )
          .eq('location_id', locationId)
          .maybeSingle();
      if (!mounted || widget.controller.activeLocationId != locationId) return;
      setState(() {
        _maxApprovedDiscountCtrl.text = _formatPct(
          (row?['max_approved_discount_pct'] as num?)?.toDouble() ?? 25,
        );
        _gcashEnabled = row?['gcash_enabled'] != false;
        _gcashAccountCtrl.text = row?['gcash_account_name']?.toString() ?? '';
        _gcashNumberCtrl.text = row?['gcash_number']?.toString() ?? '';
        _captureDashboardExtrasBaseline(
          autoAssignOrders: row?['auto_assign_orders'] != false,
          maxHelperOrders:
              '${(row?['max_active_orders_per_helper'] as num?)?.toInt() ?? 3}',
        );
        _isLoadingDashboardExtras = false;
        _dashboardError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingDashboardExtras = false;
        _dashboardError = 'New settings require the Settings SQL migration.';
      });
    }
  }

  Future<bool> _saveDashboardExtras() async {
    final baseline = _dashboardExtrasBaseline;
    if (baseline == null) return false;
    final defaultLimit = double.tryParse(_discountLimitCtrl.text.trim());
    final maxHelperOrders = int.tryParse(baseline.maxHelperOrders);
    final maxApprovedDiscount = double.tryParse(
      _maxApprovedDiscountCtrl.text.trim(),
    );
    if (maxHelperOrders == null ||
        maxHelperOrders < 1 ||
        maxHelperOrders > 30 ||
        maxApprovedDiscount == null ||
        !maxApprovedDiscount.isFinite ||
        maxApprovedDiscount < 0 ||
        maxApprovedDiscount > 100 ||
        defaultLimit == null ||
        !defaultLimit.isFinite ||
        defaultLimit < 0 ||
        defaultLimit > maxApprovedDiscount) {
      setState(() => _dashboardError = 'Review the order and discount limits.');
      return false;
    }
    setState(() {
      _isSavingDashboard = true;
      _dashboardError = null;
    });
    try {
      await widget.controller.saveSettingsDashboardExtras(
        autoAssignOrders: baseline.autoAssignOrders,
        maxHelperOrders: maxHelperOrders,
        maxApprovedDiscount: maxApprovedDiscount,
        defaultCashierLimit: defaultLimit,
        acceptGcash: _gcashEnabled,
        gcashAccountName: _gcashAccountCtrl.text,
        gcashNumber: _gcashNumberCtrl.text,
      );
      if (!mounted) return false;
      setState(() {
        _discountLimitBaseline = defaultLimit;
        _dashboardExtrasBaseline = (
          autoAssignOrders: baseline.autoAssignOrders,
          maxHelperOrders: baseline.maxHelperOrders,
          maxApprovedDiscount: _maxApprovedDiscountCtrl.text.trim(),
          gcashEnabled: _gcashEnabled,
          gcashAccountName: _gcashAccountCtrl.text.trim(),
          gcashNumber: _gcashNumberCtrl.text.trim(),
        );
      });
      _showToast('Settings saved');
      return true;
    } catch (error, stackTrace) {
      AppLogger.error(
        'Dashboard settings save failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _dashboardError = AppErrorMapper.message(
            error,
            fallback: AppErrorCategory.dataSave,
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _isSavingDashboard = false);
    }
  }

  Future<void> _saveDashboardSection() async {
    if (!_dashboardSectionDirty || _dashboardSaving) return;
    switch (_selectedSettingsSection) {
      case _SettingsSection.stock:
        await _saveGlobalThresholds();
        return;
      case _SettingsSection.hours:
        await _saveStoreAccessSettings();
        return;
      case _SettingsSection.pos:
        if (_posDetailsDirty && !await _saveDashboardExtras()) {
          return;
        }
        await _savePendingGcashQr();
        return;
    }
  }

  void _discardDashboardSection() {
    switch (_selectedSettingsSection) {
      case _SettingsSection.stock:
        final value = _thresholdBaseline;
        if (value != null) {
          _lowPercentCtrl.text = _formatPct(value.low);
          _criticalPercentCtrl.text = _formatPct(value.critical);
        }
        break;
      case _SettingsSection.hours:
        final value = _storeAccessBaseline;
        if (value != null) _applyStoreAccessToForm(value);
        break;
      case _SettingsSection.pos:
        final value = _discountLimitBaseline;
        if (value != null) _discountLimitCtrl.text = _formatPct(value);
        final baseline = _dashboardExtrasBaseline;
        if (baseline != null) {
          _maxApprovedDiscountCtrl.text = baseline.maxApprovedDiscount;
        }
        final gcash = _dashboardExtrasBaseline;
        if (gcash != null) {
          _gcashEnabled = gcash.gcashEnabled;
          _gcashAccountCtrl.text = gcash.gcashAccountName;
          _gcashNumberCtrl.text = gcash.gcashNumber;
        }
        _pendingGcashQrBytes = null;
        _pendingGcashQrFingerprint = null;
        _pendingGcashQrOperationId = null;
        break;
    }
    setState(() => _dashboardError = null);
  }

  Future<void> _chooseGcashQr() async {
    try {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) throw StateError('The selected image is empty.');
      if (!mounted) return;
      final croppedBytes = await showSquareImageCropDialog(context, bytes);
      if (croppedBytes == null || !mounted) return;
      setState(() {
        _pendingGcashQrBytes = croppedBytes;
        _pendingGcashQrFingerprint = null;
        _pendingGcashQrOperationId = null;
        _dashboardError = null;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'GCash QR selection failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _dashboardError = AppErrorMapper.message(
            error,
            fallback: AppErrorCategory.upload,
          ),
        );
      }
    }
  }

  Future<void> _savePendingGcashQr() async {
    final bytes = _pendingGcashQrBytes;
    if (bytes == null || !mounted) return;
    setState(() => _isUploadingQr = true);
    try {
      final fingerprint = widget.controller.gcashQrAssetFingerprint(bytes);
      final operationId =
          _pendingGcashQrFingerprint == fingerprint &&
              _pendingGcashQrOperationId != null
          ? _pendingGcashQrOperationId!
          : widget.controller.newOperationId('gcash-qr');
      _pendingGcashQrFingerprint = fingerprint;
      _pendingGcashQrOperationId = operationId;
      final uploadedUrl = await widget.controller.replaceGcashQrAsset(
        bytes,
        operationId: operationId,
      );
      if (uploadedUrl.isEmpty) throw StateError('Could not save the QR image.');
      if (!mounted) return;
      setState(() {
        _pendingGcashQrBytes = null;
        _pendingGcashQrFingerprint = null;
        _pendingGcashQrOperationId = null;
        _dashboardError = null;
      });
      _showToast('GCash QR image saved');
    } catch (error, stackTrace) {
      AppLogger.error(
        'GCash QR upload failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _dashboardError = AppErrorMapper.message(
            error,
            fallback: AppErrorCategory.upload,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingQr = false);
    }
  }

  Widget _buildSettingsDashboard(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 720;
    final busy =
        _isLoadingSettings ||
        _isLoadingStoreAccess ||
        _isLoadingDashboardExtras;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5F3),
      bottomNavigationBar: mobile && !busy ? _mobileSettingsActions() : null,
      body: busy
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : SingleChildScrollView(
              padding: mobile
                  ? const EdgeInsets.fromLTRB(12, 10, 12, 24)
                  : const EdgeInsets.fromLTRB(36, 40, 36, 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Settings',
                        style: TextStyle(
                          fontFamily: _fontFam,
                          fontSize: mobile ? 22 : 27,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                      if (!mobile) ...[
                        const SizedBox(height: 5),
                        const Text(
                          'Store-wide rules and preferences.',
                          style: TextStyle(
                            fontFamily: _fontFam,
                            fontSize: 15,
                            color: _muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: mobile ? 10 : 30),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 720;
                      final nav = narrow
                          ? SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _mobileSectionTab(
                                    'Stock & units',
                                    _SettingsSection.stock,
                                  ),
                                  _mobileSectionTab(
                                    'Store hours & access',
                                    _SettingsSection.hours,
                                  ),
                                  _mobileSectionTab(
                                    'POS settings',
                                    _SettingsSection.pos,
                                  ),
                                ],
                              ),
                            )
                          : SizedBox(
                              width: 270,
                              child: Column(
                                children: [
                                  _sectionButton(
                                    'Stock & units',
                                    _SettingsSection.stock,
                                  ),
                                  _sectionButton(
                                    'Store hours & access',
                                    _SettingsSection.hours,
                                  ),
                                  _sectionButton(
                                    'POS settings',
                                    _SettingsSection.pos,
                                  ),
                                ],
                              ),
                            );
                      final card = _settingsCard(mobile: narrow);
                      return narrow
                          ? Column(
                              children: [nav, const SizedBox(height: 8), card],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                nav,
                                const SizedBox(width: 30),
                                Expanded(child: card),
                              ],
                            );
                    },
                  ),
                ],
              ),
            ),
    );
  }

  Widget _mobileSectionTab(String label, _SettingsSection section) {
    final selected = _selectedSettingsSection == section;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton(
        onPressed: () => setState(() => _selectedSettingsSection = section),
        style: OutlinedButton.styleFrom(
          foregroundColor: selected ? _orange : _muted,
          backgroundColor: selected ? const Color(0xFFFFF0E8) : Colors.white,
          side: BorderSide(color: selected ? _orange : _line),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  Widget _mobileSettingsActions() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _dashboardSectionDirty && !_dashboardSaving
                  ? _discardDashboardSection
                  : null,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                shape: const StadiumBorder(),
              ),
              child: const Text('Discard'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _dashboardSectionDirty && !_dashboardSaving
                  ? _saveDashboardSection
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: _orange,
                minimumSize: const Size(0, 46),
                shape: const StadiumBorder(),
              ),
              child: Text(_dashboardSaving ? 'Saving…' : 'Save changes'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sectionButton(String label, _SettingsSection section) {
    final selected = _selectedSettingsSection == section;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _selectedSettingsSection = section),
          child: SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: _fontFam,
                    fontSize: 15,
                    color: _ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsCard({bool mobile = false}) {
    final title = switch (_selectedSettingsSection) {
      _SettingsSection.stock => 'Stock & units',
      _SettingsSection.hours => 'Store hours & access',
      _SettingsSection.pos => 'POS settings',
    };
    final subtitle = switch (_selectedSettingsSection) {
      _SettingsSection.stock =>
        'Stock alerts and the units products can be sold in.',
      _SettingsSection.hours => 'When the store is open and staff may sign in.',
      _SettingsSection.pos => 'Discount rules and GCash checkout details.',
    };
    final body = switch (_selectedSettingsSection) {
      _SettingsSection.stock => _stockSection(),
      _SettingsSection.hours => _hoursSection(mobile: mobile),
      _SettingsSection.pos => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Discounts',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          const Text(
            'How much cashiers may discount before approval.',
            style: TextStyle(color: _muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          _discountSection(),
          const SizedBox(height: 24),
          const Divider(color: _line),
          const SizedBox(height: 20),
          const Text(
            'GCash payments',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          _gcashSection(),
        ],
      ),
    };
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.all(mobile ? 12 : 26),
            child: LayoutBuilder(
              builder: (context, limits) {
                final heading = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 9,
                      runSpacing: 5,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: _fontFam,
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                          ),
                        ),
                        if (_selectedSettingsSection == _SettingsSection.pos)
                          _gcashStatusBadge(),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontFamily: _fontFam,
                        fontSize: 14,
                        color: _muted,
                      ),
                    ),
                  ],
                );
                if (_selectedSettingsSection != _SettingsSection.pos) {
                  if (mobile &&
                      _selectedSettingsSection == _SettingsSection.hours) {
                    return Row(
                      children: [
                        Expanded(child: heading),
                        TextButton(
                          onPressed: _copyMondayToAll,
                          style: TextButton.styleFrom(
                            foregroundColor: _orange,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: const Text(
                            'Copy Mon to all',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    );
                  }
                  return heading;
                }
                if (limits.maxWidth < 420) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      heading,
                      const SizedBox(height: 12),
                      _gcashToggle(),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: heading),
                    const SizedBox(width: 14),
                    _gcashToggle(),
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1, color: _line),
          Padding(
            padding: EdgeInsets.all(
              mobile && _selectedSettingsSection == _SettingsSection.hours
                  ? 0
                  : mobile
                  ? 16
                  : 26,
            ),
            child: body,
          ),
          if (_dashboardError != null ||
              (_selectedSettingsSection == _SettingsSection.stock &&
                  _thresholdError != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 26, 18),
              child: Text(
                _dashboardError ?? _thresholdError!,
                style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 13),
              ),
            ),
          if (!mobile)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
              decoration: const BoxDecoration(
                color: Color(0xFFFAF8F6),
                border: Border(top: BorderSide(color: _line)),
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _dashboardSectionDirty && !_dashboardSaving
                          ? _discardDashboardSection
                          : null,
                      child: const Text('Discard changes'),
                    ),
                    FilledButton(
                      onPressed: _dashboardSectionDirty && !_dashboardSaving
                          ? _saveDashboardSection
                          : null,
                      style: FilledButton.styleFrom(backgroundColor: _orange),
                      child: Text(
                        _dashboardSaving ? 'Saving…' : 'Save changes',
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _gcashStatusBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: _gcashEnabled ? const Color(0xFFEAF8EF) : const Color(0xFFF1EFEC),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      _gcashEnabled ? 'Accepting' : 'Off',
      style: TextStyle(
        color: _gcashEnabled ? const Color(0xFF15803D) : _muted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _gcashToggle() => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 250),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Flexible(
          child: Text(
            'Accept GCash at the register',
            style: TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(width: 6),
        Checkbox(
          value: _gcashEnabled,
          activeColor: _orange,
          onChanged: (value) => setState(() => _gcashEnabled = value ?? false),
        ),
      ],
    ),
  );

  Widget _numberField(
    String label,
    TextEditingController controller, {
    double? width = 260,
    String? hint,
    bool compact = false,
  }) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: compact ? const TextStyle(fontSize: 12) : null,
        contentPadding: compact
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 12)
            : null,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget _stockSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 600
            ? Row(
                children: [
                  Expanded(
                    child: _numberField(
                      'Critical at (% of max)',
                      _criticalPercentCtrl,
                      width: double.infinity,
                      compact: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _numberField(
                      'Low stock at (% of max)',
                      _lowPercentCtrl,
                      width: double.infinity,
                      compact: true,
                    ),
                  ),
                ],
              )
            : Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _numberField('Critical at (% of max)', _criticalPercentCtrl),
                  _numberField('Low stock at (% of max)', _lowPercentCtrl),
                ],
              ),
      ),
      const SizedBox(height: 20),
      StockThresholdPreview(
        lowPercent: double.tryParse(_lowPercentCtrl.text),
        criticalPercent: double.tryParse(_criticalPercentCtrl.text),
      ),
      const SizedBox(height: 28),
      const Text(
        'Measurement units',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          children: [
            for (final unit in _measurements)
              Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _line)),
                ),
                child: ListTile(
                  dense: true,
                  title: Text(unit.name),
                  leading: SizedBox(
                    width: 58,
                    child: Text(
                      unit.symbol,
                      style: const TextStyle(color: _muted),
                    ),
                  ),
                  onTap: () => _showMeasurementModal(unit),
                  trailing: IconButton(
                    icon: const Icon(LucideIcons.trash2, size: 17),
                    tooltip: 'Delete ${unit.name}',
                    onPressed: () => _confirmDeleteMeasurement(unit),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _showMeasurementModal(),
                icon: const Icon(LucideIcons.plus, size: 17),
                label: const Text('Add unit'),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  void _copyMondayToAll() {
    final monday =
        _weeklyHoursDraft[1] ??
        StoreDayHours(
          openingTime: _formatClockTime(_openingTime),
          closingTime: _formatClockTime(_closingTime),
        );
    setState(() {
      for (var day = 2; day <= 7; day++) {
        _weeklyHoursDraft[day] = StoreDayHours(
          openingTime: monday.openingTime,
          closingTime: monday.closingTime,
          closed: monday.closed,
        );
      }
    });
  }

  Widget _hoursSection({bool mobile = false}) {
    if (mobile) return _mobileHoursSection();
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var day = 1; day <= 7; day++)
          Builder(
            builder: (context) {
              final schedule =
                  _weeklyHoursDraft[day] ??
                  StoreDayHours(
                    openingTime: _formatClockTime(_openingTime),
                    closingTime: _formatClockTime(_closingTime),
                  );
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _line)),
                ),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 125,
                      child: Text(
                        names[day - 1],
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: schedule.closed
                          ? null
                          : () async {
                              final value = await _pickDashboardTime(
                                context,
                                _parseClockTime(schedule.openingTime),
                                'Opening time',
                              );
                              if (value == null || !mounted) return;
                              setState(
                                () => _weeklyHoursDraft[day] = StoreDayHours(
                                  openingTime: _formatClockTime(value),
                                  closingTime: schedule.closingTime,
                                ),
                              );
                            },
                      child: Text(
                        _formatDisplayTime(
                          _parseClockTime(schedule.openingTime),
                        ),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: schedule.closed
                          ? null
                          : () async {
                              final value = await _pickDashboardTime(
                                context,
                                _parseClockTime(schedule.closingTime),
                                'Closing time',
                              );
                              if (value == null || !mounted) return;
                              setState(
                                () => _weeklyHoursDraft[day] = StoreDayHours(
                                  openingTime: schedule.openingTime,
                                  closingTime: _formatClockTime(value),
                                ),
                              );
                            },
                      child: Text(
                        _formatDisplayTime(
                          _parseClockTime(schedule.closingTime),
                        ),
                      ),
                    ),
                    Checkbox(
                      value: schedule.closed,
                      onChanged: (value) => setState(() {
                        _weeklyHoursDraft[day] = StoreDayHours(
                          openingTime: schedule.openingTime,
                          closingTime: schedule.closingTime,
                          closed: value ?? false,
                        );
                      }),
                    ),
                    const Text('Closed'),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 20),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Limit staff sign-in to store hours'),
          subtitle: const Text(
            'Cashiers and helpers are blocked outside the schedule.',
          ),
          value: _restrictStaffLogin,
          onChanged: (value) => setState(() => _restrictStaffLogin = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Administrators are exempt'),
          value: _allowAdminAnytime,
          onChanged: (value) => setState(() => _allowAdminAnytime = value),
        ),
        const SizedBox(height: 12),
        _numberField(
          'Grace period before opening (min)',
          _beforeMinutesCtrl,
          width: 280,
        ),
        const SizedBox(height: 12),
        _numberField(
          'Grace period after closing (min)',
          _afterMinutesCtrl,
          width: 280,
        ),
        if (_storeAccessError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _storeAccessError!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
      ],
    );
  }

  Widget _mobileHoursSection() {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Column(
      children: [
        for (var day = 1; day <= 7; day++)
          _mobileDayRow(
            day,
            names[day - 1],
            _weeklyHoursDraft[day] ??
                StoreDayHours(
                  openingTime: _formatClockTime(_openingTime),
                  closingTime: _formatClockTime(_closingTime),
                ),
          ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          title: const Text(
            'Limit staff sign-in to store hours',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Cashiers and helpers are blocked outside the schedule.',
            style: TextStyle(fontSize: 12, color: _muted),
          ),
          value: _restrictStaffLogin,
          activeTrackColor: _orange,
          onChanged: (value) => setState(() => _restrictStaffLogin = value),
        ),
        const Divider(height: 1, color: _line),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          title: const Text(
            'Administrators are exempt',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          value: _allowAdminAnytime,
          activeTrackColor: _orange,
          onChanged: (value) => setState(() => _allowAdminAnytime = value),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
          child: Row(
            children: [
              Expanded(
                child: _mobileGraceField(
                  'Grace before opening (min)',
                  _beforeMinutesCtrl,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _mobileGraceField(
                  'Grace after closing (min)',
                  _afterMinutesCtrl,
                ),
              ),
            ],
          ),
        ),
        if (_storeAccessError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: Text(
              _storeAccessError!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
      ],
    );
  }

  Widget _mobileDayRow(int day, String name, StoreDayHours schedule) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _line)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(child: _mobileTimeButton(day, schedule, true)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('–', style: TextStyle(color: _muted)),
            ),
            Expanded(child: _mobileTimeButton(day, schedule, false)),
            const SizedBox(width: 4),
            SizedBox(
              width: 72,
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: Checkbox(
                      value: schedule.closed,
                      visualDensity: VisualDensity.compact,
                      onChanged: (value) => setState(() {
                        _weeklyHoursDraft[day] = StoreDayHours(
                          openingTime: schedule.openingTime,
                          closingTime: schedule.closingTime,
                          closed: value ?? false,
                        );
                      }),
                    ),
                  ),
                  const Flexible(
                    child: Text(
                      'Closed',
                      style: TextStyle(fontSize: 11, color: _muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _mobileTimeButton(int day, StoreDayHours schedule, bool opening) =>
      OutlinedButton(
        onPressed: schedule.closed
            ? null
            : () async {
                final value = await _pickDashboardTime(
                  context,
                  _parseClockTime(
                    opening ? schedule.openingTime : schedule.closingTime,
                  ),
                  opening ? 'Opening time' : 'Closing time',
                );
                if (value == null || !mounted) return;
                setState(() {
                  _weeklyHoursDraft[day] = StoreDayHours(
                    openingTime: opening
                        ? _formatClockTime(value)
                        : schedule.openingTime,
                    closingTime: opening
                        ? schedule.closingTime
                        : _formatClockTime(value),
                    closed: schedule.closed,
                  );
                });
              },
        style: OutlinedButton.styleFrom(
          foregroundColor: _orange,
          side: const BorderSide(color: _orange),
          minimumSize: const Size(0, 44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          shape: const StadiumBorder(),
        ),
        child: Text(
          _formatDisplayTime(
            _parseClockTime(
              opening ? schedule.openingTime : schedule.closingTime,
            ),
          ),
          maxLines: 1,
          style: const TextStyle(fontSize: 12),
        ),
      );

  Widget _mobileGraceField(String label, TextEditingController controller) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 11,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      );

  Future<TimeOfDay?> _pickDashboardTime(
    BuildContext context,
    TimeOfDay initialTime,
    String title,
  ) => showTimePicker(
    context: context,
    initialTime: initialTime,
    helpText: title,
    confirmText: 'Apply',
    builder: (dialogContext, child) => Theme(
      data: Theme.of(dialogContext).copyWith(
        colorScheme: const ColorScheme.light(
          primary: _orange,
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: _ink,
        ),
        timePickerTheme: TimePickerThemeData(
          backgroundColor: Colors.white,
          dialBackgroundColor: const Color(0xFFF7F5F3),
          dialHandColor: _orange,
          hourMinuteColor: const Color(0xFFFFF0E8),
          hourMinuteTextColor: _ink,
          entryModeIconColor: _orange,
          dayPeriodColor: WidgetStateColor.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? _orange
                : const Color(0xFFF7F5F3),
          ),
          dayPeriodTextColor: WidgetStateColor.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? Colors.white : _ink,
          ),
          hourMinuteShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          helpTextStyle: const TextStyle(
            color: _ink,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: _orange),
        ),
      ),
      child: child!,
    ),
  );

  Widget _discountSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: _numberField(
              'Auto-approval limit (%)',
              _discountLimitCtrl,
              width: null,
              compact: true,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _numberField(
              'Max with approval (%)',
              _maxApprovedDiscountCtrl,
              width: null,
              compact: true,
            ),
          ),
        ],
      ),
      if (_discountLimitError != null)
        Text(_discountLimitError!, style: const TextStyle(color: Colors.red)),
    ],
  );

  Widget _gcashSection() => LayoutBuilder(
    builder: (context, limits) {
      final details = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Account name',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          TextField(
            controller: _gcashAccountCtrl,
            onChanged: (_) => setState(() {}),
            decoration: _gcashInputDecoration(),
          ),
          const SizedBox(height: 6),
          const Text(
            'Shown to customers so they can confirm who they’re paying.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
          const Text(
            'GCash number',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 7),
          TextField(
            controller: _gcashNumberCtrl,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.phone,
            decoration: _gcashInputDecoration(),
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter the number linked to this merchant account.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFAF7F3),
              border: Border.all(color: const Color(0xFFF0E9E1)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Reconciling payments: ',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text:
                        'cashiers record the reference number from the customer’s GCash receipt.',
                  ),
                ],
              ),
              style: TextStyle(
                color: Color(0xFF6D5143),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      );
      final qr = _gcashQrColumn();
      if (limits.maxWidth < 400) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [details, const SizedBox(height: 26), qr],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: details),
          const SizedBox(width: 24),
          Expanded(child: qr),
        ],
      );
    },
  );

  InputDecoration _gcashInputDecoration() => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _orange, width: 1.5),
    ),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
  );

  Widget _gcashQrColumn() {
    final pending = _pendingGcashQrBytes;
    final qrUrl = widget.controller.gcashQrUrl;
    final hasQr = pending != null || qrUrl.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'QR shown at checkout',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 7),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: pending != null
                ? Image.memory(pending, fit: BoxFit.cover)
                : qrUrl.isNotEmpty
                ? Image.network(
                    qrUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(
                      child: Text(
                        'QR image unavailable',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ),
                  )
                : const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.qr_code_2_rounded, size: 62, color: _muted),
                        SizedBox(height: 8),
                        Text(
                          'No QR image yet',
                          style: TextStyle(color: _muted),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 9),
        OutlinedButton(
          onPressed: _dashboardSaving ? null : _chooseGcashQr,
          style: OutlinedButton.styleFrom(
            foregroundColor: _orange,
            side: const BorderSide(color: _orange),
          ),
          child: Text(hasQr ? 'Replace QR image' : 'Upload QR image'),
        ),
        const SizedBox(height: 5),
        Text(
          pending == null
              ? 'PNG or JPG; crop to a square before saving.'
              : 'New image selected. Save changes to apply it.',
          style: TextStyle(
            color: pending == null ? _muted : _orange,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
