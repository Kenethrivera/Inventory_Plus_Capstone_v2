import 'dart:async';

import 'package:flutter/material.dart';

import '../logic/helper_assignment.dart';
import '../logic/inventory_controller.dart';
import '../logic/staff_performance.dart';
import 'widgets/app_dialog.dart';
import 'widgets/history_period_controls.dart';

const _blue = Color(0xFF2563EB);
const _ink = Color(0xFF0F172A);
const _muted = Color(0xFF64748B);
const _border = Color(0xFFE2E8F0);
const _surface = Color(0xFFF8FAFC);

class StaffPerformancePage extends StatefulWidget {
  const StaffPerformancePage({super.key, required this.controller});

  final InventoryController controller;

  @override
  State<StaffPerformancePage> createState() => _StaffPerformancePageState();
}

class _StaffPerformancePageState extends State<StaffPerformancePage> {
  StaffPerformanceRole _role = StaffPerformanceRole.helpers;
  HistoryPeriodSelection _period = HistoryPeriodSelection.current();
  StaffPerformanceSnapshot? _snapshot;
  Object? _error;
  bool _loading = true;
  int _loadGeneration = 0;
  StreamSubscription<void>? _invalidationSubscription;
  StreamSubscription<dynamic>? _orderSubscription;

  @override
  void initState() {
    super.initState();
    _invalidationSubscription = widget.controller.staffPerformanceInvalidations
        .listen((_) => unawaited(_load(forceRefresh: true)));
    _orderSubscription = widget.controller.orderSnapshots.listen((_) {
      if (mounted && _role == StaffPerformanceRole.helpers) {
        setState(() {});
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _invalidationSubscription?.cancel();
    _orderSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final generation = ++_loadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final range = _period.range;
      final result = await widget.controller.loadStaffPerformance(
        role: _role,
        periodStart: range.start,
        periodEnd: range.end,
        forceRefresh: forceRefresh,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _snapshot = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _changeRole(StaffPerformanceRole role) {
    if (_role == role) return;
    setState(() {
      _role = role;
      _snapshot = null;
    });
    unawaited(_load());
  }

  void _changePeriod(HistoryPeriodSelection period) {
    setState(() {
      _period = period;
      _snapshot = null;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final records = _snapshot?.records ?? const <StaffPerformanceRecord>[];
    return ColoredBox(
      color: _surface,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildControls(),
              const SizedBox(height: 18),
              if (_loading && _snapshot == null)
                const SizedBox(
                  height: 320,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null && _snapshot == null)
                _ErrorPanel(onRetry: () => _load(forceRefresh: true))
              else ...[
                _buildSummary(records),
                const SizedBox(height: 18),
                _buildTable(records),
                if (_loading) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(minHeight: 2),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Staff Performance',
                style: TextStyle(
                  color: _ink,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Monitor employee workload, efficiency, and service performance',
                style: TextStyle(color: _muted, fontSize: 14),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'How performance is calculated',
          onPressed: _showFormula,
          icon: const Icon(Icons.info_outline, color: _blue),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _ChoiceGroup<StaffPerformanceRole>(
          values: StaffPerformanceRole.values,
          selected: _role,
          label: (value) => value.label,
          onSelected: _changeRole,
        ),
        _ChoiceGroup<HistoryPeriodMode>(
          values: HistoryPeriodMode.values,
          selected: _period.mode,
          label: (value) => value.label,
          onSelected: (mode) => _changePeriod(_period.withMode(mode)),
        ),
        HistoryPeriodControls(selection: _period, onChanged: _changePeriod),
      ],
    );
  }

  Widget _buildSummary(List<StaffPerformanceRecord> records) {
    final active = records.where((record) => record.isActive).length;
    final completed = records.fold<int>(
      0,
      (sum, record) => sum + record.completedCount,
    );
    final valid = records.fold<int>(
      0,
      (sum, record) => sum + record.validTimingCount,
    );
    final weightedOnTime = valid == 0
        ? 0.0
        : records.fold<double>(
                0,
                (sum, record) =>
                    sum + record.onTimeRate * record.validTimingCount,
              ) /
              valid;
    final timedMinutes = records.fold<double>(
      0,
      (sum, record) =>
          sum + (record.averageMinutes ?? 0) * record.validTimingCount,
    );
    final averageMinutes = valid == 0 ? null : timedMinutes / valid;
    final helper = _role == StaffPerformanceRole.helpers;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 900
            ? (constraints.maxWidth - 36) / 4
            : constraints.maxWidth >= 520
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _MetricCard(
              width: width,
              icon: Icons.people_outline,
              label: helper ? 'Active Helpers' : 'Active Cashiers',
              value: '$active',
            ),
            _MetricCard(
              width: width,
              icon: Icons.task_alt,
              label: helper ? 'Prepared Orders' : 'Completed Checkouts',
              value: '$completed',
            ),
            _MetricCard(
              width: width,
              icon: Icons.schedule,
              label: 'Avg On-Time',
              value: '${weightedOnTime.toStringAsFixed(1)}%',
            ),
            _MetricCard(
              width: width,
              icon: Icons.timer_outlined,
              label: helper ? 'Avg Prep Time' : 'Avg Payment Time',
              value: _minutes(averageMinutes),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTable(List<StaffPerformanceRecord> records) {
    if (records.isEmpty) {
      return const _EmptyPanel();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            children: [
              for (final record in records) ...[
                _PerformanceCard(
                  record: record,
                  currentWorkload: _currentWorkload(record),
                  onView: () => _showDetails(record),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );
        }
        return _PerformanceTable(
          role: _role,
          records: records,
          currentWorkload: _currentWorkload,
          onView: _showDetails,
        );
      },
    );
  }

  int _currentWorkload(StaffPerformanceRecord record) {
    if (_role != StaffPerformanceRole.helpers) return 0;
    return activePreparationWorkloads(
          widget.controller.currentOrders,
        )[record.employeeId] ??
        record.currentWorkload;
  }

  Future<void> _showFormula() {
    final helper = _role == StaffPerformanceRole.helpers;
    return showDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        icon: Icons.calculate_outlined,
        color: _blue,
        title: 'How this score is calculated',
        subtitle: '${_role.label} · Staff Performance V1',
        maxWidth: 580,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
        child: _FormulaExplanation(helper: helper),
      ),
    );
  }

  Future<void> _showDetails(StaffPerformanceRecord record) {
    final helper = record.role == StaffPerformanceRole.helpers;
    final workload = _currentWorkload(record);
    return showDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        icon: helper ? Icons.handyman_outlined : Icons.point_of_sale_outlined,
        color: _scoreColor(record.score),
        title: record.employeeName,
        subtitle: '${record.role.label} · ${_period.displayLabel}',
        maxWidth: 700,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ScoreBanner(record: record),
            const SizedBox(height: 16),
            _DetailSection(
              title: helper
                  ? 'Preparation performance'
                  : 'Checkout performance',
              rows: [
                _DetailValue(
                  helper ? 'Orders prepared' : 'Completed checkouts',
                  '${record.completedCount}',
                ),
                _DetailValue(
                  'Valid timing sample',
                  '${record.validTimingCount}',
                ),
                _DetailValue(
                  'Excluded timing records',
                  '${record.excludedTimingCount}',
                ),
                _DetailValue(
                  helper ? 'Complexity points' : 'Checkout complexity points',
                  record.workloadPoints.toStringAsFixed(2),
                ),
                _DetailValue(
                  helper ? 'Average prep' : 'Average ready → paid',
                  _minutes(record.averageMinutes),
                ),
                _DetailValue('Median', _minutes(record.medianMinutes)),
                _DetailValue('Fastest', _minutes(record.fastestMinutes)),
                _DetailValue('On-time rate', _percent(record.onTimeRate)),
                _DetailValue('Delayed orders', '${record.delayedCount}'),
                _DetailValue('Reliability', _percent(record.reliability)),
                _DetailValue(
                  'Efficiency',
                  record.efficiency == null
                      ? 'Not available'
                      : '${record.efficiency!.toStringAsFixed(3)} pts/min',
                ),
                _DetailValue(
                  helper ? 'Workload completed' : 'Checkout workload completed',
                  '${record.workloadPoints.toStringAsFixed(2)} pts',
                ),
                if (helper) _DetailValue('Current workload', '$workload'),
              ],
            ),
            if (!helper) ...[
              const SizedBox(height: 14),
              _DetailSection(
                title: 'Sales & discounts',
                rows: [
                  _DetailValue('Sales handled', _currency(record.salesHandled)),
                  _DetailValue(
                    'Discounted transactions',
                    '${record.discountedTransactions}',
                  ),
                  _DetailValue(
                    'Discount usage rate',
                    _percent(record.discountUsageRate),
                  ),
                  _DetailValue(
                    'Discount approval requests',
                    '${record.discountApprovalRequests}',
                  ),
                  _DetailValue(
                    'Approved / Rejected / Pending',
                    '${record.discountApprovalsApproved} / '
                        '${record.discountApprovalsRejected} / '
                        '${record.discountApprovalsPending}',
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            _FormulaExplanation(helper: helper, compact: true),
          ],
        ),
      ),
    );
  }
}

class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in values)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: ChoiceChip(
                label: Text(label(value)),
                selected: selected == value,
                onSelected: (_) => onSelected(value),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                side: BorderSide.none,
                selectedColor: const Color(0xFFDBEAFE),
                backgroundColor: Colors.transparent,
                labelStyle: TextStyle(
                  color: selected == value ? _blue : _muted,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: _blue, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PerformanceTable extends StatelessWidget {
  const _PerformanceTable({
    required this.role,
    required this.records,
    required this.currentWorkload,
    required this.onView,
  });

  final StaffPerformanceRole role;
  final List<StaffPerformanceRecord> records;
  final int Function(StaffPerformanceRecord record) currentWorkload;
  final ValueChanged<StaffPerformanceRecord> onView;

  @override
  Widget build(BuildContext context) {
    final helper = role == StaffPerformanceRole.helpers;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: [
            _row(
              header: true,
              values: [
                'Employee',
                helper ? 'Prepared' : 'Checkouts',
                'Workload',
                helper ? 'Avg Prep' : 'Avg Payment',
                'On-Time',
                'Delays',
                helper ? 'Active' : 'Sales',
                'Score',
                'View',
              ],
            ),
            for (var index = 0; index < records.length; index++) ...[
              if (index > 0) const Divider(height: 1, color: _border),
              _dataRow(records[index], helper),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dataRow(StaffPerformanceRecord record, bool helper) {
    final active = helper
        ? '${currentWorkload(record)}'
        : _compactCurrency(record.salesHandled);
    return _row(
      values: [
        record.employeeName,
        '${record.completedCount}',
        record.workloadPoints.toStringAsFixed(2),
        _minutes(record.averageMinutes),
        _percent(record.onTimeRate),
        '${record.delayedCount}',
        active,
        record.score == null
            ? 'Insufficient data'
            : record.score!.toStringAsFixed(1),
        '',
      ],
      record: record,
    );
  }

  Widget _row({
    required List<String> values,
    bool header = false,
    StaffPerformanceRecord? record,
  }) {
    const flexes = [24, 9, 11, 12, 10, 8, 10, 11, 5];
    return Container(
      color: header ? _surface : Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          for (var index = 0; index < values.length; index++)
            Expanded(
              flex: flexes[index],
              child: index == values.length - 1 && !header
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'View performance details',
                        onPressed: () => onView(record!),
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        visualDensity: VisualDensity.compact,
                        color: _blue,
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        values[index],
                        maxLines: index == 0 ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: index == 0
                            ? TextAlign.left
                            : TextAlign.center,
                        style: TextStyle(
                          color: header ? _muted : _ink,
                          fontSize: header ? 11 : 12,
                          fontWeight: header
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({
    required this.record,
    required this.currentWorkload,
    required this.onView,
  });

  final StaffPerformanceRecord record;
  final int currentWorkload;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final helper = record.role == StaffPerformanceRole.helpers;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    record.employeeName,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _ScoreChip(record: record),
                IconButton(
                  tooltip: 'View details',
                  onPressed: onView,
                  icon: const Icon(Icons.visibility_outlined, size: 19),
                  color: _blue,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _mini('Completed', '${record.completedCount}')),
                Expanded(
                  child: _mini(
                    'Workload',
                    record.workloadPoints.toStringAsFixed(2),
                  ),
                ),
                Expanded(child: _mini('On-Time', _percent(record.onTimeRate))),
                Expanded(
                  child: _mini(
                    helper ? 'Active' : 'Sales',
                    helper
                        ? '$currentWorkload'
                        : _compactCurrency(record.salesHandled),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mini(String label, String value) => Column(
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 10)),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _ink,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}

class _ScoreBanner extends StatelessWidget {
  const _ScoreBanner({required this.record});
  final StaffPerformanceRecord record;

  @override
  Widget build(BuildContext context) {
    final color = _scoreColor(record.score);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.scoreBand,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  record.score == null
                      ? 'At least ${StaffPerformanceV1.minimumScoredSample} valid records are required.'
                      : record.peerCount == 1
                      ? 'Single eligible peer: peer-normalized components use a neutral value.'
                      : 'Compared only with the same role, location, and period.',
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            record.score == null ? '—' : record.score!.toStringAsFixed(1),
            style: TextStyle(
              color: color,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreChip extends StatelessWidget {
  const _ScoreChip({required this.record});
  final StaffPerformanceRecord record;

  @override
  Widget build(BuildContext context) {
    final color = _scoreColor(record.score);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        record.score == null
            ? 'Insufficient data'
            : record.score!.toStringAsFixed(1),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DetailValue {
  const _DetailValue(this.label, this.value);
  final String label;
  final String value;
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.rows});
  final String title;
  final List<_DetailValue> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const Divider(height: 15, color: _border),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    rows[index].label,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    rows[index].value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FormulaExplanation extends StatelessWidget {
  const _FormulaExplanation({required this.helper, this.compact = false});
  final bool helper;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        border: Border.all(color: const Color(0xFFBFDBFE)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'How this score is calculated',
            style: TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '40% On-Time · 30% Complexity-Adjusted Throughput · '
            '20% Complexity-Adjusted Efficiency · 10% Reliability',
            style: TextStyle(color: _ink, fontSize: 12, height: 1.45),
          ),
          const SizedBox(height: 7),
          Text(
            helper
                ? 'Complexity starts at 1 point and considers distinct order lines, per-line quantity burden, and currently resolvable product map locations.'
                : 'Checkout complexity starts at 1 point and considers distinct lines, per-line quantity burden, GCash, discounts, and exact approved discount requests.',
            style: const TextStyle(color: _muted, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text(
            'Throughput and efficiency are peer-normalized within the same role, location, and period. '
            'Session hours are not used because overlapping/open session logs cannot provide reliable active hours.',
            style: const TextStyle(color: _muted, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: [
        const Icon(Icons.cloud_off_outlined, color: _muted, size: 34),
        const SizedBox(height: 10),
        const Text(
          'Performance data could not be loaded.',
          style: TextStyle(color: _ink, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(36),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Column(
      children: [
        Icon(Icons.query_stats_outlined, color: _muted, size: 36),
        SizedBox(height: 10),
        Text(
          'No staff performance records for this period.',
          style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

String _minutes(double? value) {
  if (value == null) return '—';
  if (value < 1) return '${(value * 60).round()} sec';
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} min';
}

String _percent(double value) => '${value.toStringAsFixed(1)}%';
String _currency(double value) => '₱${value.toStringAsFixed(2)}';
String _compactCurrency(double value) => value >= 1000
    ? '₱${(value / 1000).toStringAsFixed(1)}k'
    : '₱${value.toStringAsFixed(0)}';

Color _scoreColor(double? score) {
  if (score == null) return _muted;
  if (score >= 90) return const Color(0xFF15803D);
  if (score >= 80) return const Color(0xFF2563EB);
  if (score >= 70) return const Color(0xFF0891B2);
  if (score >= 60) return const Color(0xFFD97706);
  return const Color(0xFFDC2626);
}
