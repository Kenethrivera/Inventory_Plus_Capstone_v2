import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/bodegero_loading_history.dart';
import '../logic/inventory_controller.dart';
import 'widgets/history_period_controls.dart';

class BodegeroHistoryPage extends StatefulWidget {
  const BodegeroHistoryPage({
    super.key,
    required this.controller,
    required this.isActive,
  });

  final InventoryController controller;
  final bool isActive;

  @override
  State<BodegeroHistoryPage> createState() => _BodegeroHistoryPageState();
}

class _BodegeroHistoryPageState extends State<BodegeroHistoryPage> {
  static const _ink = Color(0xFF171717);
  static const _muted = Color(0xFF756D67);
  static const _line = Color(0xFFE1DCD5);
  static const _orange = Color(0xFFC83D08);

  final _searchController = TextEditingController();
  final _proofs = <String, Future<_LoadingProof?>>{};
  Timer? _searchDebounce;
  late Future<BodegeroLoadingHistoryPage> _history;
  int _page = 1;
  HistoryPeriodSelection _period = HistoryPeriodSelection.current();
  bool _periodActive = false;
  String _statusFilter = 'All';

  @override
  void initState() {
    super.initState();
    _history = _load();
  }

  @override
  void didUpdateWidget(BodegeroHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        (!oldWidget.isActive && widget.isActive)) {
      _proofs.clear();
      _history = _load();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<BodegeroLoadingHistoryPage> _load() {
    final range = _period.range;
    return widget.controller.fetchMyLoadingHistory(
      page: _page,
      search: _searchController.text,
      start: _periodActive ? range.start : null,
      end: _periodActive ? range.end : null,
      status: _statusFilter.toLowerCase(),
    );
  }

  String _historyErrorMessage(Object? error) =>
      error.toString().contains('PGRST202')
      ? 'History filters need a database update.'
      : 'Could not load your loading history.';

  void _changePeriod(HistoryPeriodSelection selection) {
    setState(() {
      _period = selection;
      _periodActive = true;
      _page = 1;
      _history = _load();
    });
  }

  void _changeStatus(String status) {
    setState(() {
      _statusFilter = status;
      _page = 1;
      _history = _load();
    });
  }

  void _showAllHistory() {
    setState(() {
      _periodActive = false;
      _statusFilter = 'All';
      _page = 1;
      _history = _load();
    });
  }

  Future<void> _refresh() async {
    _proofs.clear();
    final next = _load();
    setState(() => _history = next);
    try {
      await next;
    } catch (_) {
      // FutureBuilder keeps the retry action visible.
    }
  }

  void _setPage(int page) {
    setState(() {
      _proofs.clear();
      _page = page;
      _history = _load();
    });
  }

  String _shortId(String id) =>
      '#${(id.length <= 8 ? id : id.substring(0, 8)).toUpperCase()}';

  String _dayLabel(DateTime date) {
    const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    final local = date.toLocal();
    return '${weekdays[local.weekday - 1]}, ${months[local.month - 1]} ${local.day}';
  }

  String _time(DateTime date) => MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(date.toLocal()));

  String _quantity(num quantity) => quantity == quantity.roundToDouble()
      ? quantity.toInt().toString()
      : quantity.toString();

