import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'models_3d.dart';
import 'widgets/app_toast.dart';

enum MapMode { view, manage, selection, pick }

/// Changes only the map projection; both views use the same saved layout.
enum MapViewStyle { twoD, threeD }

enum MapSidebarAction {
  rotate,
  up,
  down,
  left,
  right,
  widthLeftMinus,
  widthLeftPlus,
  widthRightMinus,
  widthRightPlus,
  duplicate,
  autoAlignWall,
  delete,
}

// Updated to the soft light-blue background
const Color kMapContainerBg = Color.fromARGB(255, 214, 235, 255);

// Visual model heights are separate from the saved 2D footprints.
const double _rack3DHeight = 6.0;
const double _shelf3DHeight = 5.25;
const double _door3DHeight = 5.2;
const double _wall3DHeight = 6.5;
const double _cashierMinWidth = 168.0;
const double _cashierMaxWidth = 248.0;
const double _rackMinWidth = 80.0;
const double _rackMaxWidth = 200.0;
const double _shelfMinWidth = 64.0;
const double _shelfMaxWidth = 184.0;

({double min, double max})? mapElementWidthLimits(ElementType type) =>
    switch (type) {
      ElementType.wall => (min: 15.0, max: double.infinity),
      ElementType.cashier => (min: _cashierMinWidth, max: _cashierMaxWidth),
      ElementType.rack => (min: _rackMinWidth, max: _rackMaxWidth),
      ElementType.shelf => (min: _shelfMinWidth, max: _shelfMaxWidth),
      ElementType.door => null,
    };

bool canResizeMapElementWidth(MapElement element, {required bool grow}) {
  final limits = mapElementWidthLimits(element.type);
  if (limits == null) return false;
  final length =
      element.type == ElementType.wall &&
          element.size.height > element.size.width
      ? element.size.height
      : element.size.width;
  return grow ? length < limits.max : length > limits.min;
}

class StoreMap extends StatefulWidget {
  final InventoryController controller;
  final String? highlightId;
  final ItemLocation? location;
  final String? itemName;
  final MapMode mode;
  final MapViewStyle viewStyle;
  final bool hideWalls;
  final bool showMobileToolbar;
  final String? selectedItemId;
  final bool centerOnSelectedItem;
  final bool fitEntireMap;
  final bool compactZoomControls;
  final List<MapElement>? layout;
  final bool itemAssignmentEnabled;
  final VoidCallback? onSelectionAssigned;
  final Function(MapElement)? onElementSelected;
  final ValueChanged<MapElement?>? onManageSelectionChanged;
  final VoidCallback? onLayoutEdited;

  const StoreMap({
    super.key,
    required this.controller,
    this.highlightId,
    this.location,
    this.itemName,
    this.mode = MapMode.view,
    this.viewStyle = MapViewStyle.threeD,
    this.hideWalls = false,
    this.showMobileToolbar = true,
    this.selectedItemId,
    this.centerOnSelectedItem = false,
    this.fitEntireMap = false,
    this.compactZoomControls = false,
    this.layout,
    this.itemAssignmentEnabled = true,
    this.onSelectionAssigned,
    this.onElementSelected,
    this.onManageSelectionChanged,
    this.onLayoutEdited,
  });

  @override
  State<StoreMap> createState() => StoreMapState();
}

class StoreMapState extends State<StoreMap>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _bounceAnimation;
  String? _activeElementId;
  String? _hoveredElementId;
  bool _isAdjustingWidth = false;
  bool _isChoosingDoorType = false;

  bool _isNudging = false;
  final TransformationController _transformationController =
      TransformationController();
  bool _isInitialScaleSet = false;
  bool _hasAppliedInitialTransform = false;
  MapElement? _selectedPopupElement;

  late final GlobalKey _mapKey = GlobalKey();

  Offset? _dragPreviewPos;
  Size? _dragPreviewSize;
  bool _dragPreviewValid = true;
  double _dragPreviewRotation = 0.0;
  ElementType? _dragPreviewType;
  Offset? _rawDragPosition;

  // ==========================================
  // NEW: State for the left toolbar
  // ==========================================
  bool _isToolbarExpanded = false;

  // --- NEW: Map Centering Variables & Function ---
  double _currentMapWidth = 1000.0;
  double _currentMapHeight = 1000.0;
  double _currentMapMinX = 0.0;
  double _currentMapMinY = 0.0;
  Size _currentViewportSize = Size.zero;
  ({double minX, double minY, double width, double height})? _dragCanvasBounds;
  bool _viewportRecenterQueued = false;
  StreamSubscription<List<MapElement>>? _mapLayoutSubscription;
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;
  bool _mapLayoutLoadFailed = false;

  List<MapElement> get _layout =>
      widget.layout ?? widget.controller.storeLayout;

  MapElement? get _itemLocationElement {
    if (!widget.centerOnSelectedItem || widget.selectedItemId == null) {
      return null;
    }
    for (final item in widget.controller.allItems) {
      if (item.id != widget.selectedItemId) continue;
      for (final element in _layout) {
        if (element.id == item.locationId) return element;
      }
      break;
    }
    return null;
  }

  void _recenterMap({bool preserveScale = false}) {
    if (_currentViewportSize == Size.zero) return;

    double scale;
    if (preserveScale && _hasAppliedInitialTransform) {
      // Use the current zoom level
      scale = _transformationController.value.getMaxScaleOnAxis();
    } else {
      // Calculate initial fit-to-screen scale
      double fitWidth = _currentMapWidth;
      double fitHeight = _currentMapHeight;
      if (widget.fitEntireMap && widget.viewStyle == MapViewStyle.threeD) {
        // The 3D floor is rotated inside its original layout box. Fit its
        // projected corners, leaving room for objects that rise above it.
        final projection = Matrix4.identity()
          ..rotateX(-0.95)
          ..rotateZ(0.785);
        final corners = [
          Offset.zero,
          Offset(_currentMapWidth, 0),
          Offset(_currentMapWidth, _currentMapHeight),
          Offset(0, _currentMapHeight),
        ].map((point) => MatrixUtils.transformPoint(projection, point));
        final projectedX = corners.map((point) => point.dx);
        final projectedY = corners.map((point) => point.dy);
        fitWidth = projectedX.reduce(math.max) - projectedX.reduce(math.min);
        fitHeight = projectedY.reduce(math.max) - projectedY.reduce(math.min);
      }
      final scaleX = _currentViewportSize.width / fitWidth;
      final scaleY = _currentViewportSize.height / fitHeight;
      scale =
          math.min(scaleX, scaleY) *
          (widget.viewStyle == MapViewStyle.threeD
              ? (widget.fitEntireMap ? 0.69 : 0.68)
              : 0.83);
      scale = scale.clamp(widget.fitEntireMap ? 0.01 : 0.1, 2.5);
    }

    double dx = (_currentViewportSize.width - (_currentMapWidth * scale)) / 2;
    double dy = (_currentViewportSize.height - (_currentMapHeight * scale)) / 2;
    final selectedLocation = _itemLocationElement;
    if (selectedLocation == null &&
        widget.viewStyle == MapViewStyle.threeD &&
        _layout.isNotEmpty) {
      // Center the visible 3D layout, whose raised objects extend above the
      // floor grid, rather than centering only the grid's layout box.
      final mapCenter = Offset(_currentMapWidth / 2, _currentMapHeight / 2);
      final projection = Matrix4.identity()
        ..rotateX(-0.95)
        ..rotateZ(0.785);
      double left = double.infinity;
      double top = double.infinity;
      double right = double.negativeInfinity;
      double bottom = double.negativeInfinity;
      double tallestObject = 0;
      for (final element in _layout) {
        final height = switch (element.type) {
          ElementType.rack => _rack3DHeight,
          ElementType.shelf => _shelf3DHeight,
          ElementType.door => _door3DHeight,
          ElementType.wall => _wall3DHeight,
          ElementType.cashier => 3.5,
        };
        tallestObject = math.max(tallestObject, height);
        for (final corner in _getCorners(
          element.position,
          element.size,
          element.rotation,
        )) {
          final localCorner = corner - Offset(_currentMapMinX, _currentMapMinY);
          final projected =
              mapCenter +
              MatrixUtils.transformPoint(projection, localCorner - mapCenter);
          left = math.min(left, projected.dx);
          top = math.min(top, projected.dy);
          right = math.max(right, projected.dx);
          bottom = math.max(bottom, projected.dy);
        }
      }
      // The model painters use 40 pixels per height unit and tilt by 0.95 rad.
      final raisedHeight = tallestObject * 40 * math.cos(0.95);
      final visibleCenter = Offset(
        (left + right) / 2,
        (top - raisedHeight + bottom) / 2,
      );
      dx = _currentViewportSize.width / 2 - visibleCenter.dx * scale;
      dy = _currentViewportSize.height / 2 - visibleCenter.dy * scale;
    } else if (selectedLocation != null) {
      final localCenter =
          selectedLocation.position +
          Offset(
            selectedLocation.size.width / 2,
            selectedLocation.size.height / 2,
          ) -
          Offset(_currentMapMinX, _currentMapMinY);
      final mapCenter = Offset(_currentMapWidth / 2, _currentMapHeight / 2);
      final projection = widget.viewStyle == MapViewStyle.twoD
          ? Matrix4.identity()
          : (Matrix4.identity()
              ..rotateX(-0.95)
              ..rotateZ(0.785));
      final projectedCenter =
          mapCenter +
          MatrixUtils.transformPoint(projection, localCenter - mapCenter);
      dx = _currentViewportSize.width / 2 - projectedCenter.dx * scale;
      dy = _currentViewportSize.height / 2 - projectedCenter.dy * scale;
    }

    _transformationController.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
    _hasAppliedInitialTransform = true;
  }
  // -----------------------------------------------

  @override
  void initState() {
    super.initState();
    _bindDomainStreams();
    unawaited(_ensureLayoutLoaded());
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _bounceAnimation = Tween<double>(begin: 0, end: -8).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
    if (widget.selectedItemId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autoOpenItemCard(widget.selectedItemId!);
      });
    }
  }

  Future<void> _ensureLayoutLoaded() async {
    if (widget.layout != null) return;
    try {
      await widget.controller.fetchMapLayout();
      if (!mounted) return;
      setState(() => _mapLayoutLoadFailed = false);

      final selectedItemId = widget.selectedItemId;
      if (selectedItemId != null) {
        _autoOpenItemCard(selectedItemId);
        if (widget.centerOnSelectedItem || widget.fitEntireMap) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _recenterMap(
                preserveScale:
                    widget.centerOnSelectedItem && _isInitialScaleSet,
              );
            }
          });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _mapLayoutLoadFailed = true);
    }
  }

  @override
  void didUpdateWidget(covariant StoreMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_mapLayoutSubscription?.cancel());
      unawaited(_inventorySubscription?.cancel());
      _bindDomainStreams();
      if (widget.layout == null) unawaited(_ensureLayoutLoaded());
    }
    if (!identical(oldWidget.layout, widget.layout)) {
      _resolveCurrentPopupSelection();
    }
    if (oldWidget.selectedItemId != widget.selectedItemId ||
        oldWidget.centerOnSelectedItem != widget.centerOnSelectedItem) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final selectedItemId = widget.selectedItemId;
        if (selectedItemId != null) _autoOpenItemCard(selectedItemId);
        _recenterMap(preserveScale: _isInitialScaleSet);
      });
    }
    if (oldWidget.viewStyle != widget.viewStyle ||
        oldWidget.fitEntireMap != widget.fitEntireMap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recenterMap();
      });
    }
    // Each mode starts with a clean selection. In particular, an object
    // highlighted in Preview must not remain glowing in Manage Layout when
    // the editor sidebar has no active selection.
    if (oldWidget.mode != widget.mode) {
      _selectedPopupElement = null;
      _activeElementId = null;
      _hoveredElementId = null;
      _isNudging = false;
      _isAdjustingWidth = false;
      _isChoosingDoorType = false;
    }
  }

  @override
  void dispose() {
    _mapLayoutSubscription?.cancel();
    _inventorySubscription?.cancel();
    _animController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _bindDomainStreams() {
    _mapLayoutSubscription = widget.controller.mapLayoutSnapshots.listen((_) {
      if (!mounted || widget.layout != null) return;
      setState(_resolveCurrentPopupSelection);
      if (widget.centerOnSelectedItem) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _recenterMap(preserveScale: _isInitialScaleSet);
        });
      }
    });
    _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
      if (!mounted) return;
      final String? selectedItemId = widget.selectedItemId;
      if (selectedItemId != null) {
        final previousLocationId = _selectedPopupElement?.id;
        _autoOpenItemCard(selectedItemId);
        if (widget.centerOnSelectedItem &&
            _selectedPopupElement?.id != previousLocationId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _recenterMap(preserveScale: _isInitialScaleSet);
          });
        }
      } else {
        setState(_resolveCurrentPopupSelection);
      }
    });
  }

  void _resolveCurrentPopupSelection() {
    final String? selectedId = _selectedPopupElement?.id;
    if (selectedId == null) return;
    final Iterable<MapElement> matches = _layout.where(
      (MapElement element) => element.id == selectedId,
    );
    _selectedPopupElement = matches.isEmpty ? null : matches.first;
  }

  void _autoOpenItemCard(String itemId) {
    MapElement? element;
    try {
      final item = widget.controller.allItems.firstWhere((i) => i.id == itemId);

      if (item.locationId != null) {
        element = _layout.firstWhere((e) => e.id == item.locationId);
      }
    } catch (e) {
      element = null;
    }
    if (mounted) setState(() => _selectedPopupElement = element);
  }

  // ==========================================
  // NEW: Zoom logic for the right controls
  // ==========================================
  void _zoom(double zoomFactor) {
    final double scale = _transformationController.value.getMaxScaleOnAxis();
    final double newScale = (scale * zoomFactor).clamp(
      widget.fitEntireMap ? 0.01 : 0.1,
      2.5,
    );
    final double actualFactor = newScale / scale;

    // Get screen center to zoom in/out smoothly towards the center
    if (_currentViewportSize == Size.zero) return;
    final Offset center = Offset(
      _currentViewportSize.width / 2,
      _currentViewportSize.height / 2,
    );

    final Matrix4 matrix = _transformationController.value.clone();
    final Offset centerInMap = MatrixUtils.transformPoint(
      Matrix4.inverted(matrix),
      center,
    );

    matrix.translate(centerInMap.dx, centerInMap.dy);
    matrix.scale(actualFactor, actualFactor);
    matrix.translate(-centerInMap.dx, -centerInMap.dy);

    _transformationController.value = matrix;
  }

  Size _getDefaultSize(ElementType type) {
    if (type == ElementType.wall || type.name == 'pathway') {
      return const Size(15, 15); // Start as a 15x15 pillar
    } else if (type == ElementType.door) {
      // Changed to 15 depth so it perfectly matches the wall thickness!
      return const Size(80, 15);
    } else if (type == ElementType.cashier) {
      return const Size(_cashierMinWidth, 64);
    } else if (type == ElementType.shelf) {
      return const Size(104, 48); // Standard shelf footprint
    } else if (type == ElementType.rack) {
      return const Size(120, 60); // Standard rack footprint
    }
    return const Size(80, 80); // Fallback
  }

  Offset? _paletteWorldPosition(Offset globalPosition, Size size) {
    final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final localPosition = box.globalToLocal(globalPosition);
    return localPosition +
        Offset(_currentMapMinX, _currentMapMinY) -
        Offset(size.width / 2, size.height / 2);
  }

  void _lockDragCanvas() {
    if (_dragCanvasBounds != null) return;
    _dragCanvasBounds = (
      minX: _currentMapMinX,
      minY: _currentMapMinY,
      width: _currentMapWidth,
      height: _currentMapHeight,
    );
  }

  void _updatePalettePreview(DragTargetDetails<ElementType> details) {
    _lockDragCanvas();
    final size = _getDefaultSize(details.data);
    final position = _paletteWorldPosition(details.offset, size);
    if (position == null) return;
    final element = MapElement(
      id: 'temp',
      type: details.data,
      position: position,
      label: '',
    )..size = size;
    final snapped = _snapObjectNearWall(element, position, size, 0.0);
    setState(() {
      _dragPreviewPos = snapped;
      _dragPreviewSize = size;
      _dragPreviewValid = !_hasCollision(element, snapped, size, 0.0);
      _dragPreviewRotation = 0.0;
      _dragPreviewType = details.data;
    });
  }

  void _acceptPaletteElement(DragTargetDetails<ElementType> details) {
    final size = _getDefaultSize(details.data);
    final position = _paletteWorldPosition(details.offset, size);
    if (position == null) {
      setState(() {
        _dragCanvasBounds = null;
        _dragPreviewPos = null;
        _dragPreviewSize = null;
        _dragPreviewType = null;
      });
      return;
    }
    final element = MapElement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: details.data,
      position: position,
      label: details.data.name.toUpperCase(),
    )..size = size;
    final snapped = _snapObjectNearWall(element, position, size, 0.0);
    element.position = snapped;
    if (!_hasCollision(element, snapped, size, 0.0)) {
      setState(() => _layout.add(element));
      widget.onLayoutEdited?.call();
    } else {
      AppToast.error(
        context,
        "Cannot place element here. It overlaps with another.",
      );
    }
    setState(() {
      _dragCanvasBounds = null;
      _dragPreviewPos = null;
      _dragPreviewSize = null;
      _dragPreviewType = null;
    });
  }

  Offset _snapToGrid(Offset position, Size size, ElementType type) {
    const double step = 40.0;

    if (type == ElementType.wall) {
      // WALL: Center snaps to the grid lines (0, 40, 80...)
      final Offset center = position + Offset(size.width / 2, size.height / 2);
      final double snappedCenterX = (center.dx / step).round() * step;
      final double snappedCenterY = (center.dy / step).round() * step;
      return Offset(
        snappedCenterX - size.width / 2,
        snappedCenterY - size.height / 2,
      );
    } else {
      // OBJECTS: Top-Left corner snaps to the grid lines.
      final double snappedX = (position.dx / step).round() * step;
      final double snappedY = (position.dy / step).round() * step;
      return Offset(snappedX, snappedY);
    }
  }

  List<Offset> _getCorners(Offset pos, Size size, double rotation) {
    final double cx = pos.dx + size.width / 2;
    final double cy = pos.dy + size.height / 2;
    final double w2 = size.width / 2;
    final double h2 = size.height / 2;

    final double cosR = math.cos(rotation);
    final double sinR = math.sin(rotation);

    return [
      Offset(cx - w2 * cosR + h2 * sinR, cy - w2 * sinR - h2 * cosR), // TL
      Offset(cx + w2 * cosR + h2 * sinR, cy + w2 * sinR - h2 * cosR), // TR
      Offset(cx + w2 * cosR - h2 * sinR, cy + w2 * sinR + h2 * cosR), // BR
      Offset(cx - w2 * cosR - h2 * sinR, cy - w2 * sinR + h2 * cosR), // BL
    ];
  }

  bool _hasCollision(MapElement activeEl, Offset pos, Size size, double rot) {
    final cornersA = _getCorners(pos, size, rot);
    final axesA = [
      Offset(math.cos(rot), math.sin(rot)),
      Offset(-math.sin(rot), math.cos(rot)),
    ];

    for (var other in _layout) {
      if (other.id == activeEl.id) continue;

      // ==========================================
      // NEW: ALLOW DOORS TO ATTACH/OVERLAP WALLS
      // ==========================================
      if ((activeEl.type == ElementType.door &&
              other.type == ElementType.wall) ||
          (activeEl.type == ElementType.wall &&
              other.type == ElementType.door) ||
          (activeEl.type == ElementType.wall &&
              other.type == ElementType.wall)) {
        continue; // Skip collision check for doors vs walls
      }
      // ==========================================

      final cornersB = _getCorners(other.position, other.size, other.rotation);
      final axesB = [
        Offset(math.cos(other.rotation), math.sin(other.rotation)),
        Offset(-math.sin(other.rotation), math.cos(other.rotation)),
      ];

      final allAxes = [...axesA, ...axesB];
      bool overlap = true;

      for (var axis in allAxes) {
        double minA = double.infinity, maxA = -double.infinity;
        for (var p in cornersA) {
          final proj = p.dx * axis.dx + p.dy * axis.dy;
          if (proj < minA) minA = proj;
          if (proj > maxA) maxA = proj;
        }

        double minB = double.infinity, maxB = -double.infinity;
        for (var p in cornersB) {
          final proj = p.dx * axis.dx + p.dy * axis.dy;
          if (proj < minB) minB = proj;
          if (proj > maxB) maxB = proj;
        }

        if (maxA <= minB || maxB <= minA) {
          overlap = false;
          break;
        }
      }

      if (overlap) return true;
    }
    return false;
  }

  // Keep the 40-unit grid, but let furniture sit against a wall when the
  // nearest grid point would put its footprint inside that wall. Preview,
  // drop, and move all use this same position so what the user sees is saved.
  Offset _snapObjectNearWall(
    MapElement element,
    Offset rawPosition,
    Size size,
    double rotation,
  ) {
    final snapped = _snapToGrid(rawPosition, size, element.type);
    if (element.type == ElementType.wall ||
        element.type == ElementType.door ||
        !_hasCollision(element, snapped, size, rotation)) {
      return snapped;
    }

    Rect bounds(Offset position, Size footprint, double angle) {
      final corners = _getCorners(position, footprint, angle);
      return Rect.fromLTRB(
        corners.map((point) => point.dx).reduce(math.min),
        corners.map((point) => point.dy).reduce(math.min),
        corners.map((point) => point.dx).reduce(math.max),
        corners.map((point) => point.dy).reduce(math.max),
      );
    }

    final objectBounds = bounds(snapped, size, rotation);
    const maxAdjustment = 40.0;
    const clearance = 0.5;
    final xPositions = <double>{snapped.dx};
    final yPositions = <double>{snapped.dy};

    for (final wall in _layout.where((item) => item.type == ElementType.wall)) {
      final wallBounds = bounds(wall.position, wall.size, wall.rotation);
      if (!wallBounds.overlaps(objectBounds)) continue;

      for (final x in <double>[
        snapped.dx + wallBounds.left - objectBounds.right - clearance,
        snapped.dx + wallBounds.right - objectBounds.left + clearance,
      ]) {
        if ((x - snapped.dx).abs() <= maxAdjustment) xPositions.add(x);
      }
      for (final y in <double>[
        snapped.dy + wallBounds.top - objectBounds.bottom - clearance,
        snapped.dy + wallBounds.bottom - objectBounds.top + clearance,
      ]) {
        if ((y - snapped.dy).abs() <= maxAdjustment) yPositions.add(y);
      }
    }

    Offset? nearest;
    var nearestDistance = double.infinity;
    for (final x in xPositions) {
      for (final y in yPositions) {
        final candidate = Offset(x, y);
        if (_hasCollision(element, candidate, size, rotation)) continue;
        final distance = (candidate - rawPosition).distanceSquared;
        if (distance < nearestDistance) {
          nearest = candidate;
          nearestDistance = distance;
        }
      }
    }
    return nearest ?? snapped;
  }

  // ==========================================
  // NEW: Build the left expandable toolbar
  // ==========================================
  Widget _buildLeftToolbar() {
    return Positioned(
      bottom: 20,
      left: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // AnimatedSize handles the smooth expansion of the container's height
          AnimatedSize(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
            alignment: Alignment.bottomLeft,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutBack, // Slight bounce at the top
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (Widget child, Animation<double> animation) {
                // Combines a fade-in with a slide-up motion
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(
                        0.0,
                        0.3,
                      ), // Starts 30% lower and slides up to 0
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _isToolbarExpanded
                  ? Column(
                      // Keys are required for AnimatedSwitcher to know when to animate
                      key: const ValueKey('toolbar_expanded'),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildDraggableToolbarItem(
                          ElementType.door,
                          LucideIcons.doorOpen,
                          Colors.green,
                        ),
                        const SizedBox(height: 8),
                        _buildDraggableToolbarItem(
                          ElementType.wall,
                          Icons.line_weight,
                          Colors.blue,
                        ),
                        const SizedBox(height: 8),
                        _buildDraggableToolbarItem(
                          ElementType.shelf,
                          Icons.shelves,
                          Colors.orange,
                        ),
                        const SizedBox(height: 8),
                        _buildDraggableToolbarItem(
                          ElementType.rack,
                          Icons.view_headline,
                          Colors.purple,
                        ),
                        const SizedBox(height: 8),
                        _buildDraggableToolbarItem(
                          ElementType.cashier,
                          Icons.point_of_sale,
                          Colors.blueGrey,
                        ),
                        const SizedBox(height: 16),
                      ],
                    )
                  : const SizedBox(
                      key: ValueKey('toolbar_collapsed'),
                      width: 56,
                      height: 0,
                    ),
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                _isToolbarExpanded = !_isToolbarExpanded;
              });
            },
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.blue.shade600, // Updated to blue theme
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 8,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: AnimatedRotation(
                turns: _isToolbarExpanded ? 0.125 : 0.0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: const Icon(Icons.add, color: Colors.white, size: 32),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // NEW: Helper for the left toolbar items
  // ==========================================
  Widget _buildDraggableToolbarItem(
    ElementType type,
    IconData icon,
    Color color,
  ) {
    final String labelName =
        type.name[0].toUpperCase() + type.name.substring(1);
    bool isHovered = false; // Local state for hover tracking

    return StatefulBuilder(
      builder: (context, setState) {
        return MouseRegion(
          onEnter: (_) => setState(() => isHovered = true),
          onExit: (_) => setState(() => isHovered = false),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The Draggable Icon
              Draggable<ElementType>(
                data: type,
                feedback: const SizedBox.shrink(),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      // Change border to blue when hovered
                      color: isHovered
                          ? Colors.blue.shade400
                          : Colors.blueGrey.withOpacity(0.5),
                      width: isHovered ? 2.0 : 1.5,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Center(child: Icon(icon, color: color, size: 24)),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Custom Tooltip shown on the right when hovered
              if (isHovered) ...[
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade400, width: 1.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black45,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    labelName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // NEW: Build the right zoom controls
  // ==========================================
  Widget _buildZoomControls() {
    final compact = widget.compactZoomControls;
    final buttonSize = compact ? 34.0 : 48.0;
    final iconSize = compact ? 17.0 : 24.0;
    final iconColor = compact ? const Color(0xFF2563EB) : Colors.white;
    return Positioned(
      bottom: compact ? 8 : 20,
      right: compact ? 8 : 20,
      child: Container(
        decoration: BoxDecoration(
          color: compact ? Colors.white : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(compact ? 10 : 16),
          border: Border.all(
            color: compact
                ? const Color(0xFFBFDBFE)
                : Colors.blueGrey.withOpacity(0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: compact ? const Color(0x220F172A) : Colors.black45,
              blurRadius: compact ? 5 : 8,
              offset: Offset(0, compact ? 2 : 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              constraints: BoxConstraints.tightFor(
                width: buttonSize,
                height: buttonSize,
              ),
              padding: EdgeInsets.zero,
              icon: Icon(Icons.add, color: iconColor, size: iconSize),
              onPressed: () => _zoom(1.2), // Zoom in
            ),
            Container(
              height: 1,
              width: compact ? 28 : 40,
              color: compact
                  ? const Color(0xFFDBEAFE)
                  : Colors.blueGrey.withOpacity(0.5),
            ),
            IconButton(
              constraints: BoxConstraints.tightFor(
                width: buttonSize,
                height: buttonSize,
              ),
              padding: EdgeInsets.zero,
              icon: Icon(Icons.remove, color: iconColor, size: iconSize),
              onPressed: () => _zoom(0.8), // Zoom out
            ),
            Container(
              height: 1,
              width: compact ? 28 : 40,
              color: compact
                  ? const Color(0xFFDBEAFE)
                  : Colors.blueGrey.withOpacity(0.5),
            ),
            IconButton(
              constraints: BoxConstraints.tightFor(
                width: buttonSize,
                height: buttonSize,
              ),
              padding: EdgeInsets.zero,
              icon: Icon(
                LucideIcons.focus,
                color: iconColor,
                size: compact ? 16 : 20,
              ),
              onPressed: () {
                setState(() {
                  _recenterMap(preserveScale: true);
                });
              },
              tooltip: 'Recenter Map',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_mapLayoutLoadFailed &&
        !widget.controller.isMapLayoutLoadedForActiveLocation) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load the store map.'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                setState(() => _mapLayoutLoadFailed = false);
                unawaited(_ensureLayoutLoaded());
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Container(
      // Margin on all sides so the map doesn't touch the sidebar
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kMapContainerBg,
        borderRadius: BorderRadius.circular(16),
        // Faint border
        border: Border.all(color: Colors.black.withOpacity(0.08), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildLiveMapDisplay(),
          if (widget.location != null) _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF0F172A),
      child: Row(
        children: [
          Icon(LucideIcons.mapPin, color: Colors.blue.shade600, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Store Map",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (widget.itemName != null)
                  Text(
                    widget.itemName!,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // NUDGE LOGIC
  // ==========================================
  // Called by the desktop sidebar. Mobile uses the original floating controls.
  void clearManageSelection() {
    if (!mounted) return;
    setState(() {
      _activeElementId = null;
      _isNudging = false;
      _isAdjustingWidth = false;
      _isChoosingDoorType = false;
    });
    widget.onManageSelectionChanged?.call(null);
  }

  void _duplicateSelectedElement(MapElement original) {
    // Each map element has its own ID. Inventory assignments refer to the
    // original ID, so the copy starts with no assigned inventory items.
    const step = 40.0;
    final clone = MapElement(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: original.type,
      position: original.position,
      label: original.type.name.toUpperCase(),
    );
    clone.size = original.size;
    clone.rotation = original.rotation;

    // Search outward from the original, snapping to the existing 40-unit grid.
    Offset? freePosition;
    for (int radius = 1; radius <= 16 && freePosition == null; radius++) {
      for (int dy = -radius; dy <= radius && freePosition == null; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
          if (dx.abs() != radius && dy.abs() != radius) continue;
          final candidate = _snapToGrid(
            original.position + Offset(dx * step, dy * step),
            clone.size,
            clone.type,
          );
          if (!_hasCollision(clone, candidate, clone.size, clone.rotation)) {
            freePosition = candidate;
            break;
          }
        }
      }
    }
    if (freePosition == null) {
      AppToast.error(context, 'No free space nearby to duplicate this object.');
      return;
    }
    clone.position = freePosition;
    setState(() {
      _layout.add(clone);
      _activeElementId = clone.id;
      _isNudging = false;
      _isAdjustingWidth = false;
      _isChoosingDoorType = false;
    });
    widget.onManageSelectionChanged?.call(clone);
    widget.onLayoutEdited?.call();
  }

  void applySidebarAction(MapSidebarAction action) {
    final matches = _layout.where((e) => e.id == _activeElementId);
    if (matches.isEmpty || widget.mode != MapMode.manage) return;
    final el = matches.first;
    if (action == MapSidebarAction.duplicate) {
      _duplicateSelectedElement(el);
      return;
    }
    if (action == MapSidebarAction.autoAlignWall) {
      if (!_autoAlignWall(el)) {
        AppToast.error(context, 'No nearby wall endpoints to align.');
      }
      return;
    }
    if (action == MapSidebarAction.delete) {
      _layout.removeWhere((MapElement element) => element.id == el.id);
      setState(() {
        _activeElementId = null;
        _isAdjustingWidth = false;
        _isChoosingDoorType = false;
        _isNudging = false;
      });
      widget.onManageSelectionChanged?.call(null);
      widget.onLayoutEdited?.call();
      return;
    }
    if (action == MapSidebarAction.rotate) {
      if (el.type == ElementType.wall) {
        final center =
            el.position + Offset(el.size.width / 2, el.size.height / 2);
        final size = Size(el.size.height, el.size.width);
        final pos = center - Offset(size.width / 2, size.height / 2);
        if (_hasCollision(el, pos, size, 0)) {
          AppToast.error(
            context,
            'Cannot rotate. Overlaps with another element.',
          );
          return;
        }
        setState(() {
          el.size = size;
          el.position = pos;
          el.rotation = 0;
        });
      } else {
        final rotation = el.rotation + math.pi / 2;
        if (_hasCollision(el, el.position, el.size, rotation)) {
          AppToast.error(
            context,
            'Cannot rotate. Overlaps with another element.',
          );
          return;
        }
        setState(() => el.rotation = rotation);
      }
      widget.onLayoutEdited?.call();
      return;
    }
    switch (action) {
      case MapSidebarAction.up:
        _nudgeElement(el, const Offset(0, -40));
        break;
      case MapSidebarAction.down:
        _nudgeElement(el, const Offset(0, 40));
        break;
      case MapSidebarAction.left:
        _nudgeElement(el, const Offset(-40, 0));
        break;
      case MapSidebarAction.right:
        _nudgeElement(el, const Offset(40, 0));
        break;
      case MapSidebarAction.widthLeftMinus:
        _changeElementWidthDirectional(el, -40, isLeft: true);
        break;
      case MapSidebarAction.widthLeftPlus:
        _changeElementWidthDirectional(el, 40, isLeft: true);
        break;
      case MapSidebarAction.widthRightMinus:
        _changeElementWidthDirectional(el, -40, isLeft: false);
        break;
      case MapSidebarAction.widthRightPlus:
        _changeElementWidthDirectional(el, 40, isLeft: false);
        break;
      default:
        break;
    }
  }

  // Align endpoints of the selected axis-aligned wall to nearby
  // perpendicular wall faces. Other elements are never moved.
  bool _autoAlignWall(MapElement wall) {
    if (wall.type != ElementType.wall) return false;
    final horizontal = wall.size.width >= wall.size.height;
    const tolerance = 45.0; // slightly more than one 40-unit resize step
    final start = horizontal ? wall.position.dx : wall.position.dy;
    final end = start + (horizontal ? wall.size.width : wall.size.height);
    final crossMin = horizontal ? wall.position.dy : wall.position.dx;
    final crossMax =
        crossMin + (horizontal ? wall.size.height : wall.size.width);

    final candidates = <double>[];
    for (final other in _layout) {
      if (other.id == wall.id || other.type != ElementType.wall) continue;
      final otherHorizontal = other.size.width >= other.size.height;
      if (otherHorizontal == horizontal) continue;
      final otherStart = horizontal ? other.position.dx : other.position.dy;
      final otherEnd =
          otherStart + (horizontal ? other.size.width : other.size.height);
      final otherCrossMin = horizontal ? other.position.dy : other.position.dx;
      final otherCrossMax =
          otherCrossMin + (horizontal ? other.size.height : other.size.width);
      // The perpendicular wall must reach the selected wall's corridor.
      if (otherCrossMax < crossMin - tolerance ||
          otherCrossMin > crossMax + tolerance)
        continue;
      candidates.add(otherStart);
      candidates.add(otherEnd);
    }

    double snap(double endpoint) {
      var best = endpoint;
      var distance = tolerance + 0.001;
      for (final face in candidates) {
        final d = (endpoint - face).abs();
        if (d < distance) {
          distance = d;
          best = face;
        }
      }
      return best;
    }

    final nextStart = snap(start);
    final nextEnd = snap(end);
    if (nextEnd - nextStart < 15) return false;
    if ((nextStart - start).abs() < 0.01 && (nextEnd - end).abs() < 0.01)
      return false;

    final nextPos = horizontal
        ? Offset(nextStart, wall.position.dy)
        : Offset(wall.position.dx, nextStart);
    final nextSize = horizontal
        ? Size(nextEnd - nextStart, wall.size.height)
        : Size(wall.size.width, nextEnd - nextStart);
    if (_hasCollision(wall, nextPos, nextSize, wall.rotation)) return false;
    setState(() {
      wall.position = nextPos;
      wall.size = nextSize;
    });
    widget.onLayoutEdited?.call();
    return true;
  }

  void _nudgeElement(MapElement el, Offset delta) {
    final Offset newPosition = el.position + delta;

    if (_hasCollision(el, newPosition, el.size, el.rotation)) {
      AppToast.error(
        context,
        "Cannot nudge. It would overlap another element.",
      );
      return;
    }

    setState(() {
      el.position = newPosition;
    });
    widget.onLayoutEdited?.call();
  }

  // ==========================================
  // COC STYLE BOTTOM ACTION BAR
  // ==========================================
  void _changeElementWidthDirectional(
    MapElement el,
    double amount, {
    required bool isLeft,
  }) {
    // Doors use fixed footprints selected through the Door Type control.
    final limits = mapElementWidthLimits(el.type);
    if (limits == null || !canResizeMapElementWidth(el, grow: amount > 0)) {
      return;
    }

    // Rotating a wall swaps width and height (its rotation stays at zero).
    // Always resize along the wall's LONG axis so its 15-unit thickness never
    // grows when a vertical wall is extended from either endpoint.
    final bool verticalWall =
        el.type == ElementType.wall && el.size.height > el.size.width;
    final double oldLength = verticalWall ? el.size.height : el.size.width;
    final double newLength = (oldLength + amount).clamp(limits.min, limits.max);

    final double actualChange = newLength - oldLength;

    // Nothing to change
    if (actualChange == 0) return;

    final Size newSize = verticalWall
        ? Size(el.size.width, newLength)
        : Size(newLength, el.size.height);

    // Left = first endpoint (left when horizontal, top when vertical).
    // Right = last endpoint (right when horizontal, bottom when vertical).
    final Offset newPosition = isLeft
        ? (verticalWall
              ? Offset(el.position.dx, el.position.dy - actualChange)
              : Offset(el.position.dx - actualChange, el.position.dy))
        : el.position;

    // Check collision before applying the resize.
    if (_hasCollision(el, newPosition, newSize, el.rotation)) {
      AppToast.error(
        context,
        "Cannot resize. It would overlap another element.",
      );
      return;
    }

    setState(() {
      el.size = newSize;
      el.position = newPosition;
    });
    widget.onLayoutEdited?.call();
  }

  void setSelectedDoorStyle(DoorStyle style) {
    if (widget.mode != MapMode.manage) return;
    final matches = _layout.where((el) => el.id == _activeElementId);
    if (matches.isEmpty || matches.first.type != ElementType.door) return;
    final door = matches.first;
    const depth = 15.0;
    final nextSize = Size(style.width, depth);
    if (door.size == nextSize) return;

    final center =
        door.position + Offset(door.size.width / 2, door.size.height / 2);
    final nextPosition = center - Offset(nextSize.width / 2, depth / 2);
    if (_hasCollision(door, nextPosition, nextSize, door.rotation)) {
      AppToast.error(
        context,
        'Cannot change door type. It would overlap another object.',
      );
      return;
    }
    setState(() {
      door.position = nextPosition;
      door.size = nextSize;
    });
    widget.onLayoutEdited?.call();
  }

  Widget _buildBottomActionBar() {
    final activeEl = _layout.firstWhere(
      (el) => el.id == _activeElementId,
      orElse: () => MapElement(
        id: '',
        type: ElementType.wall,
        position: Offset.zero,
        label: '',
      ),
    );

    if (activeEl.id.isEmpty) return const SizedBox.shrink();

    // Determine which menu to show
    Widget currentMenu;
    if (_isChoosingDoorType && activeEl.type == ElementType.door) {
      currentMenu = _buildDoorTypeMenu(activeEl);
    } else if (_isAdjustingWidth) {
      currentMenu = _buildWidthAdjustmentMenu(activeEl);
    } else if (_isNudging) {
      currentMenu = _buildNudgeMenu(activeEl);
    } else {
      currentMenu = _buildMainMenu(activeEl);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: currentMenu,
    );
  }

  Widget _buildMainMenu(MapElement activeEl) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionMenuButton(
          icon: LucideIcons.rotateCw,
          label: "Rotate",
          color: Colors.blue,
          onTap: () {
            setState(() {
              if (activeEl.type == ElementType.wall) {
                // FIX: Walls must swap physical dimensions to preserve intersection math!
                final Offset center =
                    activeEl.position +
                    Offset(activeEl.size.width / 2, activeEl.size.height / 2);
                final Size newSize = Size(
                  activeEl.size.height,
                  activeEl.size.width,
                );
                final Offset newPos = Offset(
                  center.dx - newSize.width / 2,
                  center.dy - newSize.height / 2,
                );

                if (!_hasCollision(activeEl, newPos, newSize, 0.0)) {
                  activeEl.size = newSize;
                  activeEl.position = newPos;
                  activeEl.rotation = 0.0; // Force matrix rotation to 0
                } else {
                  AppToast.error(
                    context,
                    "Cannot rotate. Overlaps with another element.",
                  );
                }
              } else {
                // Normal 3D rotation for objects
                final double newRot = activeEl.rotation + (math.pi / 2);
                if (!_hasCollision(
                  activeEl,
                  activeEl.position,
                  activeEl.size,
                  newRot,
                )) {
                  activeEl.rotation = newRot;
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Cannot rotate. Overlaps with another element.",
                      ),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            });
            widget.onLayoutEdited?.call();
          },
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: activeEl.type == ElementType.door
              ? Icons.door_front_door_outlined
              : Icons.compare_arrows,
          label: activeEl.type == ElementType.door
              ? "Door Type"
              : "Adjust Width",
          color: Colors.orange,
          onTap: () {
            setState(() {
              _isChoosingDoorType = activeEl.type == ElementType.door;
              _isAdjustingWidth = activeEl.type != ElementType.door;
              _isNudging = false;
            });
          },
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.open_with,
          label: "Nudge",
          color: Colors.purpleAccent,
          onTap: () {
            setState(() {
              _isNudging = true;
              _isAdjustingWidth = false;
              _isChoosingDoorType = false;
            });
          },
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: LucideIcons.trash,
          label: "Remove",
          color: Colors.redAccent,
          onTap: () {
            _layout.removeWhere(
              (MapElement element) => element.id == activeEl.id,
            );
            setState(() {
              _activeElementId = null;
              _isAdjustingWidth = false;
              _isChoosingDoorType = false;
              _isNudging = false;
            });
            widget.onLayoutEdited?.call();
          },
        ),
      ],
    );
  }

  Widget _buildWidthAdjustmentMenu(MapElement activeEl) {
    final canShrink = canResizeMapElementWidth(activeEl, grow: false);
    final canGrow = canResizeMapElementWidth(activeEl, grow: true);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionMenuButton(
          icon: Icons.arrow_back,
          label: "Back",
          color: Colors.white,
          onTap: () {
            setState(() {
              _isAdjustingWidth = false;
            });
          },
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.remove,
          label: "Dec Left",
          color: Colors.orangeAccent,
          onTap: canShrink
              ? () =>
                    _changeElementWidthDirectional(activeEl, -40, isLeft: true)
              : null,
        ),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.add,
          label: "Inc Left",
          color: Colors.greenAccent,
          onTap: canGrow
              ? () => _changeElementWidthDirectional(activeEl, 40, isLeft: true)
              : null,
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.remove,
          label: "Dec Right",
          color: Colors.orangeAccent,
          onTap: canShrink
              ? () =>
                    _changeElementWidthDirectional(activeEl, -40, isLeft: false)
              : null,
        ),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.add,
          label: "Inc Right",
          color: Colors.greenAccent,
          onTap: canGrow
              ? () =>
                    _changeElementWidthDirectional(activeEl, 40, isLeft: false)
              : null,
        ),
      ],
    );
  }

  Widget _buildDoorTypeMenu(MapElement activeEl) {
    final selected = DoorStyle.fromWidth(activeEl.size.width);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionMenuButton(
          icon: Icons.arrow_back,
          label: 'Back',
          color: Colors.white,
          onTap: () => setState(() => _isChoosingDoorType = false),
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        for (final style in DoorStyle.values) ...[
          _buildActionMenuButton(
            icon: switch (style) {
              DoorStyle.single => Icons.door_front_door_outlined,
              DoorStyle.doubleDoor => Icons.meeting_room_outlined,
              DoorStyle.loading => Icons.garage_outlined,
            },
            label: style.label,
            color: selected == style ? Colors.greenAccent : Colors.white,
            onTap: () => setSelectedDoorStyle(style),
          ),
          const SizedBox(width: 12),
        ],
      ],
    );
  }

  Widget _buildNudgeMenu(MapElement activeEl) {
    // 40.0 keeps the object perfectly synced with your grid snap step size.
    const double step = 40.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildActionMenuButton(
          icon: Icons.arrow_back,
          label: "Back",
          color: Colors.white,
          onTap: () {
            setState(() {
              _isNudging = false;
            });
          },
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.keyboard_arrow_up,
          label: "Up",
          color: Colors.blueAccent,
          onTap: () => _nudgeElement(activeEl, const Offset(0, -step)),
        ),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.keyboard_arrow_down,
          label: "Down",
          color: Colors.blueAccent,
          onTap: () => _nudgeElement(activeEl, const Offset(0, step)),
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.keyboard_arrow_left,
          label: "Left",
          color: Colors.blueAccent,
          onTap: () => _nudgeElement(activeEl, const Offset(-step, 0)),
        ),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.keyboard_arrow_right,
          label: "Right",
          color: Colors.blueAccent,
          onTap: () => _nudgeElement(activeEl, const Offset(step, 0)),
        ),
      ],
    );
  }

  Widget _buildActionMenuButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onTap == null ? Colors.grey : color, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: onTap == null ? Colors.grey : Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveMapDisplay() {
    double minX = 0.0;
    double minY = 0.0;
    double maxX = 200.0;
    double maxY = 200.0;
    const double padding = 40.0;

    // 1. Find the bounds of all placed elements (including negative coordinates)
    for (var el in _layout) {
      if (el.position.dx < minX) minX = el.position.dx;
      if (el.position.dy < minY) minY = el.position.dy;

      final double rightEdge = el.position.dx + el.size.width;
      final double bottomEdge = el.position.dy + el.size.height;
      if (rightEdge > maxX) maxX = rightEdge;
      if (bottomEdge > maxY) maxY = bottomEdge;
    }

    // A drag must not resize the coordinate system used to locate the pointer.
    // Recompute bounds once after the gesture ends.
    final dragBounds = _dragCanvasBounds;
    if (dragBounds != null) {
      minX = dragBounds.minX;
      minY = dragBounds.minY;
      maxX = dragBounds.minX + dragBounds.width;
      maxY = dragBounds.minY + dragBounds.height;
    } else {
      minX = (minX / 40.0).floor() * 40.0 - padding;
      minY = (minY / 40.0).floor() * 40.0 - padding;
      maxX = (maxX / 40.0).ceil() * 40.0 + padding;
      maxY = (maxY / 40.0).ceil() * 40.0 + padding;
    }

    double mapWidth = maxX - minX;
    double mapHeight = maxY - minY;

    /// Splits any wall that is pierced by a perpendicular wall into shorter
    /// segments that stop at the crossing wall's face, instead of letting
    /// the two rectangles overlap. This removes the ambiguous "whole wall
    /// wins" case at T-junctions, since non-overlapping segments sort
    /// correctly with plain left/right ordering.
    MapElement _buildWallSegment(
      MapElement source,
      double start,
      double end,
      bool isHoriz,
      int segIndex,
    ) {
      final double length = end - start;
      final Offset newPos = isHoriz
          ? Offset(start, source.position.dy)
          : Offset(source.position.dx, start);
      final Size newSize = isHoriz
          ? Size(length, source.size.height)
          : Size(source.size.width, length);

      return source.copyWith(
        id: '${source.id}__seg$segIndex',
        position: newPos,
        size: newSize,
      );
    }

    List<MapElement> _splitWallsAtJunctions(List<MapElement> input) {
      final List<MapElement> result = [];
      final walls = input.where((e) => e.type == ElementType.wall).toList();
      final nonWalls = input.where((e) => e.type != ElementType.wall).toList();

      // For each wall id, the (start, end) ranges along its own long axis
      // that must be removed because a perpendicular wall pierces it there.
      final Map<String, List<List<double>>> cuts = {};

      List<double> boundsOf(MapElement el) {
        final c = _getCorners(el.position, el.size, el.rotation);
        return [
          c.map((p) => p.dx).reduce(math.min),
          c.map((p) => p.dx).reduce(math.max),
          c.map((p) => p.dy).reduce(math.min),
          c.map((p) => p.dy).reduce(math.max),
        ];
      }

      for (int i = 0; i < walls.length; i++) {
        for (int j = i + 1; j < walls.length; j++) {
          final a = walls[i];
          final b = walls[j];
          final bA = boundsOf(a);
          final bB = boundsOf(b);
          const e = 0.5;

          final overlapX = !(bA[1] <= bB[0] + e || bA[0] >= bB[1] - e);
          final overlapY = !(bA[3] <= bB[2] + e || bA[2] >= bB[3] - e);
          if (!(overlapX && overlapY)) continue;

          final aIsHoriz = (bA[1] - bA[0]) > (bA[3] - bA[2]);
          final bIsHoriz = (bB[1] - bB[0]) > (bB[3] - bB[2]);
          if (aIsHoriz == bIsHoriz)
            continue; // parallel overlap, not a T/+ joint

          final horizEl = aIsHoriz ? a : b;
          final vertEl = aIsHoriz ? b : a;
          final horizB = aIsHoriz ? bA : bB;
          final vertB = aIsHoriz ? bB : bA;

          // >>> Robust T-junction classification <<<
          // Measure how far each wall extends past the other wall's bounds
          final double hLeft = vertB[0] - horizB[0];
          final double hRight = horizB[1] - vertB[1];

          final double vTop = horizB[2] - vertB[2];
          final double vBottom = vertB[3] - horizB[3];

          // A wall is "continuous" if it has significant length on BOTH sides of the joint.
          final bool horizContinuous = hLeft > 5.0 && hRight > 5.0;
          final bool vertContinuous = vTop > 5.0 && vBottom > 5.0;

          bool
          cutVert; // true => split the vertical wall, false => split horizontal

          if (vertContinuous && !horizContinuous) {
            // Vertical wall continues, horizontal is the stem -> cut horizontal.
            cutVert = false;
          } else if (horizContinuous && !vertContinuous) {
            // Horizontal wall continues, vertical is the stem -> cut vertical.
            cutVert = true;
          } else {
            // Ambiguous (corner or fully crossed intersection).
            // Always cut the shorter wall so the main, longer wall stays completely solid.
            final double hLength = horizB[1] - horizB[0];
            final double vLength = vertB[3] - vertB[2];
            cutVert = vLength < hLength;
          }

          if (cutVert) {
            cuts.putIfAbsent(vertEl.id, () => []).add([horizB[2], horizB[3]]);
          } else {
            cuts.putIfAbsent(horizEl.id, () => []).add([vertB[0], vertB[1]]);
          }
        }
      }

      for (final wall in walls) {
        final wallCuts = cuts[wall.id];
        if (wallCuts == null || wallCuts.isEmpty) {
          result.add(wall);
          continue;
        }

        final isHoriz = wall.size.width > wall.size.height;
        final axisStart = isHoriz ? wall.position.dx : wall.position.dy;
        final axisEnd =
            axisStart + (isHoriz ? wall.size.width : wall.size.height);

        final sortedCuts =
            wallCuts
                .map(
                  (c) => [
                    c[0].clamp(axisStart, axisEnd),
                    c[1].clamp(axisStart, axisEnd),
                  ],
                )
                .where((c) => c[1] > c[0])
                .toList()
              ..sort((x, y) => x[0].compareTo(y[0]));

        double cursor = axisStart;
        int segIndex = 0;
        for (final cut in sortedCuts) {
          if (cut[0] > cursor && (cut[0] - cursor) > 1.0) {
            // FIX: Prevent micro-fragments
            result.add(
              _buildWallSegment(wall, cursor, cut[0], isHoriz, segIndex++),
            );
          }
          cursor = math.max(cursor, cut[1]);
        }
        if (cursor < axisEnd && (axisEnd - cursor) > 1.0) {
          // FIX: Prevent micro-fragments
          result.add(
            _buildWallSegment(wall, cursor, axisEnd, isHoriz, segIndex++),
          );
        }
      }

      return [...result, ...nonWalls];
    }

    List<MapElement> _buildRenderOrder() {
      final rawElements = List<MapElement>.from(_layout);
      final elements = _splitWallsAtJunctions(rawElements);
      if (elements.length <= 1) return elements;

      // 1. Pre-calculate exact bounds for all elements to ensure performance
      final bounds = <String, List<double>>{};
      for (var el in elements) {
        final c = _getCorners(el.position, el.size, el.rotation);
        bounds[el.id] = [
          c.map((p) => p.dx).reduce(math.min), // 0: minX
          c.map((p) => p.dx).reduce(math.max), // 1: maxX
          c.map((p) => p.dy).reduce(math.min), // 2: minY
          c.map((p) => p.dy).reduce(math.max), // 3: maxY
        ];
      }

      // 2. Helper function: Should element 'A' draw BEFORE element 'B'? (Is A behind B?)
      bool isBehind(MapElement a, MapElement b) {
        final bA = bounds[a.id]!;
        final bB = bounds[b.id]!;
        const double e = 0.5; // Tolerance for floating point snapping

        bool overlapX = !(bA[1] <= bB[0] + e || bA[0] >= bB[1] - e);
        bool overlapY = !(bA[3] <= bB[2] + e || bA[2] >= bB[3] - e);

        // -- SCENARIO A: Objects are intersecting/touching on the grid --
        if (overlapX && overlapY) {
          // >>> DEFINITIVE RULE: Wall-to-Wall Intersections (T-junctions & Corners) <<<
          if (a.type == ElementType.wall && b.type == ElementType.wall) {
            bool aIsHoriz = (bA[1] - bA[0]) > (bA[3] - bA[2]);
            bool bIsHoriz = (bB[1] - bB[0]) > (bB[3] - bB[2]);

            if (aIsHoriz != bIsHoriz) {
              // Identify which wall is which
              List<double> horiz = aIsHoriz ? bA : bB;
              List<double> vert = aIsHoriz ? bB : bA;

              // Measure overhang towards the camera from the junction
              double hExtend =
                  horiz[1] -
                  vert[1]; // How far the Horizontal wall extends Right (+X)
              double vExtend =
                  vert[3] -
                  horiz[3]; // How far the Vertical wall extends Down (+Y)

              // Whichever wall has the largest camera-facing overhang wins
              bool horizInFront = hExtend > vExtend;

              // Return true if 'A' is behind 'B'
              return aIsHoriz ? !horizInFront : horizInFront;
            }
          }

          // Doors always render after the wall they share space with
          if (a.type == ElementType.wall && b.type == ElementType.door)
            return true;
          if (a.type == ElementType.door && b.type == ElementType.wall)
            return false;

          // Props embedded in walls: isolate the wall's thickness to find true depth
          if (a.type == ElementType.wall && b.type != ElementType.wall) {
            bool aIsHoriz = (bA[1] - bA[0]) > (bA[3] - bA[2]);
            return aIsHoriz ? bA[3] < bB[3] : bA[1] < bB[1];
          }
          if (b.type == ElementType.wall && a.type != ElementType.wall) {
            bool bIsHoriz = (bB[1] - bB[0]) > (bB[3] - bB[2]);
            return bIsHoriz ? bA[3] < bB[3] : bA[1] < bB[1];
          }
        }

        // -- SCENARIO B: Objects are strictly separated on the grid --
        if (bA[1] <= bB[0] + e) return true; // A is strictly to the left of B
        if (bA[3] <= bB[2] + e) return true; // A is strictly above B
        if (bB[1] <= bA[0] + e) return false; // B is strictly to the left of A
        if (bB[3] <= bA[2] + e) return false; // B is strictly above A

        // -- SCENARIO C: Fallback for identically placed overlapping objects --
        return (bA[1] + bA[3]) < (bB[1] + bB[3]);
      }

      // 3. Custom Stable Insertion Sort
      for (int i = 1; i < elements.length; i++) {
        MapElement key = elements[i];
        int j = i - 1;

        // Shift elements up if they are visually in front of the key
        while (j >= 0 && isBehind(key, elements[j])) {
          elements[j + 1] = elements[j];
          j = j - 1;
        }
        elements[j + 1] = key;
      }

      return elements;
    }

    // Flat walls stay whole; only the isometric view needs split depth order.
    final sortedLayout = widget.viewStyle == MapViewStyle.twoD
        ? <MapElement>[
            ..._layout.where((el) => el.type == ElementType.wall),
            ..._layout.where((el) => el.type != ElementType.wall),
          ]
        : _buildRenderOrder();
    final visibleLayout = widget.mode == MapMode.manage && widget.hideWalls
        ? sortedLayout.where((el) => el.type != ElementType.wall)
        : sortedLayout;

    Widget map = LayoutBuilder(
      builder: (context, constraints) {
        final nextViewport = Size(constraints.maxWidth, constraints.maxHeight);
        final viewportChanged =
            _currentViewportSize != Size.zero &&
            _currentViewportSize != nextViewport;
        final mapBoundsChanged =
            _currentMapWidth != mapWidth ||
            _currentMapHeight != mapHeight ||
            _currentMapMinX != minX ||
            _currentMapMinY != minY;
        _currentViewportSize = nextViewport;
        _currentMapWidth = mapWidth;
        _currentMapHeight = mapHeight;
        _currentMapMinX = minX;
        _currentMapMinY = minY;

        // Manage/Assign use a sidebar; Preview has a wider canvas.
        // Keep the current zoom, but recenter when the viewport changes.
        if ((viewportChanged || (widget.fitEntireMap && mapBoundsChanged)) &&
            _isInitialScaleSet &&
            !_viewportRecenterQueued &&
            nextViewport.width > 0 &&
            nextViewport.height > 0) {
          _viewportRecenterQueued = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _viewportRecenterQueued = false;
            if (mounted) {
              _recenterMap(preserveScale: !widget.fitEntireMap);
            }
          });
        }

        if (!_isInitialScaleSet && constraints.maxWidth > 0) {
          _isInitialScaleSet = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _recenterMap();
          });
        }

        return DragTarget<ElementType>(
          onMove: _updatePalettePreview,
          onLeave: (_) {
            setState(() {
              _dragCanvasBounds = null;
              _dragPreviewPos = null;
              _dragPreviewSize = null;
              _dragPreviewType = null;
            });
          },
          onAcceptWithDetails: _acceptPaletteElement,
          builder: (context, candidateData, rejectedData) => InteractiveViewer(
            transformationController: _transformationController,
            constrained: false,
            scaleEnabled: false,
            minScale: widget.fitEntireMap ? 0.01 : 0.1,
            maxScale: 2.5,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: Builder(
              builder: (BuildContext dropContext) {
                return GestureDetector(
                  onTap: () {
                    if (widget.mode == MapMode.manage) {
                      setState(() {
                        _activeElementId = null;
                        _isAdjustingWidth = false;
                        _isChoosingDoorType = false;
                        _isNudging = false; // Add reset for nudge menu here
                      });
                      widget.onManageSelectionChanged?.call(null);
                    } else if (widget.mode == MapMode.view) {
                      setState(() {
                        _selectedPopupElement = null;
                      });
                    }
                  },
                  child: Transform(
                    alignment: FractionalOffset.center,
                    transform: widget.viewStyle == MapViewStyle.twoD
                        ? Matrix4.identity()
                        : (Matrix4.identity()
                            ..rotateX(-0.95)
                            ..rotateZ(0.785)),
                    child: Container(
                      key: _mapKey,
                      width: mapWidth,
                      height: mapHeight,
                      decoration: const BoxDecoration(
                        color: Colors
                            .transparent, // Completely transparent to show background
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CustomPaint(
                            painter: GridPainter(
                              flat: widget.viewStyle == MapViewStyle.twoD,
                            ),
                            size: Size(mapWidth, mapHeight),
                          ),
                          if (_dragPreviewPos != null &&
                              _dragPreviewSize != null &&
                              _dragPreviewType != null)
                            Positioned(
                              left: _dragPreviewPos!.dx - minX,
                              top: _dragPreviewPos!.dy - minY,
                              width: _dragPreviewSize!.width,
                              height: _dragPreviewSize!.height,
                              child: IgnorePointer(
                                child: Transform.rotate(
                                  angle: _dragPreviewRotation,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      // Low-opacity render of the actual object.
                                      Opacity(
                                        opacity: 0.55,
                                        child: _buildElementVisual(
                                          _dragPreviewType!,
                                          _dragPreviewSize!,
                                          _dragPreviewRotation,
                                        ),
                                      ),
                                      // Subtle valid/invalid tint over the
                                      // footprint so placement feedback
                                      // still reads at a glance.
                                      Positioned.fill(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: _dragPreviewValid
                                                ? Colors.greenAccent
                                                      .withOpacity(0.12)
                                                : Colors.redAccent.withOpacity(
                                                    0.25,
                                                  ),
                                            border: Border.all(
                                              color: _dragPreviewValid
                                                  ? Colors.green
                                                  : Colors.red,
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ...visibleLayout.map(
                            (el) => _buildPhysicalElement(el, minX, minY),
                          ),
                          if (widget.mode == MapMode.view &&
                              _selectedPopupElement != null)
                            _buildFloatingPopup(mapWidth, minX, minY),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );

    Widget mapDisplay = Stack(
      children: [
        map,
        if (widget.mode == MapMode.manage &&
            widget.showMobileToolbar &&
            _activeElementId != null)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Center(child: _buildBottomActionBar()),
          ),
        // ==========================================
        // NEW: Left Toolbar & Right Zoom Controls injected here
        // ==========================================
        if (widget.mode == MapMode.manage && widget.showMobileToolbar) ...[
          _buildLeftToolbar(),
        ],

        _buildZoomControls(),
      ],
    );

    return Expanded(
      child: Container(
        width: double.infinity,
        color: Colors.transparent,
        child: mapDisplay,
      ),
    );
  }

  Color _getElementColor(ElementType type, bool isHighlighted) {
    switch (type) {
      case ElementType.door:
        return Colors.green;
      case ElementType.rack:
        return Colors.blue;
      case ElementType.shelf:
        return Colors.brown;
      case ElementType.cashier:
        return Colors.purple;
      case ElementType.wall:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Widget _buildFlatElement(
    ElementType type,
    Size size, {
    bool selected = false,
    bool highlighted = false,
    double highlightPulse = 1,
  }) {
    final Color fill;
    final Color edge;
    final String name;
    switch (type) {
      case ElementType.wall:
        fill = const Color(0xFF64748B);
        edge = const Color(0xFF475569);
        name = '';
        break;
      case ElementType.door:
        fill = const Color(0xFFF59E0B);
        edge = const Color(0xFFB45309);
        name = '';
        break;
      case ElementType.rack:
        fill = const Color(0xFFBFDBFE);
        edge = const Color(0xFF3B82F6);
        name = 'RACK';
        break;
      case ElementType.shelf:
        fill = const Color(0xFFA7F3D0);
        edge = const Color(0xFF059669);
        name = 'SHELF';
        break;
      case ElementType.cashier:
        fill = const Color(0xFFC4B5FD);
        edge = const Color(0xFF7C3AED);
        name = 'CASHIER';
        break;
    }

    final emphasized = selected || highlighted;
    return Container(
      width: size.width,
      height: size.height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(
          type == ElementType.wall || type == ElementType.door ? 2 : 5,
        ),
        border: Border.all(
          color: highlighted
              ? const Color(
                  0xFFFF9800,
                ).withValues(alpha: 0.15 + 0.85 * highlightPulse)
              : (selected ? const Color(0xFF1D4ED8) : edge),
          width: emphasized ? 3 : 1.5,
        ),
        boxShadow: emphasized
            ? [
                BoxShadow(
                  color:
                      (highlighted
                              ? const Color(0xFFFF9800)
                              : const Color(0xFF2563EB))
                          .withValues(
                            alpha: highlighted
                                ? 0.05 + 0.4 * highlightPulse
                                : 0.25,
                          ),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: name.isNotEmpty && size.width >= 65 && size.height >= 33
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1E293B),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 0.6,
                ),
              ),
            )
          : null,
    );
  }

  /// Renders just the 3D model for a given type/size/rotation, with no
  /// interaction wrapper — used for the drag/move ghost preview.
  Widget _buildElementVisual(ElementType type, Size size, double rotation) {
    if (widget.viewStyle == MapViewStyle.twoD) {
      return _buildFlatElement(type, size);
    }
    final double modelWidth = size.width / 40.0;
    final double modelDepth = size.height / 40.0;
    const double mapRotX = 0.95;
    final double mapRotZ = math.pi / 4;
    final double true3DRotationY = rotation + mapRotZ;

    CustomPainter? modelPainter;
    double baseY = 0.0;
    double nudgeX = 0.0;
    double nudgeY = 0.0;

    switch (type) {
      case ElementType.rack:
        modelPainter = RackPainter(
          rack: Rack3D(
            width: modelWidth,
            depth: modelDepth,
            height: _rack3DHeight,
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.0;
        nudgeX = -2.0;
        nudgeY = -3.0;
        break;
      case ElementType.shelf:
        modelPainter = ShelfPainter(
          shelf: Shelf3D(
            width: modelWidth,
            depth: modelDepth,
            height: _shelf3DHeight,
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -1.75;
        nudgeX = 11.0;
        nudgeY = -9.0;
        break;
      case ElementType.cashier:
        modelPainter = CashierPainter(
          cashier: Cashier3D(width: modelWidth, depth: modelDepth, height: 3.5),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -2.75;
        break;
      case ElementType.door:
        modelPainter = DoorPainter(
          door: Door3D(
            width: modelWidth,
            depth: modelDepth,
            height: _door3DHeight,
            style: DoorStyle.fromWidth(size.width),
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -2.2;
        nudgeX = 9.6;
        break;
      case ElementType.wall:
        modelPainter = WallPainter(
          wall: Wall3D(
            width: modelWidth,
            depth: modelDepth,
            height: _wall3DHeight,
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.5;
        nudgeX = -6.0;
        break;
      default:
        modelPainter = null;
    }

    if (modelPainter == null) {
      return SizedBox(width: size.width, height: size.height);
    }

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..rotateZ(-rotation)
          ..rotateZ(-math.pi / 4)
          ..rotateX(0.17),
        child: Transform.translate(
          offset: Offset(
            (-baseY * 12 - 33) + nudgeX,
            (baseY * 12 - 35) + nudgeY,
          ),
          child: CustomPaint(painter: modelPainter, size: size),
        ),
      ),
    );
  }

  Widget _buildPhysicalElement(MapElement el, double minX, double minY) {
    // Split wall segments carry a synthetic id like "wall_3__seg0" so each
    // piece sorts independently; compare against the original source id
    // for selection/highlight purposes.
    final String sourceId = el.id.split('__seg').first;
    final bool isHighlighted = sourceId == widget.highlightId;
    final bool isActive =
        sourceId == _activeElementId && widget.mode == MapMode.manage;
    // Also highlight the object whose details are open in Preview mode.
    final bool isPreviewSelected =
        widget.mode == MapMode.view && _selectedPopupElement?.id == sourceId;
    final bool showObjectGlow = isActive || isPreviewSelected || isHighlighted;
    final bool isHovered = sourceId == _hoveredElementId && !showObjectGlow;

    // `el` may be a synthetic wall segment created by _splitWallsAtJunctions
    // purely for rendering/z-order purposes — it is NOT in storeLayout and
    // must never be mutated or passed to the controller. All selection,
    // dragging, collision-checking and callbacks must operate on the real
    // source element instead. For non-wall elements sourceId == el.id, so
    // this just resolves to el itself.
    final MapElement interactiveEl = _layout.firstWhere(
      (e) => e.id == sourceId,
      orElse: () => el,
    );

    final bool isWall = el.type == ElementType.wall;
    final bool isHorizontal = isWall ? el.size.width > 20 : false;
    final bool isVertical = isWall ? el.size.height > 20 : false;
    final double minSize = isWall ? 15.0 : 40.0;
    const double arrowFloorOffsetY = 20.0;

    Color baseColor = _getElementColor(el.type, isHighlighted);
    final double modelWidth = el.size.width / 40.0;
    final double modelDepth = el.size.height / 40.0;

    const double mapRotX = 0.95;
    final double mapRotZ = math.pi / 4;

    final double true3DRotationY = el.rotation + mapRotZ;

    final bool isTallThin =
        el.type == ElementType.wall || el.type == ElementType.door;
    final double extraHeight = isTallThin ? 180.0 : 40.0;
    final double topOffset = isTallThin ? -160.0 : -20.0;

    CustomPainter? modelPainter;
    double baseY = 0.0;
    double modelHeight = 0.0;
    double footprintScale = 40.0;
    double? footprintCameraDistance;

    double nudgeX = 0.0;
    double nudgeY = 0.0;

    switch (el.type) {
      case ElementType.rack:
        modelPainter = RackPainter(
          rack: Rack3D(
            width: modelWidth,
            depth: modelDepth,
            height: _rack3DHeight,
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.0;
        modelHeight = _rack3DHeight;
        footprintScale = 40.0;
        footprintCameraDistance = null;
        nudgeX = -2.0;
        nudgeY = -3.0;
        break;
      case ElementType.shelf:
        modelPainter = ShelfPainter(
          shelf: Shelf3D(
            width: modelWidth,
            depth: modelDepth,
            height: _shelf3DHeight,
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -1.75;
        modelHeight = _shelf3DHeight;
        footprintScale = 40.0;
        footprintCameraDistance = null;
        nudgeX = 11.0;
        nudgeY = -9.0;
        break;
      case ElementType.cashier:
        modelPainter = CashierPainter(
          cashier: Cashier3D(width: modelWidth, depth: modelDepth, height: 3.5),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -2.75;
        modelHeight = 3.5;
        footprintScale = 130.0;
        footprintCameraDistance = null;
        nudgeX = 0;
        nudgeY = 0;
        break;
      case ElementType.door:
        modelPainter = DoorPainter(
          door: Door3D(
            width: modelWidth,
            depth: modelDepth,
            height: _door3DHeight,
            style: DoorStyle.fromWidth(el.size.width),
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -2.2;
        modelHeight = _door3DHeight;
        footprintScale = 40.0;
        footprintCameraDistance = null;

        nudgeX = 9.6;
        nudgeY = 0;
        break;
      case ElementType.wall:
        modelPainter = WallPainter(
          wall: Wall3D(
            width: modelWidth,
            depth: modelDepth,
            height: _wall3DHeight,
          ),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.5;
        modelHeight = _wall3DHeight;
        footprintScale = 40.0;
        footprintCameraDistance = null;

        nudgeX = -6.0;
        nudgeY = 0;
        break;
      default:
        modelPainter = null;
    }

    final bool useFootprintOutline = false;

    // Walls/doors are visually thin (15px), so give them extra invisible
    // hit-test padding to make them easier to hover/tap precisely.
    final double hitPadding =
        (el.type == ElementType.wall || el.type == ElementType.door)
        ? 12.0
        : 0.0;
    final bool hitVisibleModel =
        widget.viewStyle == MapViewStyle.threeD && modelPainter != null;
    final double hitSideExtra = hitVisibleModel ? el.size.height / 2 + 40 : 0;
    final double hitTopExtra = hitVisibleModel ? modelHeight * 40 + 40 : 0;
    final double hitBottomExtra = hitVisibleModel ? 40 : 0;
    final double hitOuterHeight =
        el.size.height + 40 + hitTopExtra + hitBottomExtra;

    Widget shelf = widget.viewStyle == MapViewStyle.twoD
        ? (isHighlighted
              ? AnimatedBuilder(
                  animation: _animController,
                  builder: (context, child) => _buildFlatElement(
                    el.type,
                    el.size,
                    highlighted: true,
                    highlightPulse: _animController.value,
                  ),
                )
              : _buildFlatElement(
                  el.type,
                  el.size,
                  selected: showObjectGlow || isHovered,
                ))
        : Container(
            width: el.size.width,
            height: el.size.height,
            decoration: BoxDecoration(
              color: modelPainter == null
                  ? baseColor.withOpacity(0.3)
                  : Colors.transparent,
              border: !useFootprintOutline && isActive
                  ? Border.all(color: Colors.blue.shade600, width: 3)
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (modelPainter != null)
                  Positioned.fill(
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..rotateZ(-el.rotation)
                        ..rotateZ(-math.pi / 4)
                        ..rotateX(0.17),
                      child: Transform.translate(
                        offset: Offset(
                          (-baseY * 12 - 33) + nudgeX,
                          (baseY * 12 - 35) + nudgeY,
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (showObjectGlow && !isHighlighted)
                              // The glow is made from the SAME 3D painter, so it
                              // follows the rendered object instead of its floor tile.
                              ColorFiltered(
                                colorFilter: const ColorFilter.mode(
                                  Color(0xBBFF9800),
                                  BlendMode.srcIn,
                                ),
                                child: Transform.scale(
                                  scale: 1.045,
                                  child: CustomPaint(
                                    painter: modelPainter,
                                    size: Size(el.size.width, el.size.height),
                                  ),
                                ),
                              ),
                            if (isHovered)
                              ColorFiltered(
                                key: ValueKey('map-hover-glow-$sourceId'),
                                colorFilter: const ColorFilter.mode(
                                  Color(0xB32563EB),
                                  BlendMode.srcIn,
                                ),
                                child: Transform.scale(
                                  scale: 1.025,
                                  child: CustomPaint(
                                    painter: modelPainter,
                                    size: Size(el.size.width, el.size.height),
                                  ),
                                ),
                              ),
                            CustomPaint(
                              painter: modelPainter,
                              size: Size(el.size.width, el.size.height),
                            ),
                            if (isHighlighted)
                              AnimatedBuilder(
                                animation: _animController,
                                builder: (context, child) => CustomPaint(
                                  painter: _ObjectSilhouettePainter(
                                    width: modelWidth,
                                    height: modelHeight,
                                    depth: modelDepth,
                                    rotationX: mapRotX,
                                    rotationY: true3DRotationY,
                                    pulse: _animController.value,
                                  ),
                                  size: Size(el.size.width, el.size.height),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (useFootprintOutline && isActive)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..rotateZ(-el.rotation)
                          ..rotateZ(-math.pi / 4)
                          ..rotateX(0.95),
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            (-el.size.height * 0.5) + (baseY * 12),
                          ),
                          child: Transform.scale(
                            scale: 0.30,
                            child: CustomPaint(
                              painter: FootprintOutlinePainter(
                                width: modelWidth,
                                depth: modelDepth,
                                rotationX: mapRotX,
                                rotationY: true3DRotationY,
                                groundY: baseY,
                                height: modelHeight,
                                scale: footprintScale,
                                cameraDistance: footprintCameraDistance,
                                color: Colors.yellowAccent,
                                strokeWidth: 3,
                              ),
                              size: Size(el.size.width, el.size.height),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );

    return Positioned(
      key: ValueKey(el.id),
      left: el.position.dx - minX - 20 - hitSideExtra,
      top: el.position.dy - minY - 20 - hitTopExtra,
      width: el.size.width + 40 + hitSideExtra * 2,
      height: hitOuterHeight,
      child: Transform.rotate(
        angle: el.rotation,
        alignment: Alignment(
          0,
          (hitTopExtra - hitBottomExtra) / hitOuterHeight,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 20 - hitPadding,
              top: 20 - hitPadding,
              width: el.size.width + hitSideExtra * 2 + hitPadding * 2,
              height:
                  el.size.height +
                  hitTopExtra +
                  hitBottomExtra +
                  hitPadding * 2,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                opaque: false,
                hitTestBehavior: HitTestBehavior.deferToChild,
                onEnter: (_) {
                  if (_hoveredElementId != sourceId) {
                    setState(() => _hoveredElementId = sourceId);
                  }
                },
                onExit: (_) {
                  if (_hoveredElementId == sourceId) {
                    setState(() => _hoveredElementId = null);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTap: () async {
                    if (widget.mode == MapMode.manage) {
                      setState(() {
                        if (_activeElementId != interactiveEl.id) {
                          _isAdjustingWidth = false;
                          _isChoosingDoorType = false;
                          _isNudging = false; // Add reset for nudge menu here
                        }
                        _activeElementId = interactiveEl.id;
                      });
                      widget.onManageSelectionChanged?.call(interactiveEl);
                    } else if (widget.mode == MapMode.selection &&
                        widget.selectedItemId != null) {
                      if (!widget.itemAssignmentEnabled) {
                        AppToast.error(
                          context,
                          'Save or reload the map before assigning items.',
                        );
                        return;
                      }
                      if (el.type == ElementType.door ||
                          el.type == ElementType.cashier ||
                          el.type == ElementType.wall) {
                        AppToast.error(
                          context,
                          "Cannot assign items to ${el.type.name}s.",
                        );
                        return;
                      }
                      await widget.controller.assignItemToLocation(
                        widget.selectedItemId!,
                        interactiveEl.id,
                      );

                      if (mounted) {
                        if (widget.onSelectionAssigned != null) {
                          widget.onSelectionAssigned!();
                        }
                        setState(() {});
                        AppToast.success(context, "Item assigned to location!");
                      }
                    } else if (widget.mode == MapMode.pick) {
                      if (el.type == ElementType.door ||
                          el.type == ElementType.cashier ||
                          el.type == ElementType.wall) {
                        AppToast.error(
                          context,
                          "Cannot assign items to ${el.type.name}s.",
                        );
                        return;
                      }
                      if (widget.onElementSelected != null) {
                        widget.onElementSelected!(interactiveEl);
                      }
                    } else if (widget.mode == MapMode.view) {
                      if (el.type != ElementType.door &&
                          el.type != ElementType.cashier &&
                          el.type != ElementType.wall) {
                        setState(() {
                          if (_selectedPopupElement?.id == interactiveEl.id) {
                            _selectedPopupElement = null;
                          } else {
                            _selectedPopupElement = interactiveEl;
                          }
                        });
                      }
                    }
                  },
                  onPanStart: widget.mode == MapMode.manage
                      ? (details) {
                          _lockDragCanvas();
                          _rawDragPosition = interactiveEl.position;
                        }
                      : null,
                  onPanUpdate: widget.mode == MapMode.manage
                      ? (details) {
                          setState(() {
                            _activeElementId = interactiveEl.id;
                            final double cosR = math.cos(
                              interactiveEl.rotation,
                            );
                            final double sinR = math.sin(
                              interactiveEl.rotation,
                            );

                            final double mapDx =
                                details.delta.dx * cosR -
                                details.delta.dy * sinR;
                            final double mapDy =
                                details.delta.dx * sinR +
                                details.delta.dy * cosR;

                            _rawDragPosition =
                                _rawDragPosition! + Offset(mapDx, mapDy);
                            final Offset snappedPos = _snapObjectNearWall(
                              interactiveEl,
                              _rawDragPosition!,
                              interactiveEl.size,
                              interactiveEl.rotation,
                            );

                            final bool isValid = !_hasCollision(
                              interactiveEl,
                              snappedPos,
                              interactiveEl.size,
                              interactiveEl.rotation,
                            );
                            _dragPreviewPos = snappedPos;
                            _dragPreviewSize = interactiveEl.size;
                            _dragPreviewValid = isValid;
                            _dragPreviewRotation = interactiveEl.rotation;
                            _dragPreviewType = interactiveEl.type;

                            if (isValid) {
                              interactiveEl.position = snappedPos;
                            }
                          });
                        }
                      : null,
                  onPanEnd: widget.mode == MapMode.manage
                      ? (details) {
                          setState(() {
                            _dragCanvasBounds = null;
                            _rawDragPosition = null;
                            _dragPreviewPos = null;
                            _dragPreviewSize = null;
                            _dragPreviewType = null;
                          });
                          widget.onLayoutEdited?.call();
                        }
                      : null,
                  onPanCancel: widget.mode == MapMode.manage
                      ? () {
                          setState(() {
                            _dragCanvasBounds = null;
                            _rawDragPosition = null;
                            _dragPreviewPos = null;
                            _dragPreviewSize = null;
                            _dragPreviewType = null;
                          });
                        }
                      : null,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _MapObjectHitPainter(
                            footprint: el.size,
                            hitPadding: hitPadding,
                            sideExtra: hitSideExtra,
                            topExtra: hitTopExtra,
                            modelHeight: modelHeight,
                            baseY: baseY,
                            rotationX: mapRotX,
                            rotationY: true3DRotationY,
                            elementRotation: el.rotation,
                            nudgeX: nudgeX,
                            nudgeY: nudgeY,
                            threeD: hitVisibleModel,
                          ),
                        ),
                      ),
                      Positioned(
                        left: hitSideExtra + hitPadding,
                        top: hitTopExtra + hitPadding,
                        child: IgnorePointer(child: shelf),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Inverse of the ambient isometric Transform applied to the whole map
  /// (rotateX(-0.95) then rotateZ(0.785)). Wrapping a widget in this
  /// transform makes it render flat / facing the viewer ("standing") instead
  /// of lying skewed on the tilted floor plane, while its Positioned anchor
  /// point still tracks the object's real map position.
  Matrix4 _billboardTransform() {
    final Matrix4 ambient = Matrix4.identity()
      ..rotateX(-0.95)
      ..rotateZ(0.785);
    return Matrix4.inverted(ambient);
  }

  /// How far above the object's anchor point (in local map units) the
  /// bounce-marker pin should float, so it clears the top of the object's
  /// 3D model instead of hovering mid-way through it. Scaled roughly to
  /// each type's modelHeight used in _buildElementVisual/_buildPhysicalElement.
  double _pinHeightOffset(ElementType type) {
    switch (type) {
      case ElementType.rack:
        return 92.0;
      case ElementType.shelf:
        return 80.0;
      case ElementType.door:
        return 70.0;
      case ElementType.wall:
        return 70.0;
      case ElementType.cashier:
        return 55.0;
    }
  }

  Widget _buildFloatingPopup(double mapWidth, double minX, double minY) {
    final el = _selectedPopupElement!;
    final assignedItems = widget.controller.allItems
        .where((item) => item.locationId == el.id)
        .toList();

    double px = el.position.dx + el.size.width + 15 - minX;
    double py = el.position.dy - 10 - minY;

    if (px + 200 > mapWidth) {
      px = el.position.dx - 215 - minX;
    }

    final Matrix4 billboard = widget.viewStyle == MapViewStyle.twoD
        ? Matrix4.identity()
        : _billboardTransform();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // No location pin: the selected 3D model glows instead.
        Positioned(
          left: px,
          top: py,
          child: Transform(
            transform: billboard,
            // Pivot at the anchor corner so the card's position stays
            // pinned near the object while its face unfolds flat/upright.
            alignment: Alignment.topLeft,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 200,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                  border: Border.all(color: Colors.blue.shade600, width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade600.withOpacity(0.15),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(10),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              el.label,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade600,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: () =>
                                setState(() => _selectedPopupElement = null),
                            child: const Icon(
                              LucideIcons.x,
                              size: 14,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: assignedItems.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(12.0),
                              child: Text(
                                "Empty",
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 11,
                                ),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: assignedItems.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final item = assignedItems[index];
                                return Padding(
                                  padding: const EdgeInsets.all(10.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            "SKU: ${item.sku}",
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: Colors.grey,
                                            ),
                                          ),
                                          Text(
                                            "Qty: ${item.quantity}",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFFE5E7EB),
      child: Row(
        children: [
          _buildDetailItem("Aisle", widget.location?.aisle ?? "N/A"),
          const SizedBox(width: 8),
          _buildDetailItem("Shelf", widget.location?.shelf.toString() ?? "N/A"),
          const SizedBox(width: 8),
          _buildDetailItem("Section", widget.location?.section ?? "N/A"),
          const SizedBox(width: 8),
          _buildDetailItem(
            "Layer",
            (widget.location as dynamic)?.layer?.toString() ?? "N/A",
          ),
        ],
      ),
    );
  }

  Widget _buildArrow(IconData icon) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.green,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      child: Icon(icon, size: 16, color: Colors.white),
    );
  }

  Widget _buildDetailItem(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showElementDetails(MapElement el, List<InventoryItem> items) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Container(
            padding: const EdgeInsets.all(16),
            constraints: const BoxConstraints(maxHeight: 500, maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      el.label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      "This location is currently empty.",
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            "SKU: ${item.sku} • Lvl: ${item.shelfLevel ?? 'N/A'}",
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                "Qty: ${item.quantity} ${item.unit}",
                                style: TextStyle(
                                  color: Colors.blue.shade600,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                "₱${item.price.toStringAsFixed(2)}",
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Hits the projected body as well as its floor footprint. The painter draws
/// nothing; its convex hull lets pointer events pass through empty corners.
class _MapObjectHitPainter extends CustomPainter {
  final Size footprint;
  final double hitPadding;
  final double sideExtra;
  final double topExtra;
  final double modelHeight;
  final double baseY;
  final double rotationX;
  final double rotationY;
  final double elementRotation;
  final double nudgeX;
  final double nudgeY;
  final bool threeD;

  const _MapObjectHitPainter({
    required this.footprint,
    required this.hitPadding,
    required this.sideExtra,
    required this.topExtra,
    required this.modelHeight,
    required this.baseY,
    required this.rotationX,
    required this.rotationY,
    required this.elementRotation,
    required this.nudgeX,
    required this.nudgeY,
    required this.threeD,
  });

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool? hitTest(Offset position) {
    final origin = Offset(sideExtra + hitPadding, topExtra + hitPadding);
    final footprintBounds = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      footprint.width,
      footprint.height,
    ).inflate(hitPadding);
    if (footprintBounds.contains(position)) return true;
    if (!threeD || modelHeight <= 0) return false;

    final innerTransform = Matrix4.identity()
      ..rotateZ(-elementRotation)
      ..rotateZ(-math.pi / 4)
      ..rotateX(0.17);
    final center = Offset(footprint.width / 2, footprint.height / 2);
    final paintOffset = Offset(
      -baseY * 12 - 33 + nudgeX,
      baseY * 12 - 35 + nudgeY,
    );
    final halfWidth = footprint.width / 80 + 0.3;
    final halfDepth = footprint.height / 80 + 0.3;
    final bottom = math.min(-modelHeight / 2, baseY) - 0.4;
    final top = math.max(modelHeight / 2, baseY + modelHeight) + 0.4;

    final points =
        <Offset>[
          for (final x in [-halfWidth, halfWidth])
            for (final y in [bottom, top])
              for (final z in [-halfDepth, halfDepth])
                () {
                  final rotatedX =
                      x * math.cos(rotationY) - z * math.sin(rotationY);
                  final rotatedZ =
                      x * math.sin(rotationY) + z * math.cos(rotationY);
                  final rotatedY =
                      y * math.cos(rotationX) - rotatedZ * math.sin(rotationX);
                  final projected = Offset(
                    center.dx + rotatedX * 40,
                    center.dy - rotatedY * 40,
                  );
                  return origin +
                      center +
                      MatrixUtils.transformPoint(
                        innerTransform,
                        projected + paintOffset - center,
                      );
                }(),
        ]..sort((a, b) {
          final xOrder = a.dx.compareTo(b.dx);
          return xOrder != 0 ? xOrder : a.dy.compareTo(b.dy);
        });

    double cross(Offset a, Offset b, Offset c) =>
        (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
    final lower = <Offset>[];
    for (final point in points) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, point) <= 0) {
        lower.removeLast();
      }
      lower.add(point);
    }
    final upper = <Offset>[];
    for (final point in points.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, point) <= 0) {
        upper.removeLast();
      }
      upper.add(point);
    }
    final hull = [
      ...lower.take(lower.length - 1),
      ...upper.take(upper.length - 1),
    ];
    if (hull.length < 3) return false;
    final centroid = hull.reduce((a, b) => a + b) / hull.length.toDouble();
    final paddedHull = [
      for (final point in hull)
        point + (point - centroid) / (point - centroid).distance * 6,
    ];
    return (Path()..addPolygon(paddedHull, true)).contains(position);
  }

  @override
  bool shouldRepaint(covariant _MapObjectHitPainter oldDelegate) => false;
}

/// Draws only the outside contour of a 3D object, not its floor footprint or
/// the internal shelf faces.
class _ObjectSilhouettePainter extends CustomPainter {
  final double width;
  final double height;
  final double depth;
  final double rotationX;
  final double rotationY;
  final double pulse;

  const _ObjectSilhouettePainter({
    required this.width,
    required this.height,
    required this.depth,
    required this.rotationX,
    required this.rotationY,
    required this.pulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Offset project(double x, double y, double z) {
      final xRotated = x * math.cos(rotationY) - z * math.sin(rotationY);
      final zRotated = x * math.sin(rotationY) + z * math.cos(rotationY);
      final yRotated = y * math.cos(rotationX) - zRotated * math.sin(rotationX);
      return Offset(
        size.width / 2 + xRotated * 40,
        size.height / 2 - yRotated * 40,
      );
    }

    final points =
        <Offset>[
          for (final x in [-width / 2, width / 2])
            for (final y in [-height / 2, height / 2])
              for (final z in [-depth / 2, depth / 2]) project(x, y, z),
        ]..sort((a, b) {
          final xOrder = a.dx.compareTo(b.dx);
          return xOrder != 0 ? xOrder : a.dy.compareTo(b.dy);
        });

    double cross(Offset a, Offset b, Offset c) =>
        (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

    final lower = <Offset>[];
    for (final point in points) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, point) <= 0) {
        lower.removeLast();
      }
      lower.add(point);
    }
    final upper = <Offset>[];
    for (final point in points.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, point) <= 0) {
        upper.removeLast();
      }
      upper.add(point);
    }
    final hull = [
      ...lower.take(lower.length - 1),
      ...upper.take(upper.length - 1),
    ];
    if (hull.length < 3) return;

    final center = hull.reduce((a, b) => a + b) / hull.length.toDouble();
    final contour = <Offset>[
      for (final point in hull)
        point + (point - center) / (point - center).distance * 5,
    ];
    final path = Path()..moveTo(contour.first.dx, contour.first.dy);
    for (final point in contour.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 10 + 4 * pulse
        ..color = const Color(0xFFFF9800).withValues(alpha: 0.04 + 0.2 * pulse),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 2 + 2 * pulse
        ..color = const Color(
          0xFFFF9800,
        ).withValues(alpha: 0.12 + 0.88 * pulse),
    );
  }

  @override
  bool shouldRepaint(covariant _ObjectSilhouettePainter oldDelegate) =>
      pulse != oldDelegate.pulse ||
      width != oldDelegate.width ||
      height != oldDelegate.height ||
      depth != oldDelegate.depth ||
      rotationX != oldDelegate.rotationX ||
      rotationY != oldDelegate.rotationY;
}

// class GridPainter extends CustomPainter {
//   @override
//   void paint(Canvas canvas, Size size) {
//     final gridPaint = Paint()
//       ..color = Colors.white
//       ..strokeWidth = 1.5
//       ..style = PaintingStyle.stroke;

//     // Draw the white isometric grid lines across the available area
//     const double step = 40;

//     for (double i = 0; i <= size.width; i += step) {
//       canvas.drawLine(Offset(i, 0), Offset(i, size.height), gridPaint);
//     }
//     for (double i = 0; i <= size.height; i += step) {
//       canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
//     }
//   }

//   @override
//   bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
// }
class GridPainter extends CustomPainter {
  final bool flat;

  const GridPainter({this.flat = false});

  @override
  void paint(Canvas canvas, Size size) {
    final floorPaint = Paint()
      ..color = flat
          ? const Color(0xFFEFF6FF)
          : const Color.fromARGB(255, 165, 205, 245);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), floorPaint);

    final linePaint = Paint()
      ..color = flat ? const Color(0xFFC3DBF8) : Colors.white
      ..strokeWidth = flat ? 1.0 : 1.5;

    final double step = flat ? 20.0 : 40.0;

    for (double i = 0; i <= size.width; i += step) {
      if (flat) linePaint.strokeWidth = i % 40.0 == 0 ? 1.3 : 0.7;
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), linePaint);
    }
    for (double i = 0; i <= size.height; i += step) {
      if (flat) linePaint.strokeWidth = i % 40.0 == 0 ? 1.3 : 0.7;
      canvas.drawLine(Offset(0, i), Offset(size.width, i), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) =>
      oldDelegate.flat != flat;
}

class CADBlockPainter extends CustomPainter {
  final Color baseColor;
  final double zHeight;

  CADBlockPainter({required this.baseColor, this.zHeight = 25.0});

  @override
  void paint(Canvas canvas, Size size) {
    final topColor = baseColor;
    final frontColor = Color.lerp(baseColor, Colors.black, 0.2)!;
    final rightColor = Color.lerp(baseColor, Colors.black, 0.4)!;
    final outlineColor = Colors.black87;

    final double ex = zHeight * 0.4;
    final double ey = -zHeight;

    final double w = size.width - ex;
    final double h = size.height - ey.abs();

    final pBL = Offset(0, size.height);
    final pBR = Offset(w, size.height);
    final pTR = Offset(w, size.height - h);
    final pTL = Offset(0, size.height - h);

    final rBL = pBL + Offset(ex, ey);
    final rBR = pBR + Offset(ex, ey);
    final rTR = pTR + Offset(ex, ey);
    final rTL = pTL + Offset(ex, ey);

    final fillPaint = Paint()..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = outlineColor;

    void drawFace(List<Offset> points, Color color) {
      final path = Path()..addPolygon(points, true);
      fillPaint.color = color;
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
    }

    drawFace([pBR, pTR, rTR, rBR], rightColor);
    drawFace([pBL, pBR, rBR, rBL], frontColor);
    drawFace([rBL, rBR, rTR, rTL], topColor);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
