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

@immutable
class StaffPerformanceRankedRecord {
  const StaffPerformanceRankedRecord({required this.record, this.rank});

  final StaffPerformanceRecord record;
  final int? rank;
}

/// Presentation-only ordering. The backend score and eligibility are unchanged.
List<StaffPerformanceRankedRecord> rankStaffPerformanceRecords(
  Iterable<StaffPerformanceRecord> records,
) {
  final sorted = records.toList(growable: false)
    ..sort((left, right) {
      final leftScore = left.score;
      final rightScore = right.score;
      if (leftScore == null && rightScore != null) return 1;
      if (leftScore != null && rightScore == null) return -1;
      if (leftScore != null && rightScore != null) {
        final byScore = rightScore.compareTo(leftScore);
        if (byScore != 0) return byScore;
      }
      final byName = left.employeeName.toLowerCase().compareTo(
        right.employeeName.toLowerCase(),
      );
      return byName != 0 ? byName : left.employeeId.compareTo(right.employeeId);
    });

  var scoredPosition = 0;
  return List<StaffPerformanceRankedRecord>.unmodifiable(
    sorted.map((record) {
      if (record.score == null) {
        return StaffPerformanceRankedRecord(record: record);
      }
      scoredPosition++;
      return StaffPerformanceRankedRecord(record: record, rank: scoredPosition);
    }),
  );
}

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
    final snapshot = _snapshot;
    final records = snapshot?.records ?? const <StaffPerformanceRecord>[];
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
                _buildSummary(snapshot!),
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

  Widget _buildSummary(StaffPerformanceSnapshot snapshot) {
    final records = snapshot.records;
    final valid = snapshot.totalValidTimingCount;
    final weightedOnTime = valid == 0
        ? 0.0
        : records.fold<double>(
                0,
                (sum, record) =>
                    sum + record.onTimeRate * record.validTimingCount,
              ) /
              valid;
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
              icon: Icons.receipt_long_outlined,
              label: helper ? 'Total Orders' : 'Completed Orders',
              value: '${snapshot.totalStoreOrders}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.task_alt,
              label: helper
                  ? 'Helper-Handled Orders'
                  : 'Cashier-Handled Checkouts',
              value: '${snapshot.totalRoleHandledOrders}',
            ),
            _MetricCard(
              width: width,
              icon: Icons.scale_outlined,
              label: helper
                  ? 'Total Workload Points'
                  : 'Total Checkout Workload',
              value:
                  '${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} pts',
            ),
            _MetricCard(
              width: width,
              icon: Icons.schedule,
              label: helper
                  ? 'Average On-Time Rate'
                  : 'Average Payment On-Time',
              value: '${weightedOnTime.toStringAsFixed(1)}%',
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
    final rankedRecords = rankStaffPerformanceRecords(records);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            children: [
              for (final ranked in rankedRecords) ...[
                _PerformanceCard(
                  ranked: ranked,
                  currentWorkload: _currentWorkload(ranked.record),
                  onView: () => _showDetails(ranked.record),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );
        }
        return _PerformanceTable(
          role: _role,
          records: rankedRecords,
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
    final snapshot = _snapshot!;
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
        child: StaffPerformanceDetailContent(
          record: record,
          snapshot: snapshot,
          currentWorkload: workload,
          periodLabel: _period.displayLabel,
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
    required this.onView,
  });

  final StaffPerformanceRole role;
  final List<StaffPerformanceRankedRecord> records;
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
                'Rank',
                'Employee',
                helper ? 'Orders' : 'Checkouts',
                'Workload',
                helper ? 'Avg Prep' : 'Avg Payment',
                'On-Time',
                'Score',
                'View',
              ],
            ),
            for (var index = 0; index < records.length; index++) ...[
              if (index > 0) const Divider(height: 1, color: _border),
              _dataRow(records[index]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dataRow(StaffPerformanceRankedRecord ranked) {
    final record = ranked.record;
    return _row(
      values: [
        '',
        record.employeeName,
        '${record.completedCount}',
        '${record.workloadPoints.toStringAsFixed(2)} pts',
        _minutes(record.averageMinutes),
        _percent(record.onTimeRate),
        record.score == null
            ? 'Insufficient data'
            : record.score!.toStringAsFixed(1),
        '',
      ],
      secondaryValues: [
        null,
        null,
        '${record.orderShare.toStringAsFixed(1)}% of total',
        '${record.workloadShare.toStringAsFixed(1)}% share',
        null,
        null,
        record.score == null ? null : record.scoreBand,
        null,
      ],
      record: record,
      rank: ranked.rank,
    );
  }

  Widget _row({
    required List<String> values,
    List<String?>? secondaryValues,
    bool header = false,
    StaffPerformanceRecord? record,
    int? rank,
  }) {
    const flexes = [7, 23, 12, 14, 13, 11, 14, 6];
    return Container(
      color: header ? _surface : Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          for (var index = 0; index < values.length; index++)
            Expanded(
              flex: flexes[index],
              child: index == 0 && !header
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: StaffPerformanceRankBadge(rank: rank),
                    )
                  : index == values.length - 1 && !header
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
                      child: Column(
                        crossAxisAlignment: index == 1
                            ? CrossAxisAlignment.start
                            : CrossAxisAlignment.center,
                        children: [
                          Text(
                            values[index],
                            maxLines: index == 1 ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: index == 1
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
                          if (!header && secondaryValues?[index] != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              secondaryValues![index]!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: index == 1
                                  ? TextAlign.left
                                  : TextAlign.center,
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
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
    required this.ranked,
    required this.currentWorkload,
    required this.onView,
  });

  final StaffPerformanceRankedRecord ranked;
  final int currentWorkload;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final record = ranked.record;
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
                StaffPerformanceRankBadge(rank: ranked.rank),
                const SizedBox(width: 10),
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
                Expanded(
                  child: _mini(
                    helper ? 'Orders' : 'Checkouts',
                    '${record.completedCount} '
                    '(${record.orderShare.toStringAsFixed(1)}%)',
                  ),
                ),
                Expanded(
                  child: _mini(
                    'Workload',
                    '${record.workloadPoints.toStringAsFixed(2)} '
                        '(${record.workloadShare.toStringAsFixed(1)}%)',
                  ),
                ),
                Expanded(child: _mini('On-Time', _percent(record.onTimeRate))),
                Expanded(
                  child: _mini(
                    helper ? 'Live' : 'Sales',
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

class StaffPerformanceRankBadge extends StatelessWidget {
  const StaffPerformanceRankBadge({super.key, required this.rank});

  final int? rank;

  @override
  Widget build(BuildContext context) {
    final currentRank = rank;
    if (currentRank == null) {
      return const SizedBox(
        key: Key('staff-rank-unranked'),
        width: 28,
        child: Text(
          '—',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
        ),
      );
    }

    final medalColor = switch (currentRank) {
      1 => const Color(0xFFD4A017),
      2 => const Color(0xFF94A3B8),
      3 => const Color(0xFFB87333),
      _ => _muted,
    };
    final medal = currentRank <= 3;
    final medalName = switch (currentRank) {
      1 => 'Gold',
      2 => 'Silver',
      3 => 'Bronze',
      _ => null,
    };
    return Tooltip(
      message: medal
          ? '$medalName medal — rank #$currentRank'
          : 'Rank #$currentRank',
      child: Semantics(
        label: medal
            ? '$medalName medal rank $currentRank'
            : 'Rank $currentRank',
        child: Container(
          key: Key('staff-rank-$currentRank'),
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: medal ? medalColor.withValues(alpha: 0.12) : _surface,
            shape: BoxShape.circle,
            border: Border.all(
              color: medal ? medalColor.withValues(alpha: 0.45) : _border,
            ),
          ),
          child: Text(
            medal ? '#$currentRank' : '$currentRank',
            style: TextStyle(
              color: medal ? medalColor : _muted,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
class StaffMetricExplanation {
  const StaffMetricExplanation({
    required this.title,
    required this.whatItMeasures,
    required this.whyItMatters,
    required this.calculation,
    required this.result,
    required this.scoreUse,
  });

  final String title;
  final String whatItMeasures;
  final String whyItMatters;
  final String calculation;
  final String result;
  final String scoreUse;
}

Future<void> showStaffMetricExplanation(
  BuildContext context,
  StaffMetricExplanation explanation,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AppDialog(
      icon: Icons.info_outline,
      color: _blue,
      title: explanation.title,
      subtitle: 'Metric explanation',
      maxWidth: 560,
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExplanationBlock(
            title: 'What it measures',
            value: explanation.whatItMeasures,
          ),
          _ExplanationBlock(
            title: 'Why it matters',
            value: explanation.whyItMatters,
          ),
          _ExplanationBlock(
            title: 'How it is calculated',
            value: explanation.calculation,
          ),
          _ExplanationBlock(
            title: 'Your result / actual calculation',
            value: explanation.result,
          ),
          _ExplanationBlock(
            title: 'Used in final score?',
            value: explanation.scoreUse,
            last: true,
          ),
        ],
      ),
    ),
  );
}

class _ExplanationBlock extends StatelessWidget {
  const _ExplanationBlock({
    required this.title,
    required this.value,
    this.last = false,
  });

  final String title;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: last ? 0 : 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: _ink,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(color: _muted, fontSize: 12, height: 1.45),
        ),
      ],
    ),
  );
}

class StaffPerformanceDetailContent extends StatelessWidget {
  const StaffPerformanceDetailContent({
    super.key,
    required this.record,
    required this.snapshot,
    required this.currentWorkload,
    required this.periodLabel,
  });

  final StaffPerformanceRecord record;
  final StaffPerformanceSnapshot snapshot;
  final int currentWorkload;
  final String periodLabel;

  bool get _helper => record.role == StaffPerformanceRole.helpers;
  int get _delayThreshold => _helper
      ? StaffPerformanceV1.helperDelayMinutes
      : StaffPerformanceV1.cashierDelayMinutes;
  String get _unit => _helper ? 'orders' : 'checkouts';
  String get _roleName => _helper ? 'Helper' : 'Cashier';

  String get _workloadFormula => _helper
      ? '1 base point + 1 per distinct item line + quantity burden per line '
            '(<=1 = 0, >1-5 = 0.25, >5-10 = 0.50, >10-20 = 0.75, '
            '>20 = 1.00) + 0.50 per additional currently resolvable '
            'storage location.'
      : '1 base point + 1 per distinct item line + quantity burden per line '
            '(<=1 = 0, >1-5 = 0.25, >5-10 = 0.50, >10-20 = 0.75, '
            '>20 = 1.00). Cashiers do not receive storage-location burden. '
            'Add 0.50 for GCash, 0.50 for a discounted transaction, and '
            '1.00 for an approved admin discount.';

  String _peerWorkloads() {
    final peers = snapshot.records.where(
      (peer) => peer.validTimingCount >= StaffPerformanceV1.minimumScoredSample,
    );
    if (peers.isEmpty) return 'No eligible peer workload values.';
    return peers
        .map(
          (peer) =>
              '${peer.employeeName}: ${peer.workloadPoints.toStringAsFixed(2)} pts',
        )
        .join('; ');
  }

  String _peerEfficiencies() {
    final peers = snapshot.records.where(
      (peer) => peer.validTimingCount >= StaffPerformanceV1.minimumScoredSample,
    );
    if (peers.isEmpty) return 'No eligible peer efficiency values.';
    return peers
        .map(
          (peer) =>
              '${peer.employeeName}: ${peer.efficiency?.toStringAsFixed(3) ?? 'N/A'} pts/min',
        )
        .join('; ');
  }

  StaffMetricExplanation _handledExplanation() => StaffMetricExplanation(
    title: _helper ? 'Orders handled' : 'Completed checkouts',
    whatItMeasures:
        'The number of selected-period $_unit attributed to this employee.',
    whyItMatters:
        'It shows the employee count contribution without changing the score.',
    calculation:
        'Count qualifying $_unit attributed to the employee within the selected store and period.',
    result:
        '${record.completedCount} employee $_unit / ${snapshot.totalStoreOrders} total store $_unit.',
    scoreUse: 'No. This is an informational contribution metric.',
  );

  StaffMetricExplanation _orderShareExplanation() => StaffMetricExplanation(
    title: _helper ? 'Order share' : 'Checkout share',
    whatItMeasures:
        'The employee share of all qualifying store $_unit in the period.',
    whyItMatters:
        'It makes the handled count comparable with the full store volume.',
    calculation:
        '${record.completedCount} / ${snapshot.totalStoreOrders} × 100.',
    result: _percent(record.orderShare),
    scoreUse: 'No. Order/Checkout Share is not directly added to Final Score.',
  );

  StaffMetricExplanation _workloadExplanation() => StaffMetricExplanation(
    title: 'Workload',
    whatItMeasures:
        'The complexity-weighted amount of work attributed to this employee.',
    whyItMatters:
        'Two employees can handle the same number of $_unit with different complexity.',
    calculation: _workloadFormula,
    result:
        '${record.workloadPoints.toStringAsFixed(2)} employee points / '
        '${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} total $_roleName points.',
    scoreUse:
        'Not directly. The returned workload feeds Adjusted Throughput, which has a 30% score weight.',
  );

  StaffMetricExplanation _workloadShareExplanation() => StaffMetricExplanation(
    title: 'Workload share',
    whatItMeasures:
        'The employee share of all attributed $_roleName workload points.',
    whyItMatters:
        'It compares complexity contribution rather than order count alone.',
    calculation:
        '${record.workloadPoints.toStringAsFixed(2)} / '
        '${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} × 100.',
    result: _percent(record.workloadShare),
    scoreUse: 'No. Workload Share is informational and is not directly added.',
  );

  StaffMetricExplanation _activeHoursExplanation() => StaffMetricExplanation(
    title: snapshot.activeHoursAvailable
        ? 'Active-hour contribution'
        : 'Active-hour data unavailable',
    whatItMeasures:
        'Active Time Share would compare employee active hours with total role active hours. Contribution Index would compare Workload Share with Active Time Share.',
    whyItMatters:
        'It can show whether workload contribution matched the employee share of working time when reliable historical sessions exist.',
    calculation:
        'Active Time Share = employee active hours / total role active hours × 100. Contribution Index = Workload Share / Active Time Share.',
    result: snapshot.activeHoursAvailable
        ? 'Active hours: ${record.activeHours?.toStringAsFixed(2) ?? 'N/A'} / '
              '${snapshot.totalRoleActiveHours?.toStringAsFixed(2) ?? 'N/A'}; '
              'Active Time Share: ${_optionalPercent(record.activeTimeShare)}; '
              'Contribution Index: ${record.contributionIndex?.toStringAsFixed(2) ?? 'N/A'}.'
        : 'Normal historical login/logout sessions are not reliably recorded, so Active Time Share and Contribution Index remain unavailable.',
    scoreUse: 'No. Contribution Index is excluded from the final score.',
  );

  StaffMetricExplanation _validSampleExplanation() => StaffMetricExplanation(
    title: 'Valid timing sample',
    whatItMeasures:
        'Attributed $_unit with complete, logically ordered timing timestamps.',
    whyItMatters:
        'Timing rates and speed metrics use only trustworthy duration records.',
    calculation:
        'Count records where the required start and finish timestamps exist and finish is not before start.',
    result:
        '${record.validTimingCount} valid records. At least ${StaffPerformanceV1.minimumScoredSample} are required for a score.',
    scoreUse: 'Yes, as the eligibility basis. It has no separate weight.',
  );

  StaffMetricExplanation _excludedExplanation() => StaffMetricExplanation(
    title: 'Excluded timing records',
    whatItMeasures:
        'Employee-attributed records with missing or logically invalid timing.',
    whyItMatters:
        'Invalid durations are excluded instead of being treated as zero-duration work.',
    calculation:
        'Attributed records minus records with a valid chronological duration.',
    result: '${record.excludedTimingCount} employee timing records excluded.',
    scoreUse: 'No. Excluded records do not enter timing calculations.',
  );

  StaffMetricExplanation _totalMinutesExplanation() => StaffMetricExplanation(
    title: 'Total service minutes',
    whatItMeasures:
        'The sum of valid ${_helper ? 'assignment-to-preparation' : 'ready-to-paid'} durations.',
    whyItMatters:
        'It is the time denominator for average duration and efficiency.',
    calculation: 'Add every valid duration in the employee timing sample.',
    result:
        '${record.totalServiceMinutes.toStringAsFixed(2)} minutes across ${record.validTimingCount} valid records.',
    scoreUse: 'Not directly. It feeds Adjusted Efficiency.',
  );

  StaffMetricExplanation _averageExplanation() => StaffMetricExplanation(
    title: _helper ? 'Average prep' : 'Average ready to paid',
    whatItMeasures: 'Mean service duration for valid timing records.',
    whyItMatters: 'It summarizes typical elapsed time across the sample.',
    calculation:
        '${record.totalServiceMinutes.toStringAsFixed(2)} total valid minutes / ${record.validTimingCount} valid records.',
    result: _minutes(record.averageMinutes),
    scoreUse:
        'No direct weight. The underlying time contributes to efficiency.',
  );

  StaffMetricExplanation _medianExplanation() => StaffMetricExplanation(
    title: 'Median service time',
    whatItMeasures: 'The middle valid duration after durations are sorted.',
    whyItMatters: 'It is less affected by unusually long or short records.',
    calculation:
        'Sort all ${record.validTimingCount} valid durations and take the middle value.',
    result: _minutes(record.medianMinutes),
    scoreUse: 'No. It is a descriptive speed metric.',
  );

  StaffMetricExplanation _fastestExplanation() => StaffMetricExplanation(
    title: 'Fastest service time',
    whatItMeasures: 'The shortest valid duration in the selected period.',
    whyItMatters: 'It shows the observed lower bound, not typical performance.',
    calculation: 'Minimum of all valid employee durations.',
    result: _minutes(record.fastestMinutes),
    scoreUse: 'No. It is a descriptive speed metric.',
  );

  StaffMetricExplanation _onTimeExplanation() => StaffMetricExplanation(
    title: 'On-time rate',
    whatItMeasures:
        'The percentage of valid $_unit completed under $_delayThreshold minutes.',
    whyItMatters: 'It is the primary timeliness component of Final Score.',
    calculation:
        '${record.onTimeCount} on-time / ${record.validTimingCount} valid × 100. Under $_delayThreshold min is on-time; $_delayThreshold min or more is delayed.',
    result: _percent(record.onTimeRate),
    scoreUse:
        'Yes — 40%. ${record.onTimeRate.toStringAsFixed(2)} × 40% = ${record.onTimeScoreContribution.toStringAsFixed(2)}.',
  );

  StaffMetricExplanation _onTimeCountExplanation() => StaffMetricExplanation(
    title: 'On-time records',
    whatItMeasures:
        'Valid $_unit completed in less than $_delayThreshold minutes.',
    whyItMatters: 'It is the numerator of the On-Time Rate.',
    calculation:
        'Count valid durations below the $_delayThreshold-minute threshold.',
    result:
        '${record.onTimeCount} of ${record.validTimingCount} valid records.',
    scoreUse: 'Indirectly. It determines the 40% On-Time component.',
  );

  StaffMetricExplanation _delayedExplanation() => StaffMetricExplanation(
    title: _helper ? 'Delayed orders' : 'Delayed checkouts',
    whatItMeasures: 'Valid $_unit taking $_delayThreshold minutes or longer.',
    whyItMatters: 'It identifies records outside the V1 on-time threshold.',
    calculation:
        'Count valid durations greater than or equal to $_delayThreshold minutes.',
    result:
        '${record.delayedCount} delayed of ${record.validTimingCount} valid.',
    scoreUse: 'Indirectly. It determines Delay Rate and Reliability.',
  );

  StaffMetricExplanation _delayRateExplanation() => StaffMetricExplanation(
    title: 'Delay rate',
    whatItMeasures: 'The percentage of valid records classified as delayed.',
    whyItMatters: 'It makes delay counts comparable across sample sizes.',
    calculation:
        '${record.delayedCount} delayed / ${record.validTimingCount} valid × 100.',
    result: _percent(record.delayRate),
    scoreUse: 'Indirectly. Reliability is 100 minus Delay Rate.',
  );

  StaffMetricExplanation _reliabilityExplanation() => StaffMetricExplanation(
    title: 'Reliability',
    whatItMeasures: 'Consistency in avoiding delayed valid records.',
    whyItMatters:
        'It rewards repeatable timeliness across the selected period.',
    calculation: '100 - ${record.delayRate.toStringAsFixed(2)}% delay rate.',
    result: _percent(record.reliability),
    scoreUse:
        'Yes — 10%. ${record.reliability.toStringAsFixed(2)} × 10% = ${record.reliabilityScoreContribution.toStringAsFixed(2)}.',
  );

  StaffMetricExplanation _efficiencyExplanation() => StaffMetricExplanation(
    title: 'Complexity-adjusted efficiency',
    whatItMeasures: 'Valid workload complexity completed per service minute.',
    whyItMatters:
        'It relates completed complexity to elapsed time instead of using speed alone.',
    calculation:
        '${record.timedWorkloadPoints.toStringAsFixed(2)} valid workload points / ${record.totalServiceMinutes.toStringAsFixed(2)} valid service minutes.',
    result: record.efficiency == null
        ? 'Not available.'
        : '${record.efficiency!.toStringAsFixed(3)} points per minute.',
    scoreUse:
        'Not directly. This raw value is peer-normalized into Adjusted Efficiency.',
  );

  StaffMetricExplanation
  _efficiencyBasisExplanation() => StaffMetricExplanation(
    title: 'Efficiency basis',
    whatItMeasures:
        'The exact numerator and denominator used for raw efficiency.',
    whyItMatters: 'It makes the efficiency result manually auditable.',
    calculation: 'Valid complexity points / total valid service minutes.',
    result:
        '${record.timedWorkloadPoints.toStringAsFixed(2)} pts / ${record.totalServiceMinutes.toStringAsFixed(2)} min.',
    scoreUse: 'Indirectly. It feeds the 20% Adjusted Efficiency component.',
  );

  StaffMetricExplanation
  _adjustedThroughputExplanation() => StaffMetricExplanation(
    title: 'Adjusted throughput',
    whatItMeasures:
        'The backend-returned 0-100 peer-normalized workload result.',
    whyItMatters:
        'It compares complexity-adjusted amount of work with eligible employees in the same role, store, and period.',
    calculation:
        'The Phase 4 report peer-normalizes employee workload among eligible same-role employees. This UI displays the returned value without recomputing it.',
    result:
        'Employee workload: ${record.workloadPoints.toStringAsFixed(2)} pts. '
        'Eligible cohort values: ${_peerWorkloads()} '
        'Returned normalized value: ${_optionalScore(record.adjustedThroughput)}.',
    scoreUse: record.adjustedThroughput == null
        ? 'Yes — 30%, once the minimum sample is met.'
        : 'Yes — 30%. ${record.adjustedThroughput!.toStringAsFixed(2)} × 30% = ${record.throughputScoreContribution!.toStringAsFixed(2)}.',
  );

  StaffMetricExplanation
  _adjustedEfficiencyExplanation() => StaffMetricExplanation(
    title: 'Adjusted efficiency',
    whatItMeasures:
        'The backend-returned 0-100 peer-normalized efficiency result.',
    whyItMatters:
        'It compares complexity handled relative to time with eligible employees in the same role, store, and period.',
    calculation:
        'The Phase 4 report peer-normalizes raw efficiency among eligible same-role employees. This UI displays the returned value without recomputing it.',
    result:
        'Employee raw efficiency: ${record.efficiency?.toStringAsFixed(3) ?? 'N/A'} pts/min. '
        'Eligible cohort values: ${_peerEfficiencies()} '
        'Returned normalized value: ${_optionalScore(record.adjustedEfficiency)}.',
    scoreUse: record.adjustedEfficiency == null
        ? 'Yes — 20%, once the minimum sample is met.'
        : 'Yes — 20%. ${record.adjustedEfficiency!.toStringAsFixed(2)} × 20% = ${record.efficiencyScoreContribution!.toStringAsFixed(2)}.',
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScoreBanner(record: record),
        const SizedBox(height: 10),
        _PerformanceInsights(record: record),
        const SizedBox(height: 16),
        _DetailSection(
          title: 'Contribution',
          rows: [
            _DetailValue(
              _helper ? 'Orders handled' : 'Completed checkouts',
              '${record.completedCount} / ${snapshot.totalStoreOrders}',
              explanation: _handledExplanation(),
            ),
            _DetailValue(
              _helper ? 'Order share' : 'Checkout share',
              _percent(record.orderShare),
              explanation: _orderShareExplanation(),
            ),
            _DetailValue(
              'Workload',
              '${record.workloadPoints.toStringAsFixed(2)} / '
                  '${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} points',
              explanation: _workloadExplanation(),
            ),
            _DetailValue(
              'Workload share',
              _percent(record.workloadShare),
              explanation: _workloadShareExplanation(),
            ),
            if (snapshot.activeHoursAvailable &&
                record.activeHours != null &&
                snapshot.totalRoleActiveHours != null) ...[
              _DetailValue(
                'Active hours',
                '${record.activeHours!.toStringAsFixed(2)} / '
                    '${snapshot.totalRoleActiveHours!.toStringAsFixed(2)}',
                explanation: _activeHoursExplanation(),
              ),
              _DetailValue(
                'Active time share',
                _optionalPercent(record.activeTimeShare),
                explanation: _activeHoursExplanation(),
              ),
              _DetailValue(
                'Contribution Index',
                record.contributionIndex?.toStringAsFixed(2) ?? 'Not available',
                explanation: _activeHoursExplanation(),
              ),
            ] else
              _DetailValue(
                'Active-hour data',
                'Unavailable — Contribution Index disabled',
                explanation: _activeHoursExplanation(),
              ),
          ],
        ),
        const SizedBox(height: 18),
        const _GroupHeading(title: 'Performance'),
        const SizedBox(height: 8),
        _DetailSection(
          title: 'A. Data Basis',
          rows: [
            _DetailValue(
              'Valid timing sample',
              '${record.validTimingCount}',
              explanation: _validSampleExplanation(),
            ),
            _DetailValue(
              'Excluded timing records',
              '${record.excludedTimingCount}',
              explanation: _excludedExplanation(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _DetailSection(
          title: 'B. Speed',
          rows: [
            _DetailValue(
              'Total service minutes',
              record.totalServiceMinutes.toStringAsFixed(2),
              explanation: _totalMinutesExplanation(),
            ),
            _DetailValue(
              _helper ? 'Average prep' : 'Average ready → paid',
              _minutes(record.averageMinutes),
              explanation: _averageExplanation(),
            ),
            _DetailValue(
              'Median',
              _minutes(record.medianMinutes),
              explanation: _medianExplanation(),
            ),
            _DetailValue(
              'Fastest',
              _minutes(record.fastestMinutes),
              explanation: _fastestExplanation(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _DetailSection(
          title: 'C. Timeliness & Delays',
          rows: [
            _DetailValue(
              'On-time rate',
              _percent(record.onTimeRate),
              explanation: _onTimeExplanation(),
            ),
            _DetailValue(
              'On-time records',
              '${record.onTimeCount}',
              explanation: _onTimeCountExplanation(),
            ),
            _DetailValue(
              _helper ? 'Delayed orders' : 'Delayed checkouts',
              '${record.delayedCount}',
              explanation: _delayedExplanation(),
            ),
            _DetailValue(
              'Delay rate',
              _percent(record.delayRate),
              explanation: _delayRateExplanation(),
            ),
            _DetailValue(
              'Reliability',
              _percent(record.reliability),
              explanation: _reliabilityExplanation(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _DetailSection(
          title: 'D. Complexity-Adjusted Productivity',
          rows: [
            _DetailValue(
              'Complexity-adjusted efficiency',
              record.efficiency == null
                  ? 'Not available'
                  : '${record.efficiency!.toStringAsFixed(3)} pts/min',
              explanation: _efficiencyExplanation(),
            ),
            _DetailValue(
              'Efficiency basis',
              '${record.timedWorkloadPoints.toStringAsFixed(2)} pts / '
                  '${record.totalServiceMinutes.toStringAsFixed(2)} min',
              explanation: _efficiencyBasisExplanation(),
            ),
            _DetailValue(
              'Adjusted throughput',
              _optionalScore(record.adjustedThroughput),
              explanation: _adjustedThroughputExplanation(),
            ),
            _DetailValue(
              'Adjusted efficiency',
              _optionalScore(record.adjustedEfficiency),
              explanation: _adjustedEfficiencyExplanation(),
            ),
          ],
        ),
        if (_helper) ...[
          const SizedBox(height: 14),
          StaffPerformanceLiveWorkloadCard(
            count: currentWorkload,
            periodLabel: periodLabel,
          ),
        ],
        if (!_helper) ...[
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
        _ScoreBreakdown(
          record: record,
          periodLabel: periodLabel,
          adjustedThroughputExplanation: _adjustedThroughputExplanation(),
          adjustedEfficiencyExplanation: _adjustedEfficiencyExplanation(),
          onTimeExplanation: _onTimeExplanation(),
          reliabilityExplanation: _reliabilityExplanation(),
        ),
        const SizedBox(height: 14),
        StaffPerformanceDataConfidence(record: record, snapshot: snapshot),
      ],
    );
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(
      color: _ink,
      fontSize: 15,
      fontWeight: FontWeight.w900,
    ),
  );
}

class _PerformanceInsights extends StatelessWidget {
  const _PerformanceInsights({required this.record});

  final StaffPerformanceRecord record;

  @override
  Widget build(BuildContext context) {
    final strengths = <String>[];
    final needsAttention = <String>[];

    if (record.score != null) {
      if (record.onTimeRate >= 85) {
        strengths.add('Timeliness: ${_percent(record.onTimeRate)} on-time.');
      } else if (record.onTimeRate < 70) {
        needsAttention.add(
          'Timeliness: ${_percent(record.onTimeRate)} on-time.',
        );
      }
      if (record.reliability >= 90 && record.delayedCount <= 1) {
        strengths.add(
          'Reliability: ${record.delayedCount} delayed record${record.delayedCount == 1 ? '' : 's'}.',
        );
      } else if (record.reliability < 70) {
        needsAttention.add(
          'Reliability: ${_percent(record.reliability)} with ${record.delayedCount} delays.',
        );
      }
      if ((record.adjustedThroughput ?? 0) >= 75) {
        strengths.add(
          'Workload contribution: ${record.adjustedThroughput!.toStringAsFixed(1)}/100 adjusted throughput.',
        );
      } else if ((record.adjustedThroughput ?? 100) < 40) {
        needsAttention.add(
          'Workload contribution: ${record.adjustedThroughput!.toStringAsFixed(1)}/100 adjusted throughput.',
        );
      }
      if ((record.adjustedEfficiency ?? 0) >= 75) {
        strengths.add(
          'Productivity: ${record.adjustedEfficiency!.toStringAsFixed(1)}/100 adjusted efficiency.',
        );
      } else if ((record.adjustedEfficiency ?? 100) < 40) {
        needsAttention.add(
          'Productivity: ${record.adjustedEfficiency!.toStringAsFixed(1)}/100 adjusted efficiency.',
        );
      }
    }

    if (strengths.isEmpty) {
      strengths.add(
        record.score == null
            ? 'A scored summary requires ${StaffPerformanceV1.minimumScoredSample} valid records; current sample: ${record.validTimingCount}.'
            : 'No metric crossed the high-result display threshold this period.',
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Strengths',
            style: TextStyle(
              color: Color(0xFF15803D),
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          for (final strength in strengths)
            _InsightLine(icon: Icons.check_circle_outline, text: strength),
          if (needsAttention.isNotEmpty) ...[
            const Divider(height: 18, color: _border),
            const Text(
              'Needs attention',
              style: TextStyle(
                color: Color(0xFFD97706),
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 5),
            for (final item in needsAttention)
              _InsightLine(
                icon: Icons.error_outline,
                text: item,
                color: const Color(0xFFD97706),
              ),
          ],
        ],
      ),
    );
  }
}

class _InsightLine extends StatelessWidget {
  const _InsightLine({
    required this.icon,
    required this.text,
    this.color = _muted,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: _muted, fontSize: 11, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class StaffPerformanceLiveWorkloadCard extends StatelessWidget {
  const StaffPerformanceLiveWorkloadCard({
    super.key,
    required this.count,
    required this.periodLabel,
  });

  final int count;
  final String periodLabel;

  StaffMetricExplanation get _explanation => StaffMetricExplanation(
    title: 'Live Workload',
    whatItMeasures:
        'Pending orders currently assigned to this Helper right now.',
    whyItMatters:
        'It supports operational workload awareness while viewing historical performance.',
    calculation:
        'Count live orders whose status is pending and whose assigned Helper is this employee.',
    result: '$count pending orders currently assigned.',
    scoreUse:
        'No. This live operational metric is separate from historical performance and does not affect the historical score.',
  );

  @override
  Widget build(BuildContext context) => InkWell(
    key: const Key('live-workload-card'),
    onTap: () => showStaffMetricExplanation(context, _explanation),
    mouseCursor: SystemMouseCursors.click,
    borderRadius: BorderRadius.circular(12),
    child: Ink(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Expanded(
                child: Text(
                  'Live Workload',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Tooltip(
                message: 'Explain live workload',
                child: Icon(Icons.info_outline, size: 17, color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 7,
            runSpacing: 2,
            children: [
              Text(
                '$count',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 30,
                  height: 1,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 2),
                child: Text(
                  'pending orders\ncurrently assigned',
                  style: TextStyle(color: _muted, fontSize: 11, height: 1.2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Live now • Separate from $periodLabel',
            style: const TextStyle(
              color: _muted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

class StaffPerformanceDataConfidence extends StatefulWidget {
  const StaffPerformanceDataConfidence({
    super.key,
    required this.record,
    required this.snapshot,
  });

  final StaffPerformanceRecord record;
  final StaffPerformanceSnapshot snapshot;

  @override
  State<StaffPerformanceDataConfidence> createState() =>
      _StaffPerformanceDataConfidenceState();
}

class _StaffPerformanceDataConfidenceState
    extends State<StaffPerformanceDataConfidence> {
  bool _expanded = false;

  int get _issueCount {
    final timingIssues =
        widget.snapshot.totalExcludedTimingCount >=
            widget.record.excludedTimingCount
        ? widget.snapshot.totalExcludedTimingCount
        : widget.record.excludedTimingCount;
    return timingIssues + widget.snapshot.unattributedOrderCount;
  }

  bool get _healthy => _issueCount == 0;

  @override
  Widget build(BuildContext context) {
    final color = _healthy ? const Color(0xFF15803D) : const Color(0xFFD97706);
    final helper = widget.record.role == StaffPerformanceRole.helpers;
    return Container(
      key: const Key('data-confidence-card'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _healthy
                        ? Icons.verified_outlined
                        : Icons.warning_amber_rounded,
                    color: color,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Data Confidence',
                          style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _healthy
                              ? 'No data issues detected.\nAll eligible records were used in this performance report.'
                              : '$_issueCount records need attention.\nSome calculations use a reduced or partially attributed sample.',
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'Audit status only — not included in performance scoring.',
                          style: TextStyle(
                            color: _muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    children: [
                      Text(
                        _expanded ? 'Hide details' : 'View details',
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        color: color,
                        size: 18,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: _border),
            Padding(
              padding: const EdgeInsets.all(12),
              child: _DetailSection(
                title: 'Audit details',
                rows: [
                  _DetailValue(
                    'Employee timing records excluded',
                    '${widget.record.excludedTimingCount}',
                    explanation: StaffMetricExplanation(
                      title: 'Employee timing records excluded',
                      whatItMeasures:
                          'Employee-attributed records with missing or logically invalid timing.',
                      whyItMatters:
                          'These records are excluded rather than counted as zero-duration work.',
                      calculation:
                          'Attributed records minus valid chronological timing records.',
                      result:
                          '${widget.record.excludedTimingCount} employee records excluded.',
                      scoreUse:
                          'No. Excluded records do not enter timing calculations or scoring.',
                    ),
                  ),
                  _DetailValue(
                    'Period records without ${helper ? 'Helper' : 'Cashier'} attribution',
                    '${widget.snapshot.unattributedOrderCount}',
                    explanation: StaffMetricExplanation(
                      title: 'Records without role attribution',
                      whatItMeasures:
                          'Qualifying period records that cannot be assigned to a ${helper ? 'Helper' : 'Cashier'}.',
                      whyItMatters:
                          'Employee shares may total below 100% when records are legacy, solo-picked, or unattributed.',
                      calculation:
                          'Total qualifying store records minus role-attributed records.',
                      result:
                          '${widget.snapshot.unattributedOrderCount} period records without role attribution.',
                      scoreUse:
                          'No. Unattributed records are not assigned to an employee score.',
                    ),
                  ),
                  _DetailValue(
                    'Period timing records excluded',
                    '${widget.snapshot.totalExcludedTimingCount}',
                    explanation: StaffMetricExplanation(
                      title: 'Period timing records excluded',
                      whatItMeasures:
                          'All role-attributed period records with incomplete or reverse timestamps.',
                      whyItMatters:
                          'It shows whether period timing metrics use a reduced sample.',
                      calculation:
                          'Count attributed period records without a valid chronological duration.',
                      result:
                          '${widget.snapshot.totalExcludedTimingCount} period timing records excluded.',
                      scoreUse:
                          'No. Invalid durations are excluded, never converted to zero.',
                    ),
                  ),
                  if (helper)
                    _DetailValue(
                      'Location-complexity coverage',
                      widget.snapshot.locationComplexityCoverage,
                      explanation: StaffMetricExplanation(
                        title: 'Location-complexity coverage',
                        whatItMeasures:
                            'Whether current product references can supply storage-location information.',
                        whyItMatters:
                            'Helper complexity can include additional currently resolvable storage locations.',
                        calculation:
                            'Uses the existing Phase 4 product-location fallback and coverage behavior.',
                        result: widget.snapshot.locationComplexityCoverage,
                        scoreUse:
                            'Indirectly, only through the existing Helper workload complexity calculation.',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
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

class _ScoreBreakdown extends StatelessWidget {
  const _ScoreBreakdown({
    required this.record,
    required this.periodLabel,
    required this.onTimeExplanation,
    required this.adjustedThroughputExplanation,
    required this.adjustedEfficiencyExplanation,
    required this.reliabilityExplanation,
  });

  final StaffPerformanceRecord record;
  final String periodLabel;
  final StaffMetricExplanation onTimeExplanation;
  final StaffMetricExplanation adjustedThroughputExplanation;
  final StaffMetricExplanation adjustedEfficiencyExplanation;
  final StaffMetricExplanation reliabilityExplanation;

  StaffMetricExplanation get _scoreExplanation => StaffMetricExplanation(
    title: 'Performance Score Breakdown',
    whatItMeasures:
        'The weighted 0-100 final performance score for the selected period.',
    whyItMatters:
        'It combines timeliness, complexity-adjusted peer contribution, productivity, and reliability in the established V1 weights.',
    calculation:
        'Final Score = (On-Time × 40%) + (Adjusted Throughput × 30%) + '
        '(Adjusted Efficiency × 20%) + (Reliability × 10%). '
        'On-Time represents timeliness. Adjusted Throughput represents '
        'complexity-adjusted work relative to peers. Adjusted Efficiency '
        'represents complexity handled relative to time and peers. Reliability '
        'represents consistency in avoiding delays.',
    result: record.score == null
        ? 'Insufficient data: ${record.validTimingCount} / '
              '${StaffPerformanceV1.minimumScoredSample} valid records.'
        : '${record.onTimeRate.toStringAsFixed(2)} × 40% + '
              '${record.adjustedThroughput!.toStringAsFixed(2)} × 30% + '
              '${record.adjustedEfficiency!.toStringAsFixed(2)} × 20% + '
              '${record.reliability.toStringAsFixed(2)} × 10% = '
              '${record.score!.toStringAsFixed(2)}.',
    scoreUse: 'Yes. This is the final composite score.',
  );

  StaffMetricExplanation get _peerExplanation => StaffMetricExplanation(
    title: 'Peer cohort',
    whatItMeasures: 'Employees eligible for peer-normalized comparison.',
    whyItMatters:
        'Adjusted Throughput and Adjusted Efficiency compare like-for-like employees.',
    calculation:
        'Same role, same location, same selected period ($periodLabel), with at least '
        '${StaffPerformanceV1.minimumScoredSample} valid records. Helpers are compared '
        'with Helpers and Cashiers with Cashiers. Insufficient-data employees do not '
        'participate in score normalization.',
    result: record.peerCount == 1
        ? '1 eligible employee. The existing Phase 4 result uses its neutral one-person cohort behavior.'
        : '${record.peerCount} eligible employees in this cohort.',
    scoreUse:
        'No direct weight. It defines the comparison group for the 30% throughput and 20% efficiency components.',
  );

  StaffMetricExplanation get _finalScoreExplanation => StaffMetricExplanation(
    title: 'Final Score',
    whatItMeasures: 'The sum of the four weighted score contributions.',
    whyItMatters: 'It determines the displayed performance band.',
    calculation: _scoreExplanation.calculation,
    result: _scoreExplanation.result,
    scoreUse: 'Yes. This is the final result, not an additional component.',
  );

  @override
  Widget build(BuildContext context) {
    if (record.score == null) {
      return _DetailSection(
        title: 'Performance Score Breakdown',
        headerExplanation: _scoreExplanation,
        rows: [
          _DetailValue(
            'Final Score',
            'Insufficient data (${record.validTimingCount} / '
                '${StaffPerformanceV1.minimumScoredSample} valid records)',
            explanation: _finalScoreExplanation,
          ),
          _DetailValue(
            'Peer cohort',
            '${record.peerCount} eligible employees',
            explanation: _peerExplanation,
          ),
        ],
      );
    }

    return _DetailSection(
      title: 'Performance Score Breakdown',
      headerExplanation: _scoreExplanation,
      rows: [
        _DetailValue(
          'On-Time',
          '${record.onTimeRate.toStringAsFixed(2)} × 40% = '
              '${record.onTimeScoreContribution.toStringAsFixed(2)}',
          explanation: onTimeExplanation,
        ),
        _DetailValue(
          'Adjusted Throughput',
          '${record.adjustedThroughput!.toStringAsFixed(2)} × 30% = '
              '${record.throughputScoreContribution!.toStringAsFixed(2)}',
          explanation: adjustedThroughputExplanation,
        ),
        _DetailValue(
          'Adjusted Efficiency',
          '${record.adjustedEfficiency!.toStringAsFixed(2)} × 20% = '
              '${record.efficiencyScoreContribution!.toStringAsFixed(2)}',
          explanation: adjustedEfficiencyExplanation,
        ),
        _DetailValue(
          'Reliability',
          '${record.reliability.toStringAsFixed(2)} × 10% = '
              '${record.reliabilityScoreContribution.toStringAsFixed(2)}',
          explanation: reliabilityExplanation,
        ),
        _DetailValue(
          'Final Score',
          record.score!.toStringAsFixed(2),
          explanation: _finalScoreExplanation,
        ),
        _DetailValue(
          'Peer cohort',
          record.peerCount == 1
              ? '1 eligible employee — neutral 50 used for peer components'
              : '${record.peerCount} eligible same-role employees',
          explanation: _peerExplanation,
        ),
      ],
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
  const _DetailValue(this.label, this.value, {this.explanation});
  final String label;
  final String value;
  final StaffMetricExplanation? explanation;
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.rows,
    this.headerExplanation,
  });
  final String title;
  final List<_DetailValue> rows;
  final StaffMetricExplanation? headerExplanation;

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
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (headerExplanation != null)
                IconButton(
                  tooltip: 'Explain $title',
                  onPressed: () =>
                      showStaffMetricExplanation(context, headerExplanation!),
                  icon: const Icon(Icons.info_outline, size: 17),
                  color: _muted,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const Divider(height: 15, color: _border),
            InkWell(
              key: Key('metric-row-${rows[index].label}'),
              onTap: rows[index].explanation == null
                  ? null
                  : () => showStaffMetricExplanation(
                      context,
                      rows[index].explanation!,
                    ),
              mouseCursor: rows[index].explanation == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              borderRadius: BorderRadius.circular(7),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
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
                    if (rows[index].explanation != null) ...[
                      const SizedBox(width: 6),
                      const Tooltip(
                        message: 'View explanation',
                        child: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: _muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FormulaExplanation extends StatelessWidget {
  const _FormulaExplanation({required this.helper});
  final bool helper;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
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
                ? 'Complexity: 1 base point + 1 per distinct item line + '
                      'quantity burden per line (0 / 0.25 / 0.50 / 0.75 / 1.00) '
                      '+ 0.50 per additional currently resolvable storage location.'
                : 'Complexity: 1 base point + 1 per distinct item line + '
                      'quantity burden per line (0 / 0.25 / 0.50 / 0.75 / 1.00) '
                      '+ 0.50 for GCash + 0.50 for a discount + 1.00 for an '
                      'approved discount workflow.',
            style: const TextStyle(color: _muted, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text(
            'Throughput and efficiency are peer-normalized within the same role, location, and period. '
            'Contribution Index is informational and is not part of the final score. '
            'Active-hour data remains unavailable because normal historical login/logout sessions are not reliably recorded.',
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
String _optionalPercent(double? value) =>
    value == null ? 'Not available' : _percent(value);
String _optionalScore(double? value) =>
    value == null ? 'Not scored' : value.toStringAsFixed(2);
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
