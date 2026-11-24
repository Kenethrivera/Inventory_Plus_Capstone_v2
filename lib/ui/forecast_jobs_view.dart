import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../services/forecasting_api_service.dart';
import 'widgets/app_styled_dropdown.dart';

const _ink = Color(0xFF1C1917);
const _muted = Color(0xFF78716C);
const _line = Color(0xFFE6E1DC);
const _accent = Color(0xFFEA580C);
const _tableHeader = Color(0xFFF7F6F4);
const _filterBackground = Color(0xFFF8F7F5);

/// Read-only Admin job monitor. The API derives the location from the session.
class ForecastJobsView extends StatefulWidget {
  const ForecastJobsView({super.key, required this.api, required this.sessionToken,
    required this.active, this.initialModel});

  final ForecastingApiService api;
  final String sessionToken;
  final bool active;
  final String? initialModel;

  @override
  State<ForecastJobsView> createState() => ForecastJobsViewState();
}

class ForecastJobsViewState extends State<ForecastJobsView> {
  final _searchController = TextEditingController();
  ForecastJobsPage? _data;
  String? _error;
  String _model = 'all';
  String _status = 'all';
  bool _latestOnly = true;
  bool _loading = false;
  int _page = 1;
  int _generation = 0;
  int _polls = 0;
  Timer? _pollTimer;
  Timer? _searchTimer;
  ValueNotifier<ForecastJobItem>? _openDetail;

  /// Used only by the selected tab's read-only header Refresh control.
  void refresh() => _refresh();

  @override
  void initState() {
    super.initState();
    _model = _normalizeModel(widget.initialModel);
    if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didUpdateWidget(covariant ForecastJobsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _pollTimer?.cancel();
      _generation++;
      _loading = false;
    } else if (!oldWidget.active && widget.active) {
      _polls = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    } else if (oldWidget.sessionToken != widget.sessionToken ||
        oldWidget.api != widget.api) {
      _generation++;
      _data = null;
      _page = 1;
      _loading = false;
      if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  static String _normalizeModel(String? model) =>
      model == 'calibrated_blend' ? 'blend' :
      const {'blend', 'lightgbm', 'mean28', 'seasonal_experimental'}.contains(model)
          ? model! : 'all';

  void _changeFilter(VoidCallback change) {
    _pollTimer?.cancel();
    _generation++;
    _polls = 0;
    setState(() { change(); _page = 1; _data = null; _error = null; _loading = false; });
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted || !widget.active || _loading) return;
    _pollTimer?.cancel();
    final request = ++_generation;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await widget.api.loadForecastJobs(
        sessionToken: widget.sessionToken, page: _page, pageSize: 25,
        latestOnly: _latestOnly, search: _searchController.text.trim(),
        model: _model == 'all' ? null : _model,
        status: _status == 'all' ? null : _status,
      );
      if (!mounted || !widget.active || request != _generation) return;
      if (result.pageCount > 0 && _page > result.pageCount) {
        setState(() { _page = result.pageCount; _loading = false; });
        _refresh();
        return;
      }
      setState(() { _data = result; _loading = false; });
      final detail = _openDetail;
      if (detail != null) {
        for (final job in result.items) {
          if (job.jobId == detail.value.jobId) { detail.value = job; break; }
        }
      }
      _schedulePoll();
    } catch (error) {
      if (!mounted || !widget.active || request != _generation) return;
      setState(() {
        _loading = false;
        if (error is ForecastApiException) {
          _error = error.isTimeout ? 'Status request timed out. Try Refresh.' :
              error.statusCode == 401 || error.statusCode == 403 ?
              'Admin access is required to view forecast jobs.' : error.message;
        } else {
          _error = 'Forecast jobs are unavailable. Check the connection and try Refresh.';
        }
      });
    }
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    final counts = _data?.counts;
    final active = (counts?['queued'] ?? 0) + (counts?['retry_pending'] ?? 0) +
        (counts?['running'] ?? 0);
    if (!widget.active || active == 0 || _polls >= 80) return;
    _pollTimer = Timer(const Duration(seconds: 15), () {
      _polls++;
      _refresh();
    });
  }

