import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/history_pagination_footer.dart';

class ApprovalCenterPage extends StatefulWidget {
  const ApprovalCenterPage({super.key, required this.controller});

  final InventoryController controller;

  @override
  State<ApprovalCenterPage> createState() => _ApprovalCenterPageState();
}

class _ApprovalCenterPageState extends State<ApprovalCenterPage> {
  static const _blue = Color(0xFF2563EB);
  static const _font = 'Hellix';
  StreamSubscription<InventoryApprovalPage>? _subscription;
  InventoryApprovalStatus _status = InventoryApprovalStatus.pending;
  InventoryApprovalPage? _snapshot;
  final Set<String> _reviewing = <String>{};
  final Set<String> _viewedRequests = <String>{};
  final Map<String, Future<String?>> _proofUrls = <String, Future<String?>>{};
  Map<InventoryApprovalStatus, int> _summary = <InventoryApprovalStatus, int>{};
  int _page = 1;
  bool _loading = true;
  bool _summaryLoading = true;
  bool _summaryInFlight = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.approvalPageSnapshots.listen(
      _acceptSnapshot,
      onError: (Object error, StackTrace _) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
    unawaited(_load());
    unawaited(_loadSummary());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _acceptSnapshot(InventoryApprovalPage value) {
    if (!mounted || value.key.status != _status || value.key.page != _page) {
      return;
    }
    setState(() {
      _snapshot = value;
      _summary[value.key.status] = value.totalCount;
      _loading = false;
      _error = null;
    });
    unawaited(_loadSummary());
  }

  Future<void> _loadSummary() async {
    if (_summaryInFlight) return;
    _summaryInFlight = true;
    try {
      final summary = await widget.controller.fetchApprovalStatusCounts();
      if (mounted) {
        setState(() {
          _summary = summary;
          _summaryLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _summaryLoading = false);
    } finally {
      _summaryInFlight = false;
    }
  }

  Future<void> _load({bool force = false}) async {
    final cached = widget.controller.cachedApprovalPage(
      status: _status,
      page: _page,
    );
    if (mounted) {
      setState(() {
        _snapshot = cached;
        _loading = cached == null;
        _error = null;
      });
    }
    try {
      _acceptSnapshot(
        await widget.controller.activateApprovalPage(
          status: _status,
          page: _page,
          force: force,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _changeStatus(InventoryApprovalStatus status) {
    if (status == _status) return;
    setState(() {
      _status = status;
      _page = 1;
      _snapshot = null;
    });
    unawaited(_load());
  }

  Future<String?> _proofUrl(InventoryApprovalRequest request) {
    if (!request.hasProof) return Future<String?>.value();
    return _proofUrls.putIfAbsent(
      request.id,
      () => widget.controller.fetchApprovalEvidenceUrl(request.id),
    );
  }

  Future<void> _openProof(InventoryApprovalRequest request) async {
    try {
      final url = await _proofUrl(request);
      if (!mounted) return;
      if (url == null) {
        AppToast.error(context, 'Proof image is unavailable.');
        return;
      }
      await _showLargeProof(url);
    } catch (error) {
      _proofUrls.remove(request.id);
      if (mounted) {
        AppToast.error(
          context,
          'Could not securely load proof: '
          '${error.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
  }

  String _qty(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  String _money(double? value) => '₱${(value ?? 0).toStringAsFixed(2)}';

  String _when(DateTime value) {
    final date = value.toLocal();
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    return '${date.month}/${date.day}/${date.year} $hour:'
        '${date.minute.toString().padLeft(2, '0')} '
        '${date.hour >= 12 ? 'PM' : 'AM'}';
  }

  Future<void> _details(InventoryApprovalRequest request) async {
    String? proofUrl;
    if (request.hasProof) {
      try {
        proofUrl = await _proofUrl(request);
      } catch (error) {
        _proofUrls.remove(request.id);
        if (mounted) {
          AppToast.error(
            context,
            'Could not securely load proof: '
            '${error.toString().replaceFirst('Exception: ', '')}',
          );
        }
        return;
      }
      if (proofUrl == null) {
        if (mounted) AppToast.error(context, 'Proof image is unavailable.');
        return;
      }
    }
    if (!mounted) return;
    setState(() => _viewedRequests.add(request.id));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: switch (request.type) {
          InventoryApprovalType.restock => LucideIcons.packagePlus,
          InventoryApprovalType.writeOff => LucideIcons.packageMinus,
          InventoryApprovalType.discount => LucideIcons.badgePercent,
        },
        color: request.hasStockConflict ? Colors.orange : _blue,
        title: '${request.type.label} request',
        subtitle: request.isDiscount
            ? request.requestedByName
            : request.productName,
        // AppDialog intentionally keeps its content before its action row.
        // ignore: sort_child_properties_last
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _detail('Status', request.status.label),
                _detail('Type', request.type.label),
                _detail('Requested by', request.requestedByName),
                _detail('Requested at', _when(request.requestedAt)),
                if (request.isDiscount) ...[
                  _detail(
                    'Discount mode',
                    request.discountMode == 'fixed'
                        ? 'Fixed amount'
                        : 'Percentage',
                  ),
                  _detail(
                    'Requested discount',
                    request.discountMode == 'fixed'
                        ? _money(request.discountValue)
                        : '${_qty(request.discountValue ?? 0)}%',
                  ),
                  _detail(
                    'Effective percentage',
                    '${_qty(request.discountEffectivePercentage ?? 0)}%',
                  ),
                  _detail('Discount amount', _money(request.discountAmount)),
                  _detail('Subtotal', _money(request.subtotalAmount)),
                  _detail('Resulting total', _money(request.resultingTotal)),
                ] else ...[
                  _detail(
                    'Item',
                    '${request.productName} (${request.productSku})',
                  ),
                  _detail(
                    'Quantity',
                    '${_qty(request.quantity)} ${request.unit}',
                  ),
                  _detail(
                    'Stock at request',
                    '${_qty(request.stockAtRequest)} ${request.unit}',
                  ),
                  _detail(
                    'Current stock',
                    '${_qty(request.currentStock)} ${request.unit}',
                  ),
                  _detail(
                    'Result if approved',
                    '${_qty(request.resultingStock)} ${request.unit}',
                    danger: request.hasStockConflict,
                  ),
                ],
                _detail('Reason', request.reason ?? '-'),
                if (!request.isDiscount) _detail('Note', request.note ?? '-'),
                if (request.reviewedByName != null)
                  _detail('Reviewed by', request.reviewedByName!),
                if (request.reviewedAt != null)
                  _detail('Reviewed at', _when(request.reviewedAt!)),
                if (request.reviewNote?.isNotEmpty ?? false)
                  _detail('Review note', request.reviewNote!),
                if (!request.isDiscount) ...[
                  const SizedBox(height: 16),
                  _proofPanel(request, proofUrl),
                ],
                if (request.hasStockConflict)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    color: Colors.orange.shade50,
                    child: const Text(
                      'Approval is blocked because this write-off exceeds '
                      'available stock.',
                      style: TextStyle(
                        color: Color(0xFF9A3412),
                        fontWeight: FontWeight.w700,
                        fontFamily: _font,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _proofPanel(InventoryApprovalRequest request, String? proofUrl) {
    if (!request.hasProof) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const Row(
          children: [
            Icon(LucideIcons.archive, size: 17, color: Color(0xFF94A3B8)),
            SizedBox(width: 8),
            Text(
              'No proof — legacy request',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w700,
                fontFamily: _font,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Proof image',
            style: TextStyle(fontWeight: FontWeight.w800, fontFamily: _font),
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: proofUrl == null ? null : () => _showLargeProof(proofUrl),
          borderRadius: BorderRadius.circular(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              proofUrl!,
              width: double.infinity,
              height: 240,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const SizedBox(
                height: 120,
                child: Center(child: Text('Proof preview unavailable')),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          request.proofFileName ?? 'Proof image',
          style: const TextStyle(color: Color(0xFF64748B), fontFamily: _font),
        ),
      ],
    );
  }

  Future<void> _showLargeProof(String url) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      child: Stack(
        children: [
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(child: Image.network(url, fit: BoxFit.contain)),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filled(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(LucideIcons.x),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _review(
    InventoryApprovalRequest request, {
    required bool approve,
  }) async {
    if (!_viewedRequests.contains(request.id)) {
      await _details(request);
      return;
    }
    final note = TextEditingController();
    final conflict = approve && request.hasStockConflict;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: conflict
            ? LucideIcons.triangleAlert
            : approve
            ? LucideIcons.check
            : LucideIcons.x,
        color: conflict
            ? Colors.orange
            : approve
            ? Colors.green
            : Colors.red,
        title: conflict
            ? 'Stock conflict'
            : '${approve ? 'Approve' : 'Reject'} request?',
        subtitle: request.isDiscount
            ? '${_qty(request.discountEffectivePercentage ?? 0)}% effective discount'
            : '${request.type.label} - ${request.productName}',
        // AppDialog intentionally keeps its content before its action row.
        // ignore: sort_child_properties_last
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _reviewExplanation(request, approve: approve, conflict: conflict),
              style: TextStyle(
                color: conflict ? Colors.orange.shade900 : Colors.black87,
                fontFamily: _font,
              ),
            ),
            if (!conflict) ...[
              const SizedBox(height: 16),
              TextField(
                controller: note,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Review note (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(conflict ? 'Close' : 'Cancel'),
          ),
          if (!conflict)
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: approve ? Colors.green : Colors.red,
                foregroundColor: Colors.white,
              ),
              child: Text(approve ? 'Approve' : 'Reject'),
            ),
        ],
      ),
    );
    final reviewNote = note.text.trim();
    note.dispose();
    if (confirmed != true || !mounted) return;

    setState(() => _reviewing.add(request.id));
    try {
      if (approve) {
        await widget.controller.approveInventoryApprovalRequest(
          request.id,
          reviewNote: reviewNote,
        );
      } else {
        await widget.controller.rejectInventoryApprovalRequest(
          request.id,
          reviewNote: reviewNote,
        );
      }
      if (mounted) {
        AppToast.success(
          context,
          'Request ${approve ? 'approved' : 'rejected'}.',
        );
      }
    } catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _reviewing.remove(request.id));
        await _load(force: true);
        unawaited(_loadSummary());
      }
    }
  }

  String _reviewExplanation(
    InventoryApprovalRequest request, {
    required bool approve,
    required bool conflict,
  }) {
    if (conflict) {
      return 'This request needs ${_qty(request.quantity)} ${request.unit}, '
          'but only ${_qty(request.currentStock)} remains.';
    }
    if (request.isDiscount) {
      return approve
          ? 'Approval authorizes only this exact cart, subtotal, and discount. '
                'The Cashier must still finalize checkout.'
          : 'The Cashier cannot use this discount for checkout.';
    }
    return approve
        ? 'Approval immediately applies the inventory change and writes '
              'transaction history.'
        : 'Rejection does not change inventory quantity.';
  }

  Widget _detail(String label, String value, {bool danger = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 138,
          child: Text(
            label,
            style: const TextStyle(color: Colors.grey, fontFamily: _font),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: danger ? Colors.red : const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
              fontFamily: _font,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final records = snapshot?.requests ?? const <InventoryApprovalRequest>[];
    return ColoredBox(
      color: const Color(0xFFF4F6F8),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth < 700 ? 14.0 : 22.0;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                14,
                horizontalPadding,
                16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Approval Center',
                    style: TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      fontFamily: _font,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Review and verify inventory change requests',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: _font,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildSummaryMetrics(),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _buildStatusTabs(),
                          ),
                        ),
                        const Divider(height: 1, color: Color(0xFFE2E8F0)),
                        _tableBody(records),
                        HistoryPaginationFooter(
                          currentPage: _page,
                          totalItems:
                              snapshot?.totalCount ?? _summary[_status] ?? 0,
                          pageSize: snapshot?.key.pageSize ?? 20,
                          loading: _loading,
                          onPageSelected: (page) {
                            if (page == _page) return;
                            setState(() => _page = page);
                            unawaited(_load());
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSummaryMetrics() => LayoutBuilder(
    builder: (context, constraints) {
      final stacked = constraints.maxWidth < 440;
      final width = stacked
          ? constraints.maxWidth
          : (constraints.maxWidth - 16) / 3;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: InventoryApprovalStatus.values
            .map(
              (status) => SizedBox(
                width: width,
                child: _summaryTile(status.label, status),
              ),
            )
            .toList(growable: false),
      );
    },
  );

  Widget _summaryTile(String label, InventoryApprovalStatus status) =>
      Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  fontFamily: _font,
                ),
              ),
            ),
            Text(
              _summaryLoading ? '—' : '${_summary[status] ?? 0}',
              style: TextStyle(
                color: _statusColor(status),
                fontSize: 18,
                fontWeight: FontWeight.w900,
                fontFamily: _font,
              ),
            ),
          ],
        ),
      );

  Widget _buildStatusTabs() => SegmentedButton<InventoryApprovalStatus>(
    showSelectedIcon: false,
    style: SegmentedButton.styleFrom(
      selectedBackgroundColor: _blue,
      selectedForegroundColor: Colors.white,
      foregroundColor: const Color(0xFF475569),
      backgroundColor: const Color(0xFFF8FAFC),
      side: const BorderSide(color: Color(0xFFCBD5E1)),
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: 13),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        fontFamily: _font,
      ),
    ),
    segments: InventoryApprovalStatus.values
        .map(
          (status) => ButtonSegment(value: status, label: Text(status.label)),
        )
        .toList(growable: false),
    selected: <InventoryApprovalStatus>{_status},
    onSelectionChanged: (selection) => _changeStatus(selection.first),
  );

  Widget _tableBody(List<InventoryApprovalRequest> records) {
    if (_loading && _snapshot == null) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: CircularProgressIndicator(color: _blue),
      );
    }
    if (_error != null && _snapshot == null) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _load(force: true),
              icon: const Icon(LucideIcons.refreshCw),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (records.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          children: [
            Icon(LucideIcons.clipboardCheck, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            Text(
              'No ${_status.label.toLowerCase()} approval requests.',
              style: const TextStyle(color: Colors.grey, fontFamily: _font),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(
            horizontalMargin: 16,
            columnSpacing: 16,
            headingRowHeight: 40,
            dataRowMinHeight: 50,
            dataRowMaxHeight: 50,
            dividerThickness: 1,
            headingRowColor: const WidgetStatePropertyAll(Color(0xFFF8FAFC)),
            columns: [
              DataColumn(label: _headerCell('REQUEST', 78)),
              DataColumn(label: _headerCell('TYPE', 82)),
              DataColumn(label: _headerCell('ITEM', 176)),
              DataColumn(label: _headerCell('QTY', 82)),
              DataColumn(label: _headerCell('REQUESTED BY', 128)),
              DataColumn(label: _headerCell('REQUESTED AT', 130)),
              DataColumn(label: _headerCell('PROOF', 72)),
              DataColumn(label: _headerCell('STATUS', 86)),
              DataColumn(label: _headerCell('ACTIONS', 124)),
            ],
            rows: records.map(_row).toList(growable: false),
          ),
        ),
      ),
    );
  }

  DataRow _row(InventoryApprovalRequest request) {
    final busy = _reviewing.contains(request.id);
    final viewed = _viewedRequests.contains(request.id);
    return DataRow(
      color: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? const Color(0xFFF8FAFC)
            : Colors.transparent,
      ),
      cells: [
        DataCell(
          _bodyCell(request.id.substring(0, 8).toUpperCase(), 78, strong: true),
        ),
        DataCell(
          SizedBox(
            width: 82,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(request.type.label, _typeColor(request.type)),
            ),
          ),
        ),
        DataCell(
          _bodyCell(
            request.isDiscount ? 'POS checkout' : request.productName,
            176,
            strong: true,
          ),
        ),
        DataCell(
          _bodyCell(
            request.isDiscount
                ? '${_qty(request.discountEffectivePercentage ?? 0)}%'
                : '${_qty(request.quantity)} ${request.unit}',
            82,
          ),
        ),
        DataCell(_bodyCell(request.requestedByName, 128)),
        DataCell(_bodyCell(_when(request.requestedAt), 130)),
        DataCell(
          SizedBox(
            width: 72,
            child: request.isDiscount
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: Tooltip(
                      message: 'Proof is not required for discount requests',
                      child: Text(
                        'N/A',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          fontFamily: _font,
                        ),
                      ),
                    ),
                  )
                : request.hasProof
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Tooltip(
                      message: 'View proof',
                      child: InkWell(
                        onTap: () => _openProof(request),
                        borderRadius: BorderRadius.circular(7),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Icon(
                            LucideIcons.image,
                            color: _blue,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  )
                : const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Legacy',
                      style: TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        fontFamily: _font,
                      ),
                    ),
                  ),
          ),
        ),
        DataCell(
          SizedBox(
            width: 86,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(request.status.label, _statusColor(request.status)),
            ),
          ),
        ),
        DataCell(
          SizedBox(
            width: 124,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _actionButton(
                  label: 'View',
                  icon: LucideIcons.eye,
                  color: _blue,
                  onPressed: () => _details(request),
                ),
                if (request.status == InventoryApprovalStatus.pending) ...[
                  const SizedBox(width: 4),
                  _actionButton(
                    label: viewed
                        ? 'Approve request'
                        : 'View request before approving',
                    icon: LucideIcons.check,
                    color: const Color(0xFF15803D),
                    onPressed: busy || request.hasStockConflict || !viewed
                        ? null
                        : () => _review(request, approve: true),
                  ),
                  const SizedBox(width: 4),
                  _actionButton(
                    label: viewed
                        ? 'Reject request'
                        : 'View request before rejecting',
                    icon: LucideIcons.x,
                    color: const Color(0xFFDC2626),
                    onPressed: busy || !viewed
                        ? null
                        : () => _review(request, approve: false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _headerCell(String label, double width) => SizedBox(
    width: width,
    child: Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Color(0xFF64748B),
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.35,
        fontFamily: _font,
      ),
    ),
  );

  Widget _bodyCell(String value, double width, {bool strong = false}) =>
      SizedBox(
        width: width,
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: const Color(0xFF334155),
            fontSize: 12,
            fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
            fontFamily: _font,
          ),
        ),
      );

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) => Tooltip(
    message: label,
    child: SizedBox(
      width: 36,
      height: 32,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: const Color(0xFFCBD5E1),
          backgroundColor: color.withValues(alpha: 0.09),
          disabledBackgroundColor: const Color(0xFFF8FAFC),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        icon: Icon(icon, size: 16),
      ),
    ),
  );

  Widget _chip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        fontFamily: _font,
      ),
    ),
  );

  Color _typeColor(InventoryApprovalType type) => switch (type) {
    InventoryApprovalType.restock => _blue,
    InventoryApprovalType.writeOff => const Color(0xFFEA580C),
    InventoryApprovalType.discount => const Color(0xFF7C3AED),
  };

  Color _statusColor(InventoryApprovalStatus status) => switch (status) {
    InventoryApprovalStatus.pending => const Color(0xFFD97706),
    InventoryApprovalStatus.approved => const Color(0xFF15803D),
    InventoryApprovalStatus.rejected => const Color(0xFFDC2626),
  };
}
