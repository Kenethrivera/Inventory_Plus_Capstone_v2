import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/inventory.dart';
import '../services/app_logger.dart';
import 'widgets/app_toast.dart';

class QrLabelsPreviewDialog extends StatefulWidget {
  final List<InventoryItem> items;

  const QrLabelsPreviewDialog({super.key, required this.items});

  @override
  State<QrLabelsPreviewDialog> createState() => _QrLabelsPreviewDialogState();
}

class _QrLabelsPreviewDialogState extends State<QrLabelsPreviewDialog> {
  static const _accent = Color(0xFFC83D08);

  int _labelsPerPage = 6;
  late Future<Uint8List> _pdf;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _pdf = _generatePreview(_labelsPerPage);
  }

  Future<Uint8List> _generatePreview(int count) =>
      Future(() => buildQrLabelsPdf(widget.items, count));

  void _changeCount(int count) {
    if (_labelsPerPage == count) return;
    setState(() {
      _labelsPerPage = count;
      _pdf = _generatePreview(count);
    });
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final bytes = await _pdf;
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'Inventory_QR_Labels_${_labelsPerPage}_per_page.pdf',
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Inventory QR label download failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(context, 'Could not download the QR labels.');
        setState(() => _downloading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final pageCount = (widget.items.length / _labelsPerPage).ceil();
    final layout = QrLabelPageLayout.forCount(_labelsPerPage);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: const Color(0xFFFCFAF8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: math.min(screen.width - 32, 1000),
        height: math.min(screen.height - 32, 820),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Preview QR labels',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close preview',
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'QR labels per page',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xFFE3DED7)),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: DropdownButton<int>(
                      value: _labelsPerPage,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (var count = 1; count <= 24; count++)
                          DropdownMenuItem(
                            value: count,
                            child: Text('$count QR / page'),
                          ),
                      ],
                      onChanged: (count) {
                        if (count != null) _changeCount(count);
                      },
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'A4 paper · ${layout.columns} columns × ${layout.rows} rows · about ${layout.labelSizeMm.toStringAsFixed(0)} mm per label · ${widget.items.length} labels · $pageCount ${pageCount == 1 ? 'page' : 'pages'}',
                style: const TextStyle(color: Color(0xFF756D67), fontSize: 12),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: PdfPreview(
                key: ValueKey(_labelsPerPage),
                build: (_) => _pdf,
                initialPageFormat: PdfPageFormat.a4,
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                allowPrinting: false,
                allowSharing: false,
                useActions: false,
                maxPageWidth: 560,
                onError: (context, error) => Center(
                  child: Text(
                    'Could not show the label preview: $error',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  const Text(
                    'Check the layout before downloading.',
                    style: TextStyle(color: Color(0xFF756D67), fontSize: 12),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FutureBuilder<Uint8List>(
                        future: _pdf,
                        builder: (context, snapshot) => FilledButton.icon(
                          onPressed: snapshot.hasData && !_downloading
                              ? _download
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                          ),
                          icon: const Icon(Icons.download, size: 17),
                          label: Text(
                            _downloading ? 'Downloading…' : 'Download PDF',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class QrLabelPageLayout {
  final int columns;
  final int rows;
  final double labelSize;

  const QrLabelPageLayout(this.columns, this.rows, this.labelSize);

  double get labelSizeMm => labelSize / PdfPageFormat.mm;

  factory QrLabelPageLayout.forCount(int labelsPerPage) {
    if (labelsPerPage < 1 || labelsPerPage > 24) {
      throw ArgumentError.value(labelsPerPage, 'labelsPerPage', 'Use 1 to 24');
    }
    const margin = 10 * PdfPageFormat.mm;
    const gap = 6 * PdfPageFormat.mm;
    const maxLabelSize = 85 * PdfPageFormat.mm;
    var best = const QrLabelPageLayout(1, 1, 0);

    for (var columns = 1; columns <= labelsPerPage; columns++) {
      final rows = (labelsPerPage / columns).ceil();
      final width =
          (PdfPageFormat.a4.width - 2 * margin - (columns - 1) * gap) / columns;
      final height =
          (PdfPageFormat.a4.height - 2 * margin - (rows - 1) * gap) / rows;
      final size = math.min(maxLabelSize, math.min(width, height));
      final emptySlots = columns * rows - labelsPerPage;
      final bestEmptySlots = best.columns * best.rows - labelsPerPage;
      if (size > best.labelSize + 0.01 ||
          ((size - best.labelSize).abs() <= 0.01 &&
              emptySlots < bestEmptySlots)) {
        best = QrLabelPageLayout(columns, rows, size);
      }
    }
    return best;
  }
}

Future<Uint8List> buildQrLabelsPdf(
  List<InventoryItem> items,
  int labelsPerPage,
) async {
  final doc = pw.Document();
  final layout = QrLabelPageLayout.forCount(labelsPerPage);
  final labelSize = layout.labelSize;
  final gap = 6 * PdfPageFormat.mm;
  final fontScale = labelSize / (85 * PdfPageFormat.mm);

  for (var start = 0; start < items.length; start += labelsPerPage) {
    final pageItems = items
        .skip(start)
        .take(labelsPerPage)
        .toList(growable: false);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(10 * PdfPageFormat.mm),
        build: (_) => pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            for (var row = 0; row < layout.rows; row++) ...[
              if (row > 0) pw.SizedBox(height: gap),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  for (var column = 0; column < layout.columns; column++) ...[
                    if (column > 0) pw.SizedBox(width: gap),
                    if (row * layout.columns + column < pageItems.length)
                      _pdfLabel(
                        pageItems[row * layout.columns + column],
                        labelSize,
                        fontScale,
                      )
                    else
                      pw.SizedBox(width: labelSize, height: labelSize),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  return doc.save();
}

pw.Widget _pdfLabel(InventoryItem item, double size, double fontScale) =>
    pw.Container(
      width: size,
      height: size,
      padding: pw.EdgeInsets.all(11 * fontScale),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey, width: 1),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            item.displayName.replaceAll(' · ', ' - '),
            style: pw.TextStyle(
              fontSize: 16 * fontScale,
              fontWeight: pw.FontWeight.bold,
            ),
            maxLines: 1,
          ),
          pw.SizedBox(height: 10 * fontScale),
          pw.Expanded(
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: item.sku,
              drawText: false,
            ),
          ),
          pw.SizedBox(height: 7 * fontScale),
          pw.Text(
            'Price: P${item.price.toStringAsFixed(2)}',
            style: pw.TextStyle(
              fontSize: 13 * fontScale,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
