import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/inventory.dart';
import '../../logic/inventory_approval.dart';
import '../../logic/inventory_controller.dart';
import '../../services/app_error_mapper.dart';
import '../../services/app_logger.dart';
import 'app_dialog.dart';
import 'app_toast.dart';
import 'approval_proof_picker.dart';

const String _fontFam = 'Hellix';

String _formatStockQuantity(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

void _showWriteOffToast(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  if (!context.mounted) return;
  if (isError) {
    AppToast.error(context, message);
  } else {
    AppToast.success(context, message);
  }
}

Widget _writeOffStockSummary(
  String label,
  String value,
  Color color, {
  bool alignEnd = false,
}) {
  return Column(
    crossAxisAlignment: alignEnd
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Colors.grey.shade500,
          fontFamily: _fontFam,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: color,
          fontFamily: _fontFam,
        ),
      ),
    ],
  );
}

Future<void> showWriteOffRequestDialog({
  required BuildContext context,
  required InventoryController controller,
  required InventoryItem item,
}) async {
  final currentItem = controller.findAnyItemById(item.id) ?? item;
  final qtyCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final unit = currentItem.unit;

  const reasons = ['Damaged', 'Expired', 'Lost', 'Other'];
  String reason = reasons.first;
  bool saving = false;
  bool uploadingProof = false;
  bool touched = false;
  String? error;
  ApprovalProofSelection? proof;
  final operationId = controller.newOperationId('inventory-approval');

  String? validate(String text) {
    final t = text.trim();
    if (t.isEmpty) return 'Enter the quantity to remove';
    final v = double.tryParse(t);
    if (v == null) return 'Enter a valid number';
    if (v <= 0) return 'Must be greater than 0';
    if (v > currentItem.quantity) {
      return 'Only ${_formatStockQuantity(currentItem.quantity)} $unit in stock';
    }
    return null;
  }

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final value = double.tryParse(qtyCtrl.text.trim());
        final remaining =
            (value != null && value > 0 && value <= currentItem.quantity)
            ? currentItem.quantity - value
            : null;
        final canSubmit =
            validate(qtyCtrl.text) == null && proof != null && !saving;

        Future<void> submit() async {
          touched = true;
          final err = validate(qtyCtrl.text);
          if (err != null || proof == null) {
            setDialogState(() => error = err);
            return;
          }
          setDialogState(() {
            error = null;
            saving = true;
            uploadingProof = true;
          });
          try {
            final qty = double.parse(qtyCtrl.text.trim());
            final selectedProof = proof!;
            final proofPath = await controller.uploadApprovalEvidence(
              operationId: operationId,
              bytes: selectedProof.bytes,
              fileName: selectedProof.fileName,
              mimeType: selectedProof.mimeType,
            );
            if (dialogContext.mounted) {
              setDialogState(() => uploadingProof = false);
            }
            await controller.submitInventoryApprovalRequest(
              operationId: operationId,
              type: InventoryApprovalType.writeOff,
              productId: currentItem.id,
              quantity: qty,
              reason: reason,
              note: noteCtrl.text,
              proofStoragePath: proofPath,
              proofFileName: selectedProof.fileName,
              proofMimeType: selectedProof.mimeType,
            );
            if (!context.mounted) return;
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            _showWriteOffToast(
              context,
              'Write-off request submitted. Inventory remains unchanged '
              'until Admin approval.',
            );
          } catch (e, stackTrace) {
            AppLogger.error(
              'Write-off approval request failed',
              error: e,
              stackTrace: stackTrace,
            );
            if (dialogContext.mounted) {
              setDialogState(() {
                saving = false;
                uploadingProof = false;
              });
            }
            _showWriteOffToast(
              context,
              AppErrorMapper.message(e, fallback: AppErrorCategory.dataSave),
              isError: true,
            );
          }
        }

        OutlineInputBorder border(Color c, [double w = 1]) =>
            OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c, width: w),
            );

        return AppDialog(
          icon: LucideIcons.packageMinus,
          color: Colors.red,
          title: 'Request write-off',
          subtitle: currentItem.name,
          actions: [
            OutlinedButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: BorderSide(color: Colors.grey.shade300),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(fontFamily: _fontFam),
              ),
            ),
            ElevatedButton(
              onPressed: canSubmit ? submit : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Submit for Approval',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFamily: _fontFam,
                      ),
                    ),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _writeOffStockSummary(
                        'CURRENT',
                        '${_formatStockQuantity(currentItem.quantity)} $unit',
                        const Color(0xFF0F172A),
                      ),
                    ),
                    Icon(
                      LucideIcons.arrowRight,
                      size: 18,
                      color: Colors.grey.shade400,
                    ),
                    Expanded(
                      child: _writeOffStockSummary(
                        'AFTER',
                        remaining == null
                            ? '—'
                            : '${_formatStockQuantity(remaining)} $unit',
                        remaining == null ? Colors.grey : Colors.red.shade700,
                        alignEnd: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Reason',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: _fontFam,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: reasons
                    .map(
                      (r) => ChoiceChip(
                        label: Text(r),
                        selected: reason == r,
                        selectedColor: Colors.red.withOpacity(0.12),
                        labelStyle: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: reason == r
                              ? Colors.red.shade700
                              : Colors.black87,
                          fontFamily: _fontFam,
                        ),
                        onSelected: saving
                            ? null
                            : (_) => setDialogState(() => reason = r),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 20),
              const Text(
                'Quantity to remove',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: _fontFam,
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(
                        LucideIcons.alertCircle,
                        size: 13,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          error!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFamily: _fontFam,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: qtyCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  // digits with at most one decimal point
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                onChanged: (text) => setDialogState(() {
                  if (touched) error = validate(text);
                }),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: _fontFam,
                ),
                decoration: InputDecoration(
                  hintText: '0',
                  hintStyle: const TextStyle(fontFamily: _fontFam),
                  suffixText: unit,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  enabledBorder: border(
                    error != null ? Colors.red : Colors.grey.shade300,
                  ),
                  focusedBorder: border(
                    error != null ? Colors.red : Colors.red.shade300,
                    1.5,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                style: const TextStyle(fontFamily: _fontFam),
                decoration: InputDecoration(
                  hintText: 'Note (optional), e.g. dropped during unloading',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade500,
                    fontFamily: _fontFam,
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  enabledBorder: border(Colors.grey.shade300),
                  focusedBorder: border(Colors.red.shade300, 1.5),
                ),
              ),
              const SizedBox(height: 20),
              ApprovalProofPicker(
                busy: uploadingProof,
                onChanged: (selection) {
                  setDialogState(() => proof = selection);
                },
              ),
            ],
          ),
        );
      },
    ),
  );

  qtyCtrl.dispose();
  noteCtrl.dispose();
}
