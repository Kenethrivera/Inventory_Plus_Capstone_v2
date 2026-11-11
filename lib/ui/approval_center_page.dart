import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_styled_dropdown.dart';
import 'widgets/app_toast.dart';
import 'widgets/history_pagination_footer.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

class ApprovalCenterPage extends StatefulWidget {
  const ApprovalCenterPage({
    super.key,
    required this.controller,
    this.onPendingCountChanged,
  });

  final InventoryController controller;
  final ValueChanged<int>? onPendingCountChanged;

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
  InventoryApprovalPage? _lastAcceptedSnapshot;
  String? _error;
  String? _selectedRequestId;
  InventoryApprovalType? _typeFilter;
  final TextEditingController _inlineNote = TextEditingController();

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.approvalPageSnapshots.listen(
      _acceptSnapshot,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          'Approval snapshot stream failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (mounted) {
          setState(
            () => _error = AppErrorMapper.message(
              error,
              fallback: AppErrorCategory.dataLoad,
            ),
          );
        }
      },
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _inlineNote.dispose();
    super.dispose();
  }

  void _acceptSnapshot(InventoryApprovalPage value) {
    if (!mounted || value.key.status != _status || value.key.page != _page) {
      return;
    }
    if (identical(_lastAcceptedSnapshot, value)) return;
    _lastAcceptedSnapshot = value;
    setState(() {
      _snapshot = value;
      _summary[value.key.status] = value.totalCount;
      if (_selectedRequestId != null &&
          !value.requests.any((request) => request.id == _selectedRequestId)) {
        _selectedRequestId = null;
        _inlineNote.clear();
      }
      _loading = false;
      _error = null;
    });
    if (value.key.status == InventoryApprovalStatus.pending) {
      widget.onPendingCountChanged?.call(value.totalCount);
    }
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
        widget.onPendingCountChanged?.call(
          summary[InventoryApprovalStatus.pending] ?? 0,
        );
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
    } catch (error, stackTrace) {
      AppLogger.error(
        'Approval page load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AppErrorMapper.message(
          error,
          fallback: AppErrorCategory.dataLoad,
        );
      });
    }
  }

  void _changeStatus(InventoryApprovalStatus status) {
    if (status == _status) return;
    setState(() {
      _status = status;
      _page = 1;
      _snapshot = null;
      _selectedRequestId = null;
      _inlineNote.clear();
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
    } catch (error, stackTrace) {
      AppLogger.error(
        'Approval proof load failed',
        error: error,
        stackTrace: stackTrace,
      );
      _proofUrls.remove(request.id);
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataLoad),
        );
      }
    }
  }

  String _qty(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  String _money(double? value) {
    final fixed = (value ?? 0).toStringAsFixed(2);
    final parts = fixed.split('.');
    final negative = parts.first.startsWith('-');
    final digits = negative ? parts.first.substring(1) : parts.first;
    final grouped = StringBuffer();
    if (negative) grouped.write('-');
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
      grouped.write(digits[index]);
    }
    return '₱$grouped.${parts.last}';
  }

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
      } catch (error, stackTrace) {
        AppLogger.error(
          'Approval proof load failed',
          error: error,
          stackTrace: stackTrace,
        );
        _proofUrls.remove(request.id);
        if (mounted) {
          AppToast.error(
            context,
            AppErrorMapper.message(error, fallback: AppErrorCategory.dataLoad),
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
        maxWidth: request.isDiscount ? 720 : 560,
        // AppDialog intentionally keeps its content before its action row.
        // ignore: sort_child_properties_last
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip(request.type.label, _typeColor(request.type)),
                _chip(
                  request.displayStatus,
                  request.usedAt != null
                      ? const Color(0xFF475569)
                      : _statusColor(request.status),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _detailSection(
              title: 'Request information',
              icon: LucideIcons.clipboardList,
              children: [
                _detail('Requested by', request.requestedByName),
                _detail('Location', request.locationName),
                _detail('Requested at', _when(request.requestedAt)),
                if (request.isDiscount)
                  _detail(
                    'Discount mode',
                    request.discountMode == 'amount'
                        ? 'Fixed amount'
                        : 'Percentage',
                  ),
                if (!request.isDiscount) ...[
                  _detail(
                    'Item',
                    request.productSku.isEmpty
                        ? request.productName
                        : '${request.productName} (${request.productSku})',
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
              ],
            ),
            if (request.isDiscount) ...[
              const SizedBox(height: 12),
              _cartSnapshotPanel(request),
              const SizedBox(height: 12),
              _discountSummary(request),
            ],
            const SizedBox(height: 12),
            _detailSection(
              title: 'Reason and review',
              icon: LucideIcons.messageSquareText,
              children: [
                _detail(
                  'Reason',
                  request.reason?.trim().isNotEmpty == true
                      ? request.reason!
                      : '—',
                ),
                if (!request.isDiscount)
                  _detail(
                    'Note',
                    request.note?.trim().isNotEmpty == true
                        ? request.note!
                        : '—',
                  ),
                if (request.reviewedByName != null)
                  _detail('Reviewed by', request.reviewedByName!),
                if (request.reviewedAt != null)
                  _detail('Reviewed at', _when(request.reviewedAt!)),
                if (request.reviewNote?.isNotEmpty ?? false)
                  _detail('Review note', request.reviewNote!),
              ],
            ),
            if (!request.isDiscount) ...[
              const SizedBox(height: 12),
              _proofPanel(request, proofUrl),
            ],
            if (request.hasStockConflict)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
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
    String? inlineNote,
  }) async {
    if (!_viewedRequests.contains(request.id)) {
      await _details(request);
      return;
    }
    final note = TextEditingController(text: inlineNote);
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
            : '${approve ? 'Approve' : 'Reject'} request',
        subtitle: request.isDiscount
            ? '${_qty(request.discountEffectivePercentage ?? 0)}% effective discount'
            : '${request.type.label} - ${request.productName}',
        // AppDialog intentionally keeps its content before its action row.
        // ignore: sort_child_properties_last
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _reviewRequestSummary(request),
            const SizedBox(height: 14),
            Text(
              _reviewExplanation(request, approve: approve, conflict: conflict),
              style: TextStyle(
                color: conflict ? Colors.orange.shade900 : Colors.black87,
                fontFamily: _font,
              ),
            ),
            if (!conflict && inlineNote == null) ...[
              const SizedBox(height: 16),
              TextField(
                controller: note,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: approve
                      ? 'Review note (optional)'
                      : 'Rejection note (optional)',
                  border: const OutlineInputBorder(),
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
    } catch (error, stackTrace) {
      AppLogger.error(
        'Approval review failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _reviewing.remove(request.id));
        await _load(force: true);
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

  Widget _reviewRequestSummary(InventoryApprovalRequest request) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          request.isDiscount ? request.discountDisplay : request.productName,
          style: const TextStyle(
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.w900,
            fontFamily: _font,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          request.isDiscount
              ? '${_money(request.subtotalAmount)} → '
                    '${_money(request.resultingTotal)} · '
                    '${_qty(request.discountEffectivePercentage ?? 0)}% effective'
              : '${request.type.label} · ${_qty(request.quantity)} '
                    '${request.unit}',
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: _font,
          ),
        ),
      ],
    ),
  );

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

  Widget _detailSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Icon(icon, size: 17, color: const Color(0xFF475569)),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF334155),
                fontWeight: FontWeight.w800,
                fontFamily: _font,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );

  Widget _discountSummary(InventoryApprovalRequest request) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFEFF6FF),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFBFDBFE)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(LucideIcons.receiptText, size: 17, color: _blue),
            SizedBox(width: 8),
            Text(
              'Financial summary',
              style: TextStyle(
                color: Color(0xFF1E3A8A),
                fontWeight: FontWeight.w800,
                fontFamily: _font,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _financialMetric('Subtotal', _money(request.subtotalAmount)),
            _financialMetric('Requested discount', request.discountDisplay),
            _financialMetric(
              'Effective discount',
              '${_qty(request.discountEffectivePercentage ?? 0)}% '
                  '(${_money(request.discountAmount)})',
            ),
            _financialMetric(
              'Total after discount',
              _money(request.resultingTotal),
              emphasized: true,
            ),
          ],
        ),
      ],
    ),
  );

  Widget _financialMetric(
    String label,
    String value, {
    bool emphasized = false,
  }) => SizedBox(
    width: 300,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            fontFamily: _font,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: emphasized ? _blue : const Color(0xFF0F172A),
            fontSize: emphasized ? 17 : 15,
            fontWeight: FontWeight.w900,
            fontFamily: _font,
          ),
        ),
      ],
    ),
  );

  Widget _cartSnapshotPanel(InventoryApprovalRequest request) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Reviewed cart snapshot',
          style: TextStyle(
            color: Color(0xFF334155),
            fontWeight: FontWeight.w800,
            fontFamily: _font,
          ),
        ),
        const SizedBox(height: 7),
        if (request.cartItems.isEmpty)
          const Text(
            'Detailed cart snapshot unavailable for this legacy request.',
            style: TextStyle(color: Color(0xFF94A3B8), fontFamily: _font),
          )
        else ...[
          const Divider(height: 16),
          for (final item in request.cartItems) _cartItemRow(item),
        ],
      ],
    ),
  );

  Widget _cartItemRow(Map<String, dynamic> item) {
    final quantity = (item['quantity'] as num?)?.toDouble() ?? 0;
    final unitPrice = (item['unit_price'] as num?)?.toDouble() ?? 0;
    final lineTotal =
        (item['line_total'] as num?)?.toDouble() ?? quantity * unitPrice;
    final unit = item['unit']?.toString().trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              item['product_name']?.toString() ?? 'Item',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF334155),
                fontSize: 12,
                fontWeight: FontWeight.w800,
                fontFamily: _font,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${_qty(quantity)} ${unit?.isNotEmpty == true ? unit : 'pcs'}',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontFamily: _font),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _money(unitPrice),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontFamily: _font),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _money(lineTotal),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
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
    final records = (snapshot?.requests ?? const <InventoryApprovalRequest>[])
        .where((request) => _typeFilter == null || request.type == _typeFilter)
        .toList(growable: false);
    final selected = records.isEmpty
        ? null
        : records.firstWhere(
            (request) => request.id == _selectedRequestId,
            orElse: () => records.first,
          );
    if (selected != null) _viewedRequests.add(selected.id);
    return ColoredBox(
      color: const Color(0xFFF7F5F3),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 1150;
            final horizontalPadding = compact ? 16.0 : 32.0;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                34,
                horizontalPadding,
                32,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Approvals',
                    style: TextStyle(
                      color: Color(0xFF161616),
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      fontFamily: _font,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Restock, write-off and discount requests from cashiers and helpers.',
                    style: TextStyle(
                      color: Color(0xFF827872),
                      fontSize: 14,
                      fontFamily: _font,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (compact)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _approvalList(records, snapshot),
                        const SizedBox(height: 18),
                        if (selected != null) _approvalDetail(selected),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 440,
                          child: _approvalList(records, snapshot),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: selected == null
                              ? _emptyDetail()
                              : _approvalDetail(selected),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _approvalList(
    List<InventoryApprovalRequest> records,
    InventoryApprovalPage? snapshot,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Flexible(child: _approvalStatusTabs()),
          const SizedBox(width: 12),
          SizedBox(
            height: 38,
            child: AppStyledDropdown<InventoryApprovalType?>(
              value: _typeFilter,
              isDense: true,
              style: const TextStyle(
                color: Color(0xFF171717),
                fontSize: 13,
                fontFamily: _font,
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('All types')),
                ...InventoryApprovalType.values.map(
                  (type) =>
                      DropdownMenuItem(value: type, child: Text(type.label)),
                ),
              ],
              onChanged: (value) => setState(() {
                _typeFilter = value;
                _selectedRequestId = null;
                _inlineNote.clear();
              }),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Container(
        decoration: _outlineDecoration(),
        clipBehavior: Clip.antiAlias,
        child: _loading && snapshot == null
            ? const Padding(
                padding: EdgeInsets.all(48),
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFFC83D08)),
                ),
              )
            : _error != null && snapshot == null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: () => _load(force: true),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            : records.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(28),
                child: Center(
                  child: Text(
                    _typeFilter == null
                        ? 'No ${_status.label.toLowerCase()} requests.'
                        : 'No ${_typeFilter!.label.toLowerCase()} requests on this page.',
                    style: const TextStyle(
                      color: Color(0xFF827872),
                      fontSize: 13,
                    ),
                  ),
                ),
              )
            : Column(
                children: [
                  for (var index = 0; index < records.length; index++) ...[
                    if (index > 0)
                      const Divider(height: 1, color: Color(0xFFE8E2DC)),
                    _approvalListItem(
                      records[index],
                      records[index].id ==
                          (records.any((item) => item.id == _selectedRequestId)
                              ? _selectedRequestId
                              : records.first.id),
                    ),
                  ],
                ],
              ),
      ),
      if ((snapshot?.totalPages ?? 1) > 1)
        HistoryPaginationFooter(
          currentPage: _page,
          totalItems: snapshot!.totalCount,
          pageSize: snapshot.key.pageSize,
          loading: _loading,
          onPageSelected: (page) {
            if (page == _page) return;
            setState(() {
              _page = page;
              _selectedRequestId = null;
              _inlineNote.clear();
            });
            unawaited(_load());
          },
        ),
    ],
  );

  Widget _approvalStatusTabs() => Container(
    height: 38,
    padding: const EdgeInsets.all(3),
    decoration: _outlineDecoration(),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: InventoryApprovalStatus.values
          .map((status) {
            final active = status == _status;
            final count =
                status == InventoryApprovalStatus.pending && !_summaryLoading
                ? ' ${_summary[status] ?? 0}'
                : '';
            return InkWell(
              onTap: () => _changeStatus(status),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: active ? const Color(0xFF1C1C1C) : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${status.label}$count',
                  style: TextStyle(
                    color: active ? Colors.white : const Color(0xFF766C66),
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    fontFamily: _font,
                  ),
                ),
              ),
            );
          })
          .toList(growable: false),
    ),
  );

  BoxDecoration _outlineDecoration() => BoxDecoration(
    color: Colors.white,
    border: Border.all(color: const Color(0xFFE8E2DC)),
    borderRadius: BorderRadius.circular(12),
  );

  Widget _approvalListItem(InventoryApprovalRequest request, bool selected) {
    final title = request.isDiscount
        ? '${request.discountDisplay} off ${_money(request.subtotalAmount)} cart'
        : '${request.productName} · ${_qty(request.quantity)} ${request.unit}';
    return Material(
      color: selected ? const Color(0xFFFFF0E8) : Colors.white,
      child: InkWell(
        onTap: () => setState(() {
          _selectedRequestId = request.id;
          _inlineNote.clear();
          _viewedRequests.add(request.id);
        }),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _requestAvatar(request.requestedByName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _typeBadge(request.type, request.type.label),
                        const Spacer(),
                        Text(
                          _relativeWhen(request.requestedAt),
                          style: const TextStyle(
                            color: Color(0xFFAAA19B),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF171717),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${request.requestedByName}${request.reason?.isNotEmpty == true ? ' · ${request.reason}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF827872),
                        fontSize: 12,
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

  Color _approvalTypeColor(InventoryApprovalType type) => switch (type) {
    InventoryApprovalType.restock => const Color(0xFF078443),
    InventoryApprovalType.writeOff => const Color(0xFFD11A1A),
    InventoryApprovalType.discount => const Color(0xFFC83D08),
  };

  Widget _typeBadge(InventoryApprovalType type, String label) {
    final color = _approvalTypeColor(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        border: Border.all(color: color.withValues(alpha: .22)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _requestAvatar(String name) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    return CircleAvatar(
      radius: 18,
      backgroundColor: const Color(0xFFE8F6EE),
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: const TextStyle(
          color: Color(0xFF078443),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _relativeWhen(DateTime when) {
    final delta = DateTime.now().difference(when.toLocal());
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} minutes ago';
    if (delta.inHours < 24) return '${delta.inHours} hours ago';
    return '${delta.inDays} days ago';
  }

  Widget _emptyDetail() => Container(
    padding: const EdgeInsets.all(36),
    decoration: _outlineDecoration(),
    child: const Center(
      child: Text(
        'Select an approval request.',
        style: TextStyle(color: Color(0xFF827872)),
      ),
    ),
  );

  Widget _approvalDetail(InventoryApprovalRequest request) => Container(
    decoration: _outlineDecoration(),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Row(
            children: [
              _requestAvatar(request.requestedByName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.requestedByName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${_roleLabel(request.requestedByRole)} · ${_when(request.requestedAt)}',
                      style: const TextStyle(
                        color: Color(0xFF827872),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _typeBadge(request.type, '${request.type.label} request'),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE8E2DC)),
        Padding(
          padding: const EdgeInsets.all(24),
          child: request.isDiscount
              ? _discountApprovalBody(request)
              : _inventoryApprovalBody(request),
        ),
        if (request.status == InventoryApprovalStatus.pending) ...[
          const Divider(height: 1, color: Color(0xFFE8E2DC)),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Note to ${request.requestedByName.split(' ').first} (required to reject)',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _approvalActionBar(request),
              ],
            ),
          ),
        ],
      ],
    ),
  );

  Widget _approvalActionBar(InventoryApprovalRequest request) {
    final noteField = SizedBox(
      height: 40,
      child: TextField(
        controller: _inlineNote,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'e.g. PO sent, arriving Friday',
          hintStyle: const TextStyle(color: Color(0xFFAAA19B)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: const BorderSide(color: Color(0xFFE8E2DC)),
          ),
        ),
      ),
    );
    final buttons = [
      OutlinedButton(
        onPressed: _reviewing.contains(request.id)
            ? null
            : () {
                if (_inlineNote.text.trim().isEmpty) {
                  AppToast.error(
                    context,
                    'Add a note before rejecting this request.',
                  );
                  return;
                }
                unawaited(
                  _review(
                    request,
                    approve: false,
                    inlineNote: _inlineNote.text.trim(),
                  ),
                );
              },
        child: const Text('Reject', style: TextStyle(color: Color(0xFFD11A1A))),
      ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC83D08)),
        onPressed: _reviewing.contains(request.id) || request.hasStockConflict
            ? null
            : () => unawaited(
                _review(
                  request,
                  approve: true,
                  inlineNote: _inlineNote.text.trim(),
                ),
              ),
        child: Text(switch (request.type) {
          InventoryApprovalType.discount => 'Approve discount',
          InventoryApprovalType.restock => 'Approve & add stock',
          InventoryApprovalType.writeOff => 'Approve & write off',
        }),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              noteField,
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: buttons,
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: noteField),
            const SizedBox(width: 8),
            buttons.first,
            const SizedBox(width: 8),
            buttons.last,
          ],
        );
      },
    );
  }

  String _roleLabel(String value) => switch (value.toLowerCase()) {
    'cashier' => 'Cashier',
    'helper' || 'order_helper' => 'Order helper',
    'admin' => 'Administrator',
    _ => value,
  };

  Widget _discountApprovalBody(InventoryApprovalRequest request) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 34,
        runSpacing: 12,
        children: [
          _metric('Proposed discount', request.discountDisplay, large: true),
          _metric('Customer saves', _money(request.discountAmount)),
          _metric('New total', _money(request.resultingTotal)),
        ],
      ),
      const SizedBox(height: 24),
      if (request.cartItems.isNotEmpty) ...[
        Text(
          'Cart ${request.checkoutToken?.isNotEmpty == true ? request.checkoutToken : ''}',
          style: const TextStyle(color: Color(0xFF827872), fontSize: 12),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: _outlineDecoration(),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final item in request.cartItems) ...[
                _approvalCartItemRow(item),
                const Divider(height: 1, color: Color(0xFFE8E2DC)),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Subtotal',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      _money(request.subtotalAmount),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      if (request.reason?.trim().isNotEmpty == true) ...[
        const SizedBox(height: 22),
        _textDetail("Cashier’s note", request.reason!),
      ],
      if (request.note?.trim().isNotEmpty == true) ...[
        const SizedBox(height: 14),
        _textDetail('Notes', request.note!),
      ],
      if (request.status != InventoryApprovalStatus.pending) ...[
        const SizedBox(height: 24),
        _decisionBanner(request),
      ],
    ],
  );

  Widget _approvalCartItemRow(Map<String, dynamic> item) {
    final productId = item['product_id']?.toString();
    final imageUrl = _productImageUrl(productId);
    final name = item['product_name']?.toString() ?? 'Item';
    final quantity = (item['quantity'] as num?)?.toDouble() ?? 0;
    final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
    final total = (item['line_total'] as num?)?.toDouble() ?? quantity * price;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          _productImage(imageUrl, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Text(
            '${_qty(quantity)} × ${_money(price)}',
            style: const TextStyle(color: Color(0xFF827872), fontSize: 12),
          ),
          const SizedBox(width: 20),
          Text(
            _money(total),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  String? _productImageUrl(String? productId) {
    if (productId == null) return null;
    for (final item in widget.controller.allItems) {
      if (item.id == productId && item.imageUrl.isNotEmpty) {
        return item.imageUrl;
      }
    }
    return null;
  }

  Widget _productImage(String? url, {double size = 56}) => Container(
    width: size,
    height: size,
    decoration: _outlineDecoration(),
    clipBehavior: Clip.antiAlias,
    child: url == null
        ? const Icon(LucideIcons.package, color: Color(0xFFAAA19B), size: 22)
        : Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const Icon(
              LucideIcons.package,
              color: Color(0xFFAAA19B),
              size: 22,
            ),
          ),
  );

  Widget _inventoryApprovalBody(InventoryApprovalRequest request) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 620;
          final main = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _productImage(_productImageUrl(request.productId), size: 64),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          request.productName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          request.productSku,
                          style: const TextStyle(
                            color: Color(0xFF827872),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F5F3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _metric('On hand', _qty(request.currentStock)),
                    ),
                    Expanded(
                      child: _metric(
                        request.type == InventoryApprovalType.restock
                            ? 'Add'
                            : 'Remove',
                        '${request.type == InventoryApprovalType.restock ? '+' : '−'}${_qty(request.quantity)}',
                        valueColor:
                            request.type == InventoryApprovalType.restock
                            ? const Color(0xFF078443)
                            : const Color(0xFFD11A1A),
                      ),
                    ),
                    Expanded(
                      child: _metric('After', _stockAfterLabel(request)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _textDetail(
                'Reason',
                request.reason?.isNotEmpty == true ? request.reason! : '—',
              ),
              if (request.note?.isNotEmpty == true) ...[
                const SizedBox(height: 18),
                _textDetail('Notes', request.note!),
              ],
              if (request.hasStockConflict) ...[
                const SizedBox(height: 18),
                const Text(
                  'This write-off exceeds available stock.',
                  style: TextStyle(color: Color(0xFFD11A1A)),
                ),
              ],
            ],
          );
          final proof = _supportingImage(request);
          return narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [main, const SizedBox(height: 20), proof],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: main),
                    const SizedBox(width: 24),
                    SizedBox(width: 190, child: proof),
                  ],
                );
        },
      ),
      if (request.status != InventoryApprovalStatus.pending) ...[
        const SizedBox(height: 24),
        _decisionBanner(request),
      ],
    ],
  );

  String _stockAfterLabel(InventoryApprovalRequest request) {
    for (final item in widget.controller.allItems) {
      if (item.id == request.productId) {
        return '${_qty(request.resultingStock)} /${_qty(item.maxQuantity)}';
      }
    }
    return _qty(request.resultingStock);
  }

  Widget _supportingImage(InventoryApprovalRequest request) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Supporting image',
        style: TextStyle(color: Color(0xFF827872), fontSize: 12),
      ),
      const SizedBox(height: 8),
      Container(
        height: 190,
        width: double.infinity,
        decoration: _outlineDecoration(),
        child: request.hasProof
            ? FutureBuilder<String?>(
                future: _proofUrl(request),
                builder: (context, snapshot) {
                  final url = snapshot.data;
                  if (url == null) {
                    return Center(
                      child: snapshot.connectionState == ConnectionState.done
                          ? const Text('Image unavailable')
                          : const CircularProgressIndicator(),
                    );
                  }
                  return InkWell(
                    onTap: () => _openProof(request),
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Center(child: Text('Image unavailable')),
                    ),
                  );
                },
              )
            : const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.imageOff, color: Color(0xFFAAA19B)),
                  SizedBox(height: 8),
                  Text(
                    'No image attached',
                    style: TextStyle(color: Color(0xFFAAA19B), fontSize: 12),
                  ),
                ],
              ),
      ),
    ],
  );

  Widget _metric(
    String label,
    String value, {
    bool large = false,
    Color? valueColor,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFF827872), fontSize: 12),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: TextStyle(
          color: valueColor ?? const Color(0xFF171717),
          fontSize: large ? 28 : 17,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  Widget _textDetail(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFF827872), fontSize: 12),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(color: Color(0xFF171717), fontSize: 13),
      ),
    ],
  );

  Widget _decisionBanner(InventoryApprovalRequest request) {
    final approved = request.status == InventoryApprovalStatus.approved;
    final color = approved ? const Color(0xFF078443) : const Color(0xFFD11A1A);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${approved ? 'Approved' : 'Rejected'} by ${request.reviewedByName ?? 'Administrator'}'
            '${request.reviewedAt == null ? '' : ' · ${_when(request.reviewedAt!)}'}',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (request.reviewNote?.trim().isNotEmpty == true)
            Text(
              '“${request.reviewNote}”',
              style: TextStyle(color: color, fontSize: 13),
            ),
        ],
      ),
    );
  }

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
