import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../data/inventory.dart';
import '../../logic/inventory_controller.dart';
import '../scanner_search_page.dart';
import 'app_toast.dart';
import 'app_dialog.dart';
import '../store_map.dart';

/// The checklist UI itself — no Scaffold/AppBar, so it can be dropped into
/// a full page (Order Queue) or a modal (POS Solo Mode) without duplicating
/// any of the picking logic.
class OrderChecklistView extends StatefulWidget {
  final dynamic order;
  final InventoryController controller;

  /// Label/icon for the bottom action button. The view itself doesn't know
  /// or care what "finishing" means — the host page decides.
  final String finishLabel;
  final IconData finishIcon;
  final VoidCallback onFinish;

  const OrderChecklistView({
    super.key,
    required this.order,
    required this.controller,
    required this.onFinish,
    this.finishLabel = "NOTIFY CASHIER (PREPARED)",
    this.finishIcon = LucideIcons.checkCircle2,
  });

  @override
  State<OrderChecklistView> createState() => _OrderChecklistViewState();
}

class _OrderChecklistViewState extends State<OrderChecklistView> {
  final Set<int> _checkedIndices = {};

  bool get _allChecked =>
      _checkedIndices.length == widget.order.items.length &&
      widget.order.items.isNotEmpty;
  int get _checkedCount => _checkedIndices.length;
  int get _totalCount => widget.order.items.length;

  void _toggleCheck(int index) {
    setState(() {
      if (_checkedIndices.contains(index)) {
        _checkedIndices.remove(index);
      } else {
        _checkedIndices.add(index);
      }
    });
  }
  void _showItemLocationMap(BuildContext context, String productId, String productName) {
  showDialog(
    context: context,
    builder: (dialogContext) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 600,
        height: 500,
        child: Column(
          children: [
            // Header
            Container(
              color: const Color(0xFF0F172A),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Location: $productName',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(dialogContext),
                  )
                ],
              ),
            ),
            // Map Canvas
            Expanded(
              child: StoreMap(
                controller: widget.controller,
                mode: MapMode.view, // Set to view-only mode
                selectedItemId: productId, // This highlights the specific item
                onSelectionAssigned: () {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

  void _showPickConfirmationSheet(
    InventoryItem dbItem,
    double targetQuantity,
    int listIndex,
  ) {
    showDialog(
      context: context,
      builder: (context) => PickConfirmationDialog(
        item: dbItem,
        targetQuantity: targetQuantity,
        onConfirm: () async {
          if (mounted) {
            setState(() => _checkedIndices.add(listIndex));
            Navigator.pop(context);
            AppToast.success(context, '${dbItem.name} checked off!');
          }
        },
      ),
    );
  }

  void _openScannerToCheckoff(int index, String expectedProductId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScannerSearchPage(
          controller: widget.controller,
          onSelectItem: (scannedItem) {
            Navigator.pop(context);
            if (scannedItem.id == expectedProductId) {
              _showPickConfirmationSheet(
                scannedItem,
                widget.order.items[index].quantity,
                index,
              );
            } else {
              AppToast.error(
                context,
                '${scannedItem.name} is not the right item!',
              );
            }
          },
        ),
      ),
    );
  }

  void _showTutorialModal() {
    showDialog(
      context: context,
      builder: (context) => AppDialog(
        icon: LucideIcons.helpCircle,
        color: const Color(0xFF3E322C),
        title: "How to Prepare an Order",
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "1. Manually tap the checkbox if you have visually verified the item.",
            ),
            SizedBox(height: 12),
            Text(
              "2. OR, tap the QR Scanner icon to scan the shelf barcode for exact verification.",
            ),
            SizedBox(height: 12),
            Text(
              "3. Once all items are checked, the action button below will be enabled.",
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFBEADB),
              foregroundColor: const Color(0xFF9E651D),
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              "Got it!",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String shortId = widget.order.id
        .toString()
        .substring(0, 8)
        .toUpperCase();

    final filteredEntries = widget.order.items.asMap().entries.toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "ORDER ASSIGNMENT",
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "ID: #ORD-$shortId",
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      InkWell(
                        onTap: _showTutorialModal,
                        child: const CircleAvatar(
                          radius: 14,
                          backgroundColor: Color(0xFF3E322C),
                          child: Icon(
                            LucideIcons.helpCircle,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFBEADB),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          "$_checkedCount/$_totalCount",
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF9E651D),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                _allChecked ? "ALL ITEMS PICKED" : "READY FOR PICKING",
                style: TextStyle(
                  color: _allChecked ? Colors.green : Colors.grey.shade600,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: filteredEntries.length,
            itemBuilder: (context, i) {
              final index = filteredEntries[i].key;
              final item = filteredEntries[i].value;
              final bool isChecked = _checkedIndices.contains(index);

              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(
                    color: isChecked
                        ? Colors.green.shade300
                        : Colors.grey.shade300,
                    width: isChecked ? 1.5 : 1.0,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => _toggleCheck(index),
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: isChecked ? Colors.green : Colors.transparent,
                          border: Border.all(
                            color: isChecked
                                ? Colors.green
                                : Colors.grey.shade400,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: isChecked
                            ? const Icon(
                                LucideIcons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.productName,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: isChecked
                                  ? Colors.grey.shade500
                                  : const Color(0xFF0F172A),
                              decoration: isChecked
                                  ? TextDecoration.lineThrough
                                  : TextDecoration.none,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFBEADB),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'QTY: ${item.quantity.truncateToDouble() == item.quantity ? item.quantity.toInt() : item.quantity.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF9E651D),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
      icon: const Icon(LucideIcons.mapPin, color: Colors.orange), // or LucideIcons.map
      tooltip: 'Show Location',
      onPressed: () {
        // Pass the specific item's ID and Name
        _showItemLocationMap(context, item.productId, item.productName);
      },
    ),
                    IconButton(
                      icon: const Icon(
                        LucideIcons.scanLine,
                        color: Colors.orange,
                      ),
                      tooltip: "Scan QR Code",
                      onPressed: () =>
                          _openScannerToCheckoff(index, item.productId),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFF8E9DE),
            border: Border(top: BorderSide(color: Colors.grey.shade200)),
          ),
          child: SizedBox(
            width: double.infinity,
            height: 55,
            child: ElevatedButton.icon(
              onPressed: _allChecked ? widget.onFinish : null,
              icon: Icon(widget.finishIcon),
              label: Text(
                widget.finishLabel,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              style:
                  ElevatedButton.styleFrom(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ).copyWith(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.disabled)) {
                        return const Color(0xFFDAC7B8);
                      }
                      return Colors.green;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.disabled)) {
                        return Colors.white70;
                      }
                      return Colors.white;
                    }),
                  ),
            ),
          ),
        ),
      ],
    );
  }
}

