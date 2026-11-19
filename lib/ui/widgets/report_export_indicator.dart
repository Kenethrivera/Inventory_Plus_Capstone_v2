import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../services/report_export_controller.dart';

class ReportExportIndicator extends StatefulWidget {
  const ReportExportIndicator({
    super.key,
    required this.controller,
    required this.onDownloaded,
    required this.onDownloadError,
  });

  final ReportExportController controller;
  final void Function(String reportName, String destination) onDownloaded;
  final void Function(String message) onDownloadError;

  @override
  State<ReportExportIndicator> createState() => _ReportExportIndicatorState();
}

class _ReportExportIndicatorState extends State<ReportExportIndicator> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _pillOverlay;
  ReportExportPhase? _lastPhase;

  @override
  void initState() {
    super.initState();
    _lastPhase = widget.controller.phase;
    widget.controller.addListener(_handleExportChanged);
  }

  @override
  void didUpdateWidget(covariant ReportExportIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleExportChanged);
      widget.controller.addListener(_handleExportChanged);
      _lastPhase = widget.controller.phase;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleExportChanged);
    _collapse();
    super.dispose();
  }

  void _handleExportChanged() {
    final phase = widget.controller.phase;
    _pillOverlay?.markNeedsBuild();
    if (phase == ReportExportPhase.idle) {
      _collapse();
    } else if (phase != _lastPhase &&
        (phase == ReportExportPhase.ready ||
            phase == ReportExportPhase.failed)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _expand();
      });
    }
    _lastPhase = phase;
    if (mounted) setState(() {});
  }

  void _expand() {
    if (_pillOverlay != null || !mounted) return;
    _pillOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _collapse,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.centerRight,
            followerAnchor: Alignment.centerRight,
            child: Material(color: Colors.transparent, child: _buildPill()),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_pillOverlay!);
  }

  void _collapse() {
    _pillOverlay?.remove();
    _pillOverlay = null;
  }

  Future<void> _onPillTap() async {
    final phase = widget.controller.phase;
    if (phase == ReportExportPhase.failed) {
      widget.onDownloadError(
        widget.controller.errorMessage ?? 'Could not create the report.',
      );
      widget.controller.clear();
      return;
    }
    if (phase != ReportExportPhase.ready) {
      _collapse();
      return;
    }
    final name = widget.controller.reportName ?? 'Report';
    try {
      final destination = await widget.controller.download();
      if (destination != null) widget.onDownloaded(name, destination);
    } catch (_) {
      widget.onDownloadError(
        widget.controller.errorMessage ?? 'Could not save the report.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final export = widget.controller;
    if (!export.hasExport) return const SizedBox.shrink();
    final color = switch (export.phase) {
      ReportExportPhase.ready ||
      ReportExportPhase.saving => const Color(0xFF15803D),
      ReportExportPhase.failed => const Color(0xFFDC2626),
      _ => const Color(0xFFC83D08),
    };
    return CompositedTransformTarget(
      link: _layerLink,
      child: Semantics(
        button: true,
        label: export.phase == ReportExportPhase.ready
            ? '${export.reportName} ready. Tap to download.'
            : '${export.reportName} exporting ${(export.progress * 100).round()} percent. Tap for details.',
        child: InkWell(
          onTap: _expand,
          customBorder: const CircleBorder(),
          child: Container(
            width: 48,
            height: 48,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value:
                        export.phase == ReportExportPhase.exporting &&
                            export.progress == 0
                        ? null
                        : export.progress,
                    strokeWidth: 2.5,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.15),
                  ),
                ),
                Icon(
                  export.phase == ReportExportPhase.ready
                      ? LucideIcons.check
                      : export.phase == ReportExportPhase.failed
                      ? LucideIcons.triangleAlert
                      : LucideIcons.download,
                  color: color,
                  size: 17,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPill() {
    final export = widget.controller;
    final ready = export.phase == ReportExportPhase.ready;
    final failed = export.phase == ReportExportPhase.failed;
    final saving = export.phase == ReportExportPhase.saving;
    final color = ready || saving
        ? const Color(0xFF15803D)
        : failed
        ? const Color(0xFFDC2626)
        : Colors.white;
    final foreground = ready || failed || saving
        ? Colors.white
        : const Color(0xFF211F1D);
    final title = ready
        ? 'Report ready'
        : failed
        ? 'Export failed'
        : saving
        ? 'Saving report…'
        : 'Exporting ${(export.progress * 100).round()}%';
    final subtitle = ready
        ? 'Tap to download'
        : failed
        ? 'Tap to dismiss'
        : export.reportName ?? 'Report';
    return InkWell(
      onTap: () => unawaited(_onPillTap()),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(minWidth: 160, maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ready
                  ? LucideIcons.circleCheck
                  : failed
                  ? LucideIcons.triangleAlert
                  : LucideIcons.download,
              size: 20,
              color: ready || failed || saving
                  ? Colors.white
                  : const Color(0xFFC83D08),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: foreground, fontSize: 10),
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
