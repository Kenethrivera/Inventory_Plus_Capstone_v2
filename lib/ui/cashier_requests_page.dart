import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/inventory.dart';
import '../logic/inventory_approval.dart';
import '../logic/inventory_controller.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import 'widgets/app_styled_dropdown.dart';
import 'widgets/app_toast.dart';
import 'widgets/approval_proof_picker.dart';

const _bg = Color(0xFFF7F6F4);
const _ink = Color(0xFF1B1A18);
const _muted = Color(0xFF80746E);
const _border = Color(0xFFE8E1DA);
const _orange = Color(0xFFC83D08);

class CashierRequestsPage extends StatefulWidget {
  const CashierRequestsPage({
    super.key,
    required this.controller,
    required this.onOpenRegister,
    this.approvalChanges,
  });
  final InventoryController controller;
  final VoidCallback onOpenRegister;
  final Stream<void>? approvalChanges;

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
    _discountStream = widget.controller.streamDiscountApproval();
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
      /* Retry is shown in the list. */
    }
  }

  Future<void> _newRequest() async {
    final sent = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close new request',
      barrierColor: Colors.black.withValues(alpha: .35),
      pageBuilder: (_, _, _) => Align(
        alignment: Alignment.centerRight,
        child: _NewRequestPanel(controller: widget.controller),
      ),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      ),
    );
    if (sent == true && mounted) {
      AppToast.success(context, 'Request sent for approval.');
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    body: RefreshIndicator(
      onRefresh: _refresh,
      color: _orange,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 34, 24, 56),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1060),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'My requests',
                              style: TextStyle(
                                fontSize: 27,
                                fontWeight: FontWeight.w700,
                                color: _ink,
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              'Restock and write-off requests you’ve sent, plus discount approvals.',
                              style: TextStyle(fontSize: 16, color: _muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _newRequest,
                        style: FilledButton.styleFrom(
                          backgroundColor: _orange,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 19,
                            vertical: 15,
                          ),
                        ),
                        icon: const Icon(Icons.add, size: 19),
                        label: const Text('New'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  StreamBuilder<InventoryApprovalRequest?>(
                    stream: _discountStream,
                    builder: (context, discountSnapshot) =>
                        FutureBuilder<List<InventoryApprovalRequest>>(
                          future: _history,
                          builder: (context, historySnapshot) {
                            final requests = [...?historySnapshot.data];
                            final discount = discountSnapshot.data;
                            if (discount != null) {
                              requests.removeWhere((r) => r.id == discount.id);
                              requests.add(discount);
                            }
                            requests.sort(
                              (a, b) => b.requestedAt.compareTo(a.requestedAt),
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
                                const SizedBox(height: 15),
                                if (historySnapshot.connectionState !=
                                        ConnectionState.done &&
                                    requests.isEmpty)
                                  const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(28),
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
                                  ),
                                for (final request in shown) ...[
                                  _card(request),
                                  const SizedBox(height: 10),
                                ],
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

  Widget _chip(String label, int count, InventoryApprovalStatus? status) {
    final selected = _filter == status;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: InkWell(
        onTap: () => setState(() => _filter = status),
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? _orange : Colors.white,
            border: Border.all(color: selected ? _orange : _border),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(
            '$label $count',
            style: TextStyle(
              color: selected ? Colors.white : _ink,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
      borderRadius: BorderRadius.circular(14),
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

  Widget _card(InventoryApprovalRequest request) {
    final item = widget.controller.allItems
        .where((item) => item.id == request.productId)
        .firstOrNull;
    final color = switch (request.status) {
      InventoryApprovalStatus.pending => const Color(0xFFB45309),
      InventoryApprovalStatus.approved => const Color(0xFF15803D),
      InventoryApprovalStatus.rejected => const Color(0xFFB42318),
    };
    final detail = request.isDiscount
        ? 'Discount · ${_relativeTime(request.requestedAt)}'
        : '${request.type.label} · ${_quantity(request.quantity)} ${request.unit} · '
              '${request.reason ?? 'No reason'} · ${_relativeTime(request.requestedAt)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: _bg,
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(9),
            ),
            child: item?.imageUrl.isNotEmpty == true
                ? Image.network(
                    item!.imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.inventory_2_outlined, color: _muted),
                  )
                : Icon(
                    request.isDiscount
                        ? Icons.percent
                        : Icons.inventory_2_outlined,
                    color: _muted,
                  ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.isDiscount
                      ? '${request.discountDisplay} discount'
                      : request.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 14),
                ),
                if (request.reviewNote?.trim().isNotEmpty == true)
                  Text(
                    'Admin note: ${request.reviewNote}',
                    style: const TextStyle(color: _muted, fontSize: 13),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .07),
              border: Border.all(color: color.withValues(alpha: .24)),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              request.displayStatus,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
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

  Future<void> _pickPhoto() async {
    if (_picking || _submitting) return;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
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
      _productError = product == null ? 'Choose a product.' : null;
      _quantityError = quantityError;
      _photoError = _type == InventoryApprovalType.writeOff && _photo == null
          ? 'A photo is required for write-off requests.'
          : null;
    });
    if (_productError != null ||
        _quantityError != null ||
        _photoError != null) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final operationId = widget.controller.newOperationId(
        'inventory-approval',
      );
      final photo = _photo;
      final proofPath = photo == null
          ? null
          : await widget.controller.uploadApprovalEvidence(
              operationId: operationId,
              bytes: photo.bytes,
              fileName: photo.fileName,
              mimeType: photo.mimeType,
            );
      await widget.controller.submitInventoryApprovalRequest(
        operationId: operationId,
        type: _type,
        productId: product!.id,
        quantity: quantity!,
        reason: _reason,
        note: _notes.text,
        proofStoragePath: proofPath,
        proofFileName: photo?.fileName,
        proofMimeType: photo?.mimeType,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Cashier stock request failed',
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
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 20, 22, 19),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'New request',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              color: _ink,
                            ),
                          ),
                          SizedBox(height: 5),
                          Text(
                            'An administrator will approve or reject it.',
                            style: TextStyle(fontSize: 16, color: _muted),
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
                  padding: const EdgeInsets.fromLTRB(30, 25, 30, 28),
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
                    const SizedBox(height: 23),
                    _label('Product'),
                    const SizedBox(height: 8),
                    AppStyledDropdown<String>(
                      value: selected?.id,
                      hint: const Text('Select a product...'),
                      decoration: _decoration(),
                      style: const TextStyle(fontSize: 16),
                      items: items
                          .map(
                            (item) => DropdownMenuItem(
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
                        style: const TextStyle(color: _muted, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 23),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 138,
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
                        const SizedBox(width: 15),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _label('Reason'),
                              const SizedBox(height: 8),
                              AppStyledDropdown<String>(
                                value: _reason,
                                decoration: _decoration(),
                                style: const TextStyle(fontSize: 16),
                                items:
                                    (_type == InventoryApprovalType.restock
                                            ? _restockReasons
                                            : _writeOffReasons)
                                        .map(
                                          (reason) => DropdownMenuItem(
                                            value: reason,
                                            child: Text(reason),
                                          ),
                                        )
                                        .toList(),
                                onChanged: _submitting
                                    ? null
                                    : (value) => setState(
                                        () => _reason = value ?? _reason,
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 23),
                    _label('Notes'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _notes,
                      enabled: !_submitting,
                      minLines: 3,
                      maxLines: 5,
                      decoration: _decoration(
                        hint:
                            'What did you see? Anything the admin should know?',
                      ),
                    ),
                    const SizedBox(height: 26),
                    RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 15, color: _ink),
                        children: [
                          const TextSpan(text: 'Supporting photo'),
                          TextSpan(
                            text: _type == InventoryApprovalType.writeOff
                                ? ' (required)'
                                : ' (optional)',
                            style: const TextStyle(color: _muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _photoBox(),
                    _error(_photoError),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 17, 30, 17),
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
                          horizontal: 18,
                          vertical: 14,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _submitting ? null : () => _submit(items),
                      style: FilledButton.styleFrom(
                        backgroundColor: _orange,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 19,
                          vertical: 14,
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
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF1E9) : Colors.white,
          border: Border.all(color: selected ? _orange : _border),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: selected ? _orange : _ink,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoBox() => InkWell(
    onTap: _picking || _submitting ? null : _pickPhoto,
    borderRadius: BorderRadius.circular(15),
    child: Container(
      height: 116,
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(15),
      ),
      child: _picking
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : _photo == null
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.add_photo_alternate_outlined,
                  color: _muted,
                  size: 26,
                ),
                SizedBox(height: 7),
                Text(
                  'Take or upload a photo',
                  style: TextStyle(color: _muted, fontSize: 15),
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
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _photo = null),
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
      fontSize: 15,
      fontWeight: FontWeight.w500,
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
    hintStyle: const TextStyle(color: _muted, fontSize: 15),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _orange),
    ),
  );
}
