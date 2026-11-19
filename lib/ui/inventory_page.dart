import 'package:flutter/material.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'add_item_page.dart';
import 'inventory_redesign.dart';
import 'qr_labels_preview_dialog.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import '../services/export_period.dart';
import '../services/export_reminder_service.dart';
import 'reports/inventory_report_generator.dart';
import 'reports/report_range.dart';
import 'reports/report_period_dialog.dart';
import '../notifications/notification_provider.dart';
import '../services/app_error_mapper.dart';
import '../services/app_logger.dart';
import '../services/report_export_controller.dart';
import '../services/report_pdf_build.dart';

class InventoryPage extends StatefulWidget {
  final InventoryController controller;
  final Future<void> Function(InventoryItem)? onUpdateItem;
  final bool exportDue;
  final VoidCallback? onExported;
  final Future<void> Function()? onInventoryChanged;

  const InventoryPage({
    super.key,
    required this.controller,
    this.onUpdateItem,
    this.exportDue = false,
    this.onExported,
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
      exportDue: widget.exportDue,
      onExport: () {
        showReportPeriodDialog(
          context,
          title: 'Generate Inventory Report',
          note: 'Past reports use current unit costs.',
          onGenerate: (range) =>
              _generateAndPrintInventoryReport(context, range),
        );
      },
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

  Future<void> _generateAndPrintInventoryReport(
    BuildContext context,
    ReportRange range,
  ) async {
    final items = List<InventoryItem>.of(widget.controller.reportableItems);

    if (items.isEmpty) {
      _showToast("No inventory items found to generate report.", isError: true);
      return;
    }

    final controller = widget.controller;
    final generatedBy = controller.currentUserName ?? 'Admin';
    final now = DateTime.now();
    final notificationController = NotificationProvider.maybeOf(context);
    final onExported = widget.onExported;
    final started = ReportExportController.instance.start(
      reportName: 'Inventory report',
      fileName:
          'Inventory_Report_${range.period}_${range.fileTag}_${now.millisecondsSinceEpoch}.pdf',
      afterDownload: range.isCurrent
          ? () async {
              final locId = controller.activeLocationId;
              if (locId == null) return;
              final service = ExportReminderService(
                supabase: controller.supabase,
                locationId: locId,
              );
              final period = ExportPeriod.current(range.type);
              await service.logExport(
                reportType: 'inventory',
                period: period,
                exportedBy: controller.currentUserNumericId,
              );
              await notificationController?.resolveExportReminder(
                reportType: 'inventory',
                periodType: range.type.name,
                periodKey: period.key,
              );
              onExported?.call();
            }
          : null,
      build: (progress) async {
        final allTransactions = await controller.fetchAllTransactionHistory();
        progress(0.3);

        final issuedDetails = <String, double>{};
        final receivedDetails = <String, double>{};
        final netInPeriod = <String, double>{};
        final netAfterPeriod = <String, double>{};

        for (final tx in allTransactions) {
          final productId = tx['product_id']?.toString();
          if (productId == null) continue;

          final txDate = DateTime.parse(tx['created_at']).toLocal();
          final qty = (tx['quantity_change'] as num).toDouble();

          // Happened AFTER the report period: used to roll today's stock back
          // to what it was at the end of the period.
          if (!txDate.isBefore(range.endExclusive)) {
            netAfterPeriod[productId] = (netAfterPeriod[productId] ?? 0) + qty;
            continue;
          }

          if (!range.contains(txDate)) continue;

          netInPeriod[productId] = (netInPeriod[productId] ?? 0) + qty;

          if (tx['transaction_type'] == 'checkout') {
            issuedDetails[productId] =
                (issuedDetails[productId] ?? 0) + qty.abs();
          } else if (tx['transaction_type'] == 'stock_in' ||
              tx['transaction_type'] == 'add') {
            receivedDetails[productId] =
                (receivedDetails[productId] ?? 0) + qty;
          }
        }

        final entries = items.map((item) {
          // Stock at the END of the period = current stock minus everything
          // that happened after it. For the current period this is just
          // item.quantity.
          final ending =
              item.quantity.toDouble() - (netAfterPeriod[item.id] ?? 0);
          final beginning = ending - (netInPeriod[item.id] ?? 0);

          return InventoryReportEntry(
            sku: item.sku,
            name: item.name,
            unit: item.unit,
            beginningQty: beginning,
            received: receivedDetails[item.id] ?? 0.0,
            issued: issuedDetails[item.id] ?? 0.0,
            endingQty: ending,
            unitCost: item.price,
          );
        }).toList();

        progress(0.65);
        final bytes = await buildInventoryReportPdf(
          InventoryReportPdfRequest(
            period: range.period,
            periodStart: range.start,
            periodEnd: range.displayEnd,
            generatedAt: now,
            generatedBy: generatedBy,
            items: entries,
          ),
        );
        progress(0.95);
        return bytes;
      },
    );
    if (!started) {
      _showToast('Finish or download the current report first.', isError: true);
    }
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

  String _formatCurrency(double value) {
    RegExp reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    String mathFunc(Match match) => '${match[1]},';
    return 'P${value.toStringAsFixed(2).replaceAllMapped(reg, mathFunc)}';
  }
}
