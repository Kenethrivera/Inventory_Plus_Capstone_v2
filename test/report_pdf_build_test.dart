import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/services/report_pdf_build.dart';
import 'package:inventory_plus/ui/reports/inventory_report_generator.dart';
import 'package:inventory_plus/ui/reports/sales_report_generator.dart';

void main() {
  testWidgets('report data builds PDFs without sending the UI tree', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Reports page'))),
    );
    final pageContext = tester.element(find.text('Reports page'));
    expect(pageContext.mounted, isTrue);
    final now = DateTime(2026, 11, 19);
    final sales = [
      SalesReportEntry(
        orderNumber: 'A123',
        date: now,
        cashier: 'Cashier',
        paymentMode: 'Cash',
        subtotal: 100,
        discount: 0,
        total: 100,
      ),
    ];
    final inventory = [
      const InventoryReportEntry(
        sku: 'SKU-1',
        name: 'Hammer',
        unit: 'pcs',
        beginningQty: 10,
        received: 2,
        issued: 1,
        endingQty: 11,
        unitCost: 100,
      ),
    ];
    final salesPdf = await tester.runAsync(
      () => buildSalesReportPdf(
        SalesReportPdfRequest(
          period: 'Daily',
          periodStart: now,
          periodEnd: now,
          generatedAt: now,
          generatedBy: 'Admin',
          sales: sales,
        ),
      ),
    );
    final inventoryPdf = await tester.runAsync(
      () => buildInventoryReportPdf(
        InventoryReportPdfRequest(
          period: 'Daily',
          periodStart: now,
          periodEnd: now,
          generatedAt: now,
          generatedBy: 'Admin',
          items: inventory,
        ),
      ),
    );
    expect(String.fromCharCodes(salesPdf!.take(5)), '%PDF-');
    expect(String.fromCharCodes(inventoryPdf!.take(5)), '%PDF-');
  });
}