enum ChecklistResult { finished, cancelled, dismissed }

Future<ChecklistResult> showOrderChecklistModal({
  required BuildContext context,
  required dynamic order,
  required InventoryController controller,
  required String finishLabel,
  Future<bool> Function()? onCancelOrder, // true = order was cancelled
}) async {
  final result = await showDialog<ChecklistResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final size = MediaQuery.of(dialogContext).size;
      final dialogWidth = size.width < 520 ? size.width - 40 : 480.0;
      final dialogHeight = size.height * 0.85;

      return Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (onCancelOrder != null)
                      TextButton.icon(
                        onPressed: () async {
                          // Confirm FIRST; only close if actually cancelled.
                          final cancelled = await onCancelOrder();
                          if (cancelled && dialogContext.mounted) {
                            Navigator.pop(
                              dialogContext,
                              ChecklistResult.cancelled,
                            );
                          }
                        },
                        icon: Icon(
                          LucideIcons.undo2,
                          size: 16,
                          color: Colors.red.shade400,
                        ),
                        label: Text(
                          "Cancel & Edit",
                          style: TextStyle(
                            color: Colors.red.shade400,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                    IconButton(
                      icon: const Icon(LucideIcons.x, color: Colors.grey),
                      onPressed: () => Navigator.pop(
                        dialogContext,
                        ChecklistResult.dismissed,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: OrderChecklistView(
                  order: order,
                  controller: controller,
                  finishLabel: finishLabel,
                  finishIcon: LucideIcons.creditCard,
                  onFinish: () =>
                      Navigator.pop(dialogContext, ChecklistResult.finished),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  return result ?? ChecklistResult.dismissed;
}

// ============================================================================
// PICK CONFIRMATION — unchanged, just moved here since it only serves
// OrderChecklistView now.
// ============================================================================
class PickConfirmationDialog extends StatelessWidget {
  final InventoryItem item;
  final double targetQuantity;
  final VoidCallback onConfirm;

  const PickConfirmationDialog({
    super.key,
    required this.item,
    required this.targetQuantity,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final String displayQty =
        targetQuantity.truncateToDouble() == targetQuantity
        ? targetQuantity.toInt().toString()
        : targetQuantity.toStringAsFixed(2);

    return AppDialog(
      icon: LucideIcons.checkCircle2,
      color: Colors.green,
      title: "Item Verified!",
      subtitle: "SKU-${item.sku}",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade200),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    image: item.imageUrl.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(item.imageUrl),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: item.imageUrl.isEmpty
                      ? Icon(LucideIcons.image, color: Colors.grey.shade400)
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.shoppingBasket,
                  color: Colors.green.shade700,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        color: Colors.green.shade900,
                        fontSize: 14,
                        height: 1.4,
                      ),
                      children: [
                        const TextSpan(text: "Please pick exactly "),
                        TextSpan(
                          text: "$displayQty ${item.unit}",
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: const Text(
            "Cancel",
            style: TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ElevatedButton.icon(
          onPressed: onConfirm,
          icon: const Icon(LucideIcons.check, size: 18),
          label: const Text(
            "Confirm Pick",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }
}
