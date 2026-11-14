import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/bodegero_loading_history.dart';
import '../logic/inventory_controller.dart';

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

  Future<BodegeroLoadingHistoryPage> _load() => widget.controller
      .fetchMyLoadingHistory(page: _page, search: _searchController.text);

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

  @override
  Widget build(BuildContext context) => ColoredBox(
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
              TextField(
                controller: _searchController,
                onChanged: (_) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 300),
                    () {
                      if (mounted) _setPage(1);
                    },
                  );
                },
                decoration: InputDecoration(
                  hintText: 'Search order, truck, or product',
                  prefixIcon: const Icon(LucideIcons.search, size: 18),
                  suffixIcon: IconButton(
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
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
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
                      const Text('Could not load your loading history.'),
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
