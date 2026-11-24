part of 'forecasting_page.dart';

class _RestockDecisionRow {
  const _RestockDecisionRow({required this.model, this.demand, this.shortfall,
    this.stock, this.producer, this.note, this.comparable = false});

  final String model;
  final double? demand;
  final double? shortfall;
  final double? stock;
  final String? producer;
  final String? note;
  final bool comparable;
}

class _RestockDecisionSupport extends StatefulWidget {
  const _RestockDecisionSupport({super.key, required this.api,
    required this.sessionToken, required this.locationId,
    required this.productId, required this.productName,
    required this.inventoryUnit,
    required this.selectedModel, this.initialSnapshot,
    this.autoOpen = false, this.onOpened});

  final ForecastingApiService api;
  final String sessionToken;
  final String locationId;
  final String productId;
  final String productName;
  final String inventoryUnit;
  final String selectedModel;
  final ForecastSnapshotItem? initialSnapshot;
  final bool autoOpen;
  final VoidCallback? onOpened;

  @override
  State<_RestockDecisionSupport> createState() => _RestockDecisionSupportActionState();
}

class _RestockDecisionSupportActionState extends State<_RestockDecisionSupport> {
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open();
      });
    }
  }

  Future<void> _open() async {
    if (!mounted || _opening) return;
    _opening = true;
    widget.onOpened?.call();
    _ForecastDefinition.dismissOpen();
    try {
      await showDialog<void>(context: context, barrierColor: Colors.black26,
        builder: (_) => _RestockDecisionDialog(
          api: widget.api,
          sessionToken: widget.sessionToken,
          locationId: widget.locationId,
          productId: widget.productId,
          productName: widget.productName,
          inventoryUnit: widget.inventoryUnit,
          selectedModel: widget.selectedModel,
          initialSnapshot: widget.initialSnapshot,
        ));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: _open,
      style: FilledButton.styleFrom(
        backgroundColor: _forecastAccentDark,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      icon: const Icon(LucideIcons.arrowLeftRight, size: 18),
      label: const Text('Compare Restock Estimates',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    ),
  );
}

class _RestockDecisionDialog extends StatefulWidget {
  const _RestockDecisionDialog({required this.api,
    required this.sessionToken, required this.locationId,
    required this.productId, required this.productName,
    required this.inventoryUnit, required this.selectedModel,
    this.initialSnapshot});

  final ForecastingApiService api;
  final String sessionToken;
  final String locationId;
  final String productId;
  final String productName;
  final String inventoryUnit;
  final String selectedModel;
  final ForecastSnapshotItem? initialSnapshot;

  @override
  State<_RestockDecisionDialog> createState() => _RestockDecisionDialogState();
}

class _RestockDecisionDialogState extends State<_RestockDecisionDialog> {
  static const _models = <String>[
    'mean28', 'lightgbm', 'calibrated_blend', 'seasonal_experimental',
  ];
  final Map<String, _RestockDecisionRow> _rows = {};
  bool _loading = false;
  bool _loaded = false;
  bool _stockChanged = false;
  double? _saleableStock;
  double? _pastSales;
  String? _pastSalesNote;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  static String _label(String model) => switch (model) {
    'mean28' => 'Mean28',
    'lightgbm' => 'LightGBM',
    'blend' || 'calibrated_blend' => 'Calibrated Blend',
    'seasonal_experimental' => 'Seasonal Experimental',
    _ => model,
  };

  static String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

  static String _manilaBusinessDate() =>
    _date(DateTime.now().toUtc().add(const Duration(hours: 8)));

  Future<_RestockDecisionRow> _readModel(String model, String businessDate,
      {bool useInitial = true}) async {
    try {
      final normalized = model == 'calibrated_blend' ? 'blend' : model;
      final initial = widget.initialSnapshot;
      final initialModel = widget.selectedModel == 'calibrated_blend'
        ? 'blend' : widget.selectedModel;
      final item = useInitial && initial != null && initialModel == normalized &&
          initial.productId == widget.productId &&
          initial.locationId == widget.locationId
        ? initial
        : await widget.api.loadProductSnapshot(
            productId: widget.productId,
            locationId: widget.locationId,
            sessionToken: widget.sessionToken,
            model: model);
      if (item.productId != widget.productId ||
          item.locationId != widget.locationId ||
          item.unit.trim().toLowerCase() != widget.inventoryUnit.trim().toLowerCase()) {
        return _RestockDecisionRow(model: model,
          note: 'Saved product or inventory unit does not match this selection.');
      }
      if (item.status != 'completed') {
        final safeCode = item.job['safe_error_code']?.toString();
        final reason = switch (item.status) {
          'stale' => 'Saved forecast is stale; a current result is required.',
          'failed' => safeCode == null || safeCode.isEmpty
            ? 'The latest forecast job failed.' : 'The latest job failed ($safeCode).',
          'queued' || 'running' => 'A current forecast job is still active.',
          _ => 'No current saved forecast is available.',
        };
        return _RestockDecisionRow(model: model, note: reason);
      }
      final analysis = item.analysis;
      final snapshot = item.snapshot;
      if (analysis == null) {
        return _RestockDecisionRow(model: model,
          note: item.guidanceError?.isNotEmpty == true
            ? item.guidanceError
            : 'Current-stock preliminary calculation is unavailable.');
      }
      if (snapshot == null ||
          snapshot['as_of_business_date']?.toString() != businessDate ||
          analysis.product.productId != widget.productId ||
          analysis.authorizedLocationId != widget.locationId ||
          (analysis.forecast.requestedModel == 'calibrated_blend'
              ? 'blend' : analysis.forecast.requestedModel) != normalized ||
          analysis.forecast.horizonDays != 28 ||
          analysis.forecast.periodStart != businessDate ||
          analysis.forecast.unit.trim().toLowerCase() !=
              widget.inventoryUnit.trim().toLowerCase() ||
          analysis.forecast.daily.length != 28) {
        return _RestockDecisionRow(model: model,
          note: 'Saved dates, scope, or 28-day forecast evidence could not be aligned.');
      }
      final start = DateTime.parse(businessDate);
      for (var day = 0; day < 28; day++) {
        if (_date(analysis.forecast.daily[day].date) !=
            _date(DateTime.utc(start.year, start.month, start.day + day))) {
          return _RestockDecisionRow(model: model,
            note: 'Saved forecast dates are not consecutive.');
        }
      }
      final insight = analysis.selectedModelPreliminaryInsight;
      final demand = insight?.predictedDemand;
      final forecastDemand = analysis.forecast.totalQuantity;
      final safeDemand = analysis.forecast.zeroIsUnknownDemand
        ? null
        : demand != null && demand.isFinite && demand >= 0
          ? demand : insight == null && forecastDemand.isFinite && forecastDemand >= 0
            ? forecastDemand : null;
      final stock = insight?.availableInventory;
      final shortfall = !analysis.forecast.zeroIsUnknownDemand &&
          insight?.reliability != PreliminaryReliability.unavailable &&
          insight?.suggestedRestockQuantity?.isFinite == true
        ? insight!.suggestedRestockQuantity : null;
      final fallback = analysis.forecast.experimentalFallbackReason;
      final actualProducer = analysis.forecast.model;
      final normalizedProducer = actualProducer == 'calibrated_blend'
        ? 'blend' : actualProducer;
      final limitation = insight == null
        ? 'Selected-model preliminary calculation is unavailable from this API.'
        : insight.reliability == PreliminaryReliability.unavailable
          ? insight.limitations.isEmpty
            ? 'Preliminary calculation is unavailable for this saved forecast.'
            : insight.limitations.join(' ')
          : insight.reliability == PreliminaryReliability.provisional
            ? 'Limited history; preliminary quantity requires review.'
            : null;
      final notes = <String>[
        if (analysis.forecast.zeroIsUnknownDemand)
          'Demand is unknown; zero must not be treated as a forecast.',
        if (analysis.forecast.isColdStart)
          analysis.forecast.coldStartReason == null
            ? 'Cold-start forecast.'
            : 'Cold-start forecast: ${analysis.forecast.coldStartReason}.',
        if (normalizedProducer != normalized)
          'Requested model used ${_label(actualProducer)} as its actual producer.',
        if (fallback != null && fallback.isNotEmpty)
          'Fallback: $fallback.',
        if (limitation != null && limitation.isNotEmpty) limitation,
      ];
      return _RestockDecisionRow(model: model, demand: safeDemand,
        shortfall: shortfall, stock: stock,
        producer: _label(actualProducer),
        note: notes.isEmpty ? null : notes.join(' '),
        comparable: analysis.preliminaryComparisonEligible &&
          insight?.reliability == PreliminaryReliability.normal &&
          !analysis.forecast.isColdStart &&
          safeDemand != null && safeDemand.isFinite && safeDemand >= 0);
    } on ForecastApiException catch (error) {
      return _RestockDecisionRow(model: model,
        note: 'Saved forecast could not be read: ${error.message}');
    } catch (_) {
      return _RestockDecisionRow(model: model,
        note: 'Saved forecast could not be verified.');
    }
  }

  Future<(double?, String?)> _readPastSales(String businessDate) async {
    try {
      final page = await widget.api.loadSnapshotOverview(
        locationId: widget.locationId, sessionToken: widget.sessionToken,
        model: widget.selectedModel, page: 1, pageSize: 1,
        scopeProductId: widget.productId);
      if (page.totalCount != 1 || page.items.length != 1 ||
          page.items.single.productId != widget.productId ||
          page.items.single.locationId != widget.locationId ||
          page.items.single.unit.trim().toLowerCase() !=
              widget.inventoryUnit.trim().toLowerCase()) {
        return (null, 'Completed-sales scope could not be verified.');
      }
      if (page.salesHistoryCoverage?['sales_evidence_complete'] != true) {
        return (null, 'Completed-sales history could not be verified as complete.');
      }
      final points = page.actualSalesByProduct[widget.productId];
      if ((points == null || points.isEmpty) &&
          page.salesHistoryCoverage?['total'] == 1 &&
          page.salesHistoryCoverage?['no_sales'] == 1) {
        return (0.0, null);
      }
      if (points == null || points.length != 28) {
        return (null, 'A complete preceding 28-day sales series is unavailable.');
      }
      final start = DateTime.parse(businessDate);
      var total = 0.0;
      for (var day = 0; day < 28; day++) {
        final expected = DateTime.utc(start.year, start.month, start.day - 28 + day);
        final point = points[day];
        if (_date(point.date) != _date(expected) ||
            !point.quantity.isFinite || point.quantity < 0) {
          return (null, 'Completed-sales dates or quantities could not be verified.');
        }
        total += point.quantity;
      }
      return (total, null);
    } on ForecastApiException catch (_) {
      return (null, 'Completed sales could not be read right now.');
    } catch (_) {
      return (null, 'Completed sales could not be verified.');
    }
  }

  Future<void> _load({bool forceNetwork = false}) async {
    if (_loading) return;
    final generation = ++_generation;
    final businessDate = _manilaBusinessDate();
    setState(() { _loading = true; _loaded = false; });
    final results = <String, _RestockDecisionRow>{};
    for (var index = 0; index < _models.length; index += 2) {
      final batch = _models.skip(index).take(2).toList(growable: false);
      final values = await Future.wait(batch.map(
        (model) => _readModel(model, businessDate,
          useInitial: !forceNetwork)));
      if (!mounted || generation != _generation) return;
      for (final row in values) { results[row.model] = row; }
    }
    final actual = await _readPastSales(businessDate);
    if (!mounted || generation != _generation) return;
    final stocks = results.values.map((row) => row.stock)
      .whereType<double>().where((value) => value.isFinite && value >= 0).toList();
    final stockChanged = stocks.isNotEmpty &&
      stocks.any((value) => (value - stocks.first).abs() > .001);
    setState(() {
      _rows..clear()..addAll(results);
      _stockChanged = stockChanged;
      _saleableStock = stockChanged || stocks.isEmpty ? null : stocks.first;
      _pastSales = actual.$1;
      _pastSalesNote = actual.$2;
      _loading = false;
      _loaded = true;
    });
  }

  int get _disagreementLevel {
    final baseline = _rows['lightgbm'];
    final lightgbm = baseline?.demand;
    if (baseline?.comparable != true || lightgbm == null) return 0;
    var level = 0;
    for (final row in _rows.values) {
      final demand = row.demand;
      if (row.model == 'lightgbm' || !row.comparable || demand == null) continue;
      final difference = (demand - lightgbm).abs();
      final larger = max(demand, lightgbm);
      if (larger <= 0) continue;
      if (difference >= 5 && difference / larger >= .50) return 2;
      if (difference >= 2 && difference / larger >= .30) level = 1;
    }
    return level;
  }

  @override
  Widget build(BuildContext context) => _ForecastOverviewModalFrame(
    title: 'Restock Decision Support',
    subtitle: 'Compare forecasting models before deciding how much to replenish.',
    icon: LucideIcons.arrowLeftRight,
    preferredHeight: 690,
    child: Column(children: [
      Expanded(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: _forecastBackground,
              border: Border.all(color: _forecastLine),
              borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.productName, style: const TextStyle(fontSize: 15,
                fontWeight: FontWeight.w600, color: _forecastInk)),
              const SizedBox(height: 3),
              Text('Selected model: ${_label(widget.selectedModel)}',
                style: const TextStyle(fontSize: 12, color: _forecastMuted)),
            ])),
          const SizedBox(height: 16),
          Text('Previous 28-day completed sales: ${_pastSales == null ? 'Not available' : _withUnit(_pastSales, widget.inventoryUnit)}',
            style: const TextStyle(fontSize: 13, color: _forecastBody)),
          const SizedBox(height: 3),
          const Text('Past sales are observations, not evidence that a future forecast will be correct.',
            style: TextStyle(fontSize: 11, color: _forecastMuted)),
          if (_pastSalesNote != null) Text(_pastSalesNote!,
            style: const TextStyle(fontSize: 11, color: _forecastMuted)),
          const SizedBox(height: 12),
          Text('Current saleable stock: ${_stockChanged ? 'Not available - stock changed during the read' : _withUnit(_saleableStock, widget.inventoryUnit)}',
            style: const TextStyle(fontSize: 13, color: _forecastBody)),
          if (_disagreementLevel > 0) ...[
            const SizedBox(height: 14),
            _Notice(color: Colors.orange, icon: LucideIcons.triangleAlert,
              text: _disagreementLevel == 2
                ? 'Model disagreement detected. The difference is large; review the forecast comparison before deciding on replenishment.'
                : 'Model disagreement detected. Review the forecast comparison before deciding on replenishment.'),
          ],
          const SizedBox(height: 18),
          if (_loading) ...[
            const LinearProgressIndicator(color: _forecastAccent),
            const SizedBox(height: 8),
            const Text('Loading saved model comparisons…',
              style: TextStyle(fontSize: 12, color: _forecastMuted)),
          ],
          if (_loaded) LayoutBuilder(builder: (context, constraints) {
            final compact = constraints.maxWidth < 560;
            return Column(children: [
              if (!compact) const ColoredBox(color: _forecastBackground,
                child: Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  child: Row(children: [
                    Expanded(flex: 3, child: Text('MODEL', style: TextStyle(fontSize: 11, color: _forecastMuted))),
                    Expanded(flex: 2, child: Text('28-DAY DEMAND', style: TextStyle(fontSize: 11, color: _forecastMuted))),
                    Expanded(flex: 2, child: Text('PRELIMINARY SHORTFALL', style: TextStyle(fontSize: 11, color: _forecastMuted))),
                  ]))),
              for (final model in _models)
                _row(_rows[model] ?? _RestockDecisionRow(model: model,
                  note: 'Not available.'), compact),
            ]);
          }),
        ]))),
      const Divider(height: 1, color: _forecastLine),
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          IconButton(tooltip: 'Refresh comparison',
            onPressed: _loading ? null : () => _load(forceNetwork: true),
            icon: const Icon(LucideIcons.refreshCw, size: 18)),
          const SizedBox(width: 8),
          TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
        ])),
    ]),
  );

  Widget _row(_RestockDecisionRow row, bool compact) {
    final selectedModel = widget.selectedModel == 'blend'
      ? 'calibrated_blend' : widget.selectedModel;
    final selected = row.model == selectedModel;
    final demand = row.demand == null
      ? 'Not available' : _withUnit(row.demand, widget.inventoryUnit);
    final shortfall = _stockChanged || row.shortfall == null
      ? 'Not available' : _withUnit(row.shortfall, widget.inventoryUnit);
    final model = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_label(row.model), style: TextStyle(fontSize: 12,
        fontWeight: FontWeight.w600,
        color: selected ? _forecastAccentDark : _forecastInk)),
      if (row.producer != null)
        Text('Actual producer: ${row.producer}',
          style: const TextStyle(fontSize: 11, color: _forecastMuted)),
    ]);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? _forecastAccentSoft.withValues(alpha: .45) : Colors.white,
        border: const Border(bottom: BorderSide(color: _forecastHairline))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (compact) ...[
          model,
          const SizedBox(height: 7),
          Text('28-day demand: $demand',
            style: const TextStyle(fontSize: 12, color: _forecastBody)),
          Text('Preliminary shortfall: $shortfall',
            style: const TextStyle(fontSize: 12, color: _forecastBody)),
        ] else Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: model),
          Expanded(flex: 2, child: Text(demand,
            style: const TextStyle(fontSize: 12, color: _forecastBody))),
          Expanded(flex: 2, child: Text(shortfall,
            style: const TextStyle(fontSize: 12, color: _forecastBody))),
        ]),
        if (row.note != null) ...[
          const SizedBox(height: 6),
          Text(row.note!, style: const TextStyle(fontSize: 11,
            color: _forecastMuted, height: 1.35)),
        ],
      ]),
    );
  }
}
