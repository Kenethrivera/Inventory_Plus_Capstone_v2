import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'store_map.dart';

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
      backgroundColor: const Color(0xFFFAFAFA), // Deep dark background
      appBar: AppBar(
        automaticallyImplyLeading: false, // Hidden back button as requested
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Store Layout Designer",
              style: TextStyle(
                color: Color(0xFF0F172A),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              "$_assignedCount of $_totalCount items assigned",
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withOpacity(0.3)),
            ),
            child: IconButton(
              icon: const Icon(LucideIcons.trash2, color: Colors.redAccent, size: 18),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text("Clear Map?"),
                    content: const Text(
                        "Are you sure you want to delete the entire map layout?"),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Cancel"),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red),
                        onPressed: () {
                          Navigator.pop(context);
                          widget.controller.clearMapLayout().then((_) {
                            if (mounted) setState(() {});
                          });
                        },
                        child: const Text("Delete",
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.orange,
              borderRadius: BorderRadius.circular(8),
            ),
            child: IconButton(
              icon: const Icon(LucideIcons.save, color: Colors.white, size: 18),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text("Save Map?"),
                    content: const Text(
                        "Are you sure you want to save the current map layout?"),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text("Cancel"),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue),
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          setState(() => _isSaved = true);
                          await widget.controller.saveLayout();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text("Store layout saved successfully!"),
                                  backgroundColor: Colors.green),
                            );
                          }
                        },
                        child: const Text("Save",
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildModeTabs(),
          Divider(height: 1, color: Colors.white.withOpacity(0.8)),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // SIDEBAR (Only visible in Assign mode now)
                if (_mode == MapMode.selection)
                  Container(
                    width: 280,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(
                        right: BorderSide(
                            color: Colors.white.withOpacity(0.1), width: 1),
                      ),
                    ),
                    child: _buildAssignSidebar(),
                  ),
                // MAIN MAP CANVAS
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
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
                      // Overlays based on mode
                      if (_mode == MapMode.view) _buildPreviewOverlays(),
                      if (_mode == MapMode.selection && _selectedItemId != null)
                        _buildAssignOverlayBanner(),
                    ],
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF1F3F5),
          borderRadius: BorderRadius.circular(8),
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
          color: isSelected ? Colors.orange : Colors.transparent,
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
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                color: isSelected ? Colors.white : Colors.grey.shade400,
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
              color: Colors.grey.shade600,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Color(0xFF0F172A), fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search items...',
              hintStyle: TextStyle(color: Colors.grey.shade500),
              prefixIcon: Icon(LucideIcons.search, size: 16, color: Colors.grey.shade500),
              filled: true,
              fillColor: Color(0xFFF1F3F5),
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
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
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildFilterPill('All', _totalCount),
              _buildFilterPill('Unassigned', unassignedCount),
              _buildFilterPill('Assigned', _assignedCount),
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
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.orange.withOpacity(0.1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? Colors.orange : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Status Icon
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: isAssigned ? Colors.green : (isSelected ? Colors.orange : Colors.transparent),
                          shape: isAssigned ? BoxShape.circle : BoxShape.rectangle,
                          borderRadius: isAssigned ? null : BorderRadius.circular(4),
                          border: Border.all(
                            color: isAssigned ? Colors.green : (isSelected ? Colors.orange : Colors.grey.shade600),
                            width: 1.5,
                          ),
                        ),
                        child: isAssigned
                            ? const Icon(LucideIcons.check, size: 12, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: TextStyle(
                                color: const Color(0xFF0F172A),
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isAssigned ? "Rack Assigned" : "Unassigned",
                              style: TextStyle(
                                color: isAssigned
                                    ? Colors.green
                                    : (isSelected
                                          ? Colors.orange
                                          : Colors.grey.shade500),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.orange : const Color(0xFFF1F3F5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.orange : Colors.black.withOpacity(0.05),
          ),
        ),
        child: Text(
          "$label $count",
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey.shade700,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ─── OVERLAYS ──────────────────────────────────────────────────────────────

  Widget _buildPreviewOverlays() {
    return Stack(
      children: [
        
        // Banner
        Positioned(
          top: 24,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.blue.withOpacity(0.5)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.eye, color: Colors.blue, size: 16),
                  SizedBox(width: 8),
                  Text(
                    "Preview mode — view only, tap an item to see details",
                    style: TextStyle(
                      color: Colors.blue,
                      fontSize: 12,
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

  Widget _buildLegendItem(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildAssignOverlayBanner() {
    // Find item name
    final item = widget.controller.allItems.firstWhere((i) => i.id == _selectedItemId);

    return Positioned(
      top: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.orange),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.mousePointerClick, color: Colors.orange, size: 18),
              const SizedBox(width: 12),
              const Text(
                "Tap a highlighted rack or\nshelf to place",
                style: TextStyle(
                  color: Colors.orange,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
              Container(
                width: 1,
                height: 24,
                color: Colors.orange.withOpacity(0.3),
                margin: const EdgeInsets.symmetric(horizontal: 16),
              ),
              Text(
                item.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}