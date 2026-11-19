import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../services/report_export_controller.dart';

/// Anchored Analytics export menu, including the active job state.
class AnalyticsExportMenu extends StatefulWidget {
  const AnalyticsExportMenu({
    super.key,
    required this.periodLabel,
    required this.export,
    required this.onSales,
    required this.onInventory,
  });

  final String periodLabel;
  final ReportExportController export;
  final VoidCallback onSales;
  final VoidCallback onInventory;

  @override
  State<AnalyticsExportMenu> createState() => _AnalyticsExportMenuState();
}

class _AnalyticsExportMenuState extends State<AnalyticsExportMenu> {
  static const _orange = Color(0xFFC83D08);
  static const _ink = Color(0xFF171717);
  static const _muted = Color(0xFF817A75);
  static const _line = Color(0xFFE7E1DB);

  final LayerLink _link = LayerLink();
  OverlayEntry? _menu;

  @override
  void didUpdateWidget(covariant AnalyticsExportMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    _menu?.markNeedsBuild();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _toggle() => _menu == null ? _open() : _close();

  void _open() {
    if (_menu != null) return;
    _menu = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 8),
            child: Material(
              color: Colors.transparent,
              child: ListenableBuilder(
                listenable: widget.export,
                builder: (_, _) => _panel(),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_menu!);
  }

  void _close() {
    _menu?.remove();
    _menu = null;
  }

  void _choose(VoidCallback action) {
    _close();
    action();
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
    link: _link,
    child: SizedBox(
      width: 44,
      height: 44,
      child: OutlinedButton(
        onPressed: _toggle,
        style: OutlinedButton.styleFrom(
          foregroundColor: _orange,
          backgroundColor: Colors.white,
          padding: EdgeInsets.zero,
          side: const BorderSide(color: _orange),
          shape: const CircleBorder(),
        ),
        child: const Icon(LucideIcons.download, size: 19),
      ),
    ),
  );

  Widget _panel() {
    final export = widget.export;
    final busy = export.hasExport;
    final active = export.reportName;
    final notice = switch (export.phase) {
      ReportExportPhase.exporting =>
        '${active ?? 'A report'} is exporting. Wait for it to finish before starting another.',
      ReportExportPhase.ready =>
        '${active ?? 'A report'} is ready. Tap the green indicator to download it first.',
      ReportExportPhase.saving => 'A report is saving. Please wait.',
      ReportExportPhase.failed =>
        'The export failed. Dismiss its indicator before trying again.',
      ReportExportPhase.idle => null,
    };
    return Container(
      width: (MediaQuery.sizeOf(context).width - 24).clamp(0.0, 280.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 15, 16, 12),
            child: Text(
              'Export report',
              style: TextStyle(
                color: _ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Divider(height: 1, color: _line),
          _option(
            title: 'Sales report',
            icon: LucideIcons.chartNoAxesCombined,
            status: busy ? _statusFor('Sales report') : null,
            onTap: busy ? null : () => _choose(widget.onSales),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16, color: _line),
          _option(
            title: 'Inventory report',
            icon: LucideIcons.package,
            status: busy ? _statusFor('Inventory report') : null,
            onTap: busy ? null : () => _choose(widget.onInventory),
          ),
          if (notice != null) ...[
            const Divider(height: 1, color: _line),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 15),
              child: Text(
                notice,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _statusFor(String title) {
    if (widget.export.reportName != title) return 'Wait';
    return switch (widget.export.phase) {
      ReportExportPhase.exporting => 'Exporting…',
      ReportExportPhase.ready => 'Ready',
      ReportExportPhase.saving => 'Saving…',
      ReportExportPhase.failed => 'Failed',
      ReportExportPhase.idle => '',
    };
  }

  Widget _option({
    required String title,
    required IconData icon,
    required String? status,
    required VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Icon(icon, color: onTap == null ? _muted : _orange, size: 19),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: onTap == null ? _muted : _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.periodLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ],
            ),
          ),
          if (status != null)
            Text(
              status,
              style: const TextStyle(
                color: _orange,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    ),
  );
}
