import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../logic/helper_assignment.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFamily = 'Hellix';

class HelperAssignmentSelector extends StatefulWidget {
  const HelperAssignmentSelector({
    super.key,
    required this.helpers,
    required this.workloads,
    required this.selectedHelperId,
    required this.enabled,
    required this.onChanged,
  });

  final List<HelperAssignmentCandidate> helpers;
  final Map<String, int> workloads;
  final String? selectedHelperId;
  final bool enabled;
  final ValueChanged<String?>? onChanged;

  @override
  State<HelperAssignmentSelector> createState() =>
      _HelperAssignmentSelectorState();
}

class _HelperAssignmentSelectorState extends State<HelperAssignmentSelector> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _triggerKey = GlobalKey();
  final FocusNode _focusNode = FocusNode();

  OverlayEntry? _menuEntry;
  bool _hovered = false;
  bool _focused = false;
  bool _invalidFallbackScheduled = false;
  bool _menuRebuildScheduled = false;

  bool get _isOpen => _menuEntry != null;

  HelperAssignmentCandidate? get _selectedHelper {
    final selectedId = widget.selectedHelperId;
    if (selectedId == null) return null;
    for (final helper in widget.helpers) {
      if (helper.id == selectedId) return helper;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _scheduleUnavailableSelectionFallback();
  }

  @override
  void didUpdateWidget(covariant HelperAssignmentSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isOpen) _closeMenu();
      });
    } else {
      _scheduleMenuRebuild();
    }
    _scheduleUnavailableSelectionFallback();
  }

  @override
  void dispose() {
    _menuEntry?.remove();
    _menuEntry = null;
    _menuRebuildScheduled = false;
    _focusNode.dispose();
    super.dispose();
  }

  void _scheduleMenuRebuild() {
    if (!_isOpen || _menuRebuildScheduled) return;
    _menuRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _menuRebuildScheduled = false;
      if (mounted) _menuEntry?.markNeedsBuild();
    });
  }

  void _scheduleUnavailableSelectionFallback() {
    final selectedId = widget.selectedHelperId;
    if (selectedId == null ||
        widget.helpers.any((helper) => helper.id == selectedId) ||
        _invalidFallbackScheduled) {
      return;
    }

    _invalidFallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _invalidFallbackScheduled = false;
      if (!mounted) return;
      final currentId = widget.selectedHelperId;
      if (currentId != null &&
          !widget.helpers.any((helper) => helper.id == currentId)) {
        widget.onChanged?.call(null);
      }
    });
  }

  void _toggleMenu() {
    if (!widget.enabled) return;
    _focusNode.requestFocus();
    if (_isOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (_isOpen || !widget.enabled) return;
    final overlay = Overlay.of(context);
    _menuEntry = OverlayEntry(builder: _buildMenuOverlay);
    overlay.insert(_menuEntry!);
    setState(() {});
  }

  void _closeMenu() {
    final entry = _menuEntry;
    if (entry == null) return;
    _menuEntry = null;
    entry.remove();
    if (mounted) setState(() {});
  }

  void _select(String? helperId) {
    _closeMenu();
    widget.onChanged?.call(helperId);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape && _isOpen) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (!_isOpen) _openMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildMenuOverlay(BuildContext overlayContext) {
    final triggerBox =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final triggerWidth = triggerBox?.size.width ?? 260.0;
    final optionCount = widget.helpers.length + 1;
    final menuHeight = math.min(8.0 + (optionCount * 58.0), 300.0);

    var openUpward = false;
    if (triggerBox != null && overlayBox != null) {
      final targetTop = triggerBox.localToGlobal(
        Offset.zero,
        ancestor: overlayBox,
      );
      final spaceBelow =
          overlayBox.size.height - targetTop.dy - triggerBox.size.height;
      openUpward = spaceBelow < menuHeight && targetTop.dy > menuHeight;
    }

    final selectedHelper = _selectedHelper;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeMenu,
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: Offset(0, openUpward ? -(menuHeight + 6) : 46),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: triggerWidth,
              height: menuHeight,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFD7E0EC)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A0F172A),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _HelperMenuOption(
                    key: const Key('helper-option-auto'),
                    icon: LucideIcons.zap,
                    title: 'Auto-assign',
                    subtitle: 'Least-loaded available Helper',
                    selected: selectedHelper == null,
                    onTap: () => _select(null),
                  ),
                  ...widget.helpers.map((helper) {
                    final count = widget.workloads[helper.id] ?? 0;
                    return _HelperMenuOption(
                      key: Key('helper-option-${helper.id}'),
                      icon: LucideIcons.userRound,
                      title: helper.name,
                      subtitle: _activeOrderLabel(count),
                      selected: selectedHelper?.id == helper.id,
                      onTap: () => _select(helper.id),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedHelper = _selectedHelper;
    final selectedCount = selectedHelper == null
        ? 0
        : widget.workloads[selectedHelper.id] ?? 0;
    final highlighted = widget.enabled && (_hovered || _focused || _isOpen);

    return Row(
      children: [
        const Text(
          'Helper packs',
          style: TextStyle(
            color: Color(0xFF475569),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: _fontFamily,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: CompositedTransformTarget(
            link: _layerLink,
            child: Focus(
              focusNode: _focusNode,
              onFocusChange: (focused) {
                if (_focused != focused) setState(() => _focused = focused);
              },
              onKeyEvent: _handleKeyEvent,
              child: MouseRegion(
                cursor: widget.enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: Semantics(
                  button: true,
                  enabled: widget.enabled,
                  expanded: _isOpen,
                  label: selectedHelper == null
                      ? 'Auto-assign Helper, least loaded'
                      : 'Assigned Helper ${selectedHelper.name}',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: _triggerKey,
                      onTap: widget.enabled ? _toggleMenu : null,
                      borderRadius: BorderRadius.circular(9),
                      hoverColor: Colors.transparent,
                      splashColor: const Color(0x142563EB),
                      child: AnimatedContainer(
                        key: const Key('helper-assignment-trigger'),
                        duration: const Duration(milliseconds: 120),
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: highlighted
                              ? const Color(0xFFF3F7FF)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: highlighted
                                ? _primaryBlue
                                : const Color(0xFFD7E0EC),
                            width: highlighted ? 1.25 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: highlighted
                                    ? const Color(0xFFE3EDFF)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Icon(
                                selectedHelper == null
                                    ? LucideIcons.zap
                                    : LucideIcons.userRound,
                                size: 15,
                                color: _primaryBlue,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                selectedHelper == null
                                    ? 'Auto-assign — least loaded'
                                    : '${selectedHelper.name} — '
                                          '${_activeOrderLabel(selectedCount)}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF0F172A),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: _fontFamily,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            AnimatedRotation(
                              turns: _isOpen ? 0.5 : 0,
                              duration: const Duration(milliseconds: 120),
                              child: const Icon(
                                LucideIcons.chevronDown,
                                size: 17,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HelperMenuOption extends StatelessWidget {
  const _HelperMenuOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFEFF6FF) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        hoverColor: const Color(0xFFF1F5F9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 16, color: _primaryBlue),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF0F172A),
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w700,
                        fontFamily: _fontFamily,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        fontFamily: _fontFamily,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                const Icon(LucideIcons.check, size: 16, color: _primaryBlue),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _activeOrderLabel(int count) {
  return '$count active ${count == 1 ? 'order' : 'orders'}';
}
