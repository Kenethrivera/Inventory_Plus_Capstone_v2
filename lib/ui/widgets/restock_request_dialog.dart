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

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

String _formatStockQuantity(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

void _showRestockToast(
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

Widget _restockStockSummary(
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

Future<void> showRestockRequestDialog({
  required BuildContext context,
  required InventoryController controller,
  required InventoryItem item,
}) async {
  final currentItem = controller.findAnyItemById(item.id) ?? item;
  final qtyCtrl = TextEditingController();
  final unit = currentItem.unit;
  final allowDecimals = const {
    'kg',
    'g',
    'l',
    'ml',
  }.contains(unit.toLowerCase());
  bool saving = false;
  bool uploadingProof = false;
  bool touched = false;
  String? error;
  ApprovalProofSelection? proof;
  final operationId = controller.newOperationId('inventory-approval');

  String? validate(String text) {
    final t = text.trim();
    if (t.isEmpty) return 'Enter the quantity received';
    final v = double.tryParse(t);
    if (v == null) return 'Enter a valid number';
    if (v <= 0) return 'Must be greater than 0';
    return null;
  }

  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final value = double.tryParse(qtyCtrl.text.trim());
        final newQty = (value != null && value > 0)
            ? currentItem.quantity + value
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
              type: InventoryApprovalType.restock,
              productId: currentItem.id,
              quantity: qty,
              proofStoragePath: proofPath,
              proofFileName: selectedProof.fileName,
              proofMimeType: selectedProof.mimeType,
            );
            if (!context.mounted) return;
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            _showRestockToast(
              context,
              'Restock request submitted. Inventory remains unchanged '
              'until Admin approval.',
            );
          } catch (e, stackTrace) {
            AppLogger.error(
              'Restock approval request failed',
              error: e,
              stackTrace: stackTrace,
            );
            if (dialogContext.mounted) {
              setDialogState(() {
                saving = false;
                uploadingProof = false;
              });
            }
            _showRestockToast(
              context,
              AppErrorMapper.message(e, fallback: AppErrorCategory.dataSave),
              isError: true,
            );
          }
        }

        void addChip(int n) {
          final next = (double.tryParse(qtyCtrl.text.trim()) ?? 0) + n;
          final text = _formatStockQuantity(next);
          qtyCtrl.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
          setDialogState(() {
            if (touched) error = validate(text);
          });
        }

        OutlineInputBorder border(Color c, [double w = 1]) =>
            OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c, width: w),
            );

        return AppDialog(
          icon: LucideIcons.packagePlus,
          color: _primaryBlue,
          title: 'Request restock',
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
                backgroundColor: _primaryBlue,
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
              // Current -> New summary
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
                      child: _restockStockSummary(
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
                      child: _restockStockSummary(
                        'NEW',
                        newQty == null
                            ? '—'
                            : '${_formatStockQuantity(newQty)} $unit',
                        newQty == null ? Colors.grey : _primaryBlue,
                        alignEnd: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Quantity received',
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
                keyboardType: TextInputType.numberWithOptions(
                  decimal: allowDecimals,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    RegExp(allowDecimals ? r'[0-9.]' : r'[0-9]'),
                  ),
                ],
                onChanged: (text) => setDialogState(() {
                  if (touched) error = validate(text);
                }),
                onSubmitted: (_) => saving ? null : submit(),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFamily: _fontFam,
                ),
                decoration: InputDecoration(
                  hintText: '0',
                  hintStyle: const TextStyle(fontFamily: _fontFam),
                  suffixText: unit,
                  suffixStyle: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade600,
                    fontFamily: _fontFam,
                  ),
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
                    error != null ? Colors.red : _primaryBlue,
                    1.5,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [1, 5, 10, 50]
                    .map(
                      (n) => ActionChip(
                        label: Text('+$n'),
                        labelStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamily: _fontFam,
                        ),
                        backgroundColor: _primaryBlue.withValues(alpha: 0.1),
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        onPressed: saving ? null : () => addChip(n),
                      ),
                    )
                    .toList(),
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
}