  @override
  void dispose() {
    _generation++;
    _pollTimer?.cancel();
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final theme = Theme.of(context);
    return Theme(data: theme.copyWith(colorScheme: theme.colorScheme.copyWith(
      primary: _accent, surface: Colors.white, surfaceTint: Colors.transparent)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, constraints) {
        const title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Forecast Jobs', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: _ink)),
          SizedBox(height: 3),
          Text('Jobs for your authorized store. Monitoring and Refresh only read status.',
              style: TextStyle(fontSize: 12, color: _muted)),
        ]);
        final updated = data == null ? null : Text(
          'Last updated ${_timestamp(data.generatedAt)}',
          textAlign: constraints.maxWidth < 520 ? TextAlign.left : TextAlign.right,
          style: const TextStyle(fontSize: 11, color: _muted));
        if (constraints.maxWidth < 520) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            title,
            if (updated != null) Padding(padding: const EdgeInsets.only(top: 6),
              child: updated),
          ]);
        }
        return Row(children: [Expanded(child: title),
          if (updated != null) Flexible(child: updated)]);
      }),
      const SizedBox(height: 16),
      _summary(data),
      const SizedBox(height: 16),
      _filters(),
      const SizedBox(height: 12),
      if (_loading) const LinearProgressIndicator(minHeight: 2, color: _accent),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C)))),
      if (data == null && _loading) const Padding(padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator())),
      if (data != null) ...[
        if (data.items.isEmpty) const Padding(padding: EdgeInsets.all(24),
          child: Text('No jobs match these filters. A product without a job is Missing, not Queued.',
            style: TextStyle(color: _muted))),
        if (data.items.isNotEmpty) LayoutBuilder(builder: (context, constraints) =>
          constraints.maxWidth < 760 ? _mobileList(data.items) : _table(data.items)),
        _pagination(data),
      ],
    ]));
  }

  Widget _summary(ForecastJobsPage? data) {
    final counts = data?.counts ?? const <String, int>{};
    final cards = <(String, int, Color)>[
      ('Total Jobs', data?.totalCount ?? 0, _ink),
      ('Queued', counts['queued'] ?? 0, _muted),
      ('Processing', counts['running'] ?? 0, const Color(0xFF2563EB)),
      ('Succeeded', counts['succeeded'] ?? 0, const Color(0xFF15803D)),
      ('Failed', counts['failed'] ?? 0, const Color(0xFFB91C1C)),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [for (final card in cards)
        Container(width: 145, padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(9)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(card.$1, style: const TextStyle(fontSize: 11, color: _muted)),
            const SizedBox(height: 4),
            Text('${card.$2}', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600,
              color: card.$3)),
          ])),
      ]),
    ]);
  }

  Widget _filters() => Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      SizedBox(width: 225, child: TextField(controller: _searchController,
        style: const TextStyle(fontSize: 13, color: _ink),
        decoration: _filterDecoration('Product name or SKU',
          prefixIcon: const Icon(Icons.search, size: 18, color: _muted)),
        onChanged: (_) {
          _searchTimer?.cancel();
          _searchTimer = Timer(const Duration(milliseconds: 400), () {
            if (mounted) _changeFilter(() {});
          });
        })),
      _dropdown('Forecast Model', _model, const {
        'all': 'All models', 'blend': 'Blend', 'lightgbm': 'LightGBM',
        'mean28': 'Mean28', 'seasonal_experimental': 'Seasonal',
      }, (value) => _changeFilter(() => _model = value)),
      _dropdown('Status', _status, const {
        'all': 'All statuses', 'queued': 'Queued', 'retry_pending': 'Retry Pending',
        'running': 'Running', 'succeeded': 'Succeeded', 'failed': 'Failed',
        'cancelled': 'Cancelled', 'superseded': 'Superseded',
      }, (value) => _changeFilter(() => _status = value)),
      SegmentedButton<bool>(segments: const [
        ButtonSegment(value: true, label: Text('Latest Jobs')),
        ButtonSegment(value: false, label: Text('All History')),
      ], showSelectedIcon: false,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? _ink : Colors.white),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : _ink),
          overlayColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
              ? Colors.white.withValues(alpha: .12) : _tableHeader),
          side: const WidgetStatePropertyAll(BorderSide(color: _line)),
          textStyle: const WidgetStatePropertyAll(TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        selected: {_latestOnly}, onSelectionChanged: (value) =>
        _changeFilter(() => _latestOnly = value.first)),
    ]);

  Widget _dropdown(String label, String value, Map<String, String> options,
      ValueChanged<String> onChanged) => SizedBox(width: 170,
    child: AppStyledDropdown<String>(value: value,
      style: const TextStyle(fontSize: 13, color: _ink),
      decoration: _filterDecoration(label),
      items: [for (final entry in options.entries) DropdownMenuItem(
        value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis))],
      onChanged: (next) { if (next != null) onChanged(next); }));

  InputDecoration _filterDecoration(String label, {Widget? prefixIcon}) => InputDecoration(
    labelText: label, prefixIcon: prefixIcon, isDense: true,
    filled: true, fillColor: _filterBackground,
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _line)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _line)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _accent)),
  );

  Widget _table(List<ForecastJobItem> items) => LayoutBuilder(builder: (context, constraints) => Container(
    decoration: BoxDecoration(color: Colors.white, border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(14)),
    clipBehavior: Clip.antiAlias,
    child: SingleChildScrollView(scrollDirection: Axis.horizontal,
      child: ConstrainedBox(constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: DataTable(
      headingRowColor: const WidgetStatePropertyAll(_tableHeader),
      dataRowColor: const WidgetStatePropertyAll(Colors.white),
      border: const TableBorder(horizontalInside: BorderSide(color: _line)),
      dividerThickness: 0,
      headingRowHeight: 44,
      dataRowMinHeight: 62,
      dataRowMaxHeight: 62,
      horizontalMargin: 16,
      columnSpacing: 22,
      headingTextStyle: const TextStyle(color: _muted, fontSize: 12),
      dataTextStyle: const TextStyle(color: _ink, fontSize: 13),
      columns: const [DataColumn(label: Text('Product')), DataColumn(label: Text('Forecast Model')),
        DataColumn(label: Text('Status')), DataColumn(label: Text('Requested')),
        DataColumn(label: Text('Started')), DataColumn(label: Text('Completed')),
        DataColumn(label: Text('Duration')), DataColumn(label: Text('Actions'))],
      rows: [for (final job in items) DataRow(cells: [
        DataCell(Column(mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(job.productName ?? 'Product unavailable', overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(job.sku ?? 'SKU unavailable', style: const TextStyle(fontSize: 11, color: _muted)),
        ])),
        DataCell(Text(_modelLabel(job.modelKey))),
        DataCell(_statusPill(job.displayStatus)),
        DataCell(Text(_timestamp(job.createdAt))),
        DataCell(Text(_timestamp(job.startedAt))),
        DataCell(Text(_timestamp(job.completedAt))),
        DataCell(Text(_duration(job.durationSeconds))),
        DataCell(TextButton(onPressed: () => _showDetails(job),
          style: TextButton.styleFrom(foregroundColor: _accent),
          child: const Text('View Details'))),
      ])],
    )))));

  Widget _mobileList(List<ForecastJobItem> items) => Column(children: [
    for (final job in items) Container(width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(job.productName ?? 'Product unavailable',
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600))), _statusPill(job.displayStatus)]),
        Text('${job.sku ?? 'SKU unavailable'} · ${_modelLabel(job.modelKey)}',
          style: const TextStyle(fontSize: 12, color: _muted)),
        const SizedBox(height: 5),
        Text('Requested ${_timestamp(job.createdAt)} · Duration ${_duration(job.durationSeconds)}',
          style: const TextStyle(fontSize: 11, color: _muted)),
        Align(alignment: Alignment.centerRight, child: TextButton(
          onPressed: () => _showDetails(job),
          style: TextButton.styleFrom(foregroundColor: _accent),
          child: const Text('View Details'))),
      ])),
  ]);

  Widget _pagination(ForecastJobsPage data) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      Flexible(child: Text('${data.totalCount} jobs · page ${data.page} of ${data.pageCount == 0 ? 1 : data.pageCount}',
        style: const TextStyle(fontSize: 12, color: _muted))),
      IconButton(tooltip: 'Previous page', onPressed: _loading || _page <= 1 ? null :
        () { setState(() => _page--); _refresh(); }, icon: const Icon(Icons.chevron_left)),
      IconButton(tooltip: 'Next page', onPressed: _loading || _page >= data.pageCount ? null :
        () { setState(() => _page++); _refresh(); }, icon: const Icon(Icons.chevron_right)),
    ]));

  void _showDetails(ForecastJobItem selected) {
    final detail = ValueNotifier<ForecastJobItem>(selected);
    _openDetail = detail;
    showDialog<void>(context: context, barrierColor: Colors.black26,
      builder: (dialogContext) => ValueListenableBuilder<ForecastJobItem>(
        valueListenable: detail,
        builder: (dialogContext, job, _) {
          final size = MediaQuery.sizeOf(dialogContext);
          return Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.black.withValues(alpha: .16),
            elevation: 12,
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: _line)),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: size.width < 712 ? size.width - 32 : 680,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: size.height * .86),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                    child: Row(children: [
                      Container(width: 42, height: 42,
                        decoration: BoxDecoration(color: _accent.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.work_history_outlined,
                          size: 21, color: _accent)),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('Forecast Job Details',
                        style: TextStyle(color: _ink, fontSize: 18,
                          fontWeight: FontWeight.w700))),
                      IconButton(tooltip: 'Close details',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(LucideIcons.x, size: 19, color: _muted)),
                    ])),
                  const Divider(height: 1, color: _line),
                  Flexible(child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _detailSection('Job Information', [
                          _detail('Job ID', job.jobId),
                          _detail('Product', '${job.productName ?? 'Unavailable'} · ${job.sku ?? 'SKU unavailable'}'),
                          _detail('Model', '${_modelLabel(job.modelKey)} · version ${job.modelVersion ?? 'unavailable'}'),
                          _detail('Forecast business date', job.businessDate ?? 'Unavailable'),
                          _detail('Forecast horizon', '${job.horizonDays} days'),
                          _detail('Status', _statusLabel(job.displayStatus),
                            displayValue: _statusPill(job.displayStatus)),
                          _detail('Created', _fullTimestamp(job.createdAt)),
                          _detail('Started', _fullTimestamp(job.startedAt)),
                          _detail('Completed', _fullTimestamp(job.completedAt)),
                          _detail('Attempts', '${job.attemptCount} of ${job.maxAttempts}'),
                          _detail('Duration', job.attemptCount > 1
                            ? 'Unavailable: retries make total elapsed time differ from execution time'
                            : _duration(job.durationSeconds)),
                        ]),
                        const SizedBox(height: 20),
                        _detailSection('Execution Information', [
                          _detail('Current execution state', _statusLabel(job.displayStatus)),
                          _detail('Safe error code', job.safeErrorCode ?? 'None reported'),
                          _detail('Saved result', job.resultId == null ? 'No' : 'Yes'),
                          _detail('Saved result time', _fullTimestamp(job.resultCreatedAt)),
                          _detail('Retry / recovery', _recovery(job)),
                        ]),
                        if (job.safeErrorCode != null) ...[
                          const SizedBox(height: 14),
                          Container(padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(color: _tableHeader,
                              border: Border.all(color: _line),
                              borderRadius: BorderRadius.circular(9)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Failure detail', style: TextStyle(
                                  color: _ink, fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                                const SizedBox(height: 5),
                                Text(_errorExplanation(job.safeErrorCode!),
                                  style: const TextStyle(color: _muted,
                                    fontSize: 12, height: 1.4)),
                              ])),
                        ],
                      ]))),
                ]),
              ),
            ),
          );
        },
      )).whenComplete(() {
      if (identical(_openDetail, detail)) _openDetail = null;
      detail.dispose();
    });
  }

  static Widget _detailSection(String title, List<Widget> fields) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: const TextStyle(color: _ink, fontSize: 14,
        fontWeight: FontWeight.w700)),
      const SizedBox(height: 9),
      Container(decoration: BoxDecoration(color: Colors.white,
        border: Border.all(color: _line), borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: _line),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: fields[i]),
          ],
        ])),
    ]);

  static Widget _detail(String label, String value, {Widget? displayValue}) =>
    LayoutBuilder(builder: (context, constraints) {
      final labelWidget = Text(label, style: const TextStyle(fontSize: 12,
        color: _muted, fontWeight: FontWeight.w500));
      final valueWidget = displayValue ?? SelectableText(value,
        style: const TextStyle(fontSize: 13, color: _ink, height: 1.35));
      if (constraints.maxWidth < 430) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          labelWidget, const SizedBox(height: 5), valueWidget,
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 175, child: labelWidget),
        Expanded(child: valueWidget),
      ]);
    });

  static String _recovery(ForecastJobItem job) {
    if (job.status == 'failed') return 'Terminal failure. This exact job identity requires authorized operator review. A later valid identity can be prepared separately.';
    if (job.displayStatus == 'retry_pending') return 'A retry is pending under the existing job policy.';
    if (job.status == 'cancelled' || job.status == 'superseded') return 'Terminal state. No retry action is available here.';
    if (job.status == 'queued' || job.status == 'running') return 'Worker processing is in progress; this view does not change it.';
    return 'Completed. No recovery required.';
  }

  static String _errorExplanation(String code) => switch (code) {
    'forecast_input_unavailable' => 'Forecast input was unavailable to this execution. Causes include frozen input or implementation identity mismatch; inspect operator diagnostics.',
    'insufficient_history' => 'The model reported insufficient usable training history.',
    _ => 'The worker reported this safe error code. Authorized operator diagnostics may provide more detail.',
  };
}

