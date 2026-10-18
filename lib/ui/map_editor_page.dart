import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'store_map.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _lightBg = Color(0xFFF4F6F8);
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
  MapMode _mode = MapMode.view; // Default to Preview
  String? _selectedItemId;
  String _initialLayoutJson = '[]';
  bool _isLayoutReady = false;
  bool _isSaved = false;

  // Assign mode state
  String _searchQuery = '';
  String _assignFilter = 'All'; // All, Unassigned, Assigned
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_initializeLayout());
  }

  Future<void> _initializeLayout() async {
    await widget.controller.fetchMapLayout();
    if (!mounted) return;

    _initialLayoutJson = jsonEncode(
        widget.controller.storeLayout.map((e) => e.toJson()).toList());
    setState(() => _isLayoutReady = true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (_isLayoutReady && !_isSaved) {
      final List<dynamic> decoded = jsonDecode(_initialLayoutJson);
      widget.controller.storeLayout =
          decoded.map((e) => MapElement.fromJson(e)).toList();
    }
    super.dispose();
  }

  int get _assignedCount =>
      widget.controller.allItems.where((i) => i.locationId != null).length;

  int get _totalCount => widget.controller.allItems.length;

  @override
  Widget build(BuildContext context) {
    if (!_isLayoutReady) {
      return const Scaffold(
        backgroundColor: _lightBg,
        body: Center(child: CircularProgressIndicator(color: _primaryBlue)),
      );
    }

    final bool desktopLayout = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: _lightBg,
      appBar: AppBar(
        automaticallyImplyLeading: false, // Hidden back button as requested
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Store Layout Designer",
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  fontFamily: _fontFam,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                "$_assignedCount of $_totalCount items assigned",
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 13,
                  fontWeight: FontWeight.normal,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: IconButton(
              icon: Icon(LucideIcons.trash2, color: Colors.red.shade500, size: 18),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (dialogContext) => AppDialog(
                    icon: LucideIcons.trash2,
                    color: Colors.red.shade600,
                    title: "Clear Map?",
                    subtitle: "Delete entire map layout",
                    child: const Text(
                      "Are you sure you want to delete the entire map layout? All items will be unassigned.",
                      style: TextStyle(fontFamily: _fontFam, fontSize: 13),
                    ),
                    actions: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black87,
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam, fontWeight: FontWeight.bold)),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          widget.controller.clearMapLayout().then((_) {
                            if (mounted) setState(() {});
                            if (mounted) AppToast.success(context, "Map layout cleared");
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          "Delete",
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: _fontFam,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 10, right: 24),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryBlue,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (dialogContext) => AppDialog(
                    icon: LucideIcons.save,
                    color: _primaryBlue,
                    title: "Save Map Layout?",
                    subtitle: "Apply changes to store map",
                    child: const Text(
                      "Are you sure you want to save the current map layout? This will lock in the new item locations.",
                      style: TextStyle(fontFamily: _fontFam, fontSize: 13),
                    ),
                    actions: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black87,
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam, fontWeight: FontWeight.bold)),
                      ),
                      ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          setState(() => _isSaved = true);
                          await widget.controller.saveLayout();
                          if (mounted) {
                            AppToast.success(context, "Store layout saved successfully!");
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primaryBlue,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          "Save Layout",
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: _fontFam,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
              child: const Text("Save layout", style: TextStyle(color: Colors.white, fontFamily: _fontFam, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(color: Colors.white, child: _buildModeTabs()),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Desktop Manage Layout palette, kept outside the map canvas.
                if (_mode == MapMode.manage && desktopLayout)
                  Container(
                    width: 290,
                    margin: const EdgeInsets.only(top: 16, left: 16, bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFDBEAFE)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _buildManageSidebar(),
                  ),
                // SIDEBAR (Only visible in Assign mode)
                if (_mode == MapMode.selection)
                  Container(
                    width: 320,
                    margin: const EdgeInsets.only(top: 16, left: 16, bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: _buildAssignSidebar(),
                  ),
                // MAIN MAP CANVAS
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _lightBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: StoreMap(
                              key: _storeMapKey,
                              onManageSelectionChanged: (element) {
                                if (mounted) setState(() => _manageSelected = element);
                              },
                              controller: widget.controller,
                              mode: _mode,
                              showMobileToolbar: !desktopLayout,
                              selectedItemId: _selectedItemId,
                              onSelectionAssigned: () {
                                setState(() {
                                  _selectedItemId = null;
                                });
                              },
                            ),
                          ),
                        ),
                        // Overlays based on mode
                        if (_mode == MapMode.view) _buildPreviewOverlays(),
                        if (_mode == MapMode.selection && _selectedItemId != null)
                          _buildAssignOverlayBanner(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  // Desktop-only drag palette. The map's existing DragTarget<ElementType>
  // receives the same type values as the mobile + toolbar.
  Widget _buildManageSidebar() {
    // When an element is selected, replace the entire drag palette with
    // its editing controls. Closing the editor restores the palette.
    if (_manageSelected != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: _buildManageSelectionControls(_manageSelected!),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
          color: const Color(0xFFEFF6FF),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MAP ELEMENTS',
                  style: TextStyle(fontFamily: _fontFam, fontSize: 13,
                      fontWeight: FontWeight.w800, color: Color(0xFF1D4ED8),
                      letterSpacing: 0.7)),
              SizedBox(height: 6),
              Text('Press and hold, then drag to map',
                  style: TextStyle(fontFamily: _fontFam, fontSize: 12,
                      color: Color(0xFF64748B))),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _buildManagePaletteItem(ElementType.door, 'Door',
                  LucideIcons.doorOpen, const Color(0xFF16A34A)),
              _buildManagePaletteItem(ElementType.rack, 'Rack',
                  Icons.view_headline, const Color(0xFF2563EB)),
              _buildManagePaletteItem(ElementType.shelf, 'Shelf',
                  Icons.shelves, const Color(0xFFEA580C)),
              _buildManagePaletteItem(ElementType.cashier, 'Cashier',
                  Icons.point_of_sale, const Color(0xFF9333EA)),
              _buildManagePaletteItem(ElementType.wall, 'Wall',
                  Icons.line_weight, const Color(0xFF64748B)),
            ],
          ),
        ),
        if (_manageSelected != null)
          Flexible(child: SingleChildScrollView(child: _buildManageSelectionControls(_manageSelected!))),
        if (_manageSelected == null) Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Color(0xFFF8FAFC),
            border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 16, color: Color(0xFF2563EB)),
              SizedBox(width: 8),
              Expanded(child: Text(
                'Drag elements onto the map. Select a placed element to rotate, resize, move, or remove it.',
                style: TextStyle(fontFamily: _fontFam, fontSize: 11,
                    color: Color(0xFF64748B), height: 1.5),
              )),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildManageSelectionControls(MapElement element) {
    final label = element.type.name;
    final heading = '${label[0].toUpperCase()}${label.substring(1)} #${widget.controller.storeLayout.where((e) => e.type == element.type).toList().indexWhere((e) => e.id == element.id) + 1}';
    return Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFDBEAFE)))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(heading, style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.w800, fontSize: 14, fontFamily: _fontFam))),
            IconButton(tooltip: 'Deselect object', onPressed: () => _storeMapKey.currentState?.clearManageSelection(), icon: const Icon(Icons.close, size: 17)),
          ]),
          const SizedBox(height: 5),
          _manageSectionLabel('ROTATE'),
          const SizedBox(height: 5),
          _manageAction('Rotate 90°', LucideIcons.rotateCw, MapSidebarAction.rotate),
          const SizedBox(height: 10),
          _manageSectionLabel('NUDGE'),
          const SizedBox(height: 5),
          Center(child: _manageMiniButton('▲', MapSidebarAction.up)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _manageMiniButton('◀', MapSidebarAction.left),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Icon(Icons.add, size: 14, color: Color(0xFF94A3B8))),
            _manageMiniButton('▶', MapSidebarAction.right),
          ]),
          Center(child: _manageMiniButton('▼', MapSidebarAction.down)),
          const SizedBox(height: 10),
          _manageSectionLabel('ADJUST WIDTH'),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _manageAction('◀ Left −', null, MapSidebarAction.widthLeftMinus)),
            const SizedBox(width: 6),
            Expanded(child: _manageAction('▶ Left +', null, MapSidebarAction.widthLeftPlus)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _manageAction('◀ Right −', null, MapSidebarAction.widthRightMinus)),
            const SizedBox(width: 6),
            Expanded(child: _manageAction('▶ Right +', null, MapSidebarAction.widthRightPlus)),
          ]),
          const SizedBox(height: 12),
          if (element.type == ElementType.wall) ...[
            _manageSectionLabel('WALL ALIGNMENT'),
            const SizedBox(height: 6),
            _manageAction('Auto-align corners', LucideIcons.magnet,
                MapSidebarAction.autoAlignWall),
            const SizedBox(height: 12),
          ],
          _manageAction('Duplicate object', LucideIcons.copy, MapSidebarAction.duplicate),
          const SizedBox(height: 8),
          _manageAction('Delete object', LucideIcons.trash2, MapSidebarAction.delete, destructive: true),
        ]),
      ),
    );
  }

  Widget _manageSectionLabel(String text) => Text(text,
      style: const TextStyle(color: Color(0xFF64748B), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .8, fontFamily: _fontFam));

  Widget _manageMiniButton(String text, MapSidebarAction action) => Padding(
    padding: const EdgeInsets.all(2),
    child: _HoverManageButton(label: text, onTap: () => _storeMapKey.currentState?.applySidebarAction(action), width: 44, height: 33),
  );

  Widget _manageAction(String label, IconData? icon, MapSidebarAction action, {bool destructive = false}) =>
    _HoverManageButton(label: label, icon: icon, destructive: destructive,
      onTap: () => _storeMapKey.currentState?.applySidebarAction(action));

  Widget _buildManagePaletteItem(
      ElementType type, String label, IconData icon, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Draggable<ElementType>(
        data: type,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _primaryBlue, width: 2),
              boxShadow: const [
                BoxShadow(color: Color(0x22000000), blurRadius: 12),
              ],
            ),
            child: Icon(icon, color: accent, size: 28),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: _buildPaletteCard(label, icon, accent),
        ),
        child: _buildPaletteCard(label, icon, accent),
      ),
    );
  }

  Widget _buildPaletteCard(String label, IconData icon, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDBEAFE)),
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: accent.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: accent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(
          fontFamily: _fontFam, fontWeight: FontWeight.w700,
          fontSize: 14, color: Color(0xFF0F172A),
        ))),
        const Icon(LucideIcons.gripVertical,
            size: 18, color: Color(0xFF94A3B8)),
      ]),
    );
  }

  // ─── TOP TABS ──────────────────────────────────────────────────────────────

  Widget _buildModeTabs() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Expanded(child: _buildTabButton(MapMode.manage, LucideIcons.pencil, "Manage Layout")),
            Expanded(child: _buildTabButton(MapMode.selection, LucideIcons.link, "Assign Items")),
            Expanded(child: _buildTabButton(MapMode.view, LucideIcons.eye, "Preview")),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(MapMode mode, IconData icon, String label) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () {
        setState(() {
          _mode = mode;
          if (mode != MapMode.manage) _manageSelected = null;
          if (mode != MapMode.selection) _selectedItemId = null;
        });
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? _primaryBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : Colors.grey.shade600,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontFamily: _fontFam,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── ASSIGN SIDEBAR ────────────────────────────────────────────────────────

  Widget _buildAssignSidebar() {
    var items = widget.controller.allItems.toList();

    // Filter Logic
    if (_assignFilter == 'Unassigned') {
      items = items.where((i) => i.locationId == null).toList();
    } else if (_assignFilter == 'Assigned') {
      items = items.where((i) => i.locationId != null).toList();
    }
    if (_searchQuery.isNotEmpty) {
      items = items
          .where((i) => i.name.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }

    // Sort: Unassigned first, then alphabetical
    items.sort((a, b) {
      if (a.locationId == null && b.locationId != null) return -1;
      if (a.locationId != null && b.locationId == null) return 1;
      return a.name.compareTo(b.name);
    });

    final unassignedCount =
        widget.controller.allItems.where((i) => i.locationId == null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text(
            "ITEMS TO PLACE",
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 12,
              fontFamily: _fontFam,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14, fontFamily: _fontFam),
            decoration: InputDecoration(
              hintText: 'Search items...',
              hintStyle: TextStyle(color: Colors.grey.shade400, fontFamily: _fontFam),
              prefixIcon: Icon(LucideIcons.search, size: 18, color: Colors.grey.shade500),
              filled: true,
              fillColor: _lightBg,
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (val) => setState(() => _searchQuery = val),
          ),
        ),
        const SizedBox(height: 16),
        // Filters
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: _buildFilterPill('All', _totalCount)),
              const SizedBox(width: 8),
              Expanded(child: _buildFilterPill('Unassigned', unassignedCount)),
              const SizedBox(width: 8),
              Expanded(child: _buildFilterPill('Assigned', _assignedCount)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isSelected = _selectedItemId == item.id;
              final isAssigned = item.locationId != null;

              return GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedItemId = isSelected ? null : item.id;
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isSelected ? _primaryBlue.withOpacity(0.05) : _lightBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? _primaryBlue : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Status Icon
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: isAssigned ? _primaryBlue : Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isAssigned ? _primaryBlue : Colors.grey.shade300,
                            width: 1.5,
                          ),
                        ),
                        child: isAssigned
                            ? const Icon(LucideIcons.check, size: 14, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                color: const Color(0xFF0F172A),
                                fontWeight: FontWeight.bold,
                                fontFamily: _fontFam,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isAssigned ? "Rack Assigned" : "Unassigned",
                              style: TextStyle(
                                color: isAssigned ? _primaryBlue : Colors.grey.shade500,
                                fontSize: 12,
                                fontFamily: _fontFam,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFilterPill(String label, int count) {
    final isSelected = _assignFilter == label;
    return GestureDetector(
      onTap: () => setState(() => _assignFilter = label),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? _primaryBlue : _lightBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade700,
                fontSize: 11,
                fontFamily: _fontFam,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              "$count",
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey.shade700,
                fontSize: 13,
                fontFamily: _fontFam,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── OVERLAYS ──────────────────────────────────────────────────────────────

  Widget _buildPreviewOverlays() {
    return Stack(
      children: [
        Positioned(
          top: 24,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ]
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.eye, color: _primaryBlue, size: 18),
                  SizedBox(width: 8),
                  Text(
                    "Preview mode — view only, tap an item to see details",
                    style: TextStyle(
                      color: _primaryBlue,
                      fontSize: 13,
                      fontFamily: _fontFam,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAssignOverlayBanner() {
    return Positioned(
      top: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              )
            ]
          ),
          child: const Text(
            "Tap a rack to link an item",
            style: TextStyle(
              color: _primaryBlue,
              fontSize: 14,
              fontFamily: _fontFam,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

// Shared hover behavior for desktop map-control buttons.
class _HoverManageButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool destructive;
  final double? width;
  final double height;
  const _HoverManageButton({required this.label, required this.onTap, this.icon,
    this.destructive = false, this.width, this.height = 36});
  @override
  State<_HoverManageButton> createState() => _HoverManageButtonState();
}
class _HoverManageButtonState extends State<_HoverManageButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final fg = widget.destructive ? (hover ? Colors.white : const Color(0xFFDC2626))
        : (hover ? Colors.white : const Color(0xFF1D4ED8));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.width, height: widget.height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.destructive
                ? (hover ? const Color(0xFFDC2626) : const Color(0xFFFEF2F2))
                : (hover ? const Color(0xFF2563EB) : const Color(0xFFEFF6FF)),
            border: Border.all(color: widget.destructive ? const Color(0xFFFECACA) : const Color(0xFFBFDBFE)),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (widget.icon != null) ...[Icon(widget.icon, size: 15, color: fg), const SizedBox(width: 6)],
            Flexible(child: Text(widget.label, textAlign: TextAlign.center, maxLines: 1,
              style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700, fontFamily: _fontFam))),
          ]),
        ),
      ),
    );
  }
}
