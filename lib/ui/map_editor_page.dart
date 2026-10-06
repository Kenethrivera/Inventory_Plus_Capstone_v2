import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'store_map.dart';

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
  MapMode _mode = MapMode.view; // Default to Preview
  String? _selectedItemId;
  late String _initialLayoutJson;
  bool _isSaved = false;

  // Assign mode state
  String _searchQuery = '';
  String _assignFilter = 'All'; // All, Unassigned, Assigned
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialLayoutJson = jsonEncode(
        widget.controller.storeLayout.map((e) => e.toJson()).toList());
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (!_isSaved) {
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
                  builder: (context) => AlertDialog(
                    title: const Text("Clear Map?", style: TextStyle(fontFamily: _fontFam, fontWeight: FontWeight.bold)),
                    content: const Text(
                        "Are you sure you want to delete the entire map layout?", style: TextStyle(fontFamily: _fontFam)),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade600),
                        onPressed: () {
                          Navigator.pop(context);
                          widget.controller.clearMapLayout().then((_) {
                            if (mounted) setState(() {});
                          });
                        },
                        child: const Text("Delete",
                            style: TextStyle(color: Colors.white, fontFamily: _fontFam, fontWeight: FontWeight.bold)),
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
                  builder: (dialogContext) => AlertDialog(
                    title: const Text("Save Map?", style: TextStyle(fontFamily: _fontFam, fontWeight: FontWeight.bold)),
                    content: const Text(
                        "Are you sure you want to save the current map layout?", style: TextStyle(fontFamily: _fontFam)),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryBlue),
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          setState(() => _isSaved = true);
                          await widget.controller.saveLayout();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Store layout saved successfully!", style: TextStyle(fontFamily: _fontFam)),
                                  backgroundColor: Colors.green),
                            );
                          }
                        },
                        child: const Text("Save",
                            style: TextStyle(color: Colors.white, fontFamily: _fontFam, fontWeight: FontWeight.bold)),
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
                              controller: widget.controller,
                              mode: _mode,
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