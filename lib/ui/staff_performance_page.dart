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

/// Presentation-only ordering. Existing scores and qualification rules are unchanged.
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
  const StaffPerformancePage({
    super.key,
    required this.controller,
    required this.isActive,
  });

  final InventoryController controller;
  final bool isActive;

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
  bool _staleWhileInactive = false;
  StreamSubscription<void>? _invalidationSubscription;
  StreamSubscription<dynamic>? _orderSubscription;

  @override
  void initState() {
    super.initState();
    _invalidationSubscription = widget.controller.staffPerformanceInvalidations
        .listen((_) {
          if (!widget.isActive) {
            _staleWhileInactive = true;
            return;
          }
          unawaited(_load(forceRefresh: true));
        });
    _orderSubscription = widget.controller.orderSnapshots.listen((_) {
      if (mounted && widget.isActive && _role == StaffPerformanceRole.helpers) {
        setState(() {});
      }
    });
    if (widget.isActive) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant StaffPerformancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      final forceRefresh = _staleWhileInactive;
      _staleWhileInactive = false;
      if (forceRefresh || _snapshot == null) {
        unawaited(_load(forceRefresh: forceRefresh));
      }
    }
  }

  @override
  void dispose() {
    _invalidationSubscription?.cancel();
    _orderSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (!widget.isActive) {
      if (forceRefresh) _staleWhileInactive = true;
      return;
    }
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
    final complexity = helper
        ? 'Helper workload uses a base point, item lines, quantity bands, and additional currently known storage locations.'
        : 'Cashier workload uses a base point, item lines, quantity bands, GCash, discounts, and approved admin discounts. It does not use storage locations.';
    return showStaffMetricExplanation(
      context,
      StaffMetricExplanation(
        title: 'How the performance score works',
        whatItMeasures:
            'How the report combines four established performance measures into one 0–100 result.',
        whyItMatters:
            'A manager can see exactly which parts shape the grade and how much each part contributes.',
        formula:
            'Final Score =\n'
            '(On-Time × 40%)\n'
            '+ (Adjusted Throughput × 30%)\n'
            '+ (Adjusted Efficiency × 20%)\n'
            '+ (Reliability × 10%)',
        data: [
          StaffMetricValue('Selected role', _role.label),
          StaffMetricValue('Selected period', _period.displayLabel),
          StaffMetricValue(
            'Minimum valid records',
            '${StaffPerformanceV1.minimumScoredSample}',
          ),
          StaffMetricValue('Workload approach', complexity),
        ],
        result: 'A transparent 0–100 Final Score for each qualifying employee',
        scoreEffect: 'Yes — this defines the Final Score',
        scoreEffectExplanation:
            'The detailed employee view shows the actual values, weighted contributions, and final result.',
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
class StaffMetricValue {
  const StaffMetricValue(this.label, this.value);

  final String label;
  final String value;
}

@immutable
class StaffMetricExplanation {
  const StaffMetricExplanation({
    required this.title,
    required this.whatItMeasures,
    required this.whyItMatters,
    this.formula,
    this.howItWorks,
    required this.data,
    this.calculation = const <StaffMetricValue>[],
    required this.result,
    required this.scoreEffect,
    required this.scoreEffectExplanation,
  }) : assert(formula != null || howItWorks != null);

  final String title;
  final String whatItMeasures;
  final String whyItMatters;
  final String? formula;
  final String? howItWorks;
  final List<StaffMetricValue> data;
  final List<StaffMetricValue> calculation;
  final String result;
  final String scoreEffect;
  final String scoreEffectExplanation;
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
          _ExplanationFormula(
            title: explanation.formula == null ? 'How it works' : 'Formula',
            value: explanation.formula ?? explanation.howItWorks!,
          ),
          _ExplanationRows(title: 'Your data', rows: explanation.data),
          if (explanation.calculation.isNotEmpty)
            _ExplanationRows(
              title: 'Calculation',
              rows: explanation.calculation,
              calculation: true,
            ),
          _ExplanationResult(value: explanation.result),
          _ExplanationScoreEffect(
            effect: explanation.scoreEffect,
            explanation: explanation.scoreEffectExplanation,
          ),
        ],
      ),
    ),
  );
}

class _ExplanationBlock extends StatelessWidget {
  const _ExplanationBlock({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
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

class _ExplanationFormula extends StatelessWidget {
  const _ExplanationFormula({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
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
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _border),
          ),
          child: Text(
            value,
            style: const TextStyle(
              color: _ink,
              fontSize: 12,
              height: 1.45,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ExplanationRows extends StatelessWidget {
  const _ExplanationRows({
    required this.title,
    required this.rows,
    this.calculation = false,
  });

  final String title;
  final List<StaffMetricValue> rows;
  final bool calculation;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
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
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: calculation ? const Color(0xFFF1F5F9) : Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: [
              for (var index = 0; index < rows.length; index++) ...[
                if (index > 0) const Divider(height: 10, color: _border),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        rows[index].label,
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        rows[index].value,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: _ink,
                          fontSize: 11,
                          fontWeight: calculation
                              ? FontWeight.w900
                              : FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _ExplanationResult extends StatelessWidget {
  const _ExplanationResult({required this.value});
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFEFF6FF),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: const Color(0xFFBFDBFE)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Result',
          style: TextStyle(
            color: _blue,
            fontSize: 11,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: _ink,
            fontSize: 15,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}

class _ExplanationScoreEffect extends StatelessWidget {
  const _ExplanationScoreEffect({
    required this.effect,
    required this.explanation,
  });

  final String effect;
  final String explanation;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Does this affect the score?',
        style: TextStyle(
          color: _ink,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        effect,
        style: const TextStyle(
          color: _blue,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        explanation,
        style: const TextStyle(color: _muted, fontSize: 11, height: 1.4),
      ),
    ],
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
      ? '1 base point\n'
            '+ 1 × distinct item lines\n'
            '+ quantity burden for each line\n'
            '  ≤1 = 0  |  >1–5 = 0.25  |  >5–10 = 0.50\n'
            '  >10–20 = 0.75  |  >20 = 1.00\n'
            '+ 0.50 × additional currently known storage locations'
      : '1 base point\n'
            '+ 1 × distinct item lines\n'
            '+ quantity burden for each line\n'
            '  ≤1 = 0  |  >1–5 = 0.25  |  >5–10 = 0.50\n'
            '  >10–20 = 0.75  |  >20 = 1.00\n'
            '+ 0.50 for GCash\n'
            '+ 0.50 for a discounted transaction\n'
            '+ 1.00 for an approved admin discount';

  String _peerWorkloads() {
    final peers = snapshot.records.where(
      (peer) => peer.validTimingCount >= StaffPerformanceV1.minimumScoredSample,
    );
    if (peers.isEmpty) return 'No coworkers reached the minimum sample.';
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
    if (peers.isEmpty) return 'No coworkers reached the minimum sample.';
    return peers
        .map(
          (peer) =>
              '${peer.employeeName}: ${peer.efficiency?.toStringAsFixed(3) ?? 'N/A'} pts/min',
        )
        .join('; ');
  }

  StaffMetricExplanation _handledExplanation() => StaffMetricExplanation(
    title: _helper ? 'Orders handled' : 'Completed checkouts',
    whatItMeasures: 'How many store $_unit this employee handled.',
    whyItMatters:
        'This shows the employee’s share of day-to-day activity. Managers can compare the count with overall store demand.',
    formula: 'Handled count = qualifying $_unit handled by this employee',
    data: [
      StaffMetricValue('All store $_unit', '${snapshot.totalStoreOrders}'),
      StaffMetricValue('Handled by employee', '${record.completedCount}'),
    ],
    calculation: [
      StaffMetricValue('Counted employee $_unit', '${record.completedCount}'),
    ],
    result: '${record.completedCount} $_unit handled',
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'The handled count provides context but is not added directly to the score.',
  );

  StaffMetricExplanation _orderShareExplanation() => StaffMetricExplanation(
    title: _helper ? 'Order share' : 'Checkout share',
    whatItMeasures:
        'How much of the store’s $_unit were handled by this employee.',
    whyItMatters:
        'This puts the employee count in context. It helps a manager see contribution relative to total store volume.',
    formula: 'Employee $_unit ÷ all store $_unit × 100',
    data: [
      StaffMetricValue('Employee $_unit', '${record.completedCount}'),
      StaffMetricValue('All store $_unit', '${snapshot.totalStoreOrders}'),
    ],
    calculation: [
      StaffMetricValue(
        'Share',
        '${record.completedCount} ÷ ${snapshot.totalStoreOrders} × 100',
      ),
    ],
    result: _percent(record.orderShare),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Order and checkout share describe contribution but are not score components.',
  );

  StaffMetricExplanation _workloadExplanation() => StaffMetricExplanation(
    title: 'Workload',
    whatItMeasures:
        'How much work the employee handled after allowing for task complexity.',
    whyItMatters:
        'Equal order counts can represent very different effort. Workload points help managers compare that difference fairly.',
    formula: _workloadFormula,
    data: [
      StaffMetricValue('Employee $_unit', '${record.completedCount}'),
      StaffMetricValue(
        'Employee workload',
        '${record.workloadPoints.toStringAsFixed(2)} pts',
      ),
      StaffMetricValue(
        'All $_roleName workload',
        '${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} pts',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Complexity rules applied',
        '${record.workloadPoints.toStringAsFixed(2)} pts',
      ),
    ],
    result: '${record.workloadPoints.toStringAsFixed(2)} workload points',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'Workload points feed the 30% Adjusted Throughput component. Workload from records with usable service times also feeds the 20% Adjusted Efficiency component.',
  );

  StaffMetricExplanation _workloadShareExplanation() => StaffMetricExplanation(
    title: 'Workload share',
    whatItMeasures:
        'How much of the role’s total complexity was handled by this employee.',
    whyItMatters:
        'This shows contribution by difficulty, not just by number of orders or checkouts.',
    formula: 'Employee workload ÷ all $_roleName workload × 100',
    data: [
      StaffMetricValue(
        'Employee workload',
        '${record.workloadPoints.toStringAsFixed(2)} pts',
      ),
      StaffMetricValue(
        'All $_roleName workload',
        '${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} pts',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Share',
        '${record.workloadPoints.toStringAsFixed(2)} ÷ ${snapshot.totalRoleWorkloadPoints.toStringAsFixed(2)} × 100',
      ),
    ],
    result: _percent(record.workloadShare),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Workload Share is shown for management context and is not added to Final Score.',
  );

  StaffMetricExplanation _activeHoursExplanation() => StaffMetricExplanation(
    title: snapshot.activeHoursAvailable
        ? 'Active-hour contribution'
        : 'Active-hour data unavailable',
    whatItMeasures:
        'Whether the employee’s share of work matched their share of recorded working time.',
    whyItMatters:
        'This can add useful staffing context, but only when complete historical work sessions are available.',
    formula: snapshot.activeHoursAvailable
        ? 'Active Time Share = employee active hours ÷ all $_roleName active hours × 100\n'
              'Contribution Index = Workload Share ÷ Active Time Share'
        : null,
    howItWorks: snapshot.activeHoursAvailable
        ? null
        : 'Complete historical login and logout sessions are required. Because those sessions are not recorded reliably, Active Time Share and Contribution Index are not shown.',
    data: [
      StaffMetricValue(
        'Employee active hours',
        record.activeHours?.toStringAsFixed(2) ?? 'Unavailable',
      ),
      StaffMetricValue(
        'All $_roleName active hours',
        snapshot.totalRoleActiveHours?.toStringAsFixed(2) ?? 'Unavailable',
      ),
      StaffMetricValue('Workload share', _percent(record.workloadShare)),
    ],
    calculation:
        snapshot.activeHoursAvailable &&
            record.activeHours != null &&
            snapshot.totalRoleActiveHours != null
        ? [
            StaffMetricValue(
              'Active Time Share',
              '${record.activeHours!.toStringAsFixed(2)} ÷ ${snapshot.totalRoleActiveHours!.toStringAsFixed(2)} × 100',
            ),
            StaffMetricValue(
              'Contribution Index',
              '${record.workloadShare.toStringAsFixed(2)} ÷ ${record.activeTimeShare?.toStringAsFixed(2) ?? 'Unavailable'}',
            ),
          ]
        : const <StaffMetricValue>[],
    result: snapshot.activeHoursAvailable
        ? 'Contribution Index: ${record.contributionIndex?.toStringAsFixed(2) ?? 'Unavailable'}'
        : 'Unavailable because complete historical login and logout sessions are not recorded reliably.',
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Active-time measures and Contribution Index are excluded from Final Score.',
  );

  StaffMetricExplanation _validSampleExplanation() => StaffMetricExplanation(
    title: 'Valid timing sample',
    whatItMeasures:
        'How many handled $_unit have complete and believable service times.',
    whyItMatters:
        'A larger trustworthy sample gives managers more confidence in speed and timeliness results.',
    formula:
        'Valid sample = handled records with a complete start and finish time',
    data: [
      StaffMetricValue('Handled $_unit', '${record.completedCount}'),
      StaffMetricValue(
        'Excluded timing records',
        '${record.excludedTimingCount}',
      ),
      StaffMetricValue(
        'Minimum needed for a score',
        '${StaffPerformanceV1.minimumScoredSample}',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Usable timing records',
        '${record.completedCount} - ${record.excludedTimingCount}',
      ),
    ],
    result: '${record.validTimingCount} valid timing records',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'At least ${StaffPerformanceV1.minimumScoredSample} valid records are required before a Final Score is shown.',
  );

  StaffMetricExplanation _excludedExplanation() => StaffMetricExplanation(
    title: 'Excluded timing records',
    whatItMeasures:
        'How many handled $_unit could not provide a trustworthy service time.',
    whyItMatters:
        'Managers should know when timing results use a reduced sample. Incomplete or reversed times are excluded instead of treated as instant work.',
    formula: 'Excluded records = handled records - valid timing records',
    data: [
      StaffMetricValue('Handled $_unit', '${record.completedCount}'),
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
    ],
    calculation: [
      StaffMetricValue(
        'Excluded',
        '${record.completedCount} - ${record.validTimingCount}',
      ),
    ],
    result: '${record.excludedTimingCount} records excluded',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'Excluded records do not enter timing measures and can affect whether the minimum sample is reached.',
  );

  StaffMetricExplanation _totalMinutesExplanation() => StaffMetricExplanation(
    title: 'Total service minutes',
    whatItMeasures: 'The combined service time for all valid employee $_unit.',
    whyItMatters:
        'This shows the total time represented by the report and supplies the time used for efficiency.',
    formula: 'Total service minutes = sum of all valid service durations',
    data: [
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
      StaffMetricValue(
        'Recorded service time',
        '${record.totalServiceMinutes.toStringAsFixed(2)} min',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Sum of valid durations',
        '${record.totalServiceMinutes.toStringAsFixed(2)} min',
      ),
    ],
    result: '${record.totalServiceMinutes.toStringAsFixed(2)} minutes',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'These minutes are used to work out efficiency, which feeds the 20% Adjusted Efficiency component.',
  );

  StaffMetricExplanation _averageExplanation() => StaffMetricExplanation(
    title: _helper ? 'Average prep' : 'Average ready to paid',
    whatItMeasures: 'The average service time for each valid $_unit record.',
    whyItMatters:
        'This gives managers a simple view of typical pace across the selected period.',
    formula: 'Average time = total service minutes ÷ valid timing records',
    data: [
      StaffMetricValue(
        'Total service minutes',
        record.totalServiceMinutes.toStringAsFixed(2),
      ),
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
    ],
    calculation: [
      StaffMetricValue(
        'Average',
        '${record.totalServiceMinutes.toStringAsFixed(2)} ÷ ${record.validTimingCount}',
      ),
    ],
    result: _minutes(record.averageMinutes),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Average time is shown for context. Final Score uses the established timeliness and efficiency measures instead.',
  );

  StaffMetricExplanation _medianExplanation() => StaffMetricExplanation(
    title: _helper ? 'Median prep' : 'Median ready to paid',
    whatItMeasures:
        'The middle service time after valid times are put in order.',
    whyItMatters:
        'This shows a typical middle result without one unusually long or short record dominating the view.',
    howItWorks:
        'Arrange all valid service times from shortest to longest and select the middle value.',
    data: [
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
      StaffMetricValue('Middle service time', _minutes(record.medianMinutes)),
    ],
    result: _minutes(record.medianMinutes),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Median time helps managers interpret pace but is not a score component.',
  );

  StaffMetricExplanation _fastestExplanation() => StaffMetricExplanation(
    title: _helper ? 'Fastest prep' : 'Fastest ready to paid',
    whatItMeasures: 'The shortest trustworthy service time in the period.',
    whyItMatters:
        'This shows the best observed time, but it should not be treated as the employee’s normal pace.',
    formula: 'Fastest time = shortest valid service duration',
    data: [
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
    ],
    calculation: [
      StaffMetricValue('Shortest duration', _minutes(record.fastestMinutes)),
    ],
    result: _minutes(record.fastestMinutes),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'The fastest single result is not added to Final Score.',
  );

  StaffMetricExplanation _onTimeExplanation() => StaffMetricExplanation(
    title: 'On-time rate',
    whatItMeasures:
        'How often this employee finished valid $_unit within the service target.',
    whyItMatters:
        'This tells a manager whether customers and coworkers can usually expect work to finish on schedule.',
    formula: 'On-time rate = on-time records ÷ valid timing records × 100',
    data: [
      StaffMetricValue('On-time records', '${record.onTimeCount}'),
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
      StaffMetricValue('Service target', 'Under $_delayThreshold min'),
    ],
    calculation: [
      StaffMetricValue(
        'On-time rate',
        '${record.onTimeCount} ÷ ${record.validTimingCount} × 100',
      ),
      StaffMetricValue(
        'Weighted contribution',
        '${record.onTimeRate.toStringAsFixed(2)} × 40% = ${record.onTimeScoreContribution.toStringAsFixed(2)}',
      ),
    ],
    result: _percent(record.onTimeRate),
    scoreEffect: 'Yes — 40%',
    scoreEffectExplanation:
        'Timeliness supplies ${record.onTimeScoreContribution.toStringAsFixed(2)} points to Final Score.',
  );

  StaffMetricExplanation _onTimeCountExplanation() => StaffMetricExplanation(
    title: 'On-time records',
    whatItMeasures:
        'How many valid $_unit finished before the delay threshold.',
    whyItMatters:
        'This is the count behind On-Time Rate and shows the size of the employee’s timely work sample.',
    formula: 'On-time records = valid durations under $_delayThreshold minutes',
    data: [
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
      StaffMetricValue('Service target', 'Under $_delayThreshold min'),
    ],
    calculation: [
      StaffMetricValue('Count below target', '${record.onTimeCount}'),
    ],
    result: '${record.onTimeCount} on-time records',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'This count is used to work out the 40% On-Time Rate component.',
  );

  StaffMetricExplanation _delayedExplanation() => StaffMetricExplanation(
    title: _helper ? 'Delayed orders' : 'Delayed checkouts',
    whatItMeasures:
        'How many valid $_unit reached or exceeded the delay threshold.',
    whyItMatters:
        'This helps a manager spot whether late work is occasional or recurring.',
    formula:
        'Delayed records = valid durations at least $_delayThreshold minutes',
    data: [
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
      StaffMetricValue('Delay threshold', '$_delayThreshold min or more'),
    ],
    calculation: [
      StaffMetricValue('Count at or above threshold', '${record.delayedCount}'),
    ],
    result: '${record.delayedCount} delayed $_unit',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'Delayed records determine Delay Rate and the 10% Reliability component.',
  );

  StaffMetricExplanation _delayRateExplanation() => StaffMetricExplanation(
    title: 'Delay rate',
    whatItMeasures: 'How often valid work was delayed.',
    whyItMatters:
        'A percentage lets managers compare delay patterns even when employees handled different amounts of work.',
    formula: 'Delay rate = delayed records ÷ valid timing records × 100',
    data: [
      StaffMetricValue('Delayed records', '${record.delayedCount}'),
      StaffMetricValue('Valid timing records', '${record.validTimingCount}'),
    ],
    calculation: [
      StaffMetricValue(
        'Delay rate',
        '${record.delayedCount} ÷ ${record.validTimingCount} × 100',
      ),
    ],
    result: _percent(record.delayRate),
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'Reliability is calculated from Delay Rate and contributes 10% to Final Score.',
  );

  StaffMetricExplanation _reliabilityExplanation() => StaffMetricExplanation(
    title: 'Reliability',
    whatItMeasures: 'How consistently this employee avoided delays.',
    whyItMatters:
        'Managers need dependable service, not only occasional fast results.',
    formula: 'Reliability = 100 - delay rate',
    data: [
      StaffMetricValue('Delay rate', _percent(record.delayRate)),
      StaffMetricValue('Delayed records', '${record.delayedCount}'),
    ],
    calculation: [
      StaffMetricValue(
        'Reliability',
        '100 - ${record.delayRate.toStringAsFixed(2)}',
      ),
      StaffMetricValue(
        'Weighted contribution',
        '${record.reliability.toStringAsFixed(2)} × 10% = ${record.reliabilityScoreContribution.toStringAsFixed(2)}',
      ),
    ],
    result: _percent(record.reliability),
    scoreEffect: 'Yes — 10%',
    scoreEffectExplanation:
        'Reliability supplies ${record.reliabilityScoreContribution.toStringAsFixed(2)} points to Final Score.',
  );

  StaffMetricExplanation _efficiencyExplanation() => StaffMetricExplanation(
    title: 'Complexity-adjusted efficiency',
    whatItMeasures:
        'How many valid workload points were handled per service minute.',
    whyItMatters:
        'This helps a manager judge pace while still allowing for more difficult work.',
    formula: 'Efficiency = valid workload points ÷ total valid service minutes',
    data: [
      StaffMetricValue(
        'Valid workload',
        '${record.timedWorkloadPoints.toStringAsFixed(2)} pts',
      ),
      StaffMetricValue(
        'Valid service time',
        '${record.totalServiceMinutes.toStringAsFixed(2)} min',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Points per minute',
        '${record.timedWorkloadPoints.toStringAsFixed(2)} ÷ ${record.totalServiceMinutes.toStringAsFixed(2)}',
      ),
    ],
    result: record.efficiency == null
        ? 'Unavailable'
        : '${record.efficiency!.toStringAsFixed(3)} points per minute',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'This value is compared with coworkers who reached the minimum sample to prepare the 20% Adjusted Efficiency component.',
  );

  StaffMetricExplanation
  _efficiencyBasisExplanation() => StaffMetricExplanation(
    title: 'Efficiency basis',
    whatItMeasures: 'The work and time inputs behind the efficiency result.',
    whyItMatters:
        'Showing both inputs lets a manager verify what the efficiency figure represents.',
    formula: 'Valid workload points ÷ total valid service minutes',
    data: [
      StaffMetricValue(
        'Valid workload',
        '${record.timedWorkloadPoints.toStringAsFixed(2)} pts',
      ),
      StaffMetricValue(
        'Valid service time',
        '${record.totalServiceMinutes.toStringAsFixed(2)} min',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Efficiency basis',
        '${record.timedWorkloadPoints.toStringAsFixed(2)} ÷ ${record.totalServiceMinutes.toStringAsFixed(2)}',
      ),
    ],
    result: record.efficiency == null
        ? 'Efficiency unavailable'
        : '${record.efficiency!.toStringAsFixed(3)} points per minute',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'These inputs feed the 20% Adjusted Efficiency component.',
  );

  StaffMetricExplanation
  _adjustedThroughputExplanation() => StaffMetricExplanation(
    title: 'Adjusted throughput',
    whatItMeasures:
        'How the employee’s complexity-weighted amount of work compares with coworkers who have enough valid records.',
    whyItMatters:
        'This helps a manager compare contribution fairly within the same job, store, and period.',
    howItWorks:
        'The employee’s workload is compared only with coworkers in the same role who reached the minimum timing sample. The report’s existing 0-100 comparison result is shown without changing it.',
    data: [
      StaffMetricValue(
        'Employee workload',
        '${record.workloadPoints.toStringAsFixed(2)} pts',
      ),
      StaffMetricValue('Coworkers in comparison', '${record.peerCount}'),
      StaffMetricValue('Coworker workload values', _peerWorkloads()),
    ],
    calculation: record.adjustedThroughput == null
        ? const <StaffMetricValue>[]
        : [
            StaffMetricValue(
              'Comparison result',
              '${record.adjustedThroughput!.toStringAsFixed(2)} / 100',
            ),
            StaffMetricValue(
              'Weighted contribution',
              '${record.adjustedThroughput!.toStringAsFixed(2)} × 30% = ${record.throughputScoreContribution!.toStringAsFixed(2)}',
            ),
          ],
    result: record.adjustedThroughput == null
        ? 'Unavailable until the minimum sample is reached'
        : '${record.adjustedThroughput!.toStringAsFixed(2)} / 100',
    scoreEffect: 'Yes — 30%',
    scoreEffectExplanation: record.adjustedThroughput == null
        ? 'This component becomes available after the minimum timing sample is reached.'
        : 'Adjusted Throughput supplies ${record.throughputScoreContribution!.toStringAsFixed(2)} points to Final Score.',
  );

  StaffMetricExplanation
  _adjustedEfficiencyExplanation() => StaffMetricExplanation(
    title: 'Adjusted efficiency',
    whatItMeasures:
        'How the employee’s complexity handled per minute compares with coworkers who have enough valid records.',
    whyItMatters:
        'This helps a manager compare productive pace while allowing for task difficulty.',
    howItWorks:
        'Efficiency is compared only with coworkers in the same role who reached the minimum timing sample. The report’s existing 0-100 comparison result is shown without changing it.',
    data: [
      StaffMetricValue(
        'Employee efficiency',
        '${record.efficiency?.toStringAsFixed(3) ?? 'Unavailable'} pts/min',
      ),
      StaffMetricValue('Coworkers in comparison', '${record.peerCount}'),
      StaffMetricValue('Coworker efficiency values', _peerEfficiencies()),
    ],
    calculation: record.adjustedEfficiency == null
        ? const <StaffMetricValue>[]
        : [
            StaffMetricValue(
              'Comparison result',
              '${record.adjustedEfficiency!.toStringAsFixed(2)} / 100',
            ),
            StaffMetricValue(
              'Weighted contribution',
              '${record.adjustedEfficiency!.toStringAsFixed(2)} × 20% = ${record.efficiencyScoreContribution!.toStringAsFixed(2)}',
            ),
          ],
    result: record.adjustedEfficiency == null
        ? 'Unavailable until the minimum sample is reached'
        : '${record.adjustedEfficiency!.toStringAsFixed(2)} / 100',
    scoreEffect: 'Yes — 20%',
    scoreEffectExplanation: record.adjustedEfficiency == null
        ? 'This component becomes available after the minimum timing sample is reached.'
        : 'Adjusted Efficiency supplies ${record.efficiencyScoreContribution!.toStringAsFixed(2)} points to Final Score.',
  );

  StaffMetricExplanation _salesHandledExplanation() => StaffMetricExplanation(
    title: 'Sales handled',
    whatItMeasures:
        'The value of completed sales processed by this Cashier in the selected period.',
    whyItMatters:
        'This gives a manager financial context for the checkout activity handled by the employee.',
    formula: 'Sales handled = sum of completed checkout amounts',
    data: [
      StaffMetricValue('Completed checkouts', '${record.completedCount}'),
      StaffMetricValue('Completed sales value', _currency(record.salesHandled)),
    ],
    calculation: [
      StaffMetricValue(
        'Sum of completed sales',
        _currency(record.salesHandled),
      ),
    ],
    result: _currency(record.salesHandled),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Sales value provides business context and is not added to Final Score.',
  );

  StaffMetricExplanation
  _discountedTransactionsExplanation() => StaffMetricExplanation(
    title: 'Discounted transactions',
    whatItMeasures:
        'How many completed checkouts handled by this Cashier included a discount.',
    whyItMatters:
        'Discounted checkouts can involve extra verification and help managers understand the mix of checkout work.',
    formula: 'Discounted transactions = completed checkouts with a discount',
    data: [
      StaffMetricValue('Completed checkouts', '${record.completedCount}'),
      StaffMetricValue(
        'Checkouts with a discount',
        '${record.discountedTransactions}',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Counted discounted checkouts',
        '${record.discountedTransactions}',
      ),
    ],
    result: '${record.discountedTransactions} discounted transactions',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'A discounted transaction adds to checkout workload. That workload feeds Adjusted Throughput and Adjusted Efficiency.',
  );

  StaffMetricExplanation _discountUsageExplanation() => StaffMetricExplanation(
    title: 'Discount usage rate',
    whatItMeasures:
        'The percentage of this Cashier’s completed checkouts that included a discount.',
    whyItMatters:
        'This helps a manager understand how often discount handling appeared in the employee’s checkout work.',
    formula:
        'Discount usage rate = discounted transactions ÷ completed checkouts × 100',
    data: [
      StaffMetricValue(
        'Discounted transactions',
        '${record.discountedTransactions}',
      ),
      StaffMetricValue('Completed checkouts', '${record.completedCount}'),
    ],
    calculation: [
      StaffMetricValue(
        'Discount usage rate',
        '${record.discountedTransactions} ÷ ${record.completedCount} × 100',
      ),
    ],
    result: _percent(record.discountUsageRate),
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'The percentage itself is not added to Final Score. Individual discounted checkouts can add workload complexity.',
  );

  StaffMetricExplanation
  _approvalRequestsExplanation() => StaffMetricExplanation(
    title: 'Discount approval requests',
    whatItMeasures:
        'How many discount requests were connected with this Cashier’s checkout work.',
    whyItMatters:
        'This helps a manager see how much discount-review activity accompanied the employee’s transactions.',
    formula: 'Approval requests = approved + rejected + pending requests',
    data: [
      StaffMetricValue('Approved', '${record.discountApprovalsApproved}'),
      StaffMetricValue('Rejected', '${record.discountApprovalsRejected}'),
      StaffMetricValue('Pending', '${record.discountApprovalsPending}'),
    ],
    calculation: [
      StaffMetricValue(
        'Total requests',
        '${record.discountApprovalsApproved} + ${record.discountApprovalsRejected} + ${record.discountApprovalsPending}',
      ),
    ],
    result: '${record.discountApprovalRequests} approval requests',
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'The request count is an audit measure and is not added directly to Final Score.',
  );

  StaffMetricExplanation _approvalStatusExplanation({
    required String status,
    required int count,
  }) => StaffMetricExplanation(
    title: '$status discount approvals',
    whatItMeasures:
        'How many discount requests in this Cashier’s work currently have a ${status.toLowerCase()} outcome.',
    whyItMatters:
        'This helps a manager understand the outcome of discount-review activity without treating it as an employee grade.',
    formula: '$status count = requests with a ${status.toLowerCase()} outcome',
    data: [
      StaffMetricValue(
        'All approval requests',
        '${record.discountApprovalRequests}',
      ),
      StaffMetricValue('$status requests', '$count'),
    ],
    calculation: [StaffMetricValue('Counted $status requests', '$count')],
    result: '$count ${status.toLowerCase()} requests',
    scoreEffect: status == 'Approved'
        ? 'Yes — indirectly'
        : 'No — informational only',
    scoreEffectExplanation: status == 'Approved'
        ? 'An approved admin discount can add to checkout workload. That workload feeds the adjusted score components.'
        : 'This status count is shown for oversight and is not added to Final Score.',
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
              _DetailValue(
                'Sales handled',
                _currency(record.salesHandled),
                explanation: _salesHandledExplanation(),
              ),
              _DetailValue(
                'Discounted transactions',
                '${record.discountedTransactions}',
                explanation: _discountedTransactionsExplanation(),
              ),
              _DetailValue(
                'Discount usage rate',
                _percent(record.discountUsageRate),
                explanation: _discountUsageExplanation(),
              ),
              _DetailValue(
                'Discount approval requests',
                '${record.discountApprovalRequests}',
                explanation: _approvalRequestsExplanation(),
              ),
              _DetailValue(
                'Approved discount approvals',
                '${record.discountApprovalsApproved}',
                explanation: _approvalStatusExplanation(
                  status: 'Approved',
                  count: record.discountApprovalsApproved,
                ),
              ),
              _DetailValue(
                'Rejected discount approvals',
                '${record.discountApprovalsRejected}',
                explanation: _approvalStatusExplanation(
                  status: 'Rejected',
                  count: record.discountApprovalsRejected,
                ),
              ),
              _DetailValue(
                'Pending discount approvals',
                '${record.discountApprovalsPending}',
                explanation: _approvalStatusExplanation(
                  status: 'Pending',
                  count: record.discountApprovalsPending,
                ),
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
        strengths.add('Consistently completes work within the service target.');
      } else if (record.onTimeRate < 70) {
        needsAttention.add(
          'Review where service time is being lost and agree on a timeliness improvement plan.',
        );
      }
      if (record.reliability >= 90 && record.delayedCount <= 1) {
        strengths.add(
          'Rarely allows assigned work to cross the delay threshold.',
        );
      } else if (record.reliability < 70) {
        needsAttention.add(
          'Check recurring delay causes and remove avoidable blockers.',
        );
      }
      if ((record.adjustedThroughput ?? 0) >= 75) {
        strengths.add(
          'Handles a strong amount of complexity compared with coworkers who have enough valid records.',
        );
      } else if ((record.adjustedThroughput ?? 100) < 40) {
        needsAttention.add(
          'Review assignment mix and available capacity to improve workload contribution.',
        );
      }
      if ((record.adjustedEfficiency ?? 0) >= 75) {
        strengths.add(
          'Processes complex work efficiently compared with coworkers who have enough valid records.',
        );
      } else if ((record.adjustedEfficiency ?? 100) < 40) {
        needsAttention.add(
          'Coach on the work steps that slow down complex orders or checkouts.',
        );
      }
    }

    if (strengths.isEmpty) {
      strengths.add(
        record.score == null
            ? 'More completed work is needed before a dependable performance summary can be shown.'
            : 'Performance was balanced; no single area stood out as a clear strength this period.',
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
        'How many pending orders are assigned to this Helper right now.',
    whyItMatters:
        'This helps a manager see current capacity while reviewing past performance. It must be read separately from the selected historical period.',
    formula: 'Live workload = pending orders currently assigned to this Helper',
    data: [
      StaffMetricValue('Current assigned pending orders', '$count'),
      StaffMetricValue('Historical period on screen', periodLabel),
    ],
    calculation: [StaffMetricValue('Live pending count', '$count')],
    result: '$count pending orders currently assigned',
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Live workload is an operational snapshot and does not affect the historical score.',
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

  int get _timingIssueCount =>
      widget.snapshot.totalExcludedTimingCount >=
          widget.record.excludedTimingCount
      ? widget.snapshot.totalExcludedTimingCount
      : widget.record.excludedTimingCount;

  int get _issueCount =>
      _timingIssueCount + widget.snapshot.unattributedOrderCount;

  bool get _healthy => _issueCount == 0;

  StaffMetricExplanation get _summaryExplanation => StaffMetricExplanation(
    title: 'Data Confidence',
    whatItMeasures:
        'Whether the report used a complete, clearly assigned timing sample.',
    whyItMatters:
        'This tells a manager how much trust to place in the displayed measures. It is an audit check, not an employee grade.',
    formula:
        'Records needing attention = timing issues + records without a role assignment',
    data: [
      StaffMetricValue('Timing issues counted', '$_timingIssueCount'),
      StaffMetricValue(
        'Records without role assignment',
        '${widget.snapshot.unattributedOrderCount}',
      ),
    ],
    calculation: [
      StaffMetricValue(
        'Records needing attention',
        '$_timingIssueCount + ${widget.snapshot.unattributedOrderCount}',
      ),
    ],
    result: _healthy
        ? 'No data issues detected'
        : '$_issueCount records need attention',
    scoreEffect: 'No — informational only',
    scoreEffectExplanation:
        'Data Confidence describes report completeness and is never included in performance scoring.',
  );

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
                              ? 'No data issues detected.\nAll eligible records were used in this performance report. Eligible means the records had usable times and a clear role assignment.'
                              : '$_issueCount records need attention.\nSome calculations use a reduced or partially attributed sample — fewer usable records, or records without a clear role assignment.',
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
                      IconButton(
                        tooltip: 'Explain Data Confidence',
                        onPressed: () => showStaffMetricExplanation(
                          context,
                          _summaryExplanation,
                        ),
                        icon: const Icon(Icons.info_outline, size: 17),
                        color: color,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                      ),
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
                          'How many of this employee’s records could not provide a trustworthy service time.',
                      whyItMatters:
                          'Managers should know when employee timing measures use a reduced sample. Invalid times are excluded instead of treated as instant work.',
                      formula:
                          'Employee timing issues = handled records - valid timing records',
                      data: [
                        StaffMetricValue(
                          'Handled records',
                          '${widget.record.completedCount}',
                        ),
                        StaffMetricValue(
                          'Valid timing records',
                          '${widget.record.validTimingCount}',
                        ),
                      ],
                      calculation: [
                        StaffMetricValue(
                          'Excluded',
                          '${widget.record.completedCount} - ${widget.record.validTimingCount}',
                        ),
                      ],
                      result:
                          '${widget.record.excludedTimingCount} employee records excluded',
                      scoreEffect: 'No — informational only',
                      scoreEffectExplanation:
                          'This audit count is not added to the score. The unusable records are excluded before timing measures are calculated.',
                    ),
                  ),
                  _DetailValue(
                    'Period records without ${helper ? 'Helper' : 'Cashier'} attribution',
                    '${widget.snapshot.unattributedOrderCount}',
                    explanation: StaffMetricExplanation(
                      title: 'Records without role attribution',
                      whatItMeasures:
                          'How many period records could not be linked to a ${helper ? 'Helper' : 'Cashier'}.',
                      whyItMatters:
                          'This explains why employee shares may total below 100% and prevents unassigned work from being credited to the wrong person.',
                      formula:
                          'Unassigned records = all qualifying records - role-handled records',
                      data: [
                        StaffMetricValue(
                          'All qualifying records',
                          '${widget.snapshot.totalStoreOrders}',
                        ),
                        StaffMetricValue(
                          'Role-handled records',
                          '${widget.snapshot.totalRoleHandledOrders}',
                        ),
                      ],
                      calculation: [
                        StaffMetricValue(
                          'Without role assignment',
                          '${widget.snapshot.totalStoreOrders} - ${widget.snapshot.totalRoleHandledOrders}',
                        ),
                      ],
                      result:
                          '${widget.snapshot.unattributedOrderCount} period records without role assignment',
                      scoreEffect: 'No — informational only',
                      scoreEffectExplanation:
                          'These records are not assigned to any employee score.',
                    ),
                  ),
                  _DetailValue(
                    'Period timing records excluded',
                    '${widget.snapshot.totalExcludedTimingCount}',
                    explanation: StaffMetricExplanation(
                      title: 'Period timing records excluded',
                      whatItMeasures:
                          'How many role-handled records in the period had unusable service times.',
                      whyItMatters:
                          'This shows whether the store-level timing picture is based on a reduced sample.',
                      formula:
                          'Period timing issues = role-handled records - valid period timing records',
                      data: [
                        StaffMetricValue(
                          'Role-handled records',
                          '${widget.snapshot.totalRoleHandledOrders}',
                        ),
                        StaffMetricValue(
                          'Valid period timing records',
                          '${widget.snapshot.totalValidTimingCount}',
                        ),
                      ],
                      calculation: [
                        StaffMetricValue(
                          'Excluded period records',
                          '${widget.snapshot.totalRoleHandledOrders} - ${widget.snapshot.totalValidTimingCount}',
                        ),
                      ],
                      result:
                          '${widget.snapshot.totalExcludedTimingCount} period timing records excluded',
                      scoreEffect: 'No — informational only',
                      scoreEffectExplanation:
                          'This period audit count is not added to any employee score. Unusable records are excluded rather than converted to zero-duration work.',
                    ),
                  ),
                  if (helper)
                    _DetailValue(
                      'Location-complexity coverage',
                      widget.snapshot.locationComplexityCoverage,
                      explanation: StaffMetricExplanation(
                        title: 'Location-complexity coverage',
                        whatItMeasures:
                            'Whether Helper workload can include available storage-location detail.',
                        whyItMatters:
                            'Storage locations can make preparation more involved. This note tells managers how much location context was available.',
                        howItWorks:
                            'When a product’s current storage location is available, additional distinct locations contribute to Helper workload. Missing historical location detail uses the existing fallback.',
                        data: [
                          StaffMetricValue(
                            'Coverage note',
                            widget.snapshot.locationComplexityCoverage,
                          ),
                        ],
                        result: widget.snapshot.locationComplexityCoverage,
                        scoreEffect: 'No — informational only',
                        scoreEffectExplanation:
                            'The coverage note is not a score component. Available location detail still follows the established Helper workload rules.',
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
                      ? 'Only one employee qualified for comparison; the established neutral comparison value is used.'
                      : 'Compared only with coworkers in the same role, store, and period.',
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
        'It gives a manager one transparent summary of timeliness, workload contribution, productive pace, and consistency.',
    formula:
        'Final Score =\n'
        '(On-Time × 40%)\n'
        '+ (Adjusted Throughput × 30%)\n'
        '+ (Adjusted Efficiency × 20%)\n'
        '+ (Reliability × 10%)',
    data: [
      StaffMetricValue(
        'On-Time',
        '${record.onTimeRate.toStringAsFixed(2)} / 100',
      ),
      StaffMetricValue(
        'Adjusted Throughput',
        record.adjustedThroughput?.toStringAsFixed(2) ?? 'Unavailable',
      ),
      StaffMetricValue(
        'Adjusted Efficiency',
        record.adjustedEfficiency?.toStringAsFixed(2) ?? 'Unavailable',
      ),
      StaffMetricValue(
        'Reliability',
        '${record.reliability.toStringAsFixed(2)} / 100',
      ),
    ],
    calculation: record.score == null
        ? const <StaffMetricValue>[]
        : [
            StaffMetricValue(
              'On-Time',
              '${record.onTimeRate.toStringAsFixed(2)} × 40% = ${record.onTimeScoreContribution.toStringAsFixed(2)}',
            ),
            StaffMetricValue(
              'Adjusted Throughput',
              '${record.adjustedThroughput!.toStringAsFixed(2)} × 30% = ${record.throughputScoreContribution!.toStringAsFixed(2)}',
            ),
            StaffMetricValue(
              'Adjusted Efficiency',
              '${record.adjustedEfficiency!.toStringAsFixed(2)} × 20% = ${record.efficiencyScoreContribution!.toStringAsFixed(2)}',
            ),
            StaffMetricValue(
              'Reliability',
              '${record.reliability.toStringAsFixed(2)} × 10% = ${record.reliabilityScoreContribution.toStringAsFixed(2)}',
            ),
          ],
    result: record.score == null
        ? 'Insufficient data: ${record.validTimingCount} / '
              '${StaffPerformanceV1.minimumScoredSample} valid records.'
        : '${record.onTimeRate.toStringAsFixed(2)} × 40% + '
              '${record.adjustedThroughput!.toStringAsFixed(2)} × 30% + '
              '${record.adjustedEfficiency!.toStringAsFixed(2)} × 20% + '
              '${record.reliability.toStringAsFixed(2)} × 10% = '
              '${record.score!.toStringAsFixed(2)}.',
    scoreEffect: 'Yes — this is the Final Score',
    scoreEffectExplanation:
        'The four weighted contributions are added once to produce the displayed score and band.',
  );

  StaffMetricExplanation get _peerExplanation => StaffMetricExplanation(
    title: 'Peer cohort',
    whatItMeasures:
        'The coworkers used to compare workload contribution and productive pace.',
    whyItMatters:
        'A fair comparison uses people doing the same job in the same place and time period.',
    howItWorks:
        'The comparison includes the same role, the same store, and the same selected period. Each employee must have at least ${StaffPerformanceV1.minimumScoredSample} valid records. Helpers are compared with Helpers, and Cashiers with Cashiers. Employees without enough valid records are left out of this comparison.',
    data: [
      StaffMetricValue('Selected period', periodLabel),
      StaffMetricValue(
        'Minimum valid records',
        '${StaffPerformanceV1.minimumScoredSample}',
      ),
      StaffMetricValue('Coworkers in comparison', '${record.peerCount}'),
    ],
    result: record.peerCount == 1
        ? '1 employee qualified; the established neutral comparison value is used.'
        : '${record.peerCount} employees qualified for comparison.',
    scoreEffect: 'Yes — indirectly',
    scoreEffectExplanation:
        'This group determines the comparison used for the 30% Adjusted Throughput and 20% Adjusted Efficiency components.',
  );

  StaffMetricExplanation get _finalScoreExplanation => StaffMetricExplanation(
    title: 'Final Score',
    whatItMeasures: 'The sum of the four weighted score contributions.',
    whyItMatters:
        'This is the employee’s overall result for the selected period and determines the displayed performance band.',
    formula: _scoreExplanation.formula,
    data: _scoreExplanation.data,
    calculation: _scoreExplanation.calculation,
    result: _scoreExplanation.result,
    scoreEffect: 'Yes — this is the Final Score',
    scoreEffectExplanation:
        'It is the result of the four weighted components, not an additional fifth component.',
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
            '${record.peerCount} employees qualified for comparison',
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
              ? '1 employee — established neutral comparison used'
              : '${record.peerCount} same-role employees in comparison',
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
