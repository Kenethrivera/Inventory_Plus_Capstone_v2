import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/inventory.dart';
import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_styled_dropdown.dart';
import 'widgets/approval_proof_picker.dart';
import 'scanner_search_page.dart';
import 'cashier_requests_page.dart' show showSharedStockRequestDialog;

class HelperRequestPage extends StatefulWidget {
  const HelperRequestPage({
    super.key,
    required this.controller,
    this.approvalChanges,
  });
  final InventoryController controller;
  final Stream<void>? approvalChanges;

  @override
  State<HelperRequestPage> createState() => _HelperRequestPageState();
}

class _HelperRequestPageState extends State<HelperRequestPage> {
  static const _bg = Color(0xFFF6F5F2);
  static const _ink = Color(0xFF211F1D);
  static const _muted = Color(0xFF756D67);
  static const _border = Color(0xFFE3DED7);
  static const _orange = Color(0xFFC83D08);
  Future<List<InventoryApprovalRequest>>? _history;
  StreamSubscription<void>? _approvalChangesSubscription;
  InventoryApprovalStatus? _requestFilter;

  @override
  void initState() {
    super.initState();
    _history = widget.controller.fetchMyInventoryApprovalRequests();
    _approvalChangesSubscription = widget.approvalChanges?.listen((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _approvalChangesSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final next = widget.controller.fetchMyInventoryApprovalRequests();
    setState(() => _history = next);
    try {
      await next;
    } catch (_) {
      // The request list displays a retry action.
    }
  }

  Future<void> _openNewRequest() async {
    final sent = await showSharedStockRequestDialog(
      context: context,
      controller: widget.controller,
    );

    if (!mounted) return;

    if (sent) {
      AppToast.success(context, 'Request sent for approval.');
      await _refresh();
    }
  }

  
@override
  Widget build(BuildContext context) {
    return _buildRequestDashboard();
  }



static const Color _dashboardBg = Color(0xFFF7F6F4);
  static const Color _dashboardInk = Color(0xFF1B1A18);
  static const Color _dashboardMuted = Color(0xFF80746E);
  static const Color _dashboardBorder = Color(0xFFE8E1DA);

  Widget _buildRequestDashboard() {
    final mobile = MediaQuery.sizeOf(context).width < 600;

    return ColoredBox(
      color: _dashboardBg,
      child: RefreshIndicator(
        color: _orange,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            mobile ? 16 : 24,
            mobile ? 22 : 34,
            mobile ? 16 : 24,
            56,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 954),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'My requests',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: _dashboardInk,
                                ),
                              ),
                              SizedBox(height: 5),
                              Text(
                                'Restock and write-off requests you’ve sent.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: _dashboardMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: _openNewRequest,
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('New'),
                          style: FilledButton.styleFrom(
                            backgroundColor: _orange,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 9,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    FutureBuilder<List<InventoryApprovalRequest>>(
                      future: _history,
                      builder: (context, snapshot) {
                        final requests = [...?snapshot.data]
                          ..sort(
                            (a, b) => b.requestedAt.compareTo(a.requestedAt),
                          );

                        final visibleRequests = requests.where((request) {
                          return _requestFilter == null ||
                              request.status == _requestFilter;
                        }).toList();

                        int count(InventoryApprovalStatus? status) {
                          if (status == null) return requests.length;
                          return requests
                              .where((r) => r.status == status)
                              .length;
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _helperDashboardChip(
                                    'All',
                                    count(null),
                                    null,
                                  ),
                                  for (final status
                                      in InventoryApprovalStatus.values)
                                    _helperDashboardChip(
                                      status.label,
                                      count(status),
                                      status,
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            if (snapshot.connectionState !=
                                ConnectionState.done)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(32),
                                  child: CircularProgressIndicator(
                                    color: _orange,
                                  ),
                                ),
                              )
                            else if (snapshot.hasError)
                              _historyBox(
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'Could not load your requests.',
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: _refresh,
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                ),
                              )
                            else if (visibleRequests.isEmpty)
                              _historyBox(
                                Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Center(
                                    child: Text(
                                      _requestFilter == null
                                          ? 'No requests yet.'
                                          : 'No ${_requestFilter!.label.toLowerCase()} requests.',
                                      style: const TextStyle(
                                        color: _dashboardMuted,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              for (final request in visibleRequests) ...[
                                _helperDashboardCard(request),
                                const SizedBox(height: 9),
                              ],
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _helperDashboardChip(
    String label,
    int count,
    InventoryApprovalStatus? status,
  ) {
    final selected = _requestFilter == status;

    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        onTap: () => setState(() => _requestFilter = status),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _orange : Colors.white,
            border: Border.all(color: selected ? _orange : _dashboardBorder),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$label $count',
            style: TextStyle(
              fontSize: 12,
              color: selected ? Colors.white : _dashboardInk,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _helperDashboardCard(InventoryApprovalRequest request) {
    final reason = request.reason?.trim() ?? '';
    final status = request.status;

    final statusColor = switch (status) {
      InventoryApprovalStatus.pending => const Color(0xFFB45309),
      InventoryApprovalStatus.approved => const Color(0xFF15803D),
      InventoryApprovalStatus.rejected => const Color(0xFFB42318),
    };

    final isMobile = MediaQuery.sizeOf(context).width < 600;

    final details = <String>[
      request.type.label,
      '${_quantity(request.quantity)} ${request.unit}',
      if (reason.isNotEmpty) reason,
      _helperDashboardTime(request.requestedAt),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12 : 18,
        vertical: 16,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _dashboardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _helperDashboardThumbnail(request),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.productName.isEmpty
                      ? 'Product request'
                      : request.productName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _dashboardInk,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  details.join(' · '),
                  maxLines: isMobile ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _dashboardMuted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                if (request.note?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    request.note!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _dashboardMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              border: Border.all(color: statusColor.withValues(alpha: 0.24)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              request.displayStatus,
              style: TextStyle(
                color: statusColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _helperDashboardThumbnail(InventoryApprovalRequest request) {
    final item = widget.controller.allItems
        .where((product) => product.id == request.productId)
        .firstOrNull;

    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _dashboardBg,
        border: Border.all(color: _dashboardBorder),
        borderRadius: BorderRadius.circular(9),
      ),
      child: item?.imageUrl.isNotEmpty == true
          ? Image.network(
              item!.imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: _dashboardMuted,
                );
              },
            )
          : const Icon(
              Icons.inventory_2_outlined,
              size: 20,
              color: _dashboardMuted,
            ),
    );
  }

  String _helperDashboardTime(DateTime date) {
    final elapsed = DateTime.now().difference(date);

    if (elapsed.isNegative || elapsed.inMinutes < 1) {
      return 'just now';
    }
    if (elapsed.inMinutes < 60) {
      return '${elapsed.inMinutes} minutes ago';
    }
    if (elapsed.inHours < 24) {
      return '${elapsed.inHours} hours ago';
    }
    if (elapsed.inDays < 7) {
      return '${elapsed.inDays} days ago';
    }

    return '${date.month}/${date.day}/${date.year}';
  }


  Widget _requestHistory() => FutureBuilder<List<InventoryApprovalRequest>>(
    future: _history,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(strokeWidth: 2, color: _orange),
          ),
        );
      }
      if (snapshot.hasError) {
        return _historyBox(
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Could not load your requests.',
                  style: TextStyle(color: _muted, fontSize: 13),
                ),
              ),
              TextButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        );
      }
      final requests = snapshot.data ?? const <InventoryApprovalRequest>[];
      if (requests.isEmpty) {
        return _historyBox(
          const Center(
            child: Text(
              'No requests yet.',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
          ),
        );
      }
      return _historyBox(
        Column(
          children: [
            for (var i = 0; i < requests.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: _border),
              _requestRow(requests[i]),
            ],
          ],
        ),
        padding: EdgeInsets.zero,
      );
    },
  );

  Widget _historyBox(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(16),
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(14),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _requestRow(InventoryApprovalRequest request) {
    final statusColor = switch (request.status) {
      InventoryApprovalStatus.pending => const Color(0xFF9A5B00),
      InventoryApprovalStatus.approved => const Color(0xFF047B3A),
      InventoryApprovalStatus.rejected => const Color(0xFFB42318),
    };
    final statusBackground = switch (request.status) {
      InventoryApprovalStatus.pending => const Color(0xFFFFF1CB),
      InventoryApprovalStatus.approved => const Color(0xFFE6F5EA),
      InventoryApprovalStatus.rejected => const Color(0xFFFDEBEC),
    };
    final status = request.status == InventoryApprovalStatus.pending
        ? 'In review'
        : request.status.label;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${request.type.label} · ${_quantity(request.quantity)} ${request.unit} ${request.productName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _dashboardInk,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${request.reason ?? 'No reason'} · ${_date(request.requestedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          
Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.08),
              border: Border.all(color: statusColor.withValues(alpha: 0.26)),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              request.displayStatus,
              style: TextStyle(
                color: statusColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

        ],
      ),
    );
  }

  String _quantity(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  String _date(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return '${months[value.month - 1]} ${value.day}, '
        '$hour:${value.minute.toString().padLeft(2, '0')} '
        '${value.hour < 12 ? 'AM' : 'PM'}';
  }
}
