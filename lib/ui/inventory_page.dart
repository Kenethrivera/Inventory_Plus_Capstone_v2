import 'package:flutter/material.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'add_item_page.dart';
import 'inventory_redesign.dart';
import 'qr_labels_preview_dialog.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';

class InventoryPage extends StatefulWidget {
  final InventoryController controller;
  final Future<void> Function(InventoryItem)? onUpdateItem;
  final Future<void> Function()? onInventoryChanged;

  const InventoryPage({
    super.key,
    required this.controller,
    this.onUpdateItem,
    this.onInventoryChanged,
  });

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  @override
  void initState() {
    super.initState();
    _loadSystemSettings();
  }

  Future<void> _loadSystemSettings() async {
    try {
      await widget.controller.loadStockThresholdSettings();
    } catch (e, stackTrace) {
      AppLogger.error(
        'Stock threshold load failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showToast(
          AppErrorMapper.message(e, fallback: AppErrorCategory.dataLoad),
          isError: true,
        );
      }
    }
    if (mounted) setState(() {});
  }

  // --- UPPER RIGHT TOAST NOTIFICATION ---
  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    isError
        ? AppToast.error(context, message)
        : AppToast.success(context, message);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InventoryItem>>(
      stream: widget.controller.streamInventory(),
      initialData: widget.controller.currentInventory,
      builder: (context, snapshot) => _buildInventoryView(context),
    );
  }

  Widget _buildInventoryView(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onInventoryChanged?.call();
    });
    return InventoryRedesign(
      controller: widget.controller,
      onUpdateItem: widget.onUpdateItem ?? widget.controller.updateItem,
      onQrLabels: (items) {
        _generateAndPrintQRLabels(context, items: items);
      },
      onNewItem: () => _openNewItem(context),
    );
  }

  void _openNewItem(BuildContext context) {
    void onAdd(InventoryItem newItem) {
      if (mounted) {
        setState(() {});
        _showToast('"${newItem.name}" added to inventory');
      }
    }

    final page = AddItemPage(controller: widget.controller, onAdd: onAdd);
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close new item form',
      barrierColor: const Color(0x990F172A),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, _, __) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: MediaQuery.of(dialogContext).size.width < 500
              ? MediaQuery.of(dialogContext).size.width
              : 480,
          height: double.infinity,
          child: Material(color: Colors.white, child: page),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    );
  }

  Future<void> _generateAndPrintQRLabels(
    BuildContext context, {
    List<InventoryItem>? items,
  }) async {
    items ??= widget.controller.allItems;

    if (items.isEmpty) {
      _showToast("No inventory items found to generate labels.", isError: true);
      return;
    }
    final downloaded = await showDialog<bool>(
      context: context,
      builder: (_) => QrLabelsPreviewDialog(items: List.of(items!)),
    );
    if (downloaded == true && mounted) _showToast('QR labels ready');
  }
}
