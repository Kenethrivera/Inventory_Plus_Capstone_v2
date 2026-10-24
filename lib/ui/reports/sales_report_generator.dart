import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'report_period_text.dart';

/// One row of the sales report table — a single completed order.
class SalesReportEntry {
  final String orderNumber;
  final DateTime date;
  final String cashier;
  final String paymentMode;
  final String? paymentReference;
  final double subtotal;
  final double discount;
  final double total;

  const SalesReportEntry({
    required this.orderNumber,
    required this.date,
    required this.cashier,
    required this.paymentMode,
    this.paymentReference,
    required this.subtotal,
    required this.discount,
    required this.total,
  });
}

/// Builds a professional, multi-page sales summary PDF.
///
/// This class knows nothing about Supabase or the app's order model — it
/// just takes a flat list of [SalesReportEntry] and returns PDF bytes.
/// That keeps it reusable (e.g. an emailed daily close, a printed summary)
/// without depending on the transaction history page.
///
/// Usage:
/// ```dart
/// final bytes = await SalesReportGenerator.generate(
///   period: 'Daily',
///   periodStart: start,
///   periodEnd: end,
///   generatedAt: DateTime.now(),
///   generatedBy: 'Admin User',
///   sales: entries,
/// );
/// await Printing.sharePdf(bytes: bytes, filename: 'report.pdf');
/// ```
class SalesReportGenerator {
  SalesReportGenerator._();

