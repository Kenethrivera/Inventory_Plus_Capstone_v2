import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'models_3d.dart';

enum MapMode { view, manage, selection, pick }
const Color kMapContainerBg = Color.fromARGB(255, 9, 36, 73);

class StoreMap extends StatefulWidget {
  final InventoryController controller;
  final String? highlightId;
  final ItemLocation? location;
  final String? itemName;
  final MapMode mode;
  final String? selectedItemId;
  final VoidCallback? onSelectionAssigned;
  final Function(MapElement)? onElementSelected;

  const StoreMap({
    super.key,
    required this.controller,
    this.highlightId,
    this.location,
    this.itemName,
    this.mode = MapMode.view,
    this.selectedItemId,
    this.onSelectionAssigned,
    this.onElementSelected,
  });

  @override
  State<StoreMap> createState() => _StoreMapState();
}

class _StoreMapState extends State<StoreMap>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _bounceAnimation;
  String? _activeElementId;
  bool _isAdjustingWidth = false;

  bool _isNudging = false;
  final TransformationController _transformationController =
      TransformationController();
  bool _isInitialScaleSet = false;
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

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _animController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _autoOpenItemCard(String itemId) {
    try {
      final item = widget.controller.allItems.firstWhere((i) => i.id == itemId);
      
      if (item.locationId != null) {
        final element = widget.controller.storeLayout.firstWhere((e) => e.id == item.locationId);
        
        setState(() {
          // Uses the correct variable defined on line 42
          _selectedPopupElement = element; 
        });
      }
    } catch (e) {
      // Item or location not found; fail silently
    }
  }
  // ==========================================
  // NEW: Zoom logic for the right controls
  // ==========================================
  void _zoom(double zoomFactor) {
    final double scale = _transformationController.value.getMaxScaleOnAxis();
    final double newScale = (scale * zoomFactor).clamp(0.1, 2.5);
    final double actualFactor = newScale / scale;

    // Get screen center to zoom in/out smoothly towards the center
    final Size screenSize = MediaQuery.of(context).size;
    final Offset center = Offset(screenSize.width / 2, screenSize.height / 2);

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
      return const Size(168, 64); // Wider counter
    } else if (type == ElementType.shelf) {
      return const Size(104, 48); // Standard shelf footprint
    } else if (type == ElementType.rack) {
      return const Size(120, 60); // Standard rack footprint
    }
    return const Size(80, 80); // Fallback
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

    for (var other in widget.controller.storeLayout) {
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
                color: Colors.orange,
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
                child: const Icon(Icons.add, color: Colors.black, size: 32),
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
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: color, width: 2),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                ),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      // Change border to orange when hovered
                      color: isHovered
                          ? Colors.orange
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
                    border: Border.all(color: Colors.orange, width: 1.5),
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
    return Positioned(
      bottom: 20,
      right: 20,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.blueGrey.withOpacity(0.5),
            width: 1.5,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () => _zoom(1.2), // Zoom in
            ),
            Container(
              height: 1,
              width: 40,
              color: Colors.blueGrey.withOpacity(0.5),
            ),
            IconButton(
              icon: const Icon(Icons.remove, color: Colors.white),
              onPressed: () => _zoom(0.8), // Zoom out
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      // Margin on all sides so the map doesn't touch the sidebar
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kMapContainerBg,
        borderRadius: BorderRadius.circular(16),
         border: Border.all(
  color: Colors.black.withOpacity(0.15),
  width: 1,
), // was Colors.white.withOpacity(0.12)
          
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
          const Icon(LucideIcons.mapPin, color: Colors.orange, size: 20),
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
  void _nudgeElement(MapElement el, Offset delta) {
    final Offset newPosition = el.position + delta;

    if (_hasCollision(el, newPosition, el.size, el.rotation)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Cannot nudge. It would overlap another element."),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    setState(() {
      el.position = newPosition;
    });
  }

  // ==========================================
  // COC STYLE BOTTOM ACTION BAR
  // ==========================================
  void _changeElementWidthDirectional(
    MapElement el,
    double amount, {
    required bool isLeft,
  }) {
    const double minSizeWall = 15.0;
    const double minSizeObject = 40.0;

    final double minWidth = el.type == ElementType.wall
        ? minSizeWall
        : minSizeObject;

    final double newWidth = (el.size.width + amount).clamp(
      minWidth,
      double.infinity,
    );

    final double actualChange = newWidth - el.size.width;

    // Nothing to change
    if (actualChange == 0) return;

    final Size newSize = Size(newWidth, el.size.height);

    // If expanding/shrinking on the left, shift the X position in the opposite direction.
    // If on the right, the top-left X position stays the same.
    final Offset newPosition = isLeft
        ? Offset(el.position.dx - actualChange, el.position.dy)
        : el.position;

    // Check collision before applying the resize.
    if (_hasCollision(el, newPosition, newSize, el.rotation)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Cannot change width. It would overlap another element.",
          ),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    setState(() {
      el.size = newSize;
      el.position = newPosition;
    });
  }

  Widget _buildBottomActionBar() {
    final activeEl = widget.controller.storeLayout.firstWhere(
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
    if (_isAdjustingWidth) {
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
                final Offset center = activeEl.position + Offset(activeEl.size.width / 2, activeEl.size.height / 2);
                final Size newSize = Size(activeEl.size.height, activeEl.size.width);
                final Offset newPos = Offset(center.dx - newSize.width / 2, center.dy - newSize.height / 2);

                if (!_hasCollision(activeEl, newPos, newSize, 0.0)) {
                  activeEl.size = newSize;
                  activeEl.position = newPos;
                  activeEl.rotation = 0.0; // Force matrix rotation to 0
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Cannot rotate. Overlaps with another element."), backgroundColor: Colors.redAccent),
                  );
                }
              } else {
                // Normal 3D rotation for objects
                final double newRot = activeEl.rotation + (math.pi / 2);
                if (!_hasCollision(activeEl, activeEl.position, activeEl.size, newRot)) {
                  activeEl.rotation = newRot;
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Cannot rotate. Overlaps with another element."), backgroundColor: Colors.redAccent),
                  );
                }
              }
            });
          },
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.compare_arrows,
          label: "Adjust Width",
          color: Colors.orange,
          onTap: () {
            setState(() {
              _isAdjustingWidth = true;
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
            widget.controller.deleteMapElement(activeEl.id);
            setState(() {
              _activeElementId = null;
              _isAdjustingWidth = false;
              _isNudging = false;
            });
          },
        ),
      ],
    );
  }

  Widget _buildWidthAdjustmentMenu(MapElement activeEl) {
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
          onTap: () =>
              _changeElementWidthDirectional(activeEl, -40, isLeft: true),
        ),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.add,
          label: "Inc Left",
          color: Colors.greenAccent,
          onTap: () =>
              _changeElementWidthDirectional(activeEl, 40, isLeft: true),
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 40, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.remove,
          label: "Dec Right",
          color: Colors.orangeAccent,
          onTap: () =>
              _changeElementWidthDirectional(activeEl, -40, isLeft: false),
        ),
        const SizedBox(width: 12),
        _buildActionMenuButton(
          icon: Icons.add,
          label: "Inc Right",
          color: Colors.greenAccent,
          onTap: () =>
              _changeElementWidthDirectional(activeEl, 40, isLeft: false),
        ),
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
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
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
    for (var el in widget.controller.storeLayout) {
      if (el.position.dx < minX) minX = el.position.dx;
      if (el.position.dy < minY) minY = el.position.dy;

      final double rightEdge = el.position.dx + el.size.width;
      final double bottomEdge = el.position.dy + el.size.height;
      if (rightEdge > maxX) maxX = rightEdge;
      if (bottomEdge > maxY) maxY = bottomEdge;
    }

    // 2. Include the preview element if dragging
    if (_dragPreviewPos != null && _dragPreviewSize != null) {
      if (_dragPreviewPos!.dx < minX) minX = _dragPreviewPos!.dx;
      if (_dragPreviewPos!.dy < minY) minY = _dragPreviewPos!.dy;

      final double dragRight = _dragPreviewPos!.dx + _dragPreviewSize!.width;
      final double dragBottom = _dragPreviewPos!.dy + _dragPreviewSize!.height;
      if (dragRight > maxX) maxX = dragRight;
      if (dragBottom > maxY) maxY = dragBottom;
    }

    // 3. Snap the bounding box to the grid and add padding
    minX = (minX / 40.0).floor() * 40.0 - padding;
    minY = (minY / 40.0).floor() * 40.0 - padding;
    maxX = (maxX / 40.0).ceil() * 40.0 + padding;
    maxY = (maxY / 40.0).ceil() * 40.0 + padding;

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
        if (cut[0] > cursor && (cut[0] - cursor) > 1.0) { // FIX: Prevent micro-fragments
          result.add(_buildWallSegment(wall, cursor, cut[0], isHoriz, segIndex++));
        }
        cursor = math.max(cursor, cut[1]);
      }
      if (cursor < axisEnd && (axisEnd - cursor) > 1.0) { // FIX: Prevent micro-fragments
        result.add(_buildWallSegment(wall, cursor, axisEnd, isHoriz, segIndex++));
      }
    }

    return [...result, ...nonWalls];
    }

    List<MapElement> _buildRenderOrder() {
      final rawElements = List<MapElement>.from(widget.controller.storeLayout);
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

    final sortedLayout = _buildRenderOrder();

    Widget map = LayoutBuilder(
      builder: (context, constraints) {
        if (!_isInitialScaleSet && constraints.maxWidth > 0) {
          _isInitialScaleSet = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              double scaleX = constraints.maxWidth / mapWidth;
              double scaleY = constraints.maxHeight / mapHeight;
              double scale = math.min(scaleX, scaleY) * 0.9;
              scale = scale.clamp(0.1, 2.5);

              double dx = (constraints.maxWidth - (mapWidth * scale)) / 2;
              double dy = (constraints.maxHeight - (mapHeight * scale)) / 2;

              _transformationController.value = Matrix4.identity()
                ..translate(dx, dy)
                ..scale(scale);
            }
          });
        }

        return InteractiveViewer(
          transformationController: _transformationController,
          constrained: false,
          minScale: 0.1,
          maxScale: 2.5,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: Builder(
            builder: (BuildContext dropContext) {
              return DragTarget<ElementType>(
                onMove: (details) {
                  final RenderBox? box =
                      _mapKey.currentContext?.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final Offset localOffset = box.globalToLocal(details.offset);

                  // NEW: Map visual coordinate back to true world coordinate
                  final Offset worldOffset = Offset(
                    localOffset.dx + minX,
                    localOffset.dy + minY,
                  );

                  final Size previewSize = _getDefaultSize(details.data);
                  final snappedPos = _snapToGrid(
                    worldOffset,
                    previewSize,
                    details.data,
                  );

                  final tempEl = MapElement(
                    id: 'temp',
                    type: details.data,
                    position: snappedPos,
                    label: '',
                  );
                  tempEl.size = previewSize;

                  setState(() {
                    _dragPreviewPos = snappedPos;
                    _dragPreviewSize = previewSize;
                    _dragPreviewValid = !_hasCollision(
                      tempEl,
                      snappedPos,
                      previewSize,
                      0.0,
                    );
                    _dragPreviewRotation = 0.0;
                    _dragPreviewType = details.data;
                  });
                },
                onLeave: (_) {
                  setState(() {
                    _dragPreviewPos = null;
                    _dragPreviewSize = null;
                    _dragPreviewType = null;
                  });
                },
                onAcceptWithDetails: (details) {
                  final RenderBox? box =
                      _mapKey.currentContext?.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final Offset localOffset = box.globalToLocal(details.offset);

                  // NEW: Map visual coordinate back to true world coordinate
                  final Offset worldOffset = Offset(
                    localOffset.dx + minX,
                    localOffset.dy + minY,
                  );

                  final Size finalSize = _getDefaultSize(details.data);
                  final Offset finalPos = _snapToGrid(
                    worldOffset,
                    finalSize,
                    details.data,
                  );

                  final newEl = MapElement(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    type: details.data,
                    position: finalPos,
                    label: details.data.name.toUpperCase(),
                  );

                  newEl.size = finalSize;

                  if (!_hasCollision(newEl, finalPos, finalSize, 0.0)) {
                    setState(() {
                      widget.controller.storeLayout.add(newEl);
                    });
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          "Cannot place element here. It overlaps with another.",
                        ),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  }

                  setState(() {
                    _dragPreviewPos = null;
                    _dragPreviewSize = null;
                    _dragPreviewType = null;
                  });
                },
                builder: (context, candidateData, rejectedData) {
                  return GestureDetector(
                    onTap: () {
                      if (widget.mode == MapMode.manage) {
                        setState(() {
                          _activeElementId = null;
                          _isAdjustingWidth = false;
                          _isNudging = false; // Add reset for nudge menu here
                        });
                      } else if (widget.mode == MapMode.view) {
                        setState(() {
                          _selectedPopupElement = null;
                        });
                      }
                    },
                    child: Transform(
                      alignment: FractionalOffset.center,
                      transform: Matrix4.identity()
                        ..rotateX(-0.95)
                        ..rotateZ(0.785),
                      child: Container(
                        key: _mapKey,
                        width: mapWidth,
                        height: mapHeight,
                        decoration: BoxDecoration(
                          color: const Color(0xFF7C7E81),
                          border: Border.all(color: Colors.blueGrey, width: 2),
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CustomPaint(
                              painter: GridPainter(),
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
                                                  : Colors.redAccent
                                                        .withOpacity(0.25),
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
                            ...sortedLayout.map(
                              (el) => _buildPhysicalElement(el, minX, minY),
                            ),
                            if (_selectedPopupElement != null)
                              _buildFloatingPopup(mapWidth, minX, minY),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );

    Widget mapDisplay = Stack(
      children: [
        map,
        if (widget.mode == MapMode.manage && _activeElementId != null)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Center(child: _buildBottomActionBar()),
          ),
        // ==========================================
        // NEW: Left Toolbar & Right Zoom Controls injected here
        // ==========================================
        if (widget.mode == MapMode.manage) ...[
          _buildLeftToolbar(),
          _buildZoomControls(),
        ],
      ],
    );

    // if (widget.mode == MapMode.view) {
    //   return Container(
    //     height: 800,
    //     width: double.infinity,
    //     color: const Color(0xFF0F172A),
    //     child: mapDisplay,
    //   );
    // } else {
    //   return Expanded(
    //     child: Container(
    //       width: double.infinity,
    //       color: const Color(0xFF0F172A),
    //       child: mapDisplay,
    //     ),
    //   );
    // }
    return Expanded(
      child: Container(
        width: double.infinity,
        color: kMapContainerBg,
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
  /// Renders just the 3D model for a given type/size/rotation, with no
  /// interaction wrapper — used for the drag/move ghost preview.
  Widget _buildElementVisual(ElementType type, Size size, double rotation) {
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
          rack: Rack3D(width: modelWidth, depth: modelDepth, height: 8.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -5.0;
        nudgeX = -26.0;
        nudgeY = -3.0;
        break;
      case ElementType.shelf:
        modelPainter = ShelfPainter(
          shelf: Shelf3D(width: modelWidth, depth: modelDepth, height: 7.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.5;
        nudgeX = -10.0;
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
          door: Door3D(width: modelWidth, depth: modelDepth, height: 6.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.0;
        break;
      case ElementType.wall:
        modelPainter = WallPainter(
          wall: Wall3D(width: modelWidth, depth: modelDepth, height: 6.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.0;
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

    // `el` may be a synthetic wall segment created by _splitWallsAtJunctions
    // purely for rendering/z-order purposes — it is NOT in storeLayout and
    // must never be mutated or passed to the controller. All selection,
    // dragging, collision-checking and callbacks must operate on the real
    // source element instead. For non-wall elements sourceId == el.id, so
    // this just resolves to el itself.
    final MapElement interactiveEl = widget.controller.storeLayout.firstWhere(
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
          rack: Rack3D(width: modelWidth, depth: modelDepth, height: 8.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -5.0;
        modelHeight = 8.0;
        footprintScale = 40.0;
        footprintCameraDistance = null;
        nudgeX = -26.0;
        nudgeY = -3.0;
        break;
      case ElementType.shelf:
        modelPainter = ShelfPainter(
          shelf: Shelf3D(width: modelWidth, depth: modelDepth, height: 7.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.5;
        modelHeight = 7.0;
        footprintScale = 40.0;
        footprintCameraDistance = null;
        nudgeX = -10.0;
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
          door: Door3D(width: modelWidth, depth: modelDepth, height: 6.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.0;
        modelHeight = 6.0;
        footprintScale = 40.0;
        footprintCameraDistance = null;

        nudgeX = 0;
        nudgeY = 0;
        break;
      case ElementType.wall:
        modelPainter = WallPainter(
          wall: Wall3D(width: modelWidth, depth: modelDepth, height: 6.0),
          rotationX: mapRotX,
          rotationY: true3DRotationY,
        );
        baseY = -3.0;
        modelHeight = 6.0;
        footprintScale = 40.0;
        footprintCameraDistance = null;

        nudgeX = 0;
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

    Widget shelf = Container(
      width: el.size.width,
      height: el.size.height,
      decoration: BoxDecoration(
        color: modelPainter == null
            ? baseColor.withOpacity(0.3)
            : Colors.transparent,
        border: !useFootprintOutline && isActive
            ? Border.all(color: Colors.yellowAccent, width: 3)
            : (isHighlighted
                  ? Border.all(color: Colors.orange, width: 2)
                  : null),
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
                  child: CustomPaint(
                    painter: modelPainter,
                    size: Size(el.size.width, el.size.height),
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
                    offset: Offset(0, (-el.size.height * 0.5) + (baseY * 12)),
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
      left: el.position.dx - minX - 20,
      top: el.position.dy - minY - 20,
      width: el.size.width + 40,
      height: el.size.height + 40,
      child: Transform.rotate(
        angle: el.rotation,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 20 - hitPadding,
              top: 20 - hitPadding,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    if (widget.mode == MapMode.manage) {
                      setState(() {
                        if (_activeElementId != interactiveEl.id) {
                          _isAdjustingWidth = false;
                          _isNudging = false; // Add reset for nudge menu here
                        }
                        _activeElementId = interactiveEl.id;
                      });
                    } else if (widget.mode == MapMode.selection &&
                        widget.selectedItemId != null) {
                      if (el.type == ElementType.door ||
                          el.type == ElementType.cashier ||
                          el.type == ElementType.wall) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Cannot assign items to ${el.type.name}s.",
                            ),
                            backgroundColor: Colors.redAccent,
                          ),
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              "Item assigned to location!",
                              style: TextStyle(color: Colors.white),
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    } else if (widget.mode == MapMode.pick) {
                      if (el.type == ElementType.door ||
                          el.type == ElementType.cashier ||
                          el.type == ElementType.wall) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Cannot assign items to ${el.type.name}s.",
                            ),
                            backgroundColor: Colors.redAccent,
                          ),
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
                            final Offset snappedPos = _snapToGrid(
                              _rawDragPosition!,
                              interactiveEl.size,
                              interactiveEl.type,
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
                            _rawDragPosition = null;
                            _dragPreviewPos = null;
                            _dragPreviewSize = null;
                            _dragPreviewType = null;
                          });
                        }
                      : null,
                  child: Container(
                    // Transparent padding = bigger tap/hover target without
                    // changing how thin the wall/door actually looks.
                    padding: EdgeInsets.all(hitPadding),
                    color: Colors.transparent,
                    child: shelf,
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

    final Matrix4 billboard = _billboardTransform();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Arrow/pin marking exactly which object this popup belongs to.
        // Billboarded so it stands upright instead of lying on the floor.
        Positioned(
          left: el.position.dx + el.size.width / 2 - 100 - minX,
          top: el.position.dy - _pinHeightOffset(el.type) - minY,
          child: Transform(
            transform: billboard,
            alignment: Alignment.bottomCenter,
            child: AnimatedBuilder(
              animation: _bounceAnimation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _bounceAnimation.value),
                  child: child,
                );
              },
              child: const Icon(
                LucideIcons.mapPin,
                color: Colors.orange,
                size: 26,
                shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          ),
        ),
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
                  border: Border.all(color: Colors.orange, width: 2),
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
                        color: Colors.orange.withOpacity(0.15),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.orange,
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
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.orange,
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
                                style: const TextStyle(
                                  color: Colors.orange,
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

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;

    const double step = 40;

    for (double i = 0; i <= size.width; i += step) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double i = 0; i <= size.height; i += step) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
