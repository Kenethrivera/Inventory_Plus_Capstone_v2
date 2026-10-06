import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'add_item_page.dart';
import 'package:inventory_plus/ui/widgets/item_card.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import '../services/export_period.dart'; 
import '../services/export_reminder_service.dart';  
import 'reports/inventory_report_generator.dart';
import 'reports/report_range.dart';
import 'reports/report_period_dialog.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

String _fmtQty(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

class InventoryPage extends StatefulWidget {
  final InventoryController controller;
  final Function(InventoryItem) onSelectItem;
  final bool exportDue;
  final VoidCallback? onExported;

  const InventoryPage({
    super.key,
    required this.controller,
    required this.onSelectItem,
    this.exportDue = false,
    this.onExported,
  });

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  String _searchQuery = "";
  String _selectedCategory = "All";
  bool _showDisabled = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSystemSettings();
  }

  Future<void> _loadSystemSettings() async {
    try {
      await widget.controller.loadSystemSettings();
    } catch (e) {
      if (mounted)
        _showToast("Could not load stock thresholds: $e", isError: true);
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
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fetch categories and immediately remove 'Unassigned'
    final categories = widget.controller
        .getUniqueCategories()
        .where((category) => category.toLowerCase() != 'unassigned')
        .toList();

    final filteredInventory = _showDisabled
        ? widget.controller.filterDisabled(
            query: _searchQuery,
            category: _selectedCategory,
          )
        : widget.controller.filterInventory(
            query: _searchQuery,
            category: _selectedCategory,
          );

    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.only(
              top: 16,
              bottom: 12,
              left: 16,
              right: 16,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Inventory List",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF111827),
                        fontFamily: _fontFam,
                      ),
                    ),
                    if (widget.controller.isAdmin)
                      Row(
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => showReportPeriodDialog(
                                  context,
                                  title: 'Generate Inventory Report',
                                  note: 'Past reports use current unit costs.',
                                  onGenerate: (range) =>
                                      _generateAndPrintInventoryReport(
                                        context,
                                        range,
                                      ),
                                ),
                                icon: const Icon(
                                  LucideIcons.download,
                                  size: 16,
                                ),
                                label: const Text(
                                  "Export Inventory Report",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.black87,
                                  side: BorderSide(
                                    color: widget.exportDue
                                        ? Colors.red
                                        : Colors.grey.shade300,
                                    width: widget.exportDue ? 1.5 : 1,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                              if (widget.exportDue)
                                Positioned(
                                  top: -4,
                                  right: -4,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 8),
                          _buildHeaderButton(
                            icon: LucideIcons.qrCode,
                            label: "QR Labels",
                            onPressed: () => _generateAndPrintQRLabels(context),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              final isDesktop =
                                  MediaQuery.of(context).size.width >= 600;
                              if (isDesktop) {
                                showDialog(
                                  context: context,
                                  builder: (context) => Dialog(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: SizedBox(
                                      width: 500,
                                      height: 750,
                                      child: AddItemPage(
                                        controller: widget.controller,
                                        onAdd: (newItem) {
                                          setState(() {});
                                          _showToast(
                                            '"${newItem.name}" added to inventory',
                                          );
                                        }
                                      ),
                                    ),
                                  ),
                                );
                              } else {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => AddItemPage(
                                      controller: widget.controller,
                                      onAdd: (newItem) {
                                        setState(() {});
                                        _showToast(
                                          '"${newItem.name}" added to inventory',
                                        );
                                      }
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(LucideIcons.plus, size: 14),
                            label: const Text("New Item", style: TextStyle(fontFamily: _fontFam)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primaryBlue,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _searchController,
                  style: const TextStyle(fontFamily: _fontFam),
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: InputDecoration(
                    hintText: "Search inventory...",
                    hintStyle: const TextStyle(fontFamily: _fontFam),
                    prefixIcon: const Icon(LucideIcons.search, size: 18),
                    filled: true,
                    fillColor: Colors.grey[50],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: categories.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final category = categories[index];
                            final isSelected = _selectedCategory == category;
                            return GestureDetector(
                              onTap: () =>
                                  setState(() => _selectedCategory = category),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF1E293B)
                                      : Colors.grey[100],
                                  borderRadius: BorderRadius.circular(100),
                                ),
                                child: Text(
                                  category,
                                  style: TextStyle(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.grey[600],
                                    fontSize: 12,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (widget.controller.isAdmin) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 1,
                          height: 20,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(width: 8),
                        _buildDisabledPill(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: filteredInventory.isNotEmpty
                ? ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredInventory.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _buildListHeader(filteredInventory.length);
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ItemCard(
                          item: filteredInventory[index - 1],
                          controller: widget.controller,
                          onClick: widget.onSelectItem,
                        ),
                      );
                    },
                  )
                : _buildEmptyState(),
          ),
        ],
      ),
    );
  }

  Widget _buildDisabledPill() {
    final color = _showDisabled ? _primaryBlue : Colors.grey.shade600;
    return GestureDetector(
      onTap: () => setState(() => _showDisabled = !_showDisabled),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _showDisabled
              ? _primaryBlue.withOpacity(0.1)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(100),
          border: Border.all(
            color: _showDisabled ? _primaryBlue : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.eyeOff, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              'Show disabled (${widget.controller.disabledItems.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListHeader(int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            "${_selectedCategory.toUpperCase()} ($count)",
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
              letterSpacing: 1.1,
              fontFamily: _fontFam,
            ),
          ),
          const Icon(LucideIcons.arrowUpDown, size: 14, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.package, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 12),
          const Text(
            "No items found",
            style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
          ),
        ],
      ),
    );
  }

  // --- NEW UI HELPER FOR EXPORT BUTTONS ---
  Widget _buildHeaderButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 14, color: const Color(0xFF0F172A)),
          label: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: _fontFam,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: Colors.grey.shade300),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            backgroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Future<void> _generateAndPrintInventoryReport(
    BuildContext context,
    ReportRange range,
  ) async {
    final items = widget.controller.reportableItems;

    if (items.isEmpty) {
      _showToast("No inventory items found to generate report.", isError: true);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          const Center(child: CircularProgressIndicator()),
    );

    try {
      final now = DateTime.now();

      final allTransactions = await widget.controller
          .fetchAllTransactionHistory();

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
          receivedDetails[productId] = (receivedDetails[productId] ?? 0) + qty;
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

      final bytes = await InventoryReportGenerator.generate(
        period: range.period,
        periodStart: range.start,
        periodEnd: range.displayEnd,
        generatedAt: now,
        generatedBy: widget.controller.currentUserName ?? 'Admin',
        items: entries,
      );

      if (context.mounted) Navigator.pop(context);
      await Printing.sharePdf(
        bytes: bytes,
        filename:
            'Inventory_Report_${range.period}_${range.fileTag}_${now.millisecondsSinceEpoch}.pdf',
      );

      _showToast("Report generated");

      // Only the CURRENT period counts toward the export reminder.
      if (range.isCurrent) await _markExported(range.type);
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        _showToast("Error generating PDF: $e", isError: true);
      }
    }
  }

  Future<void> _generateAndPrintQRLabels(BuildContext context) async {
    final items = widget.controller.allItems;

    if (items.isEmpty) {
      _showToast("No inventory items found to generate labels.", isError: true);
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) =>
          const Center(child: CircularProgressIndicator()),
    );

    try {
      final doc = pw.Document();
      const int itemsPerPage = 6;

      for (var i = 0; i < items.length; i += itemsPerPage) {
        final chunk = items.skip(i).take(itemsPerPage).toList();

        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(32),
            build: (pw.Context context) {
              return pw.Wrap(
                spacing: 20,
                runSpacing: 20,
                children: chunk.map((item) {
                  return pw.Container(
                    width: 240,
                    height: 240,
                    padding: const pw.EdgeInsets.all(12),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey, width: 2),
                      borderRadius: pw.BorderRadius.circular(12),
                    ),
                    child: pw.Column(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text(
                          item.name,
                          style: pw.TextStyle(
                            fontSize: 16,
                            fontWeight: pw.FontWeight.bold,
                          ),
                          maxLines: 1,
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          "SKU: ${item.sku}",
                          style: const pw.TextStyle(
                            fontSize: 12,
                            color: PdfColors.black,
                          ),
                        ),
                        pw.SizedBox(height: 12),
                        pw.Expanded(
                          child: pw.BarcodeWidget(
                            barcode: pw.Barcode.qrCode(),
                            data: item.sku,
                            drawText: false,
                          ),
                        ),
                        pw.SizedBox(height: 8),
                        pw.Text(
                          "Price: P${item.price.toStringAsFixed(2)}",
                          style: pw.TextStyle(
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        );
      }

      final bytes = await doc.save();
      if (context.mounted) Navigator.pop(context);
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'Inventory_QR_Labels.pdf',
      );

      _showToast("QR labels generated");
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        _showToast("Error generating PDF: $e", isError: true);
      }
    }
  }

  String _formatCurrency(double value) {
    RegExp reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    String mathFunc(Match match) => '${match[1]},';
    return 'P${value.toStringAsFixed(2).replaceAllMapped(reg, mathFunc)}';
  }

  Future<void> _markExported(ExportPeriodType type) async {
    final locId = widget.controller.activeLocationId;
    if (locId == null) return;
    final service = ExportReminderService(
      supabase: widget.controller.supabase,
      locationId: locId,
    );
    await service.logExport(
      reportType: 'inventory',
      period: ExportPeriod.current(type),
      exportedBy: widget.controller.currentUserNumericId,
    );
    widget.onExported
        ?.call(); // clears both the button dot and sidebar dot instantly
  }
}