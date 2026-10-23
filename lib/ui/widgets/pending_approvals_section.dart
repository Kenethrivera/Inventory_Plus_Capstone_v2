import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../logic/inventory_approval.dart';
import '../../logic/inventory_controller.dart';
import 'app_dialog.dart';
import 'app_toast.dart';

class PendingApprovalsSection extends StatefulWidget {
  const PendingApprovalsSection({super.key, required this.controller});

  final InventoryController controller;

  @override
  State<PendingApprovalsSection> createState() =>
      _PendingApprovalsSectionState();
}

class _PendingApprovalsSectionState extends State<PendingApprovalsSection> {
  static const String _font = 'Hellix';
  StreamSubscription<InventoryApprovalPage>? _subscription;
  InventoryApprovalStatus _status = InventoryApprovalStatus.pending;
  InventoryApprovalPage? _snapshot;
  final Set<String> _reviewing = <String>{};
  int _page = 1;
  bool _loading = true;
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
      _loading = false;
      _error = null;
    });
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

  String _qty(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  String _when(DateTime value) {
    final date = value.toLocal();
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    return '${date.month}/${date.day}/${date.year} $hour:'
        '${date.minute.toString().padLeft(2, '0')} '
        '${date.hour >= 12 ? 'PM' : 'AM'}';
  }

  Future<void> _review(
    InventoryApprovalRequest request, {
    required bool approve,
  }) async {
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
        subtitle: '${request.type.label} - ${request.productName}',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conflict
                  ? 'This request needs ${_qty(request.quantity)} '
                        '${request.unit}, but only '
                        '${_qty(request.currentStock)} remains. Approval is '
                        'blocked; reject it or request a correction.'
                  : approve
                  ? 'Approval immediately applies the inventory change and '
                        'writes transaction history.'
                  : 'Rejection does not change inventory quantity.',
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
      }
    }
  }

  Future<void> _details(InventoryApprovalRequest request) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: request.type == InventoryApprovalType.restock
            ? LucideIcons.packagePlus
            : LucideIcons.packageMinus,
        color: request.hasStockConflict ? Colors.orange : Colors.blue,
        title: '${request.type.label} request',
        subtitle: request.productName,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _detail('Status', request.status.label),
            _detail('Item', '${request.productName} (${request.productSku})'),
            _detail('Quantity', '${_qty(request.quantity)} ${request.unit}'),
            _detail('Requested by', request.requestedByName),
            _detail('Requested at', _when(request.requestedAt)),
            _detail('Reason', request.reason ?? '-'),
            _detail('Note', request.note ?? '-'),
            _detail(
              'Current stock',
              '${_qty(request.currentStock)} ${request.unit}',
            ),
            _detail(
              'Result if approved',
              '${_qty(request.resultingStock)} ${request.unit}',
              danger: request.hasStockConflict,
            ),
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
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _detail(String label, String value, {bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
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
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final records = snapshot?.requests ?? const <InventoryApprovalRequest>[];
    final totalPages = snapshot?.totalPages ?? 1;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Wrap(
              spacing: 20,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.clipboardCheck, color: Color(0xFFD97706)),
                    SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pending Approvals',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            fontFamily: _font,
                          ),
                        ),
                        Text(
                          'Review Restock and Write-off requests.',
                          style: TextStyle(
                            color: Colors.grey,
                            fontFamily: _font,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SegmentedButton<InventoryApprovalStatus>(
                  segments: InventoryApprovalStatus.values
                      .map(
                        (status) => ButtonSegment(
                          value: status,
                          label: Text(status.label),
                        ),
                      )
                      .toList(growable: false),
                  selected: <InventoryApprovalStatus>{_status},
                  onSelectionChanged: (selection) =>
                      _changeStatus(selection.first),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_loading && snapshot == null)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null && snapshot == null)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
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
              ),
            )
          else if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  'No ${_status.label.toLowerCase()} approval requests.',
                  style: const TextStyle(color: Colors.grey, fontFamily: _font),
                ),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Request')),
                  DataColumn(label: Text('Type')),
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Qty')),
                  DataColumn(label: Text('Requested By')),
                  DataColumn(label: Text('Requested At')),
                  DataColumn(label: Text('Status')),
                  DataColumn(label: Text('Actions')),
                ],
                rows: records.map(_row).toList(growable: false),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('Page $_page of $totalPages'),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _page > 1
                      ? () {
                          setState(() => _page--);
                          unawaited(_load());
                        }
                      : null,
                  icon: const Icon(LucideIcons.chevronLeft),
                ),
                IconButton(
                  onPressed: _page < totalPages
                      ? () {
                          setState(() => _page++);
                          unawaited(_load());
                        }
                      : null,
                  icon: const Icon(LucideIcons.chevronRight),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  DataRow _row(InventoryApprovalRequest request) {
    final busy = _reviewing.contains(request.id);
    return DataRow(
      cells: [
        DataCell(Text(request.id.substring(0, 8).toUpperCase())),
        DataCell(Text(request.type.label)),
        DataCell(Text(request.productName)),
        DataCell(Text('${_qty(request.quantity)} ${request.unit}')),
        DataCell(Text(request.requestedByName)),
        DataCell(Text(_when(request.requestedAt))),
        DataCell(Text(request.status.label)),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => _details(request),
                tooltip: 'View details',
                icon: const Icon(LucideIcons.eye, size: 18),
              ),
              if (request.status == InventoryApprovalStatus.pending) ...[
                IconButton(
                  onPressed: busy || request.hasStockConflict
                      ? null
                      : () => _review(request, approve: true),
                  tooltip: request.hasStockConflict
                      ? 'Blocked by current stock'
                      : 'Approve',
                  icon: const Icon(LucideIcons.check, color: Colors.green),
                ),
                IconButton(
                  onPressed: busy
                      ? null
                      : () => _review(request, approve: false),
                  tooltip: 'Reject',
                  icon: const Icon(LucideIcons.x, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
