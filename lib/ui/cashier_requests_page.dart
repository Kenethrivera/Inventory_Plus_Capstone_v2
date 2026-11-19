import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/inventory.dart';
import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import 'scanner_search_page.dart';
import 'widgets/app_styled_dropdown.dart';
import 'widgets/app_toast.dart';
import 'widgets/approval_proof_picker.dart';

const _bg = Color(0xFFF7F6F4);
const _ink = Color(0xFF1B1A18);
const _muted = Color(0xFF80746E);
const _border = Color(0xFFE8E1DA);
const _orange = Color(0xFFC83D08);
const _tableHeading = Color(0xFFF5F3F1);

/// Opens the same inventory request drawer for authorized staff roles.
/// The authenticated controller determines the requester.
Future<bool> showSharedStockRequestDialog({
  required BuildContext context,
  required InventoryController controller,
}) async {
  final sent = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close new request',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    pageBuilder: (_, _, _) => Align(
      alignment: Alignment.centerRight,
      child: _NewRequestPanel(controller: controller),
    ),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
      child: child,
    ),
  );

  return sent == true;
}

class CashierRequestsPage extends StatefulWidget {
  const CashierRequestsPage({
    super.key,
    required this.controller,
    required this.onOpenRegister,
    this.approvalChanges,
    this.showDiscountApprovals = true,
  });

  final InventoryController controller;
  final VoidCallback onOpenRegister;
  final Stream<void>? approvalChanges;
  final bool showDiscountApprovals;

  @override
  State<CashierRequestsPage> createState() => _CashierRequestsPageState();
}

class _CashierRequestsPageState extends State<CashierRequestsPage> {
  late Future<List<InventoryApprovalRequest>> _history;
  late final Stream<InventoryApprovalRequest?> _discountStream;
  StreamSubscription<void>? _subscription;
  InventoryApprovalStatus? _filter;

  @override
  void initState() {
    super.initState();
    _history = widget.controller.fetchMyInventoryApprovalRequests();
    _discountStream = widget.showDiscountApprovals
        ? widget.controller.streamDiscountApproval()
        : Stream<InventoryApprovalRequest?>.value(null);
    _subscription = widget.approvalChanges?.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final next = widget.controller.fetchMyInventoryApprovalRequests();
    if (mounted) setState(() => _history = next);
    try {
      await next;
    } catch (_) {
      // The retry state is displayed in the requests table.
    }
  }

  Future<void> _newRequest() async {
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
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      backgroundColor: _bg,
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: _orange,
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
                constraints: const BoxConstraints(maxWidth: 1160),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'My requests',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: _ink,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                widget.showDiscountApprovals
                                    ? 'Restock, write-off, and discount approvals.'
                                    : 'Restock and write-off requests you’ve sent.',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: _muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: _newRequest,
                          style: FilledButton.styleFrom(
                            backgroundColor: _ink,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                              horizontal: mobile ? 12 : 17,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                          icon: const Icon(Icons.add, size: 17),
                          label: Text(mobile ? 'New' : 'New request'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    StreamBuilder<InventoryApprovalRequest?>(
                      stream: _discountStream,
                      builder: (context, discountSnapshot) =>
                          FutureBuilder<List<InventoryApprovalRequest>>(
                            future: _history,
                            builder: (context, historySnapshot) {
                              final requests = [...?historySnapshot.data];
                              final discount = discountSnapshot.data;
                              if (discount != null) {
                                requests.removeWhere(
                                  (r) => r.id == discount.id,
                                );
                                requests.add(discount);
                              }
                              requests.sort(
                                (a, b) =>
                                    b.requestedAt.compareTo(a.requestedAt),
                              );
                              final shown = _filter == null
                                  ? requests
                                  : requests
                                        .where((r) => r.status == _filter)
                                        .toList();
                              int count(InventoryApprovalStatus? status) =>
                                  status == null
                                  ? requests.length
                                  : requests
                                        .where((r) => r.status == status)
                                        .length;

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        _chip('All', count(null), null),
                                        for (final status
                                            in InventoryApprovalStatus.values)
                                          _chip(
                                            status.label,
                                            count(status),
                                            status,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  if (historySnapshot.connectionState !=
                                          ConnectionState.done &&
                                      requests.isEmpty)
                                    const Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(32),
                                        child: CircularProgressIndicator(
                                          color: _orange,
                                        ),
                                      ),
                                    )
                                  else if (historySnapshot.hasError)
                                    _message(
                                      'Could not load your requests.',
                                      retry: true,
                                    )
                                  else if (shown.isEmpty)
                                    _message(
                                      _filter == null
                                          ? 'No requests yet.'
                                          : 'No ${_filter!.label.toLowerCase()} requests.',
                                    )
                                  else
                                    _requestsTable(shown),
                                ],
                              );
                            },
                          ),
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

  Widget _chip(String label, int count, InventoryApprovalStatus? status) {
    final selected = _filter == status;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        onTap: () => setState(() => _filter = status),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? _ink : Colors.white,
            border: Border.all(color: selected ? _ink : _border),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '$label  $count',
            style: TextStyle(
              fontSize: 12,
              color: selected ? Colors.white : _ink,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(String message, {bool retry = false}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(message, style: const TextStyle(color: _muted)),
        ),
        if (retry) TextButton(onPressed: _refresh, child: const Text('Retry')),
      ],
    ),
  );

  Color _statusColor(InventoryApprovalStatus status) => switch (status) {
    InventoryApprovalStatus.pending => const Color(0xFFB45309),
    InventoryApprovalStatus.approved => const Color(0xFF15803D),
    InventoryApprovalStatus.rejected => const Color(0xFFB42318),
  };

  Widget _statusBadge(InventoryApprovalRequest request) {
    final color = _statusColor(request.status);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.26)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          request.displayStatus,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _requestsTable(List<InventoryApprovalRequest> requests) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A compact card layout avoids horizontal scrolling on phones and
        // narrower tablet-sized windows.
        if (constraints.maxWidth < 900) {
          return Column(
            children: [
              for (var index = 0; index < requests.length; index++) ...[
                _mobileRequestCard(requests[index]),
                if (index != requests.length - 1) const SizedBox(height: 9),
              ],
            ],
          );
        }

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: const {
              0: FlexColumnWidth(3.0),
              1: FlexColumnWidth(1.05),
              2: FlexColumnWidth(1.35),
              3: FlexColumnWidth(2.1),
              4: FlexColumnWidth(1.25),
              5: FlexColumnWidth(1.25),
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(color: _tableHeading),
                children: [
                  _requestTableHeader('Product / request'),
                  _requestTableHeader('Type'),
                  _requestTableHeader('Quantity / discount'),
                  _requestTableHeader('Reason / notes'),
                  _requestTableHeader('Submitted'),
                  _requestTableHeader('Status'),
                ],
              ),
              for (var index = 0; index < requests.length; index++)
                _requestTableRow(requests[index], index),
            ],
          ),
        );
      },
    );
  }

  Widget _requestTableHeader(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 15),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: _muted,
      ),
    ),
  );

  Widget _requestTableCell(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 15),
    child: child,
  );

  TableRow _requestTableRow(InventoryApprovalRequest request, int index) {
    final note = request.note?.trim() ?? '';
    final adminNote = request.reviewNote?.trim() ?? '';
    final reason = request.reason?.trim() ?? '';
    return TableRow(
      decoration: BoxDecoration(
        color: index.isEven ? Colors.white : const Color(0xFFFCFBFA),
        border: const Border(top: BorderSide(color: _border, width: 0.7)),
      ),
      children: [
        _requestTableCell(
          Row(
            children: [
              _requestThumbnail(request),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.isDiscount
                          ? '${request.discountDisplay} discount'
                          : request.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      request.isDiscount
                          ? 'Checkout approval'
                          : request.productSku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _requestTableCell(
          Text(
            request.type.label,
            style: const TextStyle(fontSize: 12, color: _ink),
          ),
        ),
        _requestTableCell(
          Text(
            request.isDiscount
                ? request.discountDisplay
                : '${_quantity(request.quantity)} ${request.unit}',
            style: const TextStyle(fontSize: 12, color: _ink),
          ),
        ),
        _requestTableCell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                reason.isEmpty ? '—' : reason,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: _ink),
              ),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 3),
                Tooltip(
                  message: note,
                  child: Text(
                    'Note: $note',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                ),
              ],
              if (adminNote.isNotEmpty) ...[
                const SizedBox(height: 3),
                Tooltip(
                  message: adminNote,
                  child: Text(
                    'Admin: $adminNote',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                ),
              ],
            ],
          ),
        ),
        _requestTableCell(
          Text(
            _relativeTime(request.requestedAt),
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
        ),
        _requestTableCell(
          Align(alignment: Alignment.centerLeft, child: _statusBadge(request)),
        ),
      ],
    );
  }

  Widget _mobileRequestCard(InventoryApprovalRequest request) {
    final reason = request.reason?.trim() ?? '';
    final note = request.note?.trim() ?? '';
    final adminNote = request.reviewNote?.trim() ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _requestThumbnail(request),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.isDiscount
                          ? '${request.discountDisplay} discount'
                          : request.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      request.isDiscount
                          ? 'Checkout approval'
                          : request.productSku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _statusBadge(request),
            ],
          ),
          const SizedBox(height: 11),
          const Divider(height: 1, color: _border),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _mobileRequestField('Type', request.type.label)),
              const SizedBox(width: 8),
              Expanded(
                child: _mobileRequestField(
                  'Quantity / discount',
                  request.isDiscount
                      ? request.discountDisplay
                      : '${_quantity(request.quantity)} ${request.unit}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _mobileRequestField(
                  'Reason',
                  reason.isEmpty ? '—' : reason,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _mobileRequestField(
                  'Submitted',
                  _relativeTime(request.requestedAt),
                ),
              ),
            ],
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 9),
            _mobileRequestField('Notes', note),
          ],
          if (adminNote.isNotEmpty) ...[
            const SizedBox(height: 9),
            _mobileRequestField('Admin note', adminNote),
          ],
        ],
      ),
    );
  }

  Widget _mobileRequestField(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10, color: _muted)),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(fontSize: 12, color: _ink),
        softWrap: true,
      ),
    ],
  );

  Widget _requestThumbnail(InventoryApprovalRequest request) {
    final item = widget.controller.allItems
        .where((product) => product.id == request.productId)
        .firstOrNull;
    return Container(
      width: 38,
      height: 38,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _bg,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: item?.imageUrl.isNotEmpty == true
          ? Image.network(
              item!.imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(
                Icons.inventory_2_outlined,
                size: 18,
                color: _muted,
              ),
            )
          : Icon(
              request.isDiscount ? Icons.percent : Icons.inventory_2_outlined,
              color: _muted,
              size: 18,
            ),
    );
  }
}

String _quantity(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

String _relativeTime(DateTime date) {
  final elapsed = DateTime.now().difference(date);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} minutes ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours} hours ago';
  if (elapsed.inDays < 7) return '${elapsed.inDays} days ago';
  return '${date.month}/${date.day}/${date.year}';
}

class _NewRequestPanel extends StatefulWidget {
  const _NewRequestPanel({required this.controller});

  final InventoryController controller;

  @override
  State<_NewRequestPanel> createState() => _NewRequestPanelState();
}

class _NewRequestPanelState extends State<_NewRequestPanel> {
  static const _restockReasons = [
    'Low shelf stock',
    'Below stock threshold',
    'Customer demand',
    'Shelf is empty',
    'Other',
  ];
  static const _writeOffReasons = ['Damaged', 'Expired', 'Lost', 'Other'];

  final _qty = TextEditingController();
  final _notes = TextEditingController();
  final _picker = ImagePicker();
  InventoryApprovalType _type = InventoryApprovalType.restock;
  String _reason = _restockReasons.first;
  String? _productId;
  ApprovalProofSelection? _photo;
  bool _picking = false;
  bool _submitting = false;
  String? _productError;
  String? _quantityError;
  String? _photoError;
  String? _notesError;

  bool get _notesRequired => _reason.trim().toLowerCase() == 'other';

  @override
  void dispose() {
    _qty.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _selectType(InventoryApprovalType type) {
    if (_submitting) return;
    setState(() {
      _type = type;
      _reason = type == InventoryApprovalType.restock
          ? _restockReasons.first
          : _writeOffReasons.first;
      _quantityError = null;
      _photoError = null;
      _notesError = null;
      _notesError = _notesRequired && _notes.text.trim().isEmpty
          ? 'Notes are required when the reason is Other.'
          : null;
    });
  }

  String? _mimeType(XFile file) {
    final mime = file.mimeType?.toLowerCase();
    if (const {
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    }.contains(mime)) {
      return mime;
    }
    final name = file.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.gif')) return 'image/gif';
    return null;
  }

  // Matches the Inventory product-image source dialog visually. Evidence
  // continues to use device images/camera so the existing upload API stays
  // unchanged; remote URL submissions are intentionally not introduced.
  Future<void> _pickPhoto() async {
    if (_picking || _submitting) return;
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 22,
                        color: _orange,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'Import image',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Choose where the supporting photo comes from.',
                  style: TextStyle(fontSize: 13, color: _muted),
                ),
                const SizedBox(height: 22),
                _imageSourceOption(
                  dialogContext,
                  source: ImageSource.gallery,
                  icon: Icons.image_outlined,
                  title: 'Local image',
                  subtitle: 'Choose a photo from this device',
                ),
                const SizedBox(height: 10),
                _imageSourceOption(
                  dialogContext,
                  source: ImageSource.camera,
                  icon: Icons.photo_camera_outlined,
                  title: 'Take photo',
                  subtitle: 'Capture supporting evidence using the camera',
                ),
                const SizedBox(height: 18),
                const Text(
                  'Images must be JPG, PNG, WebP, or GIF, up to 10 MB.',
                  style: TextStyle(fontSize: 12, color: _muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    setState(() => _picking = true);
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 85);
      if (file == null) return;
      final mime = _mimeType(file);
      if (mime == null) {
        throw const FormatException('Use a JPG, PNG, WebP, or GIF image.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw const FormatException('Photo must be smaller than 10 MB.');
      }
      if (mounted) {
        setState(() {
          _photo = ApprovalProofSelection(
            bytes: bytes,
            fileName: file.name,
            mimeType: mime,
          );
          _photoError = null;
        });
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Request photo selection failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          error is FormatException
              ? error.message.toString()
              : AppErrorMapper.message(
                  error,
                  fallback: AppErrorCategory.upload,
                ),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Widget _imageSourceOption(
    BuildContext dialogContext, {
    required ImageSource source,
    required IconData icon,
    required String title,
    required String subtitle,
  }) => SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: () => Navigator.pop(dialogContext, source),
      style: OutlinedButton.styleFrom(
        backgroundColor: _bg,
        foregroundColor: _ink,
        padding: const EdgeInsets.all(14),
        side: const BorderSide(color: _border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _orange, size: 20),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 18, color: _muted),
        ],
      ),
    ),
  );

  Future<void> _scanProduct() async {
    if (_submitting) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (scannerContext) => ScannerSearchPage(
          controller: widget.controller,
          onSelectItem: (item) {
            Navigator.pop(scannerContext);
            if (!mounted) return;
            setState(() {
              _productId = item.id;
              _productError = null;
            });
          },
        ),
      ),
    );
  }

  Future<void> _submit(List<InventoryItem> items) async {
    if (_submitting) return;
    final product = items.where((item) => item.id == _productId).firstOrNull;
    final quantity = double.tryParse(_qty.text.trim());
    String? quantityError;
    if (quantity == null || !quantity.isFinite || quantity <= 0) {
      quantityError = 'Enter a quantity above 0.';
    } else if (product != null) {
      final decimals = const {
        'kg',
        'g',
        'l',
        'ml',
      }.contains(product.unit.toLowerCase());
      if (!decimals && quantity != quantity.roundToDouble()) {
        quantityError = 'Enter a whole-number quantity for ${product.unit}.';
      } else if (_type == InventoryApprovalType.writeOff &&
          quantity > product.quantity) {
        quantityError =
            'Only ${_quantity(product.quantity)} ${product.unit} is on hand.';
      }
    }
    setState(() {
      _productError = product == null
          ? 'Choose a product or scan its shelf QR.'
          : null;
      _quantityError = quantityError;
      _photoError = _photo == null
          ? 'Attach a supporting photo before submitting.'
          : null;
      _notesError = _notesRequired && _notes.text.trim().isEmpty
          ? 'Notes are required when the reason is Other.'
          : null;
    });
    if (_productError != null ||
        _quantityError != null ||
        _photoError != null ||
        _notesError != null) {
      return;
    }
    setState(() => _submitting = true);
    var requestStage = 'supporting photo upload';
    try {
      final operationId = widget.controller.newOperationId(
        'inventory-approval',
      );
      final photo = _photo!;
      final proofPath = await widget.controller.uploadApprovalEvidence(
        operationId: operationId,
        bytes: photo.bytes,
        fileName: photo.fileName,
        mimeType: photo.mimeType,
      );
      requestStage = 'stock request submission';
      await widget.controller.submitInventoryApprovalRequest(
        operationId: operationId,
        type: _type,
        productId: product!.id,
        quantity: quantity!,
        reason: _reason,
        note: _notes.text,
        proofStoragePath: proofPath,
        proofFileName: photo.fileName,
        proofMimeType: photo.mimeType,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Inventory $requestStage failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        final message = AppErrorMapper.message(
          error,
          fallback: AppErrorCategory.dataSave,
        );
        AppToast.error(
          context,
          message == AppErrorMapper.permission
              ? 'The server rejected the $requestStage. Please contact your administrator.'
              : message,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SizedBox(
      width: MediaQuery.sizeOf(context).width.clamp(0, 640).toDouble(),
      height: double.infinity,
      child: StreamBuilder<List<InventoryItem>>(
        stream: widget.controller.streamInventory(),
        builder: (context, snapshot) {
          final items = [...(snapshot.data ?? widget.controller.allItems)]
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
          final selected = items
              .where((item) => item.id == _productId)
              .firstOrNull;
          final isMobile = MediaQuery.sizeOf(context).width < 600;
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  isMobile ? 18 : 30,
                  20,
                  isMobile ? 12 : 22,
                  19,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'New request',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: _ink,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            'An administrator will approve or reject it.',
                            style: TextStyle(fontSize: 13, color: _muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    isMobile ? 18 : 30,
                    23,
                    isMobile ? 18 : 30,
                    28,
                  ),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _typeCard(
                            InventoryApprovalType.restock,
                            'Restock',
                            'Ask for more stock',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _typeCard(
                            InventoryApprovalType.writeOff,
                            'Write-off',
                            'Remove damaged or lost stock',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Expanded(child: _label('Product')),
                        TextButton.icon(
                          onPressed: _submitting ? null : _scanProduct,
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: Text(isMobile ? 'Scan QR' : 'Scan shelf QR'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    AppStyledDropdown<String>(
                      value: selected?.id,
                      hint: const Text('Select a product...'),
                      decoration: _decoration(),
                      style: const TextStyle(fontSize: 14),
                      items: items
                          .map(
                            (item) => DropdownMenuItem<String>(
                              value: item.id,
                              child: Text('${item.name} · ${item.sku}'),
                            ),
                          )
                          .toList(),
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() {
                              _productId = value;
                              _productError = null;
                            }),
                    ),
                    _error(_productError),
                    if (selected != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        '${_quantity(selected.quantity)} ${selected.unit} on hand',
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 23),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: isMobile ? 110 : 138,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Quantity'),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _qty,
                                enabled: !_submitting,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9.]'),
                                  ),
                                ],
                                decoration: _decoration(),
                                onChanged: (_) =>
                                    setState(() => _quantityError = null),
                              ),
                              _error(_quantityError),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Reason'),
                              const SizedBox(height: 8),
                              AppStyledDropdown<String>(
                                value: _reason,
                                decoration: _decoration(),
                                style: const TextStyle(fontSize: 14),
                                items:
                                    (_type == InventoryApprovalType.restock
                                            ? _restockReasons
                                            : _writeOffReasons)
                                        .map(
                                          (reason) => DropdownMenuItem<String>(
                                            value: reason,
                                            child: Text(reason),
                                          ),
                                        )
                                        .toList(),
                                onChanged: _submitting
                                    ? null
                                    : (value) => setState(() {
                                        _reason = value ?? _reason;
                                        _notesError = null;
                                      }),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        _label('Notes'),
                        const SizedBox(width: 6),
                        Text(
                          _notesRequired ? '(required)' : '(optional)',
                          style: TextStyle(
                            fontSize: 12,
                            color: _notesRequired ? _orange : _muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _notes,
                      enabled: !_submitting,
                      minLines: 3,
                      maxLines: 5,
                      decoration: _decoration(
                        hint: _notesRequired
                            ? 'Describe your other reason (required)'
                            : 'What did you see? Anything the admin should know?',
                      ),
                      onChanged: (_) => setState(() => _notesError = null),
                    ),
                    _error(_notesError),
                    const SizedBox(height: 24),
                    const Row(
                      children: [
                        Text(
                          'Supporting photo',
                          style: TextStyle(fontSize: 13, color: _ink),
                        ),
                        SizedBox(width: 5),
                        Text(
                          '(required)',
                          style: TextStyle(fontSize: 12, color: _muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _photoBox(),
                    _error(_photoError),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  isMobile ? 16 : 20,
                  17,
                  isMobile ? 16 : 30,
                  17,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _ink,
                        side: const BorderSide(color: _border),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _submitting ? null : () => _submit(items),
                      style: FilledButton.styleFrom(
                        backgroundColor: _ink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 17,
                          vertical: 13,
                        ),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Send request'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _typeCard(InventoryApprovalType type, String title, String subtitle) {
    final selected = _type == type;
    return InkWell(
      onTap: () => _selectType(type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF1E9) : Colors.white,
          border: Border.all(color: selected ? _orange : _border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: selected ? _orange : _ink,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoBox() => InkWell(
    onTap: _picking || _submitting ? null : _pickPhoto,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      height: 116,
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: _picking
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : _photo == null
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.add_photo_alternate_outlined,
                  color: _orange,
                  size: 26,
                ),
                SizedBox(height: 7),
                Text(
                  'Import supporting image',
                  style: TextStyle(color: _ink, fontSize: 13),
                ),
                SizedBox(height: 3),
                Text(
                  'JPG, PNG, WebP or GIF · Max 10 MB',
                  style: TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            )
          : Row(
              children: [
                const SizedBox(width: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _photo!.bytes,
                    width: 70,
                    height: 70,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _photo!.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  onPressed: _submitting
                      ? null
                      : () => setState(() {
                          _photo = null;
                          _photoError = null;
                        }),
                  icon: const Icon(Icons.close),
                  tooltip: 'Remove photo',
                ),
              ],
            ),
    ),
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: _ink,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _error(String? message) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            message,
            style: const TextStyle(color: Color(0xFFB42318), fontSize: 12),
          ),
        );

  InputDecoration _decoration({String? hint}) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: _muted, fontSize: 13),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _orange),
    ),
  );
}