  bool _sameDay(DateTime first, DateTime second) {
    final a = first.toLocal();
    final b = second.toLocal();
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<_LoadingProof?> _proofFor(String orderId) =>
      _proofs.putIfAbsent(orderId, () async {
        final proof = await widget.controller.getOrderLoadingProof(orderId);
        if (proof == null) return null;
        final encoded = (proof['photo_base64']?.toString() ?? '').replaceAll(
          RegExp(r'\s+'),
          '',
        );
        if (encoded.isEmpty) return null;
        return _LoadingProof(
          bytes: base64Decode(encoded),
          truckPlate: proof['truck_plate']?.toString(),
        );
      });

  Future<void> _showProof(BodegeroLoadingRecord record) async {
    final zoom = TransformationController();
    var proofFuture = _proofFor(record.orderId);
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, updateDialog) {
            void retry() {
              _proofs.remove(record.orderId);
              updateDialog(() => proofFuture = _proofFor(record.orderId));
            }

            void changeZoom(double factor) {
              final scale = (zoom.value.getMaxScaleOnAxis() * factor).clamp(
                1.0,
                5.0,
              );
              zoom.value = Matrix4.diagonal3Values(scale, scale, 1);
            }

            return Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              elevation: 16,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 720,
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'LOADING PROOF',
                                  style: TextStyle(
                                    color: _orange,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _shortId(record.orderId),
                                  style: const TextStyle(
                                    color: _ink,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFFF4F2F0),
                              foregroundColor: _ink,
                            ),
                            onPressed: () => Navigator.pop(dialogContext),
                            icon: const Icon(Icons.close, size: 20),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1, color: _line),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 9,
                        runSpacing: 7,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (record.status.isNotEmpty)
                            _statusBadge(record.status),
                          Text(
                            'Loaded ${_dayLabel(record.capturedAt)} at ${_time(record.capturedAt)}',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: SingleChildScrollView(
                          child: Container(
                            padding: const EdgeInsets.all(13),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8F7F5),
                              border: Border.all(color: _line),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      LucideIcons.truck,
                                      size: 18,
                                      color: _orange,
                                    ),
                                    const SizedBox(width: 9),
                                    const Text(
                                      'TRUCK',
                                      style: TextStyle(
                                        color: _muted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.7,
                                      ),
                                    ),
                                    const Spacer(),
                                    Flexible(
                                      child: FutureBuilder<_LoadingProof?>(
                                        future: proofFuture,
                                        builder: (context, snapshot) => Text(
                                          snapshot.data?.truckPlate ??
                                              record.truckPlate,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: _ink,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 10),
                                  child: Divider(height: 1, color: _line),
                                ),
                                const Text(
                                  'LOADED ITEMS',
                                  style: TextStyle(
                                    color: _muted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.7,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                for (final item in record.items)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      '${item.name} · ${_quantity(item.quantity)} loaded',
                                      style: const TextStyle(
                                        color: _ink,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Text(
                            'LOADING PHOTO',
                            style: TextStyle(
                              color: _ink,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const Spacer(),
                          const Text(
                            'Pinch to zoom',
                            style: TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8F7F5),
                            border: Border.all(color: _line),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(9),
                            child: ColoredBox(
                              color: const Color(0xFFF1F0EE),
                              child: FutureBuilder<_LoadingProof?>(
                                future: proofFuture,
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return const Center(
                                      child: CircularProgressIndicator(
                                        color: _orange,
                                      ),
                                    );
                                  }
                                  if (snapshot.hasError ||
                                      snapshot.data == null) {
                                    return Center(
                                      child: TextButton(
                                        onPressed: retry,
                                        child: const Text(
                                          'Photo unavailable · Retry',
                                        ),
                                      ),
                                    );
                                  }
                                  return LayoutBuilder(
                                    builder: (context, constraints) =>
                                        InteractiveViewer(
                                          transformationController: zoom,
                                          minScale: 1,
                                          maxScale: 5,
                                          child: SizedBox(
                                            width: constraints.maxWidth,
                                            height: constraints.maxHeight,
                                            child: Image.memory(
                                              snapshot.data!.bytes,
                                              fit: BoxFit.contain,
                                              errorBuilder:
                                                  (context, error, stack) =>
                                                      const Center(
                                                        child: Text(
                                                          'Photo unavailable',
                                                        ),
                                                      ),
                                            ),
                                          ),
                                        ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text(
                            'ZOOM',
                            style: TextStyle(
                              color: _muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.7,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8F7F5),
                              border: Border.all(color: _line),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Zoom out',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => changeZoom(0.8),
                                  icon: const Icon(Icons.remove, size: 19),
                                ),
                                const SizedBox(
                                  height: 22,
                                  child: VerticalDivider(
                                    width: 1,
                                    color: _line,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      zoom.value = Matrix4.identity(),
                                  child: const Text('Reset'),
                                ),
                                const SizedBox(
                                  height: 22,
                                  child: VerticalDivider(
                                    width: 1,
                                    color: _line,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Zoom in',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => changeZoom(1.25),
                                  icon: const Icon(Icons.add, size: 19),
                                ),
                              ],
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
      );
    } finally {
      zoom.dispose();
    }
  }

  Widget _statusBadge(String status) {
    final normalized = status.trim().toLowerCase();
    final completed = normalized == 'completed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: completed ? const Color(0xFFE8F5ED) : const Color(0xFFF3F1EF),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        normalized.replaceAll('_', ' '),
        style: TextStyle(
          color: completed ? const Color(0xFF168047) : _muted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _recordCard(BodegeroLoadingRecord record) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _showProof(record),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 7,
                    runSpacing: 3,
                    children: [
                      Text(
                        _shortId(record.orderId),
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Icon(
                        LucideIcons.check,
                        color: Color(0xFF168047),
                        size: 15,
                      ),
                      if (record.status.isNotEmpty) _statusBadge(record.status),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Loaded ${_time(record.capturedAt)} · Truck ${record.truckPlate}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                  const SizedBox(height: 5),
                  for (final item in record.items)
                    Text(
                      '${item.name} · ${_quantity(item.quantity)} loaded',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _ink, fontSize: 13),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: 'View loading photo',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: FutureBuilder<_LoadingProof?>(
                    future: _proofFor(record.orderId),
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return Image.memory(
                          snapshot.data!.bytes,
                          width: 62,
                          height: 62,
                          fit: BoxFit.cover,
                          cacheWidth: 124,
                          errorBuilder: (context, error, stack) =>
                              const _ProofFallback(),
                        );
                      }
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const ColoredBox(
                          color: Color(0xFFF1F0EE),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _orange,
                              ),
                            ),
                          ),
                        );
                      }
                      return const _ProofFallback();
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _historyList(BodegeroLoadingHistoryPage page) {
    final sorted = [...page.records]
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    final hasPager = page.totalPages > 1;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: sorted.isEmpty ? 1 : sorted.length + (hasPager ? 1 : 0),
      itemBuilder: (context, index) {
        if (sorted.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 56),
            child: Center(child: Text('No loading records yet.')),
          );
        }
        if (index == sorted.length) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _page > 1 ? () => _setPage(_page - 1) : null,
                child: const Text('Previous'),
              ),
              Text('$_page / ${page.totalPages}'),
              TextButton(
                onPressed: _page < page.totalPages
                    ? () => _setPage(_page + 1)
                    : null,
                child: const Text('Next'),
              ),
            ],
          );
        }
        final record = sorted[index];
        final newDay =
            index == 0 ||
            !_sameDay(sorted[index - 1].capturedAt, record.capturedAt);
        return Column(
          key: ValueKey(record.orderId),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay) ...[
              if (index > 0) const SizedBox(height: 13),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 0, 0, 5),
                child: Text(
                  _dayLabel(record.capturedAt),
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
            _recordCard(record),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Widget _searchField({bool compact = false}) => TextField(
    controller: _searchController,
    onChanged: (_) {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _setPage(1);
      });
    },
    decoration: InputDecoration(
      hintText: 'Search order, truck, or product',
      isDense: compact,
      contentPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 9)
          : null,
      prefixIcon: const Icon(LucideIcons.search, size: 18),
      prefixIconConstraints: compact
          ? const BoxConstraints(minWidth: 36, minHeight: 36)
          : null,
      suffixIcon: _searchController.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear search',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                _searchDebounce?.cancel();
                _searchController.clear();
                _setPage(1);
              },
            ),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );

  Widget _filterChip(String label, bool selected, VoidCallback onTap) =>
      ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        selectedColor: _ink,
        backgroundColor: const Color(0xFFF4F1EE),
        labelStyle: TextStyle(
          color: selected ? Colors.white : _muted,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );

  Widget _historyFilters() => Wrap(
    spacing: 4,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _filterChip('All time', !_periodActive, () {
        setState(() {
          _periodActive = false;
          _page = 1;
          _history = _load();
        });
      }),
      for (final mode in HistoryPeriodMode.values)
        _filterChip(
          mode.label,
          _periodActive && _period.mode == mode,
          () => _changePeriod(_period.withMode(mode)),
        ),
      HistoryPeriodControls(
        selection: _period,
        onChanged: _changePeriod,
        warmPalette: true,
      ),
      for (final status in const [
        'All',
        'Waiting',
        'Ready',
        'Completed',
        'Cancelled',
      ])
        _filterChip(
          status,
          _statusFilter == status,
          () => _changeStatus(status),
        ),
    ],
  );

  Widget _metric(String label, String value, IconData icon, Color color) =>
      Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 10),
                  ),
                  Text(
                    value,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _desktopCell(String text, {int flex = 1, bool bold = false}) =>
      Expanded(
        flex: flex,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: bold ? _ink : _muted,
            fontSize: 13,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      );

  Widget _desktopRecord(BodegeroLoadingRecord record) => InkWell(
    onTap: () => _showProof(record),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          _desktopCell(_shortId(record.orderId), flex: 2, bold: true),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  MaterialLocalizations.of(
                    context,
                  ).formatMediumDate(record.capturedAt.toLocal()),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _time(record.capturedAt),
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            ),
          ),
          _desktopCell('Loaded by you', flex: 2, bold: true),
          _desktopCell('${record.items.length}', flex: 1),
          Expanded(flex: 1, child: _statusBadge(record.status)),
          _desktopCell(record.truckPlate, flex: 2),
          const Icon(LucideIcons.chevronRight, color: _muted, size: 18),
        ],
      ),
    ),
  );

  Widget _desktopHistory(BodegeroLoadingHistoryPage page) {
    final records = [...page.records]
      ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    final ready = records.where((record) => record.status == 'prepared').length;
    final completed = records
        .where((record) => record.status == 'completed')
        .length;
    final first = page.totalCount == 0
        ? 0
        : (page.page - 1) * page.pageSize + 1;
    final last = (page.page - 1) * page.pageSize + records.length;
    return RefreshIndicator(
      color: _orange,
      onRefresh: _refresh,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1160),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              const Text(
                'My Loading History',
                style: TextStyle(
                  color: _ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${page.totalCount} loading record${page.totalCount == 1 ? '' : 's'}.',
                style: const TextStyle(color: _muted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 10.0;
                  final width = (constraints.maxWidth - gap * 3) / 4;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      SizedBox(
                        width: width,
                        child: _metric(
                          'My Records',
                          '${page.totalCount}',
                          LucideIcons.history,
                          _orange,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _metric(
                          'On this page',
                          '${records.length}',
                          LucideIcons.list,
                          const Color(0xFFD97706),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _metric(
                          'Ready on page',
                          '$ready',
                          LucideIcons.circleCheck,
                          const Color(0xFF168047),
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _metric(
                          'Completed on page',
                          '$completed',
                          LucideIcons.packageCheck,
                          const Color(0xFF245C9E),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      constraints.maxWidth >= 1030
                      ? Row(
                          children: [
                            Expanded(child: _historyFilters()),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 235,
                              child: _searchField(compact: true),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _historyFilters(),
                            const SizedBox(height: 8),
                            _searchField(compact: true),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      color: const Color(0xFFFAF9F7),
                      child: Row(
                        children: [
                          _desktopCell('ORDER', flex: 2),
                          _desktopCell('DATE & TIME', flex: 2),
                          _desktopCell('ACTIVITY', flex: 2),
                          _desktopCell('ITEMS'),
                          _desktopCell('STATUS'),
                          _desktopCell('TRUCK', flex: 2),
                          const SizedBox(width: 18),
                        ],
                      ),
                    ),
                    if (records.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(40),
                        child: Text('No loading records match your search.'),
                      ),
                    for (final record in records) _desktopRecord(record),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: _line)),
                      ),
                      child: Row(
                        children: [
                          Text(
                            '$first–$last of ${page.totalCount}',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Previous page',
                            onPressed: _page > 1
                                ? () => _setPage(_page - 1)
                                : null,
                            icon: const Icon(LucideIcons.chevronLeft, size: 18),
                          ),
                          Text('$_page of ${page.totalPages}'),
                          IconButton(
                            tooltip: 'Next page',
                            onPressed: _page < page.totalPages
                                ? () => _setPage(_page + 1)
                                : null,
                            icon: const Icon(
                              LucideIcons.chevronRight,
                              size: 18,
                            ),
                          ),
                          const Spacer(),
                          const SizedBox(width: 90),
                        ],
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

  @override
  Widget build(BuildContext context) => MediaQuery.sizeOf(context).width >= 900
      ? ColoredBox(
          color: const Color(0xFFF6F5F2),
          child: FutureBuilder<BodegeroLoadingHistoryPage>(
            future: _history,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: _orange),
                );
              }
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_historyErrorMessage(snapshot.error)),
                      TextButton(
                        onPressed: _showAllHistory,
                        child: const Text('Show all history'),
                      ),
                      TextButton(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }
              return _desktopHistory(snapshot.data!);
            },
          ),
        )
      : ColoredBox(
          color: const Color(0xFFF6F5F2),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'My loading history',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Heavy orders you verified and loaded onto a truck.',
                      style: TextStyle(color: _muted, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    _searchField(),
                    const SizedBox(height: 10),
                    _historyFilters(),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<BodegeroLoadingHistoryPage>(
                  future: _history,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: _orange),
                      );
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_historyErrorMessage(snapshot.error)),
                            TextButton(
                              onPressed: _refresh,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    final page = snapshot.data!;
                    return RefreshIndicator(
                      color: _orange,
                      onRefresh: _refresh,
                      child: _historyList(page),
                    );
                  },
                ),
              ),
            ],
          ),
        );
}

class _LoadingProof {
  const _LoadingProof({required this.bytes, this.truckPlate});

  final Uint8List bytes;
  final String? truckPlate;
}

class _ProofFallback extends StatelessWidget {
  const _ProofFallback();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFFF1F0EE),
    child: Center(
      child: Icon(LucideIcons.imageOff, color: Color(0xFF817A75), size: 24),
    ),
  );
}
