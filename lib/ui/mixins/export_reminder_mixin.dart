import 'package:flutter/material.dart';
import '../../logic/inventory_controller.dart';
import '../../services/export_period.dart';
import '../../services/export_reminder_service.dart';
import '../../notifications/notification_provider.dart';
import '../widgets/app_toast.dart';

mixin ExportReminderMixin<T extends StatefulWidget> on State<T> {
  InventoryController get controller;
  String get exportReportType; // 'sales' | 'inventory'

  bool exportDue = false;
  List<ExportPeriodType> dueExportTypes = [];

  ExportReminderService get _service => ExportReminderService(
    supabase: controller.supabase,
    locationId: controller.activeLocationId,
  );

  /// Call this once, e.g. in initState (after a small delay or right away).
  Future<void> checkExportReminder() async {
    final due = await _service.dueReminders(exportReportType);
    if (!mounted) return;
    setState(() {
      dueExportTypes = due;
      exportDue = due.isNotEmpty;
    });
    if (due.isNotEmpty) {
      AppToast.error(context, _reminderMessage(due));
    }
  }

  /// Call this right after a successful export for [type].
  Future<void> markExported(ExportPeriodType type) async {
    final notificationController = NotificationProvider.maybeOf(context);
    final period = ExportPeriod.current(type);
    await _service.logExport(
      reportType: exportReportType,
      period: period,
      exportedBy: controller.currentUserNumericId,
    );
    if (!mounted) return;
    await notificationController?.resolveExportReminder(
      reportType: exportReportType,
      periodType: type.name,
      periodKey: period.key,
    );
    setState(() {
      dueExportTypes.remove(type);
      exportDue = dueExportTypes.isNotEmpty;
    });
  }

  String _reminderMessage(List<ExportPeriodType> due) {
    final labels = due.map((t) => t.label.toLowerCase()).join(', ');
    final what = exportReportType == 'inventory' ? 'inventory' : 'sales';
    return "Time to export your $labels $what report${due.length > 1 ? 's' : ''}.";
  }
}