  static Future<Uint8List> generate({
    required String period, // 'Daily' | 'Weekly' | 'Monthly'
    required DateTime periodStart,
    required DateTime periodEnd,
    required DateTime generatedAt,
    required String generatedBy,
    required List<SalesReportEntry> sales,
    String businessName = 'SPRJ Paint Center',
    String businessAddress = 'San Pedro, Laguna',
  }) async {
    final doc = pw.Document();

    final double grossSales = sales.fold(0.0, (s, e) => s + e.subtotal);
    final double totalDiscounts = sales.fold(0.0, (s, e) => s + e.discount);
    final double netRevenue = sales.fold(0.0, (s, e) => s + e.total);

    final Map<String, double> paymentBreakdown = {};
    for (final e in sales) {
      paymentBreakdown[e.paymentMode] =
          (paymentBreakdown[e.paymentMode] ?? 0) + e.total;
    }

    final reportRef =
        'SR-${generatedAt.year}${_two(generatedAt.month)}'
        '${_two(generatedAt.day)}-${_two(generatedAt.hour)}'
        '${_two(generatedAt.minute)}${_two(generatedAt.second)}';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(32, 28, 32, 28),
        header: (context) => _header(
          context: context,
          businessName: businessName,
          businessAddress: businessAddress,
          period: period,
          periodStart: periodStart,
          periodEnd: periodEnd,
          reportRef: reportRef,
          generatedAt: generatedAt,
        ),
        footer: (context) => _footer(
          context: context,
          generatedBy: generatedBy,
          generatedAt: generatedAt,
        ),
        build: (context) => [
          _summaryBox(
            orderCount: sales.length,
            grossSales: grossSales,
            totalDiscounts: totalDiscounts,
            netRevenue: netRevenue,
            paymentBreakdown: paymentBreakdown,
          ),
          pw.SizedBox(height: 16),
          _table(context, sales),
          pw.SizedBox(height: 4),
          _totalsRow(grossSales, totalDiscounts, netRevenue),
          pw.SizedBox(height: 32),
          _signatureBlock(),
        ],
      ),
    );

    return doc.save();
  }

  // ─── Header / Footer ────────────────────────────────────────────────────

  static pw.Widget _header({
    required pw.Context context,
    required String businessName,
    required String businessAddress,
    required String period,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String reportRef,
    required DateTime generatedAt,
  }) {
    // Full letterhead on the first page only.
    if (context.pageNumber == 1) {
      final asOf = ReportPeriodText.asOf(generatedAt, periodEnd);
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    businessName,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    businessAddress,
                    style: const pw.TextStyle(
                      fontSize: 10,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
              pw.Text(
                'Report Ref: $reportRef',
                style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.grey600,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Text(
            'Sales Summary Report',
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            '$period Report:  ${ReportPeriodText.label(period, periodStart, periodEnd)}',
            style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
          ),
          if (asOf != null) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              asOf,
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
          ],
          pw.SizedBox(height: 12),
          pw.Divider(color: PdfColors.grey400, thickness: 1),
        ],
      );
    }

    // Simplified running header on continuation pages.
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              '$businessName - Sales Summary Report (continued)',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              reportRef,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Divider(color: PdfColors.grey300, thickness: 0.5),
      ],
    );
  }

  static pw.Widget _footer({
    required pw.Context context,
    required String generatedBy,
    required DateTime generatedAt,
  }) {
    return pw.Column(
      children: [
        pw.Divider(color: PdfColors.grey300, thickness: 0.5),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Generated by $generatedBy on ${_formatDateTime(generatedAt)}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ],
        ),
      ],
    );
  }

  // ─── Summary box ────────────────────────────────────────────────────────

  static pw.Widget _summaryBox({
    required int orderCount,
    required double grossSales,
    required double totalDiscounts,
    required double netRevenue,
    required Map<String, double> paymentBreakdown,
  }) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _summaryLine('Total Orders Completed', '$orderCount'),
                _summaryLine('Gross Sales (Subtotal)', _currency(grossSales)),
                _summaryLine(
                  'Total Discounts Given',
                  _currency(totalDiscounts),
                  color: PdfColors.red700,
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'NET REVENUE: ${_currency(netRevenue)}',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.green800,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 24),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'PAYMENT BREAKDOWN',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.grey700,
                  ),
                ),
                pw.SizedBox(height: 6),
                ...paymentBreakdown.entries.map(
                  (e) => _summaryLine(e.key, _currency(e.value)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _summaryLine(String label, String value, {PdfColor? color}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 10)),
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Table ──────────────────────────────────────────────────────────────

  static pw.Widget _table(pw.Context context, List<SalesReportEntry> sales) {
    final headers = [
      'Order #',
      'Date & Time',
      'Cashier',
      'Payment / Reference',
      'Subtotal',
      'Discount',
      'Total',
    ];

    final data = sales.map((s) {
      return [
        s.orderNumber,
        _formatDateTime(s.date),
        s.cashier,
        s.paymentMode.toLowerCase() == 'gcash' &&
                s.paymentReference?.trim().isNotEmpty == true
            ? '${s.paymentMode}\n${s.paymentReference!.trim()}'
            : s.paymentMode,
        _currency(s.subtotal),
        s.discount > 0 ? _currency(s.discount) : '-',
        _currency(s.total),
      ];
    }).toList();

    // TableHelper.fromTextArray repeats the header row automatically on
    // every page when given the MultiPage `context` — that's what fixes
    // the "no header on page 2" problem from the old report.
    return pw.TableHelper.fromTextArray(
      context: context,
      headers: headers,
      data: data,
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        fontSize: 9,
        color: PdfColors.white,
      ),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
      headerPadding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      cellStyle: const pw.TextStyle(fontSize: 9),
      cellPadding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      cellAlignments: const {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerLeft,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.centerLeft,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.centerRight,
        6: pw.Alignment.centerRight,
      },
      columnWidths: {
        0: const pw.FlexColumnWidth(1.3),
        1: const pw.FlexColumnWidth(1.8),
        2: const pw.FlexColumnWidth(1.6),
        3: const pw.FlexColumnWidth(1.1),
        4: const pw.FlexColumnWidth(1.2),
        5: const pw.FlexColumnWidth(1.1),
        6: const pw.FlexColumnWidth(1.3),
      },
    );
  }

  static pw.Widget _totalsRow(
    double grossSales,
    double totalDiscounts,
    double netRevenue,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: PdfColors.grey700, width: 1),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.Text(
            'TOTAL   Subtotal: ${_currency(grossSales)}    '
            'Discount: ${_currency(totalDiscounts)}    ',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
          pw.Text(
            _currency(netRevenue),
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // ─── Signature block ────────────────────────────────────────────────────

  static pw.Widget _signatureBlock() {
    pw.Widget line(String label) {
      return pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(height: 24),
            pw.Container(height: 1, color: PdfColors.grey500),
            pw.SizedBox(height: 4),
            pw.Text(
              label,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ],
        ),
      );
    }

    return pw.Row(
      children: [
        line('Prepared by'),
        pw.SizedBox(width: 24),
        line('Reviewed by'),
        pw.SizedBox(width: 24),
        line('Approved by'),
      ],
    );
  }

  // ─── Formatting helpers ─────────────────────────────────────────────────

  static String _two(int n) => n.toString().padLeft(2, '0');

  // Note: uses the letter "P", not the ₱ glyph. The default PDF core fonts
  // used by the `pdf` package don't include the peso sign, so ₱ renders as
  // a blank box. This matches the convention already used by the existing
  // inventory report in this app.
  static String _currency(double value) {
    final reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    final withCommas = value
        .toStringAsFixed(2)
        .replaceAllMapped(reg, (m) => '${m[1]},');
    return 'P$withCommas';
  }

  static const _months = [
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

  static String _formatDateTime(DateTime d) {
    final hour = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final minute = _two(d.minute);
    final period = d.hour >= 12 ? 'PM' : 'AM';
    return '${_months[d.month - 1]} ${d.day}, ${d.year}, $hour:$minute $period';
  }

  static String _formatDate(DateTime d) =>
      '${_months[d.month - 1]} ${d.day}, ${d.year}';

  static String _formatRange(DateTime start, DateTime end) {
    if (_isSameDay(start, end)) return _formatDate(start);
    return '${_formatDate(start)} - ${_formatDate(end)}';
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
