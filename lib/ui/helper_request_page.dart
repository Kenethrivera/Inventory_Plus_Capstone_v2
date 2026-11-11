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
  static const _restockReasons = [
    'Below stock threshold',
    'Customer demand',
    'Shelf is empty',
    'Other',
  ];
  static const _writeOffReasons = ['Damaged', 'Expired', 'Lost', 'Other'];

  final _qty = TextEditingController();
  final _notes = TextEditingController();
  final _picker = ImagePicker();
  Future<List<InventoryApprovalRequest>>? _history;
  StreamSubscription<void>? _approvalChangesSubscription;
  InventoryApprovalType _type = InventoryApprovalType.restock;
  String _reason = _restockReasons.first;
  String? _productId;
  ApprovalProofSelection? _photo;
  bool _picking = false;
  bool _submitting = false;
  String? _productError;
  String? _quantityError;
  String? _photoError;
  int _productFieldKey = 0;
  int _reasonFieldKey = 0;

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
    _qty.dispose();
    _notes.dispose();
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

  String? _mimeType(XFile file) {
    final reported = file.mimeType?.toLowerCase();
    if (const {
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/gif',
    }.contains(reported)) {
      return reported;
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
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.camera),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(LucideIcons.image),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
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
      if (!mounted) return;
      setState(() {
        _photo = ApprovalProofSelection(
          bytes: bytes,
          fileName: file.name,
          mimeType: mime,
        );
        _photoError = null;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'Stock request photo selection failed',
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
    final amount = double.tryParse(_qty.text.trim());
    final productError = product == null ? 'Choose a product.' : null;
    String? quantityError;
    if (amount == null || !amount.isFinite || amount <= 0) {
      quantityError = 'Enter a quantity above 0.';
    } else if (product != null) {
      final allowsDecimals = const {
        'kg',
        'g',
        'l',
        'ml',
      }.contains(product.unit.toLowerCase());
      if (!allowsDecimals && amount != amount.roundToDouble()) {
        quantityError = 'Enter a whole-number quantity for ${product.unit}.';
      } else if (_type == InventoryApprovalType.writeOff &&
          amount > product.quantity) {
        quantityError =
            'Only ${_quantity(product.quantity)} ${product.unit} is on hand.';
      }
    }
    final photoError = _type == InventoryApprovalType.writeOff && _photo == null
        ? 'Attach at least one photo of the affected stock.'
        : null;
    if (productError != null || quantityError != null || photoError != null) {
      setState(() {
        _productError = productError;
        _quantityError = quantityError;
        _photoError = photoError;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _productError = null;
      _quantityError = null;
      _photoError = null;
    });
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
        quantity: amount!,
        reason: _reason,
        note: _notes.text,
        proofStoragePath: proofPath,
        proofFileName: photo?.fileName,
        proofMimeType: photo?.mimeType,
      );
      if (!mounted) return;
      final typeLabel = _type.label;
      _qty.clear();
      _notes.clear();
      setState(() {
        _productId = null;
        _photo = null;
        _productFieldKey++;
        _productError = null;
        _quantityError = null;
        _photoError = null;
      });
      AppToast.success(context, '$typeLabel request submitted for review.');
      await _refresh();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Helper stock request failed',
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
  Widget build(BuildContext context) {
    return StreamBuilder<List<InventoryItem>>(
      stream: widget.controller.streamInventory(),
      builder: (context, snapshot) {
        final items = [
          ...(snapshot.data ?? widget.controller.allItems),
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final selected = items
            .where((item) => item.id == _productId)
            .firstOrNull;
        return ColoredBox(
          color: _bg,
          child: RefreshIndicator(
            color: _orange,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 30),
              children: [
                const Text(
                  'Stock request',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Spotted low shelves or damaged items? Let an administrator know.',
                  style: TextStyle(color: _muted, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _typeSelector(),
                      const SizedBox(height: 26),
                      _label('Product'),
                      const SizedBox(height: 8),
                      AppStyledDropdown<String>(
                        key: ValueKey(
                          '$_productFieldKey:${selected?.id ?? ''}',
                        ),
                        initialValue: selected?.id,
                        hint: const Text('Select a product...'),
                        decoration: _decoration(),
                        items: items
                            .map(
                              (item) => DropdownMenuItem(
                                value: item.id,
                                child: Text(
                                  '${item.name} · ${item.sku}',
                                  overflow: TextOverflow.ellipsis,
                                ),
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
                      _fieldError(_productError),
                      if (selected != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          '${_quantity(selected.quantity)} ${selected.unit} on hand',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
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
                                  onChanged: (_) {
                                    if (_quantityError != null) {
                                      setState(() => _quantityError = null);
                                    }
                                  },
                                ),
                                _fieldError(_quantityError),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _label('Reason'),
                                const SizedBox(height: 8),
                                AppStyledDropdown<String>(
                                  key: ValueKey(_reasonFieldKey),
                                  initialValue: _reason,
                                  decoration: _decoration(),
                                  items:
                                      (_type == InventoryApprovalType.restock
                                              ? _restockReasons
                                              : _writeOffReasons)
                                          .map(
                                            (reason) => DropdownMenuItem(
                                              value: reason,
                                              child: Text(
                                                reason,
                                                overflow: TextOverflow.ellipsis,
                                              ),
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
                      const SizedBox(height: 24),
                      _optionalLabel('Notes'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _notes,
                        enabled: !_submitting,
                        maxLines: 3,
                        decoration: _decoration(
                          hint:
                              'What happened, or why the extra stock is needed',
                        ),
                      ),
                      const SizedBox(height: 24),
                      _type == InventoryApprovalType.writeOff
                          ? _annotatedLabel('Photos', 'required')
                          : _optionalLabel('Photos'),
                      const SizedBox(height: 8),
                      _photoPicker(),
                      _fieldError(_photoError),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _submitting ? null : () => _submit(items),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _orange,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  'Submit ${_type == InventoryApprovalType.restock ? 'restock' : 'write-off'} request',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                const Text(
                  'My requests',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                _requestHistory(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _typeSelector() => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFFEFEDE9),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _typeButton(InventoryApprovalType.restock, 'Restock'),
        _typeButton(InventoryApprovalType.writeOff, 'Write-off'),
      ],
    ),
  );

  Widget _typeButton(InventoryApprovalType type, String label) {
    final selected = _type == type;
    return InkWell(
      onTap: _submitting
          ? null
          : () => setState(() {
              _type = type;
              _reason = type == InventoryApprovalType.restock
                  ? _restockReasons.first
                  : _writeOffReasons.first;
              _reasonFieldKey++;
              _productError = null;
              _quantityError = null;
              _photoError = null;
            }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _ink : _muted,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: _ink,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _optionalLabel(String text) => _annotatedLabel(text, 'optional');

  Widget _annotatedLabel(String text, String annotation) => RichText(
    text: TextSpan(
      style: const TextStyle(
        color: _ink,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      children: [
        TextSpan(text: '$text '),
        TextSpan(
          text: '($annotation)',
          style: const TextStyle(color: _muted, fontWeight: FontWeight.w400),
        ),
      ],
    ),
  );

  Widget _fieldError(String? message) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            message,
            style: const TextStyle(color: Color(0xFFB42318), fontSize: 12),
          ),
        );

  InputDecoration _decoration({String? hint}) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFFA29AA5), fontSize: 13),
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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

  Widget _photoPicker() {
    final photo = _photo;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _picking || _submitting ? null : _pickPhoto,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 90,
            height: 94,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFBDB6AE)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: _picking
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        photo == null
                            ? LucideIcons.imagePlus
                            : LucideIcons.refreshCw,
                        size: 20,
                        color: _muted,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        photo == null ? 'Add' : 'Replace',
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
          ),
        ),
        if (photo != null) ...[
          const SizedBox(width: 10),
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  photo.bytes,
                  width: 94,
                  height: 94,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                right: 2,
                top: 2,
                child: IconButton.filledTonal(
                  tooltip: 'Remove photo',
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 15,
                  onPressed: _submitting
                      ? null
                      : () => setState(() => _photo = null),
                  icon: const Icon(LucideIcons.x),
                ),
              ),
            ],
          ),
        ],
      ],
    );
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
                    color: _ink,
                    fontSize: 13,
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
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: statusBackground,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              status,
              style: TextStyle(
                color: statusColor,
                fontSize: 11,
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
