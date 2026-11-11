import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'store_map.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_styled_dropdown.dart';

const Color _primaryBlue = Color(0xFFC83D08);
const Color _lightBg = Color(0xFFF7F5F3);
const String _fontFam = 'Hellix'; // Or 'Outline'

class MapEditorPage extends StatefulWidget {
  final InventoryController controller;

  const MapEditorPage({super.key, required this.controller});

  @override
  State<MapEditorPage> createState() => _MapEditorPageState();
}

class _MapEditorPageState extends State<MapEditorPage> {
  final GlobalKey<StoreMapState> _storeMapKey = GlobalKey<StoreMapState>();
  MapElement? _manageSelected;
  MapMode _mode = MapMode.manage;
  MapViewStyle _viewStyle = MapViewStyle.twoD;
  ElementType? _placementType;
  String? _productToAssignId;
  String? _selectedItemId;
  String _assignFilter = 'All';
  String _assignmentSearch = '';
  bool _hideWalls = false;
  List<MapElement> _draftLayout = <MapElement>[];
  List<MapElement> _baselineLayout = <MapElement>[];
  List<MapElement> _historyCurrent = <MapElement>[];
  final List<List<MapElement>> _undoStack = <List<MapElement>>[];
  final List<List<MapElement>> _redoStack = <List<MapElement>>[];
  String _baselineSignature = '';
  String? _draftLocationId;
  String? _draftUserId;
  bool _isLayoutReady = false;
  bool _isSaving = false;
  bool _remoteChangePending = false;
  bool _remoteChangeToastShown = false;
  bool _allowRoutePop = false;
  Object? _layoutLoadError;
  StreamSubscription<List<MapElement>>? _layoutSubscription;
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;

