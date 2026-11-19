import 'package:flutter/foundation.dart';

import '../ui/reports/inventory_report_generator.dart';
import '../ui/reports/sales_report_generator.dart';

/// Plain report data is the only value sent to the background isolate.
class SalesReportPdfRequest {
  const SalesReportPdfRequest({
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.generatedAt,
    required this.generatedBy,
    required this.sales,
    this.businessName = 'SPRJ Paint Center',
  });

  final String period;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime generatedAt;
  final String generatedBy;
  final List<SalesReportEntry> sales;
  final String businessName;
}

class InventoryReportPdfRequest {
  const InventoryReportPdfRequest({
    required this.period,
    required this.periodStart,
    required this.periodEnd,
    required this.generatedAt,
    required this.generatedBy,
    required this.items,
    this.businessName = 'SPRJ Paint Center',
  });

  final String period;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime generatedAt;
  final String generatedBy;
  final List<InventoryReportEntry> items;
  final String businessName;
}

Future<Uint8List> buildSalesReportPdf(SalesReportPdfRequest request) =>
    compute(_buildSalesPdf, request);

Future<Uint8List> buildInventoryReportPdf(InventoryReportPdfRequest request) =>
    compute(_buildInventoryPdf, request);

Future<Uint8List> _buildSalesPdf(SalesReportPdfRequest request) =>
    SalesReportGenerator.generate(
      period: request.period,
      periodStart: request.periodStart,
      periodEnd: request.periodEnd,
      generatedAt: request.generatedAt,
      generatedBy: request.generatedBy,
      sales: request.sales,
      businessName: request.businessName,
    );

Future<Uint8List> _buildInventoryPdf(InventoryReportPdfRequest request) =>
    InventoryReportGenerator.generate(
      period: request.period,
      periodStart: request.periodStart,
      periodEnd: request.periodEnd,
      generatedAt: request.generatedAt,
      generatedBy: request.generatedBy,
      items: request.items,
      businessName: request.businessName,
    );
