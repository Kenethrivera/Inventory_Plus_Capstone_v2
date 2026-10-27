import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/history_pagination_footer.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

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
          AppErrorMapper.message(
            error,
            fallback: AppErrorCategory.dataLoad,
          ),
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
            AppErrorMapper.message(
              error,
              fallback: AppErrorCategory.dataLoad,
            ),
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
            if (!conflict) ...[
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
          AppErrorMapper.message(
            error,
            fallback: AppErrorCategory.dataSave,
          ),
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
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            children: records.map(_compactApprovalCard).toList(growable: false),
          );
        }
        const actionsWidth = 104.0;
        final flexibleWidth = constraints.maxWidth - 76 - actionsWidth;
        final widths = <double>[
          flexibleWidth * 0.10,
          flexibleWidth * 0.16,
          flexibleWidth * 0.14,
          flexibleWidth * 0.16,
          flexibleWidth * 0.14,
          flexibleWidth * 0.11,
          flexibleWidth * 0.19,
          actionsWidth,
        ];
        return SizedBox(
          width: constraints.maxWidth,
          child: DataTable(
            horizontalMargin: 10,
            columnSpacing: 8,
            headingRowHeight: 40,
            dataRowMinHeight: 54,
            dataRowMaxHeight: 54,
            dividerThickness: 1,
            headingRowColor: const WidgetStatePropertyAll(Color(0xFFF8FAFC)),
            columns: [
              DataColumn(label: _headerCell('TYPE', widths[0])),
              DataColumn(label: _headerCell('REQUEST', widths[1])),
              DataColumn(label: _headerCell('REQUESTED BY', widths[2])),
              DataColumn(label: _headerCell('DETAILS', widths[3])),
              DataColumn(label: _headerCell('REASON', widths[4])),
              DataColumn(label: _headerCell('STATUS', widths[5])),
              DataColumn(label: _headerCell('REQUESTED AT', widths[6])),
              DataColumn(label: _headerCell('ACTIONS', widths[7])),
            ],
            rows: records
                .map((request) => _row(request, widths))
                .toList(growable: false),
          ),
        );
      },
    );
  }

  DataRow _row(InventoryApprovalRequest request, List<double> widths) {
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
          SizedBox(
            width: widths[0],
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(request.type.label, _typeColor(request.type)),
            ),
          ),
        ),
        DataCell(_requestTableCell(request, widths[1])),
        DataCell(_bodyCell(request.requestedByName, widths[2], strong: true)),
        DataCell(
          _bodyCell(
            request.isDiscount
                ? '${_money(request.subtotalAmount)} → '
                      '${_money(request.resultingTotal)}'
                : '${request.type == InventoryApprovalType.restock ? '+' : '-'}'
                      '${_qty(request.quantity)} ${request.unit}',
            widths[3],
            strong: true,
          ),
        ),
        DataCell(
          _bodyCell(
            request.reason?.trim().isNotEmpty == true ? request.reason! : '—',
            widths[4],
          ),
        ),
        DataCell(
          SizedBox(
            width: widths[5],
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(
                request.displayStatus,
                request.usedAt != null
                    ? const Color(0xFF475569)
                    : _statusColor(request.status),
              ),
            ),
          ),
        ),
        DataCell(_bodyCell(_when(request.requestedAt), widths[6])),
        DataCell(
          SizedBox(
            width: widths[7],
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
                    onPressed: busy || request.hasStockConflict
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
                    onPressed: busy
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

  Widget _requestTableCell(InventoryApprovalRequest request, double width) =>
      SizedBox(
        width: width,
        child: Row(
          children: [
            Expanded(
              child: Text(
                request.isDiscount
                    ? request.discountDisplay
                    : request.productName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF334155),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  fontFamily: _font,
                ),
              ),
            ),
            if (!request.isDiscount && request.hasProof) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'View proof',
                child: InkWell(
                  onTap: () => _openProof(request),
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(LucideIcons.image, color: _blue, size: 15),
                  ),
                ),
              ),
            ],
          ],
        ),
      );

  Widget _compactApprovalCard(InventoryApprovalRequest request) {
    final busy = _reviewing.contains(request.id);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _chip(request.type.label, _typeColor(request.type)),
                    const SizedBox(width: 7),
                    _chip(request.displayStatus, _statusColor(request.status)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  request.isDiscount
                      ? '${request.discountDisplay} · '
                            '${_money(request.subtotalAmount)} → '
                            '${_money(request.resultingTotal)}'
                      : '${request.productName} · '
                            '${request.type == InventoryApprovalType.restock ? '+' : '-'}'
                            '${_qty(request.quantity)} ${request.unit}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontFamily: _font,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${request.requestedByName} · ${_when(request.requestedAt)}',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                    fontFamily: _font,
                  ),
                ),
              ],
            ),
          ),
          Row(
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
                  label: 'Approve request',
                  icon: LucideIcons.check,
                  color: const Color(0xFF15803D),
                  onPressed: busy || request.hasStockConflict
                      ? null
                      : () => _review(request, approve: true),
                ),
                const SizedBox(width: 4),
                _actionButton(
                  label: 'Reject request',
                  icon: LucideIcons.x,
                  color: const Color(0xFFDC2626),
                  onPressed: busy
                      ? null
                      : () => _review(request, approve: false),
                ),
              ],
            ],
          ),
        ],
      ),
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
      width: 28,
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