  @override
  void initState() {
    super.initState();
    _layoutSubscription = widget.controller.mapLayoutSnapshots.listen(
      _handleCanonicalLayout,
    );
    _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
      if (!mounted) return;
      if (_isLayoutReady &&
          _draftUserId != null &&
          _draftUserId != widget.controller.currentUserId) {
        _resetDraftForCurrentScope();
      } else {
        setState(() {});
      }
    });
    unawaited(_initializeLayout());
  }

  Future<void> _initializeLayout() async {
    try {
      await widget.controller.fetchMapLayout();
      if (!mounted) return;

      final List<MapElement> canonical = widget.controller.currentMapLayout;
      setState(() {
        _draftLayout = widget.controller.cloneMapLayout(canonical);
        _baselineLayout = widget.controller.cloneMapLayout(canonical);
        _resetHistory(canonical);
        _baselineSignature = widget.controller.mapLayoutSignature(canonical);
        _draftLocationId = widget.controller.activeLocationId;
        _draftUserId = widget.controller.currentUserId;
        _isLayoutReady = true;
        _layoutLoadError = null;
      });
      final selectable = canonical.where(
        (element) =>
            element.type == ElementType.rack ||
            element.type == ElementType.shelf,
      );
      if (selectable.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted)
            _storeMapKey.currentState?.selectManageElement(selectable.first.id);
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _layoutLoadError = error);
    }
  }

  bool get _hasDirtyDraft =>
      _isLayoutReady &&
      widget.controller.mapLayoutSignature(_draftLayout) != _baselineSignature;

  Map<String, MapElement> get _assignmentTargets => {
    for (final element in _draftLayout)
      if (element.type == ElementType.rack || element.type == ElementType.shelf)
        element.id: element,
  };

  int get _assignedCount {
    final targets = _assignmentTargets;
    return widget.controller.allItems
        .where((item) => targets.containsKey(item.locationId))
        .length;
  }

  String? get _selectedAssignmentTargetId {
    final selected = _selectedItemId;
    if (selected == null) return null;
    for (final item in widget.controller.allItems) {
      if (item.id == selected) {
        return _assignmentTargets[item.locationId]?.id;
      }
    }
    return null;
  }

  void _resetHistory(Iterable<MapElement> layout) {
    _historyCurrent = widget.controller.cloneMapLayout(layout);
    _undoStack.clear();
    _redoStack.clear();
  }

  void _recordLayoutEdit() {
    if (_isSaving || !_isLayoutReady) return;
    if (widget.controller.mapLayoutSignature(_draftLayout) ==
        widget.controller.mapLayoutSignature(_historyCurrent))
      return;
    setState(() {
      _undoStack.add(_historyCurrent);
      if (_undoStack.length > 50) _undoStack.removeAt(0);
      _historyCurrent = widget.controller.cloneMapLayout(_draftLayout);
      _redoStack.clear();
    });
  }

  void _undo() {
    if (_mode != MapMode.manage || _isSaving || _undoStack.isEmpty) return;
    _storeMapKey.currentState?.clearManageSelection();
    setState(() {
      _redoStack.add(_historyCurrent);
      _historyCurrent = _undoStack.removeLast();
      _draftLayout = widget.controller.cloneMapLayout(_historyCurrent);
      _manageSelected = null;
    });
  }

  void _redo() {
    if (_mode != MapMode.manage || _isSaving || _redoStack.isEmpty) return;
    _storeMapKey.currentState?.clearManageSelection();
    setState(() {
      _undoStack.add(_historyCurrent);
      _historyCurrent = _redoStack.removeLast();
      _draftLayout = widget.controller.cloneMapLayout(_historyCurrent);
      _manageSelected = null;
    });
  }

  void _handleCanonicalLayout(List<MapElement> canonical) {
    if (!mounted || !_isLayoutReady || _isSaving) return;

    if (_draftLocationId != widget.controller.activeLocationId) {
      _resetDraftForCurrentScope(canonical: canonical);
      unawaited(_reloadLatestLayout());
      return;
    }

    final String canonicalSignature = widget.controller.mapLayoutSignature(
      canonical,
    );
    if (canonicalSignature == _baselineSignature) {
      if (_remoteChangePending) {
        setState(() {
          _remoteChangePending = false;
          _remoteChangeToastShown = false;
        });
      }
      return;
    }

    if (_hasDirtyDraft) {
      setState(() => _remoteChangePending = true);
      if (!_remoteChangeToastShown) {
        _remoteChangeToastShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            AppToast.error(
              context,
              'A newer saved layout is available. Your draft was kept.',
            );
          }
        });
      }
      return;
    }

    setState(() {
      _draftLayout = widget.controller.cloneMapLayout(canonical);
      _baselineLayout = widget.controller.cloneMapLayout(canonical);
      _resetHistory(canonical);
      _baselineSignature = canonicalSignature;
      _remoteChangePending = false;
      _remoteChangeToastShown = false;
      _manageSelected = null;
    });
  }

  void _resetDraftForCurrentScope({List<MapElement>? canonical}) {
    final List<MapElement> current =
        canonical ?? widget.controller.currentMapLayout;
    setState(() {
      _draftLayout = widget.controller.cloneMapLayout(current);
      _baselineLayout = widget.controller.cloneMapLayout(current);
      _resetHistory(current);
      _baselineSignature = widget.controller.mapLayoutSignature(current);
      _draftLocationId = widget.controller.activeLocationId;
      _draftUserId = widget.controller.currentUserId;
      _remoteChangePending = false;
      _remoteChangeToastShown = false;
      _manageSelected = null;
    });
  }

  @override
  void dispose() {
    _layoutSubscription?.cancel();
    _inventorySubscription?.cancel();
    super.dispose();
  }

  Future<void> _saveDraft({bool clear = false}) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final MapLayoutSaveResult result = await widget.controller
          .saveMapLayoutIfUnchanged(
            draft: clear ? <MapElement>[] : _draftLayout,
            baseline: _baselineLayout,
            baselineSignature: _baselineSignature,
            expectedLocationId: _draftLocationId ?? '',
            expectedUserId: _draftUserId ?? '',
            clear: clear,
          );
      if (!mounted) return;

      if (result.status == MapLayoutSaveStatus.conflict) {
        setState(() => _remoteChangePending = true);
        await _showSaveConflictDialog();
        return;
      }

      setState(() {
        _draftLayout = widget.controller.cloneMapLayout(result.layout);
        _baselineLayout = widget.controller.cloneMapLayout(result.layout);
        _resetHistory(result.layout);
        _baselineSignature = result.signature;
        _draftLocationId = widget.controller.activeLocationId;
        _draftUserId = widget.controller.currentUserId;
        _remoteChangePending = false;
        _remoteChangeToastShown = false;
        _manageSelected = null;
      });
      AppToast.success(
        context,
        clear ? 'Map layout cleared' : 'Store layout saved successfully!',
      );
    } catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          clear
              ? 'Could not clear the map. Your draft was kept.'
              : 'Could not save the map. Your draft was kept.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showSaveConflictDialog() async {
    final bool reload =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AppDialog(
            icon: LucideIcons.triangleAlert,
            color: Colors.orange.shade700,
            title: 'Newer Map Layout Found',
            subtitle: 'Your draft was not overwritten',
            child: const Text(
              'The store map was changed by another user. Refresh and review '
              'the latest version. You can keep editing your current draft, '
              'or reload the newest saved layout. '
              'Reloading will discard your local changes.',
              style: TextStyle(fontFamily: _fontFam, fontSize: 13),
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep Editing'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.shade700,
                ),
                child: const Text(
                  'Reload Latest',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (reload && mounted) await _reloadLatestLayout();
  }

  Future<void> _confirmReloadLatest() async {
    final bool reload =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AppDialog(
            icon: LucideIcons.refreshCw,
            color: Colors.orange.shade700,
            title: 'Reload Latest Layout?',
            subtitle: 'Discard this local draft',
            child: const Text(
              'The newest saved layout will replace your unsaved local '
              'changes. This cannot be undone.',
              style: TextStyle(fontFamily: _fontFam, fontSize: 13),
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep Editing'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.shade700,
                ),
                child: const Text(
                  'Discard & Reload',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (reload && mounted) await _reloadLatestLayout();
  }

  Future<void> _reloadLatestLayout() async {
    try {
      await widget.controller.fetchMapLayout(force: true);
      if (!mounted) return;

      final List<MapElement> canonical = widget.controller.currentMapLayout;
      setState(() {
        _draftLayout = widget.controller.cloneMapLayout(canonical);
        _baselineLayout = widget.controller.cloneMapLayout(canonical);
        _resetHistory(canonical);
        _baselineSignature = widget.controller.mapLayoutSignature(canonical);
        _draftLocationId = widget.controller.activeLocationId;
        _draftUserId = widget.controller.currentUserId;
        _remoteChangePending = false;
        _remoteChangeToastShown = false;
        _manageSelected = null;
      });
    } catch (error) {
      if (mounted) {
        AppToast.error(context, 'Could not load the newest saved layout.');
      }
    }
  }

  Future<void> _confirmDiscardAndLeave() async {
    final bool discard =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AppDialog(
            icon: LucideIcons.triangleAlert,
            color: Colors.orange.shade700,
            title: 'Discard Unsaved Map Changes?',
            subtitle: _remoteChangePending
                ? 'A newer saved layout is also available'
                : 'Your local draft has not been saved',
            child: const Text(
              'Leaving will discard your local map changes. The latest saved '
              'layout in Supabase will remain unchanged.',
              style: TextStyle(fontFamily: _fontFam, fontSize: 13),
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep Editing'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.shade700,
                ),
                child: const Text(
                  'Discard & Leave',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!discard || !mounted) return;
    setState(() => _allowRoutePop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) => _buildDashboardMap(context);

  Widget _buildDashboardMap(BuildContext context) {
    if (!_isLayoutReady) {
      return ColoredBox(
        color: _lightBg,
        child: Center(
          child: _layoutLoadError == null
              ? const CircularProgressIndicator(color: _primaryBlue)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Could not load the store map.'),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () {
                        setState(() => _layoutLoadError = null);
                        unawaited(_initializeLayout());
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): _redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            _redo,
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: _allowRoutePop || !_hasDirtyDraft,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) unawaited(_confirmDiscardAndLeave());
          },
          child: Scaffold(
            backgroundColor: _lightBg,
            body: LayoutBuilder(
              builder: (context, constraints) {
                final desktop = constraints.maxWidth >= 920;
                final horizontal = desktop ? 32.0 : 16.0;
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(horizontal, 32, horizontal, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: desktop
                                ? constraints.maxWidth - 340
                                : constraints.maxWidth - horizontal * 2,
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Store map',
                                  style: TextStyle(
                                    color: Color(0xFF171717),
                                    fontSize: 25,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                                SizedBox(height: 5),
                                Text(
                                  'Lay out the floor, place fixtures and assign products. Helpers see the saved map on their phones.',
                                  style: TextStyle(
                                    color: Color(0xFF827872),
                                    fontSize: 14,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OutlinedButton(
                                onPressed: _hasDirtyDraft && !_isSaving
                                    ? _discardDraft
                                    : null,
                                child: const Text('Discard'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: _primaryBlue,
                                ),
                                onPressed: _hasDirtyDraft && !_isSaving
                                    ? () => unawaited(_saveDraft())
                                    : null,
                                child: Text(_isSaving ? 'Saving…' : 'Save map'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (_remoteChangePending) _buildRemoteChangeBanner(),
                      _buildMapToolbar(),
                      const SizedBox(height: 14),
                      if (desktop)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildMapCanvas()),
                            const SizedBox(width: 18),
                            SizedBox(
                              width: 340,
                              child: _mode == MapMode.selection
                                  ? _buildAssignmentPanel()
                                  : _buildFixturePanel(),
                            ),
                          ],
                        )
                      else
                        Column(
                          children: [
                            _buildMapCanvas(),
                            const SizedBox(height: 16),
                            _mode == MapMode.selection
                                ? _buildAssignmentPanel()
                                : _buildFixturePanel(),
                          ],
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _switchMode(MapMode mode) {
    if (_mode == mode) return;
    _storeMapKey.currentState?.clearManageSelection();
    setState(() {
      _mode = mode;
      _placementType = null;
      _manageSelected = null;
      _selectedItemId = null;
      _productToAssignId = null;
    });
  }

  Widget _buildModeTabs() => Container(
    padding: const EdgeInsets.all(3),
    decoration: _mapPanelDecoration(),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _modeTab(MapMode.manage, 'Manage layout', LucideIcons.pencil),
        _modeTab(MapMode.selection, 'Assign items', LucideIcons.link),
      ],
    ),
  );

  Widget _modeTab(MapMode mode, String label, IconData icon) {
    final selected = _mode == mode;
    return TextButton.icon(
      onPressed: () => _switchMode(mode),
      style: TextButton.styleFrom(
        foregroundColor: selected ? Colors.white : const Color(0xFF514A45),
        backgroundColor: selected
            ? const Color(0xFF1C1C1C)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildMapToolbar() {
    final editingTools = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_mode == MapMode.manage)
          Container(
            padding: const EdgeInsets.all(3),
            decoration: _mapPanelDecoration(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mapTool('Select', LucideIcons.mousePointer2, null),
                for (final type in ElementType.values)
                  _mapTool(_elementLabel(type), _elementIcon(type), type),
              ],
            ),
          ),
        if (_mode == MapMode.manage) const SizedBox(width: 10),
        if (_mode == MapMode.manage)
          Container(
            padding: const EdgeInsets.all(3),
            decoration: _mapPanelDecoration(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: _undoStack.isEmpty ? null : _undo,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(LucideIcons.undo2, size: 17),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: _redoStack.isEmpty ? null : _redo,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(LucideIcons.redo2, size: 17),
                ),
                TextButton.icon(
                  onPressed: _draftLayout.isEmpty || _isSaving
                      ? null
                      : _confirmClearDraft,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(LucideIcons.eraser, size: 17),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ),
      ],
    );
    final viewToggle = Container(
      padding: const EdgeInsets.all(3),
      decoration: _mapPanelDecoration(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _viewTool(MapViewStyle.twoD, 'Floor plan', LucideIcons.square),
          _viewTool(MapViewStyle.threeD, '3D view', LucideIcons.box),
        ],
      ),
    );
    final zoomControls = Container(
      padding: const EdgeInsets.all(3),
      decoration: _mapPanelDecoration(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _mapZoomButton(
            'Zoom in',
            LucideIcons.plus,
            () => _storeMapKey.currentState?.zoomIn(),
          ),
          _mapZoomButton(
            'Zoom out',
            LucideIcons.minus,
            () => _storeMapKey.currentState?.zoomOut(),
          ),
          _mapZoomButton(
            'Center map',
            LucideIcons.focus,
            () => _storeMapKey.currentState?.recenterMap(),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [_buildModeTabs(), viewToggle],
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              if (_mode == MapMode.manage) editingTools,
              if (_mode == MapMode.manage) const SizedBox(width: 10),
              zoomControls,
            ],
          ),
        ),
      ],
    );
  }

  Widget _mapZoomButton(
    String tooltip,
    IconData icon,
    VoidCallback onPressed,
  ) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    padding: EdgeInsets.zero,
    icon: Icon(icon, size: 17, color: const Color(0xFF302C29)),
  );

  Widget _mapTool(String label, IconData icon, ElementType? type) {
    final selected = _placementType == type;
    final enabled = _viewStyle == MapViewStyle.twoD || type == null;
    return TextButton.icon(
      onPressed: !enabled ? null : () => setState(() => _placementType = type),
      style: TextButton.styleFrom(
        foregroundColor: selected ? Colors.white : const Color(0xFF292725),
        backgroundColor: selected
            ? const Color(0xFF1C1C1C)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
      ),
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _viewTool(MapViewStyle style, String label, IconData icon) {
    final selected = _viewStyle == style;
    return TextButton.icon(
      onPressed: () => setState(() {
        _viewStyle = style;
        if (style == MapViewStyle.threeD) _placementType = null;
      }),
      style: TextButton.styleFrom(
        foregroundColor: selected ? _primaryBlue : const Color(0xFF302C29),
        backgroundColor: selected
            ? const Color(0xFFFFF0E8)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      ),
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  BoxDecoration _mapPanelDecoration() => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(11),
    border: Border.all(color: const Color(0xFFE7E1DB)),
  );

  String _elementLabel(ElementType type) => switch (type) {
    ElementType.wall => 'Wall',
    ElementType.door => 'Door',
    ElementType.rack => 'Rack',
    ElementType.shelf => 'Shelf',
    ElementType.cashier => 'Cashier',
  };

  IconData _elementIcon(ElementType type) => switch (type) {
    ElementType.wall => LucideIcons.grid3x3,
    ElementType.door => LucideIcons.doorOpen,
    ElementType.rack => LucideIcons.columns3,
    ElementType.shelf => LucideIcons.rows3,
    ElementType.cashier => LucideIcons.rectangleHorizontal,
  };

  Widget _buildMapCanvas() => Container(
    height: 640,
    decoration: _mapPanelDecoration(),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        if (_placementType != null && _viewStyle == MapViewStyle.twoD)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFFFFF0E8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Click anywhere on the grid to place a ${_elementLabel(_placementType!).toLowerCase()}.',
                    style: const TextStyle(color: _primaryBlue, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _placementType = null),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        if (_mode == MapMode.selection)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFFFFF0E8),
            child: Text(
              _hasDirtyDraft || _remoteChangePending
                  ? 'Save or reload the map before assigning products.'
                  : _selectedItemId == null
                  ? 'Select a product from the list, then tap a rack or shelf on the map.'
                  : 'Tap a rack or shelf to place the selected product.',
              style: const TextStyle(color: _primaryBlue, fontSize: 12),
            ),
          ),
        Expanded(
          child: StoreMap(
            key: _storeMapKey,
            controller: widget.controller,
            layout: _draftLayout,
            mode: _mode,
            viewStyle: _viewStyle,
            hideWalls: _hideWalls,
            fitEntireMap: true,
            showZoomControls: false,
            showMobileToolbar: false,
            placementType: _mode == MapMode.manage ? _placementType : null,
            selectedItemId: _mode == MapMode.selection ? _selectedItemId : null,
            highlightId: _mode == MapMode.selection
                ? _selectedAssignmentTargetId
                : null,
            itemAssignmentEnabled:
                !_hasDirtyDraft && !_remoteChangePending && !_isSaving,
            onSelectionAssigned: () => setState(() => _selectedItemId = null),
            onPlacementCompleted: () => setState(() {}),
            onManageSelectionChanged: (element) {
              if (mounted)
                setState(() {
                  _manageSelected = element;
                  _productToAssignId = null;
                });
            },
            onLayoutEdited: _recordLayoutEdit,
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE7E1DB))),
          ),
          child: Text(
            _mode == MapMode.selection
                ? '$_assignedCount of ${widget.controller.allItems.length} products assigned'
                : '${_draftLayout.length} elements    Drag to move · corner handle to resize · Delete to remove',
            style: const TextStyle(color: Color(0xFF827872), fontSize: 11),
          ),
        ),
      ],
    ),
  );

  void _discardDraft() {
    _storeMapKey.currentState?.clearManageSelection();
    setState(() {
      _draftLayout = widget.controller.cloneMapLayout(_baselineLayout);
      _resetHistory(_baselineLayout);
      _manageSelected = null;
      _placementType = null;
    });
  }

  Future<void> _confirmClearDraft() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear the floor plan?'),
        content: const Text(
          'All fixtures will be removed from this draft. You can undo before saving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (clear != true || !mounted) return;
    _storeMapKey.currentState?.clearManageSelection();
    setState(() {
      _draftLayout.clear();
      _manageSelected = null;
      _placementType = null;
    });
    _recordLayoutEdit();
  }

  Widget _buildAssignmentPanel() {
    final targets = _assignmentTargets;
    final allItems = widget.controller.allItems;
    final items = allItems.where((item) {
      final assigned = targets.containsKey(item.locationId);
      if (_assignFilter == 'Assigned' && !assigned) return false;
      if (_assignFilter == 'Unassigned' && assigned) return false;
      final query = _assignmentSearch.trim().toLowerCase();
      return query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.sku.toLowerCase().contains(query);
    }).toList();
    items.sort((a, b) {
      final aAssigned = targets.containsKey(a.locationId);
      final bAssigned = targets.containsKey(b.locationId);
      if (aAssigned != bAssigned) return aAssigned ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return Container(
      height: 640,
      decoration: _mapPanelDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Items to place',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_assignedCount of ${allItems.length} products assigned',
                  style: const TextStyle(
                    color: Color(0xFF827872),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  onChanged: (value) =>
                      setState(() => _assignmentSearch = value),
                  style: const TextStyle(fontSize: 12),
                  decoration: _mapInputDecoration().copyWith(
                    hintText: 'Search items or SKU…',
                    prefixIcon: const Icon(LucideIcons.search, size: 16),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _assignmentFilterChip('All', allItems.length),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: _assignmentFilterChip(
                        'Unassigned',
                        allItems.length - _assignedCount,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: _assignmentFilterChip('Assigned', _assignedCount),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE7E1DB)),
          if (targets.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Add a rack or shelf in Manage layout before placing products.',
                style: TextStyle(color: Color(0xFF827872), fontSize: 12),
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'No products match this filter.',
                      style: TextStyle(color: Color(0xFF827872), fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final assignedTarget = targets[item.locationId];
                      final selected = _selectedItemId == item.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Material(
                          color: selected
                              ? const Color(0xFFFFF0E8)
                              : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                            side: BorderSide(
                              color: selected
                                  ? _primaryBlue
                                  : const Color(0xFFE7E1DB),
                            ),
                          ),
                          child: InkWell(
                            key: ValueKey('map-assign-product-${item.id}'),
                            borderRadius: BorderRadius.circular(9),
                            onTap: () => setState(() {
                              _selectedItemId = selected ? null : item.id;
                            }),
                            child: Padding(
                              padding: const EdgeInsets.all(9),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      _mapProductImage(item),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            Text(
                                              assignedTarget
                                                          ?.label
                                                          .isNotEmpty ==
                                                      true
                                                  ? assignedTarget!.label
                                                  : assignedTarget == null
                                                  ? 'Unassigned · ${item.sku}'
                                                  : '${_elementLabel(assignedTarget.type)} assigned',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: assignedTarget == null
                                                    ? const Color(0xFF827872)
                                                    : _primaryBlue,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (assignedTarget != null)
                                        const Icon(
                                          LucideIcons.circleCheck,
                                          size: 16,
                                          color: Color(0xFF168044),
                                        ),
                                    ],
                                  ),
                                  if (selected && assignedTarget != null) ...[
                                    const SizedBox(height: 6),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        onPressed:
                                            _hasDirtyDraft ||
                                                _remoteChangePending ||
                                                _isSaving
                                            ? null
                                            : () => unawaited(
                                                _assignProduct(item.id, null),
                                              ),
                                        child: const Text(
                                          'Remove from map',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _assignmentFilterChip(String label, int count) {
    final selected = _assignFilter == label;
    return TextButton(
      onPressed: () => setState(() => _assignFilter = label),
      style: TextButton.styleFrom(
        foregroundColor: selected ? Colors.white : const Color(0xFF514A45),
        backgroundColor: selected ? _primaryBlue : const Color(0xFFF7F5F3),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
      ),
      child: Text(
        '$label $count',
        maxLines: 1,
        style: const TextStyle(fontSize: 10),
      ),
    );
  }

  Widget _buildFixturePanel() {
    final selectedId = _manageSelected?.id;
    final matches = _draftLayout.where((element) => element.id == selectedId);
    final element = matches.isEmpty ? null : matches.first;
    return Container(
      height: 640,
      decoration: _mapPanelDecoration(),
      clipBehavior: Clip.antiAlias,
      child: element == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Select a fixture on the map to edit it and assign products.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF827872), fontSize: 13),
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _lightBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFE7E1DB)),
                        ),
                        child: Text(
                          _elementLabel(element.type),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Rotate',
                        onPressed: () => _storeMapKey.currentState
                            ?.applySidebarAction(MapSidebarAction.rotate),
                        icon: const Icon(LucideIcons.rotateCw, size: 17),
                      ),
                      if (element.type == ElementType.wall)
                        IconButton(
                          tooltip: 'Auto-align wall',
                          onPressed: () =>
                              _storeMapKey.currentState?.applySidebarAction(
                                MapSidebarAction.autoAlignWall,
                              ),
                          icon: const Icon(LucideIcons.magnet, size: 17),
                        ),
                      IconButton(
                        tooltip: 'Duplicate',
                        onPressed: () => _storeMapKey.currentState
                            ?.applySidebarAction(MapSidebarAction.duplicate),
                        icon: const Icon(LucideIcons.copy, size: 17),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _storeMapKey.currentState
                            ?.applySidebarAction(MapSidebarAction.delete),
                        icon: const Icon(
                          LucideIcons.trash2,
                          size: 17,
                          color: Color(0xFFD11A1A),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE7E1DB)),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Label',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 7),
                        TextFormField(
                          key: ValueKey('map-label-${element.id}'),
                          initialValue: element.label,
                          style: const TextStyle(fontSize: 13),
                          decoration: _mapInputDecoration(),
                          onFieldSubmitted: (value) => _updateSelectedElement(
                            element,
                            element.copyWith(label: value.trim()),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Use “Rack A · Fasteners” to show a short name on the map.',
                          style: TextStyle(
                            color: Color(0xFF827872),
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 22),
                        _buildManageSelectionControls(element),
                        const SizedBox(height: 22),
                        if (element.type == ElementType.rack ||
                            element.type == ElementType.shelf)
                          _buildAssignedProducts(element),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildManageSelectionControls(MapElement element) {
    final canShrink = canResizeMapElementWidth(element, grow: false);
    final canGrow = canResizeMapElementWidth(element, grow: true);
    final doorStyle = element.type == ElementType.door
        ? DoorStyle.fromWidth(element.size.width)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: Color(0xFFE7E1DB)),
        const SizedBox(height: 18),
        const Text(
          'Manage fixture',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        _manageSectionLabel('NUDGE'),
        const SizedBox(height: 6),
        Center(child: _manageMiniButton('▲', MapSidebarAction.up)),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _manageMiniButton('◀', MapSidebarAction.left),
            const SizedBox(width: 42),
            _manageMiniButton('▶', MapSidebarAction.right),
          ],
        ),
        Center(child: _manageMiniButton('▼', MapSidebarAction.down)),
        const SizedBox(height: 14),
        if (element.type == ElementType.door) ...[
          _manageSectionLabel('DOOR TYPE'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final style in DoorStyle.values)
                ChoiceChip(
                  label: Text(style.label),
                  selected: doorStyle == style,
                  selectedColor: const Color(0xFFFFF0E8),
                  checkmarkColor: _primaryBlue,
                  side: BorderSide(
                    color: doorStyle == style
                        ? _primaryBlue
                        : const Color(0xFFE7E1DB),
                  ),
                  labelStyle: TextStyle(
                    color: doorStyle == style
                        ? _primaryBlue
                        : const Color(0xFF292725),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  onSelected: (_) =>
                      _storeMapKey.currentState?.setSelectedDoorStyle(style),
                ),
            ],
          ),
        ] else ...[
          _manageSectionLabel('ADJUST WIDTH'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _manageAction(
                  '◀ Left −',
                  null,
                  MapSidebarAction.widthLeftMinus,
                  enabled: canShrink,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _manageAction(
                  '▶ Left +',
                  null,
                  MapSidebarAction.widthLeftPlus,
                  enabled: canGrow,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _manageAction(
                  '◀ Right −',
                  null,
                  MapSidebarAction.widthRightMinus,
                  enabled: canShrink,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _manageAction(
                  '▶ Right +',
                  null,
                  MapSidebarAction.widthRightPlus,
                  enabled: canGrow,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _manageSectionLabel(String text) => Text(
    text,
    style: const TextStyle(
      color: Color(0xFF827872),
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.7,
    ),
  );

  Widget _manageMiniButton(String label, MapSidebarAction action) => Padding(
    padding: const EdgeInsets.all(2),
    child: SizedBox(
      width: 44,
      height: 34,
      child: OutlinedButton(
        onPressed: () => _storeMapKey.currentState?.applySidebarAction(action),
        style: _manageButtonStyle(),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    ),
  );

  Widget _manageAction(
    String label,
    IconData? icon,
    MapSidebarAction action, {
    bool enabled = true,
  }) => SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: enabled
          ? () => _storeMapKey.currentState?.applySidebarAction(action)
          : null,
      style: _manageButtonStyle(),
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
    ),
  );

  ButtonStyle _manageButtonStyle() => OutlinedButton.styleFrom(
    foregroundColor: const Color(0xFF292725),
    side: const BorderSide(color: Color(0xFFE7E1DB)),
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
  );

  InputDecoration _mapInputDecoration() => InputDecoration(
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFE7E1DB)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFE7E1DB)),
    ),
  );

  void _updateSelectedElement(MapElement previous, MapElement updated) {
    final index = _draftLayout.indexWhere(
      (element) => element.id == previous.id,
    );
    if (index < 0) return;
    if (!(_storeMapKey.currentState?.canUpdateElement(updated) ?? true)) {
      AppToast.error(context, 'That position overlaps another fixture.');
      return;
    }
    setState(() {
      _draftLayout[index] = updated;
      _manageSelected = updated;
    });
    _recordLayoutEdit();
  }

  Widget _buildAssignedProducts(MapElement element) {
    final assigned = widget.controller.allItems
        .where((item) => item.locationId == element.id)
        .toList(growable: false);
    final available = widget.controller.allItems
        .where((item) => item.locationId == null || item.locationId!.isEmpty)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: Color(0xFFE7E1DB)),
        const SizedBox(height: 18),
        Text(
          'Products here · ${assigned.length}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        for (final item in assigned)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                _mapProductImage(item),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        item.shelfLevel?.isNotEmpty == true
                            ? item.shelfLevel!
                            : item.sku,
                        style: const TextStyle(
                          color: Color(0xFF827872),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove ${item.name} from this fixture',
                  onPressed: _hasDirtyDraft || _remoteChangePending
                      ? null
                      : () => unawaited(_assignProduct(item.id, null)),
                  icon: const Icon(LucideIcons.x, size: 15),
                ),
              ],
            ),
          ),
        if (assigned.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No products assigned yet.',
              style: TextStyle(color: Color(0xFF827872), fontSize: 12),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: AppStyledDropdown<String>(
                value: available.any((item) => item.id == _productToAssignId)
                    ? _productToAssignId
                    : null,
                decoration: _mapInputDecoration(),
                hint: const Text(
                  'Assign a product…',
                  style: TextStyle(fontSize: 12),
                ),
                items: available
                    .map(
                      (item) => DropdownMenuItem(
                        value: item.id,
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) =>
                    setState(() => _productToAssignId = value),
              ),
            ),
            const SizedBox(width: 7),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _primaryBlue),
              onPressed:
                  _productToAssignId == null ||
                      _hasDirtyDraft ||
                      _remoteChangePending
                  ? null
                  : () => unawaited(
                      _assignProduct(_productToAssignId!, element.id),
                    ),
              child: const Text('Add'),
            ),
          ],
        ),
        if (_hasDirtyDraft) ...[
          const SizedBox(height: 7),
          const Text(
            'Save the map before assigning products.',
            style: TextStyle(color: Color(0xFF827872), fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _mapProductImage(InventoryItem item) => Container(
    width: 36,
    height: 36,
    decoration: _mapPanelDecoration(),
    clipBehavior: Clip.antiAlias,
    child: item.imageUrl.isEmpty
        ? const Icon(LucideIcons.package, size: 18, color: Color(0xFFAAA19B))
        : Image.network(
            item.imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const Icon(
              LucideIcons.package,
              size: 18,
              color: Color(0xFFAAA19B),
            ),
          ),
  );

  Future<void> _assignProduct(String itemId, String? elementId) async {
    try {
      await widget.controller.assignItemToLocation(itemId, elementId);
      if (!mounted) return;
      setState(() => _productToAssignId = null);
      AppToast.success(
        context,
        elementId == null
            ? 'Product removed from this fixture.'
            : 'Product assigned.',
      );
    } catch (_) {
      if (mounted)
        AppToast.error(context, 'Could not update product assignment.');
    }
  }

  Widget _buildRemoteChangeBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF7ED),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        children: [
          Icon(
            LucideIcons.triangleAlert,
            size: 18,
            color: Colors.orange.shade800,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'A newer saved layout is available. Your unsaved draft is '
              'still intact.',
              style: TextStyle(
                fontFamily: _fontFam,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9A3412),
              ),
            ),
          ),
          TextButton(
            onPressed: _isSaving ? null : _confirmReloadLatest,
            child: const Text('Reload latest'),
          ),
        ],
      ),
    );
  }

  // Desktop-only drag palette. The map's existing DragTarget<ElementType>
  // receives the same type values as the mobile + toolbar.
}
