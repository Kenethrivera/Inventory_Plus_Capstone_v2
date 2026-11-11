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
  Map<String, String> cashierLimits,
});

enum _SettingsSection { stock, hours, discounts, assignment, gcash }

extension _SettingsDashboard on _SystemSettingsPageState {
  static const _ink = Color(0xFF171717);
  static const _muted = Color(0xFF83776F);
  static const _line = Color(0xFFE9E2DC);
  static const _orange = Color(0xFFC94008);

  void _captureDashboardExtrasBaseline() {
    _dashboardExtrasBaseline = (
      autoAssignOrders: _autoAssignOrders,
      maxHelperOrders: _maxHelperOrdersCtrl.text.trim(),
      maxApprovedDiscount: _maxApprovedDiscountCtrl.text.trim(),
      gcashEnabled: _gcashEnabled,
      gcashAccountName: _gcashAccountCtrl.text.trim(),
      gcashNumber: _gcashNumberCtrl.text.trim(),
      cashierLimits: Map<String, String>.unmodifiable({
        for (final entry in _cashierLimitCtrls.entries)
          entry.key: entry.value.text.trim(),
      }),
    );
  }

  bool get _dashboardSectionDirty {
    final baseline = _dashboardExtrasBaseline;
    return switch (_selectedSettingsSection) {
      _SettingsSection.stock => _thresholdDraftDirty,
      _SettingsSection.hours => _storeAccessDraftDirty,
      _SettingsSection.discounts =>
        baseline != null &&
            (_discountLimitDraftDirty ||
                _maxApprovedDiscountCtrl.text.trim() !=
                    baseline.maxApprovedDiscount ||
                _cashierLimitCtrls.entries.any(
                  (entry) =>
                      entry.value.text.trim() !=
                      (baseline.cashierLimits[entry.key] ?? ''),
                )),
      _SettingsSection.assignment =>
        baseline != null &&
            (_autoAssignOrders != baseline.autoAssignOrders ||
                _maxHelperOrdersCtrl.text.trim() != baseline.maxHelperOrders),
      _SettingsSection.gcash =>
        _gcashDetailsDirty || _pendingGcashQrBytes != null,
    };
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
      final cashiers = await widget.controller.supabase
          .from('profiles')
          .select('id, cashier_discount_limit_pct')
          .eq('location_id', locationId)
          .inFilter('role', ['staff', 'cashier']);
      if (!mounted || widget.controller.activeLocationId != locationId) return;
      setState(() {
        _autoAssignOrders = row?['auto_assign_orders'] != false;
        _maxHelperOrdersCtrl.text =
            '${(row?['max_active_orders_per_helper'] as num?)?.toInt() ?? 3}';
        _maxApprovedDiscountCtrl.text = _formatPct(
          (row?['max_approved_discount_pct'] as num?)?.toDouble() ?? 25,
        );
        _gcashEnabled = row?['gcash_enabled'] != false;
        _gcashAccountCtrl.text = row?['gcash_account_name']?.toString() ?? '';
        _gcashNumberCtrl.text = row?['gcash_number']?.toString() ?? '';
        final currentIds = cashiers
            .map((item) => item['id'].toString())
            .toSet();
        for (final id in _cashierLimitCtrls.keys.toList()) {
          if (!currentIds.contains(id)) {
            _cashierLimitCtrls.remove(id)?.dispose();
          }
        }
        for (final item in cashiers) {
          final id = item['id'].toString();
          _cashierLimitCtrls.putIfAbsent(id, TextEditingController.new).text =
              (item['cashier_discount_limit_pct'] as num?)?.toString() ?? '';
        }
        _captureDashboardExtrasBaseline();
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

  Future<bool> _saveDashboardExtras(_SettingsSection section) async {
    final baseline = _dashboardExtrasBaseline;
    if (baseline == null) return false;
    final savingDiscounts = section == _SettingsSection.discounts;
    final savingAssignment = section == _SettingsSection.assignment;
    final savingGcash = section == _SettingsSection.gcash;
    final defaultLimit = savingDiscounts
        ? double.tryParse(_discountLimitCtrl.text.trim())
        : _discountLimitBaseline ??
              widget.controller.cashierAutoApprovedDiscountLimitPct;
    final maxHelperOrders = int.tryParse(
      savingAssignment
          ? _maxHelperOrdersCtrl.text.trim()
          : baseline.maxHelperOrders,
    );
    final maxApprovedDiscount = double.tryParse(
      savingDiscounts
          ? _maxApprovedDiscountCtrl.text.trim()
          : baseline.maxApprovedDiscount,
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
    final limits = <String, double>{};
    final limitTexts = savingDiscounts
        ? {
            for (final entry in _cashierLimitCtrls.entries)
              entry.key: entry.value.text.trim(),
          }
        : baseline.cashierLimits;
    for (final entry in limitTexts.entries) {
      if (entry.value.isEmpty) continue;
      final value = double.tryParse(entry.value);
      if (value == null ||
          !value.isFinite ||
          value < 0 ||
          value > maxApprovedDiscount) {
        setState(
          () => _dashboardError = 'Cashier limits must be valid percentages.',
        );
        return false;
      }
      limits[entry.key] = value;
    }
    setState(() {
      _isSavingDashboard = true;
      _dashboardError = null;
    });
    try {
      await widget.controller.saveSettingsDashboardExtras(
        autoAssignOrders: savingAssignment
            ? _autoAssignOrders
            : baseline.autoAssignOrders,
        maxHelperOrders: maxHelperOrders,
        maxApprovedDiscount: maxApprovedDiscount,
        defaultCashierLimit: defaultLimit,
        acceptGcash: savingGcash ? _gcashEnabled : baseline.gcashEnabled,
        gcashAccountName: savingGcash
            ? _gcashAccountCtrl.text
            : baseline.gcashAccountName,
        gcashNumber: savingGcash ? _gcashNumberCtrl.text : baseline.gcashNumber,
        cashierLimits: limits,
      );
      if (!mounted) return false;
      setState(() {
        if (savingDiscounts) _discountLimitBaseline = defaultLimit;
        _dashboardExtrasBaseline = (
          autoAssignOrders: savingAssignment
              ? _autoAssignOrders
              : baseline.autoAssignOrders,
          maxHelperOrders: savingAssignment
              ? _maxHelperOrdersCtrl.text.trim()
              : baseline.maxHelperOrders,
          maxApprovedDiscount: savingDiscounts
              ? _maxApprovedDiscountCtrl.text.trim()
              : baseline.maxApprovedDiscount,
          gcashEnabled: savingGcash ? _gcashEnabled : baseline.gcashEnabled,
          gcashAccountName: savingGcash
              ? _gcashAccountCtrl.text.trim()
              : baseline.gcashAccountName,
          gcashNumber: savingGcash
              ? _gcashNumberCtrl.text.trim()
              : baseline.gcashNumber,
          cashierLimits: savingDiscounts
              ? Map<String, String>.unmodifiable(limitTexts)
              : baseline.cashierLimits,
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
      case _SettingsSection.discounts:
        await _saveDashboardExtras(_SettingsSection.discounts);
        return;
      case _SettingsSection.assignment:
        await _saveDashboardExtras(_SettingsSection.assignment);
        return;
      case _SettingsSection.gcash:
        if (_gcashDetailsDirty &&
            !await _saveDashboardExtras(_SettingsSection.gcash)) {
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
      case _SettingsSection.discounts:
        final value = _discountLimitBaseline;
        if (value != null) _discountLimitCtrl.text = _formatPct(value);
        final baseline = _dashboardExtrasBaseline;
        if (baseline != null) {
          _maxApprovedDiscountCtrl.text = baseline.maxApprovedDiscount;
          for (final entry in _cashierLimitCtrls.entries) {
            entry.value.text = baseline.cashierLimits[entry.key] ?? '';
          }
        }
        break;
      case _SettingsSection.assignment:
        final assignment = _dashboardExtrasBaseline;
        if (assignment != null) {
          _autoAssignOrders = assignment.autoAssignOrders;
          _maxHelperOrdersCtrl.text = assignment.maxHelperOrders;
        }
        break;
      case _SettingsSection.gcash:
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
    final busy =
        _isLoadingSettings ||
        _isLoadingStoreAccess ||
        _isLoadingDashboardExtras;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5F3),
      body: busy
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(36, 40, 36, 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Settings',
                        style: TextStyle(
                          fontFamily: _fontFam,
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        'Store-wide rules and preferences.',
                        style: TextStyle(
                          fontFamily: _fontFam,
                          fontSize: 15,
                          color: _muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 720;
                      final nav = SizedBox(
                        width: narrow ? double.infinity : 270,
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
                              'Discounts',
                              _SettingsSection.discounts,
                            ),
                            _sectionButton(
                              'Order assignment',
                              _SettingsSection.assignment,
                            ),
                            _sectionButton(
                              'GCash payments',
                              _SettingsSection.gcash,
                            ),
                          ],
                        ),
                      );
                      final card = _settingsCard();
                      return narrow
                          ? Column(
                              children: [nav, const SizedBox(height: 16), card],
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

  Widget _settingsCard() {
    final title = switch (_selectedSettingsSection) {
      _SettingsSection.stock => 'Stock & units',
      _SettingsSection.hours => 'Store hours & access',
      _SettingsSection.discounts => 'Discounts',
      _SettingsSection.assignment => 'Order assignment',
      _SettingsSection.gcash => 'GCash payments',
    };
    final subtitle = switch (_selectedSettingsSection) {
      _SettingsSection.stock =>
        'Stock alerts and the units products can be sold in.',
      _SettingsSection.hours => 'When the store is open and staff may sign in.',
      _SettingsSection.discounts =>
        'How much cashiers may discount before approval.',
      _SettingsSection.assignment => 'How new orders reach helpers.',
      _SettingsSection.gcash =>
        'The merchant account customers pay at checkout.',
    };
    final body = switch (_selectedSettingsSection) {
      _SettingsSection.stock => _stockSection(),
      _SettingsSection.hours => _hoursSection(),
      _SettingsSection.discounts => _discountSection(),
      _SettingsSection.assignment => _assignmentSection(),
      _SettingsSection.gcash => _gcashSection(),
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
            padding: const EdgeInsets.all(26),
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
                        if (_selectedSettingsSection == _SettingsSection.gcash)
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
                if (_selectedSettingsSection != _SettingsSection.gcash) {
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
          Padding(padding: const EdgeInsets.all(26), child: body),
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
                    child: Text(_dashboardSaving ? 'Saving…' : 'Save changes'),
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
    double width = 260,
    String? hint,
  }) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget _stockSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 16,
        runSpacing: 12,
        children: [
          _numberField('Critical at (% of max)', _criticalPercentCtrl),
          _numberField('Low stock at (% of max)', _lowPercentCtrl),
        ],
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

  Widget _hoursSection() {
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
                              final value = await showTimePicker(
                                context: context,
                                initialTime: _parseClockTime(
                                  schedule.openingTime,
                                ),
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
                              final value = await showTimePicker(
                                context: context,
                                initialTime: _parseClockTime(
                                  schedule.closingTime,
                                ),
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

  Widget _discountSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 16,
        runSpacing: 12,
        children: [
          _numberField('Default cashier limit (%)', _discountLimitCtrl),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _maxApprovedDiscountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Maximum with approval (%)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      const SizedBox(height: 27),
      const Text(
        'Per-cashier limits',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 5),
      const Text(
        'Leave blank to use the default.',
        style: TextStyle(color: _muted),
      ),
      const SizedBox(height: 12),
      for (final staff in _staffList.where(
        (row) => [
          'staff',
          'cashier',
        ].contains(row['role']?.toString().toLowerCase()),
      ))
        Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            children: [
              Expanded(child: Text(staff['name']?.toString() ?? 'Cashier')),
              _numberField(
                'Limit %',
                _cashierLimitCtrls.putIfAbsent(
                  staff['id'].toString(),
                  TextEditingController.new,
                ),
                width: 125,
              ),
            ],
          ),
        ),
      if (_discountLimitError != null)
        Text(_discountLimitError!, style: const TextStyle(color: Colors.red)),
    ],
  );

  Widget _assignmentSection() => Column(
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Assign new orders automatically'),
        subtitle: const Text(
          'Selects the available helper with the fewest active orders.',
        ),
        value: _autoAssignOrders,
        onChanged: (value) => setState(() => _autoAssignOrders = value),
      ),
      const Divider(color: _line),
      Row(
        children: [
          const Expanded(child: Text('Most active orders per helper')),
          SizedBox(
            width: 95,
            child: TextField(
              controller: _maxHelperOrdersCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
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
                        Icon(
                          Icons.qr_code_2_rounded,
                          size: 62,
                          color: _muted,
                        ),
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
