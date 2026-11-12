import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/seasonal_learning_lab.dart';
import '../../services/forecasting_api_service.dart';

typedef SeasonalLearningReportLoader =
    Future<SeasonalLearningLabReport> Function(String? productId);

class SeasonalLearningLaboratory extends StatefulWidget {
  const SeasonalLearningLaboratory({
    super.key,
    required this.onLoad,
    required this.isActive,
    this.liveAnalysis,
    this.initialReport,
    this.initiallyExpanded = false,
  });

  final SeasonalLearningReportLoader onLoad;
  final bool isActive;
  final ForecastAnalysis? liveAnalysis;
  final SeasonalLearningLabReport? initialReport;
  final bool initiallyExpanded;

  @override
  State<SeasonalLearningLaboratory> createState() =>
      _SeasonalLearningLaboratoryState();
}

class _SeasonalLearningLaboratoryState
    extends State<SeasonalLearningLaboratory> {
  SeasonalLearningLabReport? _report;
  String? _error;
  String? _chartModel;
  String? _replaySku;
  bool _loading = false;
  bool _expanded = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _report = widget.initialReport;
    _expanded = widget.initiallyExpanded;
    _adoptReportSelections();
    if (_expanded && _report == null && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void didUpdateWidget(covariant SeasonalLearningLaboratory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialReport != oldWidget.initialReport &&
        widget.initialReport != null) {
      _report = widget.initialReport;
      _error = null;
      _adoptReportSelections();
    }
    if (!oldWidget.isActive &&
        widget.isActive &&
        _expanded &&
        _report == null) {
      _load();
    }
    if (oldWidget.isActive && !widget.isActive) _generation++;
  }

  Future<void> _load([String? productId]) async {
    if (!mounted || !widget.isActive || _loading) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.onLoad(productId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _report = report;
        _adoptReportSelections();
      });
    } on ForecastApiException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error = '${error.message} Live forecasting is unaffected.',
      );
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error =
            'Research reports could not be loaded. Live forecasting is unaffected.',
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _adoptReportSelections() {
    final report = _report;
    if (report == null) return;
    final models = report.forecastActual.map((value) => value.model).toSet();
    if (_chartModel == null || !models.contains(_chartModel)) {
      _chartModel = models.contains('product_specific_seasonal_lightgbm')
          ? 'product_specific_seasonal_lightgbm'
          : models.firstOrNull;
    }
    final replaySkus = report.replay.map((value) => value.sku).toSet();
    if (_replaySku == null || !replaySkus.contains(_replaySku)) {
      _replaySku = replaySkus.firstOrNull;
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Card(
      key: const Key('seasonal-learning-laboratory'),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFBFDBFE)),
      ),
      child: ExpansionTile(
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (expanded) {
          _expanded = expanded;
          if (expanded && report == null && _error == null) _load();
        },
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFDBEAFE),
          foregroundColor: Color(0xFF1D4ED8),
          child: Icon(Icons.science_outlined),
        ),
        title: const Text(
          'Seasonal Learning Laboratory',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: const Text(
          'Read-only Stage 2.6–2.7B synthetic research; never used for stock orders',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (report != null)
              _StatusPill(
                text: report.complete ? 'REPORTS READY' : 'PROVISIONAL',
                color: report.complete
                    ? const Color(0xFF047857)
                    : const Color(0xFFB45309),
              ),
            const SizedBox(width: 8),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            _LabNotice(
              key: const Key('seasonal-lab-error'),
              icon: Icons.warning_amber_rounded,
              color: const Color(0xFFB45309),
              title: 'Research dashboard unavailable',
              message: '$_error',
              action: TextButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry research reports'),
              ),
            )
          else if (report == null && !_loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Expand this section to load the research reports.'),
            )
          else if (report != null) ...[
            const SizedBox(height: 12),
            _ResearchBoundary(
              report: report,
              liveAnalysis: widget.liveAnalysis,
            ),
            if (report.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              _LabNotice(
                key: const Key('seasonal-lab-warning'),
                icon: Icons.info_outline,
                color: const Color(0xFFB45309),
                title: 'Artifact status warning',
                message: report.warnings.join('\n'),
              ),
            ],
            const SizedBox(height: 16),
            _ArtifactHealth(artifacts: report.artifacts),
            const SizedBox(height: 16),
            _HistoricalAccuracy(report: report),
            const SizedBox(height: 16),
            _ForecastActualSection(
              report: report,
              selectedModel: _chartModel,
              onModelChanged: (value) => setState(() => _chartModel = value),
              onProductChanged: _loading ? null : (value) => _load(value),
            ),
            const SizedBox(height: 16),
            _HistoricalReplaySection(
              report: report,
              selectedSku: _replaySku,
              onSkuChanged: (value) => setState(() => _replaySku = value),
            ),
            const SizedBox(height: 16),
            _ClassificationSummary(report: report),
            const SizedBox(height: 16),
            _ChronologicalEvidence(report: report),
            const SizedBox(height: 16),
            _ProductClassificationTable(products: report.products),
          ],
        ],
      ),
    );
  }
}