String _modelLabel(String key) => switch (key) {
  'blend' => 'Blend', 'lightgbm' => 'LightGBM', 'mean28' => 'Mean28',
  'seasonal_experimental' => 'Seasonal', _ => key,
};

String _statusLabel(String status) => switch (status) {
  'queued' => 'Queued', 'running' => 'Running', 'succeeded' => 'Succeeded',
  'failed' => 'Failed', 'retry_pending' => 'Retry Pending',
  'cancelled' => 'Cancelled', 'superseded' => 'Superseded', _ => status,
};

Widget _statusPill(String status) {
  final (foreground, background) = switch (status) {
    'running' => (const Color(0xFF1D4ED8), const Color(0xFFEFF6FF)),
    'succeeded' => (const Color(0xFF15803D), const Color(0xFFF0FDF4)),
    'failed' => (const Color(0xFFB91C1C), const Color(0xFFFEF2F2)),
    'retry_pending' => (const Color(0xFFB45309), const Color(0xFFFFFBEB)),
    _ => (_muted, const Color(0xFFF5F5F4)),
  };
  return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: background,
      border: Border.all(color: foreground.withValues(alpha: .22)),
      borderRadius: BorderRadius.circular(7)),
    child: Text(_statusLabel(status), style: TextStyle(fontSize: 12,
      fontWeight: FontWeight.w600, color: foreground)));
}

String _date(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _timestamp(String? value) {
  if (value == null) return 'Unavailable';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return 'Unavailable';
  final manila = parsed.toUtc().add(const Duration(hours: 8));
  return '${_date(manila)} ${manila.hour.toString().padLeft(2, '0')}:'
      '${manila.minute.toString().padLeft(2, '0')} PHT';
}

String _fullTimestamp(String? value) {
  if (value == null) return 'Unavailable';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return 'Unavailable';
  final manila = parsed.toUtc().add(const Duration(hours: 8));
  return '${_date(manila)} ${manila.hour.toString().padLeft(2, '0')}:'
      '${manila.minute.toString().padLeft(2, '0')}:'
      '${manila.second.toString().padLeft(2, '0')}.'
      '${manila.millisecond.toString().padLeft(3, '0')}'
      '${manila.microsecond.toString().padLeft(3, '0')} +08:00';
}

String _duration(double? seconds) {
  if (seconds == null) return 'Unavailable';
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} s';
  return '${(seconds / 60).toStringAsFixed(1)} min';
}