class _ResearchBoundary extends StatelessWidget {
  const _ResearchBoundary({required this.report, required this.liveAnalysis});

  final SeasonalLearningLabReport report;
  final ForecastAnalysis? liveAnalysis;

  @override
  Widget build(BuildContext context) {
    final live = liveAnalysis;
    final liveSku = live?.product.sku ?? '';
    final historyContext = live == null
        ? 'Load a product detail above to inspect the current live forecast.'
        : live.synthetic
        ? 'Backend development fixture'
        : liveSku.startsWith('SIM-')
        ? 'Imported synthetic historical sales (SIM SKU)'
        : 'Supabase sales history; staging/test records may be present';
    final knowledge = live?.forecast.seasonalContext?.seasonalRelevance;
    return _LabCard(
      title: 'What each result means',
      icon: Icons.account_tree_outlined,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < 760
              ? constraints.maxWidth
              : (constraints.maxWidth - 12) / 2;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: width,
                child: _Definition(
                  title: 'Current live forecast',
                  value: live == null
                      ? 'Not loaded'
                      : '${live.forecast.model} · ${live.forecast.totalQuantity.toStringAsFixed(1)} ${live.forecast.unit}',
                  detail: historyContext,
                  color: const Color(0xFF1D4ED8),
                ),
              ),
              SizedBox(
                width: width,
                child: _Definition(
                  title: 'Knowledge-based classification',
                  value: knowledge?.toUpperCase() ?? 'NOT SHOWN',
                  detail:
                      'Versioned hardware knowledge used only when the live Seasonal Experimental model is loaded.',
                  color: const Color(0xFF7C3AED),
                ),
              ),
              SizedBox(
                width: width,
                child: const _Definition(
                  title: 'Frozen simulation label',
                  value: 'SYNTHETIC HYPOTHESIS',
                  detail:
                      'Programmed SUMMER/RAINY/NEUTRAL label used only to score the 24 simulation products.',
                  color: Color(0xFFB45309),
                ),
              ),
              SizedBox(
                width: width,
                child: const _Definition(
                  title: 'Sales-discovered classification',
                  value: 'OFFLINE RESEARCH',
                  detail:
                      'Original, refined and baseline labels are report outputs. They never update inventory.',
                  color: Color(0xFF047857),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HistoricalAccuracy extends StatelessWidget {
  const _HistoricalAccuracy({required this.report});

  final SeasonalLearningLabReport report;

  @override
  Widget build(BuildContext context) {
    final metrics = [...report.accuracyMetrics]
      ..sort((a, b) {
        final horizon = a.horizonDays.compareTo(b.horizonDays);
        return horizon != 0 ? horizon : a.model.compareTo(b.model);
      });
    return _LabCard(
      title: 'Stage 2.6 · Historical forecast accuracy',
      icon: Icons.query_stats,
      trailing: _StatusPill(
        text: 'DB ${report.stage26DatabaseVerification}',
        color: report.stage26DatabaseVerification == 'PASS'
            ? const Color(0xFF047857)
            : const Color(0xFFB45309),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${report.historyStart ?? 'unknown'} to ${report.historyEnd ?? 'unknown'} · frozen historical origins · decision ${report.stage26Decision}',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              columns: const [
                DataColumn(label: Text('Horizon')),
                DataColumn(label: Text('Model')),
                DataColumn(label: Text('WAPE')),
                DataColumn(label: Text('MAE')),
                DataColumn(label: Text('Bias')),
              ],
              rows: metrics
                  .map(
                    (metric) => DataRow(
                      cells: [
                        DataCell(Text('${metric.horizonDays} days')),
                        DataCell(Text(_modelLabel(metric.model))),
                        DataCell(Text(_percent(metric.wape))),
                        DataCell(Text(metric.mae.toStringAsFixed(3))),
                        DataCell(Text(_percent(metric.bias))),
                      ],
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForecastActualSection extends StatelessWidget {
  const _ForecastActualSection({
    required this.report,
    required this.selectedModel,
    required this.onModelChanged,
    required this.onProductChanged,
  });

  final SeasonalLearningLabReport report;
  final String? selectedModel;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String?>? onProductChanged;

  @override
  Widget build(BuildContext context) {
    final models = report.forecastActual.map((value) => value.model).toSet();
    final model = models.contains(selectedModel)
        ? selectedModel
        : models.firstOrNull;
    final points = report.forecastActual
        .where((value) => value.model == model)
        .toList(growable: false);
    final product = report.selectedProduct;
    return _LabCard(
      title: 'Frozen forecast versus subsequently observed sales',
      icon: Icons.show_chart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 340,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('lab-product-${report.selectedProductId}'),
                  initialValue: report.selectedProductId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Simulation product',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: report.products
                      .map(
                        (value) => DropdownMenuItem(
                          value: value.productId,
                          child: Text('${value.productName} (${value.sku})'),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: onProductChanged,
                ),
              ),
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('lab-chart-model-$model'),
                  initialValue: model,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Historical model',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: models
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(_modelLabel(value)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: onModelChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _LabNotice(
            icon: Icons.science_outlined,
            color: const Color(0xFFB45309),
            title: '${product?.sku ?? 'SIM'} · synthetic evaluation product',
            message:
                'These are frozen historical predictions, not a fake live-learning feed. Leakage check: ${report.leakageCheck}.',
          ),
          const SizedBox(height: 12),
          if (points.isEmpty)
            const Text('No forecast-versus-actual artifact is available.')
          else ...[
            SizedBox(
              height: 220,
              width: double.infinity,
              child: CustomPaint(
                key: const Key('seasonal-lab-forecast-actual-chart'),
                painter: _ForecastActualPainter(points),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 18,
              children: const [
                _Legend(color: Color(0xFF111827), text: 'Actual sales'),
                _Legend(color: Color(0xFF2563EB), text: 'Frozen prediction'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HistoricalReplaySection extends StatelessWidget {
  const _HistoricalReplaySection({
    required this.report,
    required this.selectedSku,
    required this.onSkuChanged,
  });

  final SeasonalLearningLabReport report;
  final String? selectedSku;
  final ValueChanged<String?> onSkuChanged;

  @override
  Widget build(BuildContext context) {
    final skus = report.replay.map((value) => value.sku).toSet();
    final sku = skus.contains(selectedSku) ? selectedSku : skus.firstOrNull;
    final rows = report.replay
        .where((value) => value.sku == sku)
        .toList(growable: false);
    return _LabCard(
      title: 'Historical replay · sales revealed seven days at a time',
      icon: Icons.history,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 360,
            child: DropdownButtonFormField<String>(
              key: ValueKey('lab-replay-$sku'),
              initialValue: sku,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Replay product',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: skus
                  .map(
                    (value) =>
                        DropdownMenuItem(value: value, child: Text(value)),
                  )
                  .toList(growable: false),
              onChanged: onSkuChanged,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Each next forecast was refit only after the prior seven actual days were revealed. Prior error was monitored, not directly subtracted.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Period')),
                DataColumn(label: Text('Origin')),
                DataColumn(label: Text('Forecast')),
                DataColumn(label: Text('Actual')),
                DataColumn(label: Text('Signed error')),
              ],
              rows: rows
                  .map(
                    (value) => DataRow(
                      cells: [
                        DataCell(Text('${value.period}')),
                        DataCell(Text(_date(value.origin))),
                        DataCell(Text(value.forecastTotal.toStringAsFixed(2))),
                        DataCell(Text(value.actualTotal.toStringAsFixed(2))),
                        DataCell(
                          Text(
                            value.signedError.toStringAsFixed(2),
                            style: TextStyle(
                              color: value.signedError > 0
                                  ? const Color(0xFFB45309)
                                  : const Color(0xFF047857),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClassificationSummary extends StatelessWidget {
  const _ClassificationSummary({required this.report});

  final SeasonalLearningLabReport report;

  @override
  Widget build(BuildContext context) {
    const order = ['original_evidence_gated', 'simple_baseline', 'refined'];
    return _LabCard(
      title: 'Stage 2.7–2.7B · Sales-discovered classification',
      icon: Icons.fact_check_outlined,
      trailing: _StatusPill(
        text: report.stage27bDecision,
        color: report.stage27bDecision == 'PASS'
            ? const Color(0xFF047857)
            : const Color(0xFFB45309),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Selected refinement: ${report.selectedPolicy.replaceAll('_', ' ')} · automatic label updates disabled',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth < 820
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 24) / 3;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: order
                    .map((name) {
                      final value = report.classificationModels[name];
                      if (value == null) return const SizedBox.shrink();
                      return SizedBox(
                        width: width,
                        child: _ClassificationModelCard(
                          name: _classificationModelLabel(name),
                          summary: value,
                        ),
                      );
                    })
                    .toList(growable: false),
              );
            },
          ),
          if (report.conclusion.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(report.conclusion, style: const TextStyle(fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _ChronologicalEvidence extends StatelessWidget {
  const _ChronologicalEvidence({required this.report});

  final SeasonalLearningLabReport report;

  @override
  Widget build(BuildContext context) => _LabCard(
    title: 'Chronological evidence accumulation',
    icon: Icons.timeline,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Six and twelve months remain UNKNOWN because fewer than two annual cycles are available.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('History')),
              DataColumn(label: Text('Method')),
              DataColumn(label: Text('Coverage')),
              DataColumn(label: Text('Covered accuracy')),
              DataColumn(label: Text('UNKNOWN')),
            ],
            rows: report.chronology
                .map(
                  (value) => DataRow(
                    cells: [
                      DataCell(Text('${value.windowMonths} months')),
                      DataCell(Text(_classificationModelLabel(value.model))),
                      DataCell(Text(_percent(value.coverage))),
                      DataCell(
                        Text(
                          value.coveredAccuracy == null
                              ? 'Not enough evidence'
                              : _percent(value.coveredAccuracy!),
                        ),
                      ),
                      DataCell(Text(_percent(value.unknownRate))),
                    ],
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ],
    ),
  );
}

class _ProductClassificationTable extends StatelessWidget {
  const _ProductClassificationTable({required this.products});

  final List<SeasonalLearningProduct> products;

  @override
  Widget build(BuildContext context) => _LabCard(
    title: 'Product-level research classifications',
    icon: Icons.inventory_2_outlined,
    trailing: _StatusPill(
      text: '${products.length} SIMULATION PRODUCTS',
      color: const Color(0xFFB45309),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Frozen labels score the experiment. Discovered labels are offline outputs. No original inventory product is changed.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Simulation product')),
              DataColumn(label: Text('Frozen label')),
              DataColumn(label: Text('Original discovery')),
              DataColumn(label: Text('Refined')),
              DataColumn(label: Text('Baseline')),
            ],
            rows: products
                .map(
                  (value) => DataRow(
                    cells: [
                      DataCell(
                        SizedBox(
                          width: 260,
                          child: Text('${value.productName}\n${value.sku}'),
                        ),
                      ),
                      DataCell(
                        _ClassificationText(value.frozenSimulationLabel),
                      ),
                      DataCell(_ClassificationText(value.originalDiscovered)),
                      DataCell(_ClassificationText(value.refinedDiscovered)),
                      DataCell(_ClassificationText(value.baselineDiscovered)),
                    ],
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ],
    ),
  );
}

class _ArtifactHealth extends StatelessWidget {
  const _ArtifactHealth({required this.artifacts});

  final List<ResearchArtifactStatus> artifacts;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: artifacts
        .map(
          (value) => _StatusPill(
            text: '${value.stage}: ${value.status}'.toUpperCase(),
            color: value.status == 'available'
                ? const Color(0xFF047857)
                : const Color(0xFFB45309),
          ),
        )
        .toList(growable: false),
  );
}

class _ClassificationModelCard extends StatelessWidget {
  const _ClassificationModelCard({required this.name, required this.summary});

  final String name;
  final ClassificationModelSummary summary;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        _MiniMetric('Coverage', _percent(summary.coverage)),
        _MiniMetric(
          'Covered accuracy',
          summary.coveredAccuracy == null
              ? 'Unknown'
              : _percent(summary.coveredAccuracy!),
        ),
        _MiniMetric('UNKNOWN rate', _percent(summary.unknownRate)),
        _MiniMetric(
          'Fourth-year confirmation',
          summary.holdoutConfirmationRate == null
              ? 'Not available'
              : '${_percent(summary.holdoutConfirmationRate!)} '
                    '(${summary.holdoutConfirmed}/${summary.holdoutTested})',
        ),
      ],
    ),
  );
}

class _Definition extends StatelessWidget {
  const _Definition({
    required this.title,
    required this.value,
    required this.detail,
    required this.color,
  });

  final String title;
  final String value;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.22)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: color, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text(
          detail,
          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
        ),
      ],
    ),
  );
}

class _LabCard extends StatelessWidget {
  const _LabCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: const Color(0xFF1D4ED8)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

class _LabNotice extends StatelessWidget {
  const _LabNotice({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.24)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(message, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900),
    ),
  );
}

class _ClassificationText extends StatelessWidget {
  const _ClassificationText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final unknown = value == 'UNKNOWN';
    return Text(
      value,
      style: TextStyle(
        color: unknown ? const Color(0xFFB45309) : const Color(0xFF0F172A),
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
        ),
      ],
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 18, height: 3, color: color),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 11)),
    ],
  );
}

class _ForecastActualPainter extends CustomPainter {
  _ForecastActualPainter(this.points);

  final List<ForecastActualPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    const padding = EdgeInsets.fromLTRB(34, 12, 12, 24);
    final plot = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );
    final maximum = points.fold<double>(
      0,
      (value, point) =>
          math.max(value, math.max(point.actual, point.predicted)),
    );
    final scale = maximum <= 0 ? 1.0 : maximum;
    final grid = Paint()..color = const Color(0xFFE2E8F0);
    for (var index = 0; index <= 4; index++) {
      final y = plot.bottom - plot.height * index / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    Path line(double Function(ForecastActualPoint) value) {
      final path = Path();
      for (var index = 0; index < points.length; index++) {
        final x = plot.left + plot.width * index / (points.length - 1);
        final y = plot.bottom - plot.height * value(points[index]) / scale;
        if (index == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    canvas.drawPath(
      line((point) => point.actual),
      Paint()
        ..color = const Color(0xFF111827)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      line((point) => point.predicted),
      Paint()
        ..color = const Color(0xFF2563EB)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ForecastActualPainter oldDelegate) =>
      oldDelegate.points != points;
}

String _percent(double value) => '${(value * 100).toStringAsFixed(2)}%';

String _date(DateTime value) => value.toIso8601String().split('T').first;

String _modelLabel(String value) => switch (value) {
  'mean28' => 'Mean28',
  'existing_lightgbm' => 'Existing LightGBM',
  'matched_nonseasonal_ablation' => 'Nonseasonal ablation',
  'product_specific_seasonal_lightgbm' => 'Seasonal LightGBM',
  _ => value.replaceAll('_', ' '),
};

String _classificationModelLabel(String value) => switch (value) {
  'original_evidence_gated' => 'Original conservative',
  'simple_baseline' => 'Simple baseline',
  'refined' => 'Refined discovery',
  _ => value.replaceAll('_', ' '),
};

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
