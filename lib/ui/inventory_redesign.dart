import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_styled_dropdown.dart';
import 'widgets/restock_request_dialog.dart';
import 'widgets/write_off_request_dialog.dart';
import '../services/app_error_mapper.dart';
import 'store_map.dart';

const _blue = Color(0xFF2563EB);
const _ink = Color(0xFF172033);
const _slate = Color(0xFF64748B);
const _border = Color(0xFFE6EBF2);
const _font = 'Hellix';
const _warmBackground = Color(0xFFF7F6F4);
const _warmBorder = Color(0xFFE6E1DC);
const _warmMuted = Color(0xFF817A75);
const _warmOrange = Color(0xFFC83D08);
const _warmRed = Color(0xFFDC2626);

String _qty(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

String _money(double amount) {
  final parts = amount.toStringAsFixed(2).split('.');
  final whole = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '₱$whole.${parts[1]}';
}

String _statusLabel(StockStatus status) {
  switch (status) {
    case StockStatus.ok:
      return 'In stock';
    case StockStatus.low:
      return 'Low stock';
    case StockStatus.critical:
      return 'Critical';
    case StockStatus.out:
      return 'Out of stock';
  }
}

Color _statusColor(StockStatus status) {
  switch (status) {
    case StockStatus.ok:
      return const Color(0xFF168046);
    case StockStatus.low:
      return const Color(0xFFB7791F);
    case StockStatus.critical:
    case StockStatus.out:
      return const Color(0xFFDC2626);
  }
}

class InventoryRedesign extends StatefulWidget {
  final InventoryController controller;
  final ValueChanged<InventoryItem> onSelectItem;
  final Future<void> Function(InventoryItem) onUpdateItem;
  final VoidCallback onExport;
  final void Function(List<InventoryItem>?) onQrLabels;
  final VoidCallback onNewItem;
  final bool exportDue;

  const InventoryRedesign({
    super.key,
    required this.controller,
    required this.onSelectItem,
    required this.onUpdateItem,
    required this.onExport,
    required this.onQrLabels,
    required this.onNewItem,
    this.exportDue = false,
  });

  @override
  State<InventoryRedesign> createState() => _InventoryRedesignState();
}

class _InventoryRedesignState extends State<InventoryRedesign> {
  final _search = TextEditingController();
  String _category = 'All';
  String _stockFilter = 'all';
  String _sortBy = 'nameAsc';
  bool _showDisabled = false;
  int _page = 0;
  static const _perPage = 8;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _chooseCategory(String category) {
    setState(() {
      _category = category;
      _page = 0;
    });
  }

  Future<void> _openSortFilterDialog() async {
    var draftStatus = _stockFilter;
    var draftSort = _sortBy;

    // Counts reflect the search, category, and disabled toggle outside
    // this modal, so the Apply button previews the actual result total.
    final disabledItems = widget.controller.disabledItems;
    final disabledIds = disabledItems.map((item) => item.id).toSet();
    final matchingItems =
        <InventoryItem>[
          ...widget.controller.currentInventory.where(
            (item) => !disabledIds.contains(item.id),
          ),
          if (_showDisabled) ...disabledItems,
        ].where((item) {
          final query = _search.text.trim().toLowerCase();
          return (_category == 'All' || item.category == _category) &&
              (query.isEmpty ||
                  item.name.toLowerCase().contains(query) ||
                  item.sku.toLowerCase().contains(query) ||
                  item.category.toLowerCase().contains(query));
        }).toList();

    int countForStatus(String status) {
      if (status == 'all') return matchingItems.length;
      return matchingItems.where((item) {
        if (widget.controller.isDisabled(item.id)) return false;
        final stock = widget.controller.stockStatusFor(item);
        switch (status) {
          case 'ok':
            return stock == StockStatus.ok;
          case 'low':
            return stock == StockStatus.low;
          case 'critical':
            return stock == StockStatus.critical;
          case 'out':
            return stock == StockStatus.out;
          default:
            return true;
        }
      }).length;
    }

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) {
          final screen = MediaQuery.of(context).size;
          final modalHeight = screen.height < 640
              ? screen.height * 0.88
              : 576.0;
          final matchingCount = countForStatus(draftStatus);

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 16,
            ),
            backgroundColor: Colors.white,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: SizedBox(
              width: 700,
              height: modalHeight,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(30, 23, 24, 22),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Filter & sort',
                                style: TextStyle(
                                  fontFamily: _font,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w800,
                                  color: _ink,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Narrow the list by status and choose how it is ordered.',
                                style: TextStyle(
                                  fontFamily: _font,
                                  fontSize: 13,
                                  color: _slate,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(
                            Icons.close,
                            size: 21,
                            color: _slate,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: _border),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'STATUS',
                            style: TextStyle(
                              fontFamily: _font,
                              fontSize: 12,
                              color: _slate,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _choicePill(
                                "All statuses  ${countForStatus('all')}",
                                draftStatus == 'all',
                                () => updateDialog(() => draftStatus = 'all'),
                              ),
                              _choicePill(
                                "In stock  ${countForStatus('ok')}",
                                draftStatus == 'ok',
                                () => updateDialog(() => draftStatus = 'ok'),
                              ),
                              _choicePill(
                                "Low stock  ${countForStatus('low')}",
                                draftStatus == 'low',
                                () => updateDialog(() => draftStatus = 'low'),
                              ),
                              _choicePill(
                                "Critical  ${countForStatus('critical')}",
                                draftStatus == 'critical',
                                () => updateDialog(
                                  () => draftStatus = 'critical',
                                ),
                              ),
                              _choicePill(
                                "Out of stock  ${countForStatus('out')}",
                                draftStatus == 'out',
                                () => updateDialog(() => draftStatus = 'out'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 32),
                          const Text(
                            'SORT BY',
                            style: TextStyle(
                              fontFamily: _font,
                              fontSize: 12,
                              color: _slate,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _choicePill(
                                'Default order',
                                draftSort == 'none',
                                () => updateDialog(() => draftSort = 'none'),
                              ),
                              _choicePill(
                                'Name: A to Z',
                                draftSort == 'nameAsc',
                                () => updateDialog(() => draftSort = 'nameAsc'),
                              ),
                              _choicePill(
                                'Name: Z to A',
                                draftSort == 'nameDesc',
                                () =>
                                    updateDialog(() => draftSort = 'nameDesc'),
                              ),
                              _choicePill(
                                'Price: low to high',
                                draftSort == 'priceAsc',
                                () =>
                                    updateDialog(() => draftSort = 'priceAsc'),
                              ),
                              _choicePill(
                                'Price: high to low',
                                draftSort == 'priceDesc',
                                () =>
                                    updateDialog(() => draftSort = 'priceDesc'),
                              ),
                              _choicePill(
                                'Stock: low to high',
                                draftSort == 'stockAsc',
                                () =>
                                    updateDialog(() => draftSort = 'stockAsc'),
                              ),
                              _choicePill(
                                'Stock: high to low',
                                draftSort == 'stockDesc',
                                () =>
                                    updateDialog(() => draftSort = 'stockDesc'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 30,
                      vertical: 19,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF8FAFC),
                      border: Border(top: BorderSide(color: _border)),
                    ),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () => updateDialog(() {
                            draftSort = 'none';
                            draftStatus = 'all';
                          }),
                          style: TextButton.styleFrom(foregroundColor: _ink),
                          child: const Text(
                            'Reset',
                            style: TextStyle(
                              fontFamily: _font,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _ink,
                            side: const BorderSide(color: _border),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 15,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              fontFamily: _font,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(dialogContext, {
                            'sort': draftSort,
                            'status': draftStatus,
                          }),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _blue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 23,
                              vertical: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Show $matchingCount ${matchingCount == 1 ? 'item' : 'items'}',
                            style: const TextStyle(
                              fontFamily: _font,
                              fontWeight: FontWeight.w700,
                            ),
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
    );

    if (!mounted || result == null) return;
    setState(() {
      _sortBy = result['sort'] ?? 'none';
      _stockFilter = result['status'] ?? 'all';
      _page = 0;
    });
  }

  Widget _choicePill(String label, bool selected, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEFF6FF) : Colors.white,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: selected ? _blue : const Color(0xFFCBD5E1),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: _font,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: selected ? _blue : const Color(0xFF334155),
            ),
          ),
        ),
      ),
    );
  }

  bool _matchesStatusFilter(InventoryItem item, String filter) {
    if (filter == 'all') return true;
    if (widget.controller.isDisabled(item.id)) return false;
    final status = widget.controller.stockStatusFor(item);
    switch (filter) {
      case 'ok':
        return status == StockStatus.ok;
      case 'low':
        return status == StockStatus.low;
      case 'critical':
        return status == StockStatus.critical;
      case 'out':
        return status == StockStatus.out;
      default:
        return true;
    }
  }

  bool _matchesStockFilter(InventoryItem item) =>
      _matchesStatusFilter(item, _stockFilter);

  int _compareItems(InventoryItem a, InventoryItem b) {
    int comparison;
    switch (_sortBy) {
      case 'nameDesc':
        comparison = b.name.toLowerCase().compareTo(a.name.toLowerCase());
        break;
      case 'priceAsc':
        comparison = a.price.compareTo(b.price);
        break;
      case 'priceDesc':
        comparison = b.price.compareTo(a.price);
        break;
      case 'stockAsc':
        comparison = a.quantity.compareTo(b.quantity);
        break;
      case 'stockDesc':
        comparison = b.quantity.compareTo(a.quantity);
        break;
      case 'skuAsc':
        comparison = a.sku.toLowerCase().compareTo(b.sku.toLowerCase());
        break;
      default:
        comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    if (comparison != 0) return comparison;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.controller.disabledItems;
    final disabledIds = disabled.map((item) => item.id).toSet();
    final active = widget.controller.currentInventory
        .where((item) => !disabledIds.contains(item.id))
        .toList();
    final categoryNames = <String>{
      ...active.map((item) => item.category),
      ...disabled.map((item) => item.category),
    }.where((c) => c.toLowerCase() != 'unassigned').toList()..sort();
    final categories = <String>['All', ...categoryNames];
    final selectedCategory = categories.contains(_category) ? _category : 'All';
    final source = <InventoryItem>[...active, if (_showDisabled) ...disabled];
    final query = _search.text.trim().toLowerCase();
    final filtered = source.where((item) {
      final matchesCategory =
          selectedCategory == 'All' || item.category == selectedCategory;
      final matchesSearch =
          query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.sku.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query);
      return matchesCategory && matchesSearch && _matchesStockFilter(item);
    }).toList();
    if (_sortBy != 'none') filtered.sort(_compareItems);

    final pages = filtered.isEmpty
        ? 1
        : (filtered.length + _perPage - 1) ~/ _perPage;
    final page = _page.clamp(0, pages - 1).toInt();
    final visible = filtered.skip(page * _perPage).take(_perPage).toList();

    final critical = active
        .where(
          (item) =>
              widget.controller.stockStatusFor(item) == StockStatus.critical,
        )
        .length;
    final out = active
        .where(
          (item) => widget.controller.stockStatusFor(item) == StockStatus.out,
        )
        .length;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 600) {
            return _buildMobileView(
              items: filtered,
              source: source,
              categories: categories,
              selectedCategory: selectedCategory,
            );
          }
          if (constraints.maxWidth >= 900) {
            return _buildReferenceDesktop(
              active: active,
              disabled: disabled,
              categories: categories,
              selectedCategory: selectedCategory,
              width: constraints.maxWidth,
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, c) {
                    const heading = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Inventory',
                          style: TextStyle(
                            fontFamily: _font,
                            color: _ink,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Track stock levels, prices and restock needs across your store.',
                          style: TextStyle(
                            fontFamily: _font,
                            color: _slate,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    );
                    if (!widget.controller.isAdmin) return heading;

                    final actions = Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          onPressed: widget.onExport,
                          icon: Icon(
                            LucideIcons.download,
                            size: 15,
                            color: widget.exportDue ? Colors.red : _ink,
                          ),
                          label: const Text('Export report'),
                          style: _outlineStyle,
                        ),
                        OutlinedButton.icon(
                          onPressed: () => widget.onQrLabels(null),
                          icon: const Icon(LucideIcons.qrCode, size: 15),
                          label: const Text('QR labels'),
                          style: _outlineStyle,
                        ),
                        ElevatedButton.icon(
                          onPressed: widget.onNewItem,
                          icon: const Icon(LucideIcons.plus, size: 16),
                          label: const Text('New item'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _blue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ],
                    );
                    if (c.maxWidth < 850) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          heading,
                          const SizedBox(height: 12),
                          actions,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: heading),
                        actions,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, c) {
                    final columns = c.maxWidth < 650 ? 2 : 4;
                    final cardWidth =
                        (c.maxWidth - 12 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: cardWidth,
                          child: _metric(
                            'Total items',
                            '${active.length}',
                            LucideIcons.package,
                            const Color(0xFF2563EB),
                            const Color(0xFFEFF6FF),
                          ),
                        ),
                        SizedBox(
                          width: cardWidth,
                          child: _metric(
                            'Critical stock',
                            '$critical',
                            LucideIcons.alertCircle,
                            const Color(0xFFDC2626),
                            const Color(0xFFFEF2F2),
                          ),
                        ),
                        SizedBox(
                          width: cardWidth,
                          child: _metric(
                            'Out of stock',
                            '$out',
                            LucideIcons.packageX,
                            const Color(0xFF64748B),
                            const Color(0xFFF1F5F9),
                          ),
                        ),
                        SizedBox(
                          width: cardWidth,
                          child: _metric(
                            'Categories',
                            '${categoryNames.length}',
                            LucideIcons.tag,
                            const Color(0xFF15803D),
                            const Color(0xFFECFDF5),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: _border),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final mobile = c.maxWidth < 520;
                            final fullWidth = c.maxWidth;
                            double controlWidth(double base) =>
                                mobile ? fullWidth : base;
                            final searchField = SizedBox(
                              height: 44,
                              child: TextField(
                                controller: _search,
                                onChanged: (_) => setState(() => _page = 0),
                                style: const TextStyle(
                                  fontFamily: _font,
                                  fontSize: 12,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Search name or SKU...',
                                  hintStyle: const TextStyle(
                                    fontFamily: _font,
                                    color: _slate,
                                    fontSize: 12,
                                  ),
                                  prefixIcon: const Icon(
                                    LucideIcons.search,
                                    size: 17,
                                    color: _slate,
                                  ),
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: EdgeInsets.zero,
                                  enabledBorder: OutlineInputBorder(
                                    borderSide: const BorderSide(
                                      color: _border,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: const BorderSide(color: _blue),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            );
                            return Wrap(
                              spacing: 9,
                              runSpacing: 9,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: controlWidth(300),
                                  child: searchField,
                                ),
                                _filterDropdown(
                                  width: controlWidth(240),
                                  icon: LucideIcons.tag,
                                  value: selectedCategory,
                                  items: categories.map((category) {
                                    final count = category == 'All'
                                        ? source.length
                                        : source
                                              .where(
                                                (i) => i.category == category,
                                              )
                                              .length;
                                    return DropdownMenuItem<String>(
                                      value: category,
                                      child: Text(
                                        category == 'All'
                                            ? 'All categories ($count)'
                                            : '$category ($count)',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (value) {
                                    if (value != null) _chooseCategory(value);
                                  },
                                ),
                                SizedBox(
                                  width: controlWidth(170),
                                  height: 44,
                                  child: OutlinedButton.icon(
                                    onPressed: _openSortFilterDialog,
                                    icon: const Icon(Icons.tune, size: 17),
                                    label: const Text('Filter & sort'),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: _ink,
                                      backgroundColor: const Color(0xFFF8FAFC),
                                      side: const BorderSide(color: _border),
                                      textStyle: const TextStyle(
                                        fontFamily: _font,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: controlWidth(190),
                                  height: 44,
                                  child: OutlinedButton.icon(
                                    onPressed: () => setState(() {
                                      _showDisabled = !_showDisabled;
                                      _page = 0;
                                    }),
                                    icon: Icon(
                                      _showDisabled
                                          ? LucideIcons.eye
                                          : LucideIcons.eyeOff,
                                      size: 16,
                                    ),
                                    label: Text(
                                      'Show disabled (${disabled.length})',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: _showDisabled
                                          ? _blue
                                          : _slate,
                                      backgroundColor: _showDisabled
                                          ? const Color(0xFFEFF6FF)
                                          : const Color(0xFFF8FAFC),
                                      side: BorderSide(
                                        color: _showDisabled ? _blue : _border,
                                      ),
                                      textStyle: const TextStyle(
                                        fontFamily: _font,
                                        fontSize: 11,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),

                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: constraints.maxWidth - 40 < 760
                              ? 760
                              : constraints.maxWidth - 40,
                          child: Column(
                            children: [
                              _tableHeader(),
                              if (visible.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(48),
                                  child: Center(
                                    child: Text(
                                      'No items match your filters.',
                                      style: TextStyle(
                                        fontFamily: _font,
                                        color: _slate,
                                      ),
                                    ),
                                  ),
                                ),
                              ...visible.map(_itemRow),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: SizedBox(
                          width: double.infinity,
                          height: 40,
                          child: Stack(
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  filtered.isEmpty
                                      ? 'Showing 0 items'
                                      : 'Showing ${page * _perPage + 1}–${page * _perPage + visible.length} of ${filtered.length} items',
                                  style: const TextStyle(
                                    fontFamily: _font,
                                    color: _slate,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Previous page',
                                      onPressed: page > 0
                                          ? () =>
                                                setState(() => _page = page - 1)
                                          : null,
                                      icon: const Icon(
                                        LucideIcons.chevronLeft,
                                        size: 17,
                                      ),
                                    ),
                                    Container(
                                      width: 38,
                                      height: 38,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEFF6FF),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        '${page + 1}',
                                        style: const TextStyle(
                                          fontFamily: _font,
                                          color: _blue,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Next page',
                                      onPressed: page + 1 < pages
                                          ? () =>
                                                setState(() => _page = page + 1)
                                          : null,
                                      icon: const Icon(
                                        LucideIcons.chevronRight,
                                        size: 17,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
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
        },
      ),
    );
  }

  Widget _buildReferenceDesktop({
    required List<InventoryItem> active,
    required List<InventoryItem> disabled,
    required List<String> categories,
    required String selectedCategory,
    required double width,
  }) {
    final disabledIds = disabled.map((item) => item.id).toSet();
    final allItems = <InventoryItem>[...active, ...disabled];
    final query = _search.text.trim().toLowerCase();
    final filtered = allItems.where((item) {
      final inactive = disabledIds.contains(item.id);
      final matchesStatus = switch (_stockFilter) {
        'inactive' => inactive,
        'all' || 'ok' => true,
        _ => !inactive && _matchesStatusFilter(item, _stockFilter),
      };
      return matchesStatus &&
          (selectedCategory == 'All' || item.category == selectedCategory) &&
          (query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              item.sku.toLowerCase().contains(query) ||
              (item.manufacturer ?? '').toLowerCase().contains(query) ||
              (item.model ?? '').toLowerCase().contains(query));
    }).toList();
    if (_sortBy != 'none') filtered.sort(_compareItems);
    final pageCount = math.max(1, (filtered.length + _perPage - 1) ~/ _perPage);
    final page = _page.clamp(0, pageCount - 1).toInt();
    final visible = filtered.skip(page * _perPage).take(_perPage).toList();
    final viewValue = filtered
        .where((item) => !disabledIds.contains(item.id))
        .fold<double>(0, (sum, item) => sum + item.quantity * item.price);
    final counts = <String, int>{
      'all': allItems.length,
      'ok': active
          .where((i) => widget.controller.stockStatusFor(i) == StockStatus.ok)
          .length,
      'low': active
          .where((i) => widget.controller.stockStatusFor(i) == StockStatus.low)
          .length,
      'critical': active
          .where(
            (i) => widget.controller.stockStatusFor(i) == StockStatus.critical,
          )
          .length,
      'out': active
          .where((i) => widget.controller.stockStatusFor(i) == StockStatus.out)
          .length,
      'inactive': disabled.length,
    };

    return ColoredBox(
      color: _warmBackground,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Inventory',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${filtered.length} products · ${_money(viewValue)} on hand at retail value',
                        style: const TextStyle(fontSize: 14, color: _warmMuted),
                      ),
                    ],
                  ),
                ),
                if (widget.controller.isAdmin) ...[
                  OutlinedButton.icon(
                    onPressed: widget.onExport,
                    icon: const Icon(LucideIcons.download, size: 17),
                    label: const Text('Export report'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: filtered.isEmpty
                        ? null
                        : () => widget.onQrLabels(filtered),
                    icon: const Icon(LucideIcons.qrCode, size: 17),
                    label: const Text('Print labels'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: widget.onNewItem,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1C1C1C),
                    ),
                    icon: const Icon(LucideIcons.plus, size: 17),
                    label: const Text('New product'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, limits) {
                final tabs = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _inventoryStatusTab('All', 'all', counts['all']!),
                    const SizedBox(width: 8),
                    _inventoryStatusTab('Low', 'low', counts['low']!),
                    const SizedBox(width: 8),
                    _inventoryStatusTab(
                      'Critical',
                      'critical',
                      counts['critical']!,
                    ),
                    const SizedBox(width: 8),
                    _inventoryStatusTab('Out of stock', 'out', counts['out']!),
                    const SizedBox(width: 8),
                    _inventoryStatusTab(
                      'Inactive',
                      'inactive',
                      counts['inactive']!,
                    ),
                  ],
                );
                final searchAndCategory = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 290,
                      height: 44,
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() => _page = 0),
                        decoration: InputDecoration(
                          hintText: 'Name, SKU, brand, model',
                          prefixIcon: const Icon(LucideIcons.search, size: 18),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(color: _warmBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(color: _warmBorder),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 170,
                      height: 44,
                      child: AppStyledDropdown<String>(
                        initialValue: selectedCategory,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(color: _warmBorder),
                          ),
                        ),
                        items: categories
                            .map(
                              (category) => DropdownMenuItem(
                                value: category,
                                child: Text(
                                  category == 'All'
                                      ? 'All categories'
                                      : category,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) _chooseCategory(value);
                        },
                      ),
                    ),
                  ],
                );
                return limits.maxWidth < 1000
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: tabs,
                          ),
                          const SizedBox(height: 12),
                          searchAndCategory,
                        ],
                      )
                    : Row(children: [tabs, const Spacer(), searchAndCategory]);
              },
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _warmBorder),
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(1180, width - 64),
                      child: Column(
                        children: [
                          Container(
                            height: 46,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: const BoxDecoration(
                              color: _warmBackground,
                              border: Border(
                                bottom: BorderSide(color: _warmBorder),
                              ),
                            ),
                            child: Row(
                              children: [
                                _inventoryHeading('Product', 5),
                                _inventoryHeading('Category', 2),
                                _inventoryHeading('Location', 3),
                                _inventoryHeading('Stock', 4),
                                _inventoryHeading('Price', 2, right: 16),
                                _inventoryHeading('Status', 2),
                              ],
                            ),
                          ),
                          if (visible.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(42),
                              child: Text('No products match your filters.'),
                            )
                          else
                            ...visible.map(
                              (item) => _inventoryReferenceRow(
                                item,
                                disabledIds.contains(item.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (pageCount > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Text(
                            'Showing ${page * _perPage + 1}–${page * _perPage + visible.length} of ${filtered.length}',
                            style: const TextStyle(
                              color: _warmMuted,
                              fontSize: 12,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Previous page',
                            onPressed: page == 0
                                ? null
                                : () => setState(() => _page = page - 1),
                            icon: const Icon(LucideIcons.chevronLeft, size: 18),
                          ),
                          Text(
                            '${page + 1} / $pageCount',
                            style: const TextStyle(fontSize: 12),
                          ),
                          IconButton(
                            tooltip: 'Next page',
                            onPressed: page + 1 == pageCount
                                ? null
                                : () => setState(() => _page = page + 1),
                            icon: const Icon(
                              LucideIcons.chevronRight,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inventoryStatusTab(String label, String value, int count) {
    final selected =
        _stockFilter == value || (value == 'all' && _stockFilter == 'ok');
    return InkWell(
      onTap: () => setState(() {
        _stockFilter = value;
        _page = 0;
      }),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1C1C1C) : Colors.white,
          border: Border.all(
            color: selected ? const Color(0xFF1C1C1C) : _warmBorder,
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          '$label  $count',
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : _ink,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _inventoryHeading(String label, int flex, {double right = 0}) =>
      Expanded(
        flex: flex,
        child: Padding(
          padding: EdgeInsets.only(right: right),
          child: Text(
            label,
            textAlign: right > 0 ? TextAlign.right : TextAlign.left,
            style: const TextStyle(fontSize: 11, color: _warmMuted),
          ),
        ),
      );

  String _inventoryLocation(InventoryItem item) {
    String? fixture;
    for (final element in widget.controller.storeLayout) {
      if (element.id == item.locationId) {
        fixture = element.label;
        break;
      }
    }
    final shelf = item.shelfLevel?.trim();
    final parts = [
      fixture,
      if (shelf != null && shelf.isNotEmpty)
        int.tryParse(shelf) != null ? 'Level $shelf' : shelf,
    ].where((part) => part != null && part.trim().isNotEmpty).toList();
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  Widget _inventoryThumbnail(InventoryItem item, {double size = 36}) =>
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFF2F0EC),
          border: Border.all(color: _warmBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: item.imageUrl.isEmpty
            ? const Icon(LucideIcons.package, size: 19, color: _warmMuted)
            : Image.network(
                item.imageUrl,
                 fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  LucideIcons.package,
                  size: 19,
                  color: _warmMuted,
                ),
              ),
      );

  Widget _inventoryReferenceRow(InventoryItem item, bool disabled) {
    final status = widget.controller.stockStatusFor(item);
    final color = disabled ? _warmMuted : _statusColor(status);
    final label = disabled
        ? 'Inactive'
        : status == StockStatus.ok
        ? 'In stock'
        : status == StockStatus.low
        ? 'Low'
        : _statusLabel(status);
    final fraction = item.maxQuantity <= 0
        ? 0.0
        : (item.quantity / item.maxQuantity).clamp(0.0, 1.0);
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _openDetails(item),
        child: Container(
          height: 66,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _warmBorder)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    _inventoryThumbnail(item),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _ink,
                            ),
                          ),
                          Text(
                            [item.sku, item.manufacturer, item.model]
                                .where(
                                  (part) => part != null && part.isNotEmpty,
                                )
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: _warmMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  item.category.isEmpty ? '—' : item.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _ink),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  _inventoryLocation(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _ink),
                ),
              ),
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.only(right: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 5,
                            backgroundColor: const Color(0xFFEEECE8),
                            valueColor: AlwaysStoppedAnimation<Color>(color),
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Text(
                        '${_qty(item.quantity)} / ${_qty(item.maxQuantity)}',
                        style: const TextStyle(fontSize: 11, color: _ink),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(
                    '${_money(item.price)} /${item.unit}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: _ink),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _inventoryTableBadge(label, color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inventoryTableBadge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.09),
      border: Border.all(color: color.withValues(alpha: 0.25)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      maxLines: 1,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );

  Widget _buildMobileView({
    required List<InventoryItem> items,
    required List<InventoryItem> source,
    required List<String> categories,
    required String selectedCategory,
  }) {
    const statusLabels = <String, String>{
      'ok': 'In stock',
      'low': 'Low stock',
      'critical': 'Critical',
      'out': 'Out of stock',
    };
    final hasActiveFilters = _stockFilter != 'all' || selectedCategory != 'All';
    final activeFilters = [
      if (_stockFilter != 'all') statusLabels[_stockFilter] ?? _stockFilter,
      if (selectedCategory != 'All') selectedCategory,
    ].join(' · ');

    return SafeArea(
      top: false,
      child: CustomScrollView(
        key: const PageStorageKey('mobile-inventory-list'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Inventory',
                          style: TextStyle(
                            fontFamily: _font,
                            color: _ink,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Inventory actions',
                        icon: const Icon(LucideIcons.ellipsis, color: _ink),
                        onPressed: _openMobileActionsSheet,
                      ),
                      if (widget.controller.isAdmin) ...[
                        const SizedBox(width: 4),
                        SizedBox(
                          height: 40,
                          child: FilledButton.icon(
                            onPressed: widget.onNewItem,
                            icon: const Icon(LucideIcons.plus, size: 16),
                            label: const Text('Add item'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _blue,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              textStyle: const TextStyle(
                                fontFamily: _font,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${source.length} items in this store',
                    style: const TextStyle(
                      fontFamily: _font,
                      color: _slate,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: TextField(
                            controller: _search,
                            onChanged: (_) => setState(() => _page = 0),
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: 'Search name or SKU',
                              prefixIcon: const Icon(
                                LucideIcons.search,
                                size: 19,
                              ),
                              filled: true,
                              fillColor: Colors.white,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: _border),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: _border),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 46,
                        child: OutlinedButton.icon(
                          onPressed: () => _openMobileFilterSheet(
                            source: source,
                            categories: categories,
                            selectedCategory: selectedCategory,
                          ),
                          icon: const Icon(Icons.tune, size: 17),
                          label: const Text('Filter'),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: hasActiveFilters
                                ? const Color(0xFFEFF6FF)
                                : Colors.white,
                            foregroundColor: hasActiveFilters ? _blue : _ink,
                            padding: const EdgeInsets.symmetric(horizontal: 9),
                            side: BorderSide(
                              color: hasActiveFilters ? _blue : _border,
                            ),
                            textStyle: const TextStyle(
                              fontFamily: _font,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 46,
                        height: 46,
                        child: OutlinedButton(
                          onPressed: _openMobileSortSheet,
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: _ink,
                            padding: EdgeInsets.zero,
                            side: const BorderSide(color: _border),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Icon(Icons.sort, size: 20),
                        ),
                      ),
                    ],
                  ),
                  if (hasActiveFilters) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            activeFilters,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: _font,
                              color: _blue,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _stockFilter = 'all';
                            _category = 'All';
                            _page = 0;
                          }),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: hasActiveFilters ? 4 : 14),
                  Text(
                    '${items.length} ${items.length == 1 ? 'item' : 'items'}',
                    style: const TextStyle(
                      fontFamily: _font,
                      color: _slate,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (items.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 44),
                child: Center(
                  child: Text(
                    'No items match your filters.',
                    style: TextStyle(fontFamily: _font, color: _slate),
                  ),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) => _mobileItemCard(items[index]),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _mobileItemCard(InventoryItem item) {
    final disabled = widget.controller.isDisabled(item.id);
    final status = widget.controller.stockStatusFor(item);
    final statusColor = disabled ? _slate : _statusColor(status);
    final statusText = disabled ? 'Disabled' : _statusLabel(status);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _openDetails(item),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: item.imageUrl.trim().isEmpty
                        ? const ColoredBox(
                            color: Color(0xFFEFF6FF),
                            child: Icon(LucideIcons.package, color: _blue),
                          )
                        : Image.network(
                            item.imageUrl,
                             fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const ColoredBox(
                                  color: Color(0xFFEFF6FF),
                                  child: Icon(
                                    LucideIcons.package,
                                    color: _blue,
                                  ),
                                ),
                          ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: _font,
                                fontSize: 13,
                                color: _ink,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          _badge(statusText, statusColor),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.sku,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: _font,
                          fontSize: 10,
                          color: _slate,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _money(item.price),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: _font,
                                fontSize: 12,
                                color: _ink,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '${_qty(item.quantity)} ${item.unit}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: _font,
                                fontSize: 11,
                                color: status == StockStatus.ok
                                    ? _slate
                                    : statusColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileSheetHeader({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onClose,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 16),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _blue, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 18,
                    color: _ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 12,
                    color: _slate,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, color: _slate),
          ),
        ],
      ),
    );
  }

  Widget _mobileSheetOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? count,
    Key? key,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        key: key,
        color: selected ? const Color(0xFFEFF6FF) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? const Color(0xFFBFDBFE) : _border),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: _font,
                      fontSize: 14,
                      color: selected ? _blue : _ink,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (count != null) ...[
                  Text(
                    count,
                    style: const TextStyle(
                      fontFamily: _font,
                      fontSize: 12,
                      color: _slate,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? _blue : const Color(0xFF94A3B8),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openMobileFilterSheet({
    required List<InventoryItem> source,
    required List<String> categories,
    required String selectedCategory,
  }) async {
    var draftStatus = _stockFilter;
    var draftCategory = selectedCategory;
    final query = _search.text.trim().toLowerCase();
    const statuses = <(String, String)>[
      ('all', 'All statuses'),
      ('ok', 'In stock'),
      ('low', 'Low stock'),
      ('critical', 'Critical'),
      ('out', 'Out of stock'),
    ];

    int matchingCount(String status, String category) => source.where((item) {
      final matchesCategory = category == 'All' || item.category == category;
      final matchesSearch =
          query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.sku.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query);
      return matchesCategory &&
          matchesSearch &&
          _matchesStatusFilter(item, status);
    }).length;

    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SizedBox(
          height: math.min(
            600.0,
            MediaQuery.sizeOf(sheetContext).height * 0.82,
          ),
          child: Column(
            children: [
              _mobileSheetHeader(
                title: 'Filter inventory',
                subtitle: 'Narrow down your inventory',
                icon: Icons.tune_rounded,
                onClose: () => Navigator.pop(sheetContext),
              ),
              const Divider(height: 1, color: _border),
              Expanded(
                child: ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
                      child: Text(
                        'STOCK STATUS',
                        style: TextStyle(
                          fontFamily: _font,
                          fontSize: 11,
                          color: _slate,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    for (final (value, label) in statuses)
                      _mobileSheetOption(
                        key: Key('mobile-filter-status-$value'),
                        label: label,
                        count: '${matchingCount(value, draftCategory)}',
                        selected: value == draftStatus,
                        onTap: () => updateSheet(() => draftStatus = value),
                      ),
                    const Divider(height: 18, color: _border),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
                      child: Text(
                        'CATEGORY',
                        style: TextStyle(
                          fontFamily: _font,
                          fontSize: 11,
                          color: _slate,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    for (final category in categories)
                      _mobileSheetOption(
                        key: Key('mobile-filter-category-$category'),
                        label: category == 'All' ? 'All categories' : category,
                        selected: category == draftCategory,
                        onTap: () =>
                            updateSheet(() => draftCategory = category),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => updateSheet(() {
                        draftStatus = 'all';
                        draftCategory = 'All';
                      }),
                      style: TextButton.styleFrom(foregroundColor: _blue),
                      child: const Text(
                        'Reset',
                        style: TextStyle(fontFamily: _font),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(sheetContext, (
                          draftStatus,
                          draftCategory,
                        )),
                        style: FilledButton.styleFrom(
                          backgroundColor: _blue,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Show ${matchingCount(draftStatus, draftCategory)} '
                          '${matchingCount(draftStatus, draftCategory) == 1 ? 'item' : 'items'}',
                          style: const TextStyle(
                            fontFamily: _font,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _stockFilter = result.$1;
      _category = result.$2;
      _page = 0;
    });
  }

  Future<void> _openMobileSortSheet() async {
    const options = <(String, String)>[
      ('nameAsc', 'Name: A to Z'),
      ('nameDesc', 'Name: Z to A'),
      ('priceAsc', 'Price: low to high'),
      ('priceDesc', 'Price: high to low'),
      ('stockAsc', 'Stock: low to high'),
      ('stockDesc', 'Stock: high to low'),
      ('none', 'Default order'),
    ];
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: math.min(440, MediaQuery.sizeOf(sheetContext).height * 0.7),
          child: Column(
            children: [
              _mobileSheetHeader(
                title: 'Sort inventory',
                subtitle: 'Choose the order of items',
                icon: Icons.sort_rounded,
                onClose: () => Navigator.pop(sheetContext),
              ),
              const Divider(height: 1, color: _border),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final (value, label) = options[index];
                    return _mobileSheetOption(
                      label: label,
                      selected: _sortBy == value,
                      onTap: () => Navigator.pop(sheetContext, value),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _sortBy = selected;
      _page = 0;
    });
  }

  void _openMobileActionsSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.controller.isAdmin) ...[
              ListTile(
                leading: const Icon(LucideIcons.download),
                title: const Text('Export report'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) widget.onExport();
                  });
                },
              ),
              ListTile(
                leading: const Icon(LucideIcons.qrCode),
                title: const Text('QR labels'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) widget.onQrLabels(null);
                  });
                },
              ),
            ],
            ListTile(
              leading: Icon(
                _showDisabled ? LucideIcons.eyeOff : LucideIcons.eye,
              ),
              title: Text(
                _showDisabled ? 'Hide disabled items' : 'Show disabled items',
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() {
                  _showDisabled = !_showDisabled;
                  _page = 0;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle get _outlineStyle => OutlinedButton.styleFrom(
    foregroundColor: _ink,
    backgroundColor: Colors.white,
    side: const BorderSide(color: _border),
    textStyle: const TextStyle(
      fontFamily: _font,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  Widget _filterDropdown({
    required double width,
    required IconData icon,
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return SizedBox(
      width: width,
      height: 44,
      child: AppStyledDropdown<String>(
        initialValue: value,
        items: items,
        menuMaxHeight: math.min(420, MediaQuery.sizeOf(context).height * 0.6),
        style: const TextStyle(
          fontFamily: _font,
          fontSize: 12,
          color: _ink,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 11,
          ),
          prefixIcon: Icon(icon, size: 16, color: _slate),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _border),
            borderRadius: BorderRadius.circular(8),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _blue),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _metric(
    String label,
    String value,
    IconData icon,
    Color iconColor,
    Color iconBackground,
  ) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconBackground,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 19, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 11,
                    color: _slate,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableHeader() {
    Widget heading(String label, int flex) => Expanded(
      flex: flex,
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: _font,
          color: _slate,
          fontSize: 10,
          letterSpacing: 0.7,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFFF8FAFC),
      child: Row(
        children: [
          heading('Item', 4),
          heading('SKU', 2),
          heading('Category', 2),
          heading('Price', 2),
          heading('Stock', 2),
          heading('Status', 2),
        ],
      ),
    );
  }

  Widget _itemRow(InventoryItem item) {
    final status = widget.controller.stockStatusFor(item);
    final isDisabled = widget.controller.isDisabled(item.id);
    final color = isDisabled ? _slate : _statusColor(status);
    final label = isDisabled ? 'Disabled' : _statusLabel(status);
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => _openDetails(item),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _border)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 12,
                    color: _ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  item.sku,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _font,
                    color: _slate,
                    fontSize: 11,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  item.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _font,
                    color: _slate,
                    fontSize: 11,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  _money(item.price),
                  style: const TextStyle(
                    fontFamily: _font,
                    color: _ink,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${_qty(item.quantity)} ${item.unit}',
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: status == StockStatus.ok ? _ink : color,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _badge(label, color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetails(InventoryItem item) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close item details',
      barrierColor: const Color(0x990F172A),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, _, __) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: MediaQuery.of(dialogContext).size.width < 500
              ? MediaQuery.of(dialogContext).size.width
              : MediaQuery.of(dialogContext).size.width >= 900
              ? math.min(820, MediaQuery.of(dialogContext).size.width * 0.52)
              : 440,
          height: double.infinity,
          child: Material(
            color: Colors.white,
            child: _ItemDetailsDrawer(
              item: item,
              controller: widget.controller,
              onClose: () => Navigator.of(dialogContext).pop(),
              onSave: widget.onUpdateItem,
              onQrLabel: () => widget.onQrLabels([item]),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    );
  }
}

Widget _badge(String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
  decoration: BoxDecoration(
    color: color.withOpacity(0.10),
    borderRadius: BorderRadius.circular(50),
  ),
  child: Text(
    '●  $label',
    maxLines: 1,
    style: TextStyle(
      fontFamily: _font,
      fontSize: 10,
      fontWeight: FontWeight.w700,
      color: color,
    ),
  ),
);

class _ItemDetailsDrawer extends StatefulWidget {
  final InventoryItem item;
  final InventoryController controller;
  final VoidCallback onClose;
  final Future<void> Function(InventoryItem) onSave;
  final VoidCallback onQrLabel;

  const _ItemDetailsDrawer({
    required this.item,
    required this.controller,
    required this.onClose,
    required this.onSave,
    required this.onQrLabel,
  });

  @override
  State<_ItemDetailsDrawer> createState() => _ItemDetailsDrawerState();
}

class _ItemDetailsDrawerState extends State<_ItemDetailsDrawer> {
  static const int _historyPageSize = 10;
  StreamSubscription<void>? _historySubscription;
  final ValueNotifier<List<Map<String, dynamic>>> _historyNotifier =
      ValueNotifier<List<Map<String, dynamic>>>(const []);
  List<Map<String, dynamic>> _history = const [];
  bool _historyLoading = true;
  bool _historyFailed = false;
  int _historyRequestVersion = 0;
  int _historyPage = 0;
  final _historyPageTopKey = GlobalKey();
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _maxStockController = TextEditingController();
  final _skuController = TextEditingController();
  final _stockDisplayController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _manufacturerController = TextEditingController();
  final _modelController = TextEditingController();
  final _sizeController = TextEditingController();
  final _imageUrlController = TextEditingController();
  final _shelfController = TextEditingController();
  final _binController = TextEditingController();
  String _categoryValue = '';
  String? _locationValue;
  int _referenceTab = 0;
  bool _isEditing = false;
  bool _isSaving = false;
  String? _editError;
  XFile? _chosenImage;
  Uint8List? _chosenImageBytes;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.item.name;
    _priceController.text = widget.item.price.toStringAsFixed(2);
    _maxStockController.text = _qty(widget.item.maxQuantity);
    _stockDisplayController.text =
        '${_qty(widget.item.quantity)} ${widget.item.unit}';
    _skuController.text = widget.item.sku;
    _descriptionController.text = widget.item.description;
    _manufacturerController.text = widget.item.manufacturer ?? '';
    _modelController.text = widget.item.model ?? '';
    _sizeController.text = widget.item.productSize ?? '';
    _imageUrlController.text = widget.item.imageUrl;
    _shelfController.text = widget.item.shelfLevel ?? '';
    _binController.text = widget.item.binNumber ?? '';
    _categoryValue = widget.item.category;
    _locationValue = widget.item.locationId;
    _subscribeToHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadHistory());
    });
  }

  void _subscribeToHistory() {
    unawaited(_historySubscription?.cancel());
    _historySubscription = widget.controller.transactionHistoryInvalidations
        .listen(
          (_) => unawaited(_loadHistory()),
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Item transaction history update failed: $error');
          },
        );
  }

  Future<void> _loadHistory({bool force = false}) async {
    if (!mounted) return;
    final requestVersion = ++_historyRequestVersion;
    final productId = widget.item.id;
    setState(() {
      _historyLoading = true;
      _historyFailed = false;
    });
    try {
      final transactions = await widget.controller
          .loadProductTransactionHistory(productId, force: force);
      if (!mounted ||
          requestVersion != _historyRequestVersion ||
          productId != widget.item.id)
        return;
      _historyNotifier.value = transactions;
      setState(() {
        _history = transactions;
        _historyLoading = false;
      });
    } catch (error) {
      if (!mounted || requestVersion != _historyRequestVersion) return;
      debugPrint('Could not load item transaction history: $error');
      setState(() {
        _historyLoading = false;
        _historyFailed = true;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _ItemDetailsDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _subscribeToHistory();
    }
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.controller != widget.controller) {
      _historyRequestVersion++;
      _history = const [];
      _historyPage = 0;
      _historyNotifier.value = const [];
      unawaited(_loadHistory());
    }
  }

  @override
  void dispose() {
    _historyRequestVersion++;
    unawaited(_historySubscription?.cancel());
    _historyNotifier.dispose();
    _nameController.dispose();
    _priceController.dispose();
    _maxStockController.dispose();
    _skuController.dispose();
    _stockDisplayController.dispose();
    _descriptionController.dispose();
    _manufacturerController.dispose();
    _modelController.dispose();
    _sizeController.dispose();
    _imageUrlController.dispose();
    _shelfController.dispose();
    _binController.dispose();
    super.dispose();
  }

  void _startEdit(InventoryItem item) {
    _nameController.text = item.name;
    _priceController.text = item.price.toStringAsFixed(2);
    _maxStockController.text = _qty(item.maxQuantity);
    _skuController.text = item.sku;
    _stockDisplayController.text = '${_qty(item.quantity)} ${item.unit}';
    _descriptionController.text = item.description;
    _manufacturerController.text = item.manufacturer ?? '';
    _modelController.text = item.model ?? '';
    _sizeController.text = item.productSize ?? '';
    _imageUrlController.text = item.imageUrl;
    _shelfController.text = item.shelfLevel ?? '';
    _binController.text = item.binNumber ?? '';
    _categoryValue = item.category;
    _locationValue = item.locationId;
    setState(() {
      _chosenImage = null;
      _chosenImageBytes = null;
      _editError = null;
      _isEditing = true;
    });
  }

  void _cancelEdit() {
    if (_isSaving) return;
    setState(() {
      _isEditing = false;
      _editError = null;
      _imageUrlController.text = widget.item.imageUrl;
      _chosenImage = null;
      _chosenImageBytes = null;
    });
  }

  Future<void> _pickEditImage() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _chosenImage = picked;
        _chosenImageBytes = bytes;
        _editError = null;
      });
    } catch (error) {
      if (mounted) AppToast.error(context, 'Could not choose an image.');
    }
  }

  Future<void> _replaceEditImage() async {
    if (_isSaving) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _warmOrange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        LucideIcons.imagePlus,
                        color: _warmOrange,
                        size: 21,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(dialogContext),
                      icon: const Icon(LucideIcons.x, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'Replace image',
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Choose where the new product image comes from.',
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: 13,
                    color: _warmMuted,
                  ),
                ),
                const SizedBox(height: 22),
                _replaceImageOption(
                  dialogContext,
                  choice: 'url',
                  icon: LucideIcons.link,
                  title: 'By URL',
                  subtitle: 'Paste a link to an image online',
                ),
                const SizedBox(height: 10),
                _replaceImageOption(
                  dialogContext,
                  choice: 'local',
                  icon: LucideIcons.imagePlus,
                  title: 'Local image',
                  subtitle: 'Choose a photo from this device',
                ),
                const SizedBox(height: 18),
                const Text(
                  'The new image is saved when you select Save changes.',
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: 12,
                    color: _warmMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'local') {
      await _pickEditImage();
    } else if (choice == 'url') {
      await _enterEditImageUrl();
    }
  }

  Widget _replaceImageOption(
    BuildContext dialogContext, {
    required String choice,
    required IconData icon,
    required String title,
    required String subtitle,
  }) => SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: () => Navigator.pop(dialogContext, choice),
      style: OutlinedButton.styleFrom(
        backgroundColor: _warmBackground,
        foregroundColor: _ink,
        padding: const EdgeInsets.all(14),
        side: const BorderSide(color: _warmBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _warmOrange, size: 20),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: _font,
                    fontSize: 12,
                    color: _warmMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(LucideIcons.chevronRight, size: 17, color: _warmMuted),
        ],
      ),
    ),
  );

  Future<void> _enterEditImageUrl() async {
    String enteredUrl = '';
    String? validationError;
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _warmOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      LucideIcons.link,
                      color: _warmOrange,
                      size: 21,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Use an image URL',
                    style: TextStyle(
                      fontFamily: _font,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Paste a direct link to a product image.',
                    style: TextStyle(
                      fontFamily: _font,
                      fontSize: 13,
                      color: _warmMuted,
                    ),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    onChanged: (value) => enteredUrl = value,
                    decoration: InputDecoration(
                      labelText: 'Image URL',
                      hintText: 'https://example.com/image.jpg',
                      errorText: validationError,
                      border: const OutlineInputBorder(),
                      enabledBorder: OutlineInputBorder(
                        borderSide: const BorderSide(color: _warmBorder),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: const BorderSide(color: _warmOrange),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: _warmBorder),
                          foregroundColor: _ink,
                        ),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: () {
                          final value = enteredUrl.trim();
                          final uri = Uri.tryParse(value);
                          if (uri == null ||
                              !uri.hasAuthority ||
                              (uri.scheme != 'https' &&
                                  uri.scheme != 'http')) {
                            setDialogState(
                              () => validationError =
                                  'Enter a valid http(s) image URL.',
                            );
                            return;
                          }
                          Navigator.pop(dialogContext, value);
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: _warmOrange,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Use URL'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted || url == null) return;
    setState(() {
      _imageUrlController.text = url;
      _chosenImage = null;
      _chosenImageBytes = null;
      _editError = null;
    });
  }

  void _removeEditImage() {
    if (_isSaving) return;
    setState(() {
      _imageUrlController.clear();
      _chosenImage = null;
      _chosenImageBytes = null;
      _editError = null;
    });
  }

  Future<void> _saveEdit(InventoryItem item) async {
    if (_isSaving) return;
    final name = _nameController.text.trim();
    final price = double.tryParse(_priceController.text.trim());
    final maxStock = double.tryParse(_maxStockController.text.trim());
    final imageUrl = _imageUrlController.text.trim();

    if (name.isEmpty || price == null || !price.isFinite || price < 0) {
      setState(() => _editError = 'Enter a product name and a valid price.');
      return;
    }
    if (maxStock == null || !maxStock.isFinite || maxStock < 0) {
      setState(() => _editError = 'Enter a valid max stock of 0 or more.');
      return;
    }
    setState(() {
      _isSaving = true;
      _editError = null;
    });
    try {
      var savedImageUrl = imageUrl;
      if (_chosenImageBytes != null) {
        final safeName = (_chosenImage?.name ?? '${item.id}.jpg').replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]'),
          '_',
        );
        final uploaded = await widget.controller.uploadImageBytes(
          _chosenImageBytes!,
          safeName,
          uploadKey: 'product:${item.id}:current',
        );
        savedImageUrl = uploaded;
      }

      // Retain quantity and SKU; stock changes must use the approval workflow.
      final updated = widget.controller.prepareUpdatedItem(
        originalItem: item,
        newName: name,
        newSku: item.sku,
        newPrice: price.toString(),
        newStock: item.quantity.toString(),
        newMaxStock: maxStock.toString(),
        newDesc: _descriptionController.text.trim(),
        manufacturer: _manufacturerController.text.trim(),
        model: _modelController.text.trim(),
        productSize: _sizeController.text.trim(),
        category: _categoryValue,
        shelfLevel: _shelfController.text.trim(),
        binNumber: _binController.text.trim(),
        imageUrl: savedImageUrl,
      );
      await widget.onSave(updated);
      if (_locationValue != item.locationId) {
        await widget.controller.assignItemToLocation(item.id, _locationValue);
      }
      if (!mounted) return;
      _imageUrlController.text = savedImageUrl;
      setState(() {
        _isEditing = false;
        _chosenImage = null;
        _chosenImageBytes = null;
      });
      AppToast.success(context, 'Item updated successfully');
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _editError = AppErrorMapper.message(
          error,
          fallback: AppErrorCategory.dataSave,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InventoryItem>>(
      stream: widget.controller.streamInventory(),
      initialData: widget.controller.currentInventory,
      builder: (context, _) {
        final item =
            widget.controller.findAnyItemById(widget.item.id) ?? widget.item;
        final status = widget.controller.stockStatusFor(item);
        final disabled = widget.controller.isDisabled(item.id);
        if (MediaQuery.of(context).size.width >= 900) {
          return _buildReferenceDrawer(item, status, disabled);
        }
        return SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                height: 56,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _border)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _isEditing ? _cancelEdit : widget.onClose,
                      icon: const Icon(
                        LucideIcons.chevronLeft,
                        size: 19,
                        color: _slate,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _isEditing ? 'EDIT ITEM' : 'ITEM DETAILS',
                        style: TextStyle(
                          fontFamily: _font,
                          color: _slate,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    if (!_isEditing && widget.controller.isAdmin && !disabled)
                      OutlinedButton.icon(
                        onPressed: () => _startEdit(item),
                        icon: const Icon(LucideIcons.pencil, size: 13),
                        label: const Text('Edit'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _slate,
                          side: const BorderSide(color: _border),
                          textStyle: const TextStyle(
                            fontFamily: _font,
                            fontSize: 11,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          height: 224,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            border: Border.all(color: _border),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(child: _photo(item)),
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: FilledButton.icon(
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (context) => Dialog(
                                      child: SizedBox(
                                        width: 640,
                                        height: 460,
                                        child: _photo(item),
                                      ),
                                    ),
                                  ),
                                  icon: const Icon(
                                    LucideIcons.maximize,
                                    size: 13,
                                  ),
                                  label: const Text('Enlarge'),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF475569),
                                    textStyle: const TextStyle(
                                      fontFamily: _font,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (_isEditing)
                        _buildEditForm()
                      else ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: [
                            _badge(item.category, _blue),
                            _badge(
                              disabled ? 'Disabled' : _statusLabel(status),
                              disabled ? _slate : _statusColor(status),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontFamily: _font,
                            color: _ink,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.sku,
                          style: const TextStyle(
                            fontFamily: _font,
                            color: _slate,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _valueCard('PRICE', _money(item.price)),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: _valueCard(
                                'IN STOCK',
                                '${_qty(item.quantity)} ${item.unit}',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _panel(
                          'Specifications',
                          Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _spec(
                                      'Manufacturer',
                                      item.manufacturer,
                                    ),
                                  ),
                                  Expanded(child: _spec('Model', item.model)),
                                  Expanded(
                                    child: _spec(
                                      'Product size',
                                      item.productSize,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _panel(
                          'Inventory info',
                          Column(
                            children: [
                              _infoRow('Name', item.name),
                              _infoRow('SKU', item.sku),
                              _infoRow('Category', item.category),
                              _infoRow('Unit', item.unit),
                              _infoRow(
                                'Status',
                                disabled ? 'Disabled' : 'Active',
                                last: item.description.isEmpty,
                              ),
                              if (item.description.isNotEmpty)
                                _infoRow(
                                  'Description',
                                  item.description,
                                  last: true,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildLocationSection(item),
                        const SizedBox(height: 12),
                        _buildHistorySection(item),
                      ],
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: _border)),
                ),
                child: _isEditing
                    ? Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _isSaving ? null : _cancelEdit,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _ink,
                                side: const BorderSide(color: _border),
                              ),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isSaving
                                  ? null
                                  : () => _saveEdit(item),
                              icon: _isSaving
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(LucideIcons.check, size: 15),
                              label: Text(
                                _isSaving ? 'Saving...' : 'Save changes',
                              ),
                              style: ElevatedButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: _blue,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          if (!disabled) ...[
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => unawaited(
                                  showRestockRequestDialog(
                                    context: context,
                                    controller: widget.controller,
                                    item: item,
                                  ),
                                ),
                                icon: const Icon(LucideIcons.plus, size: 14),
                                label: const Text('Restock'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _blue,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  textStyle: const TextStyle(
                                    fontFamily: _font,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            if (widget
                                .controller
                                .canRequestInventoryApproval) ...[
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: item.quantity > 0
                                      ? () => unawaited(
                                          showWriteOffRequestDialog(
                                            context: context,
                                            controller: widget.controller,
                                            item: item,
                                          ),
                                        )
                                      : null,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFDC2626),
                                    side: const BorderSide(
                                      color: Color(0xFFFECACA),
                                    ),
                                    textStyle: const TextStyle(
                                      fontFamily: _font,
                                      fontSize: 11,
                                    ),
                                  ),
                                  child: const Text('Write off'),
                                ),
                              ),
                              const SizedBox(width: 7),
                            ],
                          ],
                          Expanded(
                            child: OutlinedButton(
                              onPressed: widget.onClose,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _ink,
                                side: const BorderSide(color: _border),
                                textStyle: const TextStyle(
                                  fontFamily: _font,
                                  fontSize: 11,
                                ),
                              ),
                              child: const Text('Close'),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReferenceDrawer(
    InventoryItem item,
    StockStatus status,
    bool disabled,
  ) {
    final statusLabel = disabled
        ? 'Inactive'
        : status == StockStatus.ok
        ? 'Available'
        : status == StockStatus.low
        ? 'Low'
        : _statusLabel(status);
    final statusColor = disabled ? _warmMuted : _statusColor(status);
    final fraction = item.maxQuantity <= 0
        ? 0.0
        : (item.quantity / item.maxQuantity).clamp(0.0, 1.0);
    final canEdit = widget.controller.isAdmin;
    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 92,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _warmBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.sku,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          color: _warmMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close details',
                  onPressed: widget.onClose,
                  icon: const Icon(LucideIcons.x, size: 19, color: _warmMuted),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _referencePhoto(item),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _badge(statusLabel, statusColor),
                                Text(
                                  [
                                        item.manufacturer,
                                        item.model,
                                        item.productSize,
                                      ]
                                      .where(
                                        (part) =>
                                            part != null &&
                                            part.trim().isNotEmpty,
                                      )
                                      .join(' · '),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: _warmMuted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: _money(item.price),
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                      color: _ink,
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' / ${item.unit}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: _warmMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: fraction,
                                      minHeight: 7,
                                      backgroundColor: const Color(0xFFEEECE8),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        statusColor,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Text(
                                  '${_qty(item.quantity)} / ${_qty(item.maxQuantity)}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: _warmMuted,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEECE8),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _referenceTabButton('Details', 0),
                        _referenceTabButton('Location', 1),
                        _referenceTabButton(
                          'Stock history ${_history.length}',
                          2,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  if (_referenceTab == 0) _referenceDetails(item, canEdit),
                  if (_referenceTab == 1) _referenceLocation(item, canEdit),
                  if (_referenceTab == 2) _referenceHistory(),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
            decoration: const BoxDecoration(
              color: _warmBackground,
              border: Border(top: BorderSide(color: _warmBorder)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_editError != null) ...[
                  Text(
                    _editError!,
                    style: const TextStyle(color: _warmRed, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    if (canEdit)
                      OutlinedButton(
                        onPressed: _isSaving
                            ? null
                            : () => _toggleReferenceStatus(item, disabled),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _warmRed,
                        ),
                        child: Text(
                          disabled ? 'Restore product' : 'Disable product',
                        ),
                      ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: widget.onQrLabel,
                      icon: const Icon(LucideIcons.qrCode, size: 16),
                      label: const Text('QR label'),
                    ),
                    if (canEdit) ...[
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _isSaving ? null : () => _saveEdit(item),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1C1C1C),
                        ),
                        child: Text(_isSaving ? 'Saving…' : 'Save changes'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _referencePhoto(InventoryItem item) {
    final imageUrl = _imageUrlController.text.trim();
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFFF2F0EC),
        border: Border.all(color: _warmBorder),
        borderRadius: BorderRadius.circular(9),
      ),
      clipBehavior: Clip.antiAlias,
      child: _chosenImageBytes != null
           ? Image.memory(_chosenImageBytes!, fit: BoxFit.contain)
          : imageUrl.isEmpty
          ? const Icon(LucideIcons.package, color: _warmMuted, size: 32)
          : Image.network(
              imageUrl,
               fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const Icon(LucideIcons.package, color: _warmMuted, size: 32),
            ),
    );
  }

  Widget _referenceTabButton(String label, int index) => InkWell(
    onTap: () => setState(() => _referenceTab = index),
    borderRadius: BorderRadius.circular(7),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: _referenceTab == index ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: _referenceTab == index ? _ink : _warmMuted,
          fontWeight: _referenceTab == index
              ? FontWeight.w600
              : FontWeight.normal,
        ),
      ),
    ),
  );

  Widget _referenceDetails(InventoryItem item, bool canEdit) {
    final categories = <String>{
      item.category,
      ...widget.controller.allItems.map((product) => product.category),
    }.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Identity',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        _referenceField('Product name', _nameController, readOnly: !canEdit),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _referenceField('SKU', _skuController, readOnly: true),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Category',
                    style: TextStyle(fontSize: 12, color: _ink),
                  ),
                  const SizedBox(height: 7),
                  AppStyledDropdown<String>(
                    initialValue: categories.contains(_categoryValue)
                        ? _categoryValue
                        : item.category,
                    decoration: _referenceInputDecoration(),
                    items: categories
                        .map(
                          (category) => DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          ),
                        )
                        .toList(),
                    onChanged: canEdit
                        ? (value) => setState(
                            () => _categoryValue = value ?? item.category,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _referenceField(
                'Manufacturer',
                _manufacturerController,
                readOnly: !canEdit,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _referenceField(
                'Model',
                _modelController,
                readOnly: !canEdit,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _referenceField(
                'Size',
                _sizeController,
                readOnly: !canEdit,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _referenceField(
                'Price (₱)',
                _priceController,
                readOnly: !canEdit,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _referenceField(
                'On hand',
                _stockDisplayController,
                readOnly: true,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _referenceField(
                'Max stock',
                _maxStockController,
                readOnly: !canEdit,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
          ],
        ),
        if (item.quantity > item.maxQuantity) ...[
          const SizedBox(height: 6),
          Text(
            'On hand is above the current max stock. Set a higher max if this is expected.',
            style: const TextStyle(fontSize: 12, color: _warmMuted),
          ),
        ],
        const SizedBox(height: 16),
        if (canEdit) ...[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: _isSaving ? null : _replaceEditImage,
                icon: const Icon(LucideIcons.imagePlus, size: 16),
                label: const Text('Replace image'),
              ),
              if (_chosenImageBytes != null ||
                  _imageUrlController.text.trim().isNotEmpty)
                TextButton.icon(
                  onPressed: _isSaving ? null : _removeEditImage,
                  icon: const Icon(LucideIcons.trash2, size: 16),
                  label: const Text('Remove image'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _referenceField(
          'Description',
          _descriptionController,
          readOnly: !canEdit,
          maxLines: 4,
        ),
      ],
    );
  }

  InputDecoration _referenceInputDecoration() => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _warmBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _warmOrange),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _warmBorder),
    ),
  );

  Widget _referenceField(
    String label,
    TextEditingController controller, {
    bool readOnly = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12, color: _ink)),
      const SizedBox(height: 7),
      TextField(
        controller: controller,
        readOnly: readOnly,
        maxLines: maxLines,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13, color: _ink),
        decoration: _referenceInputDecoration(),
      ),
    ],
  );

  Widget _referenceLocation(InventoryItem item, bool canEdit) {
    final fixtures = widget.controller.storeLayout
        .where(
          (element) =>
              element.type == ElementType.rack ||
              element.type == ElementType.shelf,
        )
        .toList();
    final currentFixture = fixtures
        .where((element) => element.id == _locationValue)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Aisle',
                    style: TextStyle(fontSize: 12, color: _ink),
                  ),
                  const SizedBox(height: 7),
                  InputDecorator(
                    decoration: _referenceInputDecoration(),
                    child: Text(
                      currentFixture?.label ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: _ink),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _referenceField(
                'Shelf',
                _shelfController,
                readOnly: !canEdit,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _referenceField('Bin', _binController, readOnly: !canEdit),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Map fixture',
                    style: TextStyle(fontSize: 12, color: _ink),
                  ),
                  const SizedBox(height: 7),
                  AppStyledDropdown<String?>(
                    initialValue:
                        fixtures.any((element) => element.id == _locationValue)
                        ? _locationValue
                        : null,
                    decoration: _referenceInputDecoration(),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      ...fixtures.map(
                        (fixture) => DropdownMenuItem<String?>(
                          value: fixture.id,
                          child: Text(
                            fixture.label.isEmpty
                                ? fixture.type.name
                                : fixture.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    onChanged: canEdit
                        ? (value) => setState(() => _locationValue = value)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          height: 380,
          decoration: BoxDecoration(
            border: Border.all(color: _warmBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: StoreMap(
            controller: widget.controller,
            mode: MapMode.view,
            viewStyle: MapViewStyle.twoD,
            highlightId: _locationValue,
            showItemPopup: false,
            fitEntireMap: true,
            compactZoomControls: true,
            showMobileToolbar: false,
          ),
        ),
      ],
    );
  }

  void _changeHistoryPage(int page) {
    setState(() => _historyPage = page);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _historyPageTopKey.currentContext;
      if (mounted && anchor != null) {
        Scrollable.ensureVisible(
          anchor,
          alignment: 0.05,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _referenceHistory() {
    if (_historyLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: CircularProgressIndicator(),
      );
    }
    if (_historyFailed) {
      return TextButton(
        onPressed: () => unawaited(_loadHistory(force: true)),
        child: const Text('Could not load stock history. Retry'),
      );
    }
    if (_history.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No stock history yet.'),
      );
    }

    final pageCount =
        (_history.length + _historyPageSize - 1) ~/ _historyPageSize;
    final page = _historyPage.clamp(0, pageCount - 1);
    final start = page * _historyPageSize;
    final entries = _history.skip(start).take(_historyPageSize);
    return Column(
      key: _historyPageTopKey,
      children: [
        ...entries.map(_referenceHistoryTile),
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing ${start + 1}–${start + entries.length} of ${_history.length}',
                    style: const TextStyle(fontSize: 11, color: _warmMuted),
                  ),
                ),
                IconButton(
                  tooltip: 'First page',
                  onPressed: page == 0 ? null : () => _changeHistoryPage(0),
                  icon: const Icon(LucideIcons.chevronsLeft, size: 17),
                ),
                IconButton(
                  tooltip: 'Previous page',
                  onPressed: page == 0
                      ? null
                      : () => _changeHistoryPage(page - 1),
                  icon: const Icon(LucideIcons.chevronLeft, size: 17),
                ),
                Text(
                  '${page + 1} / $pageCount',
                  style: const TextStyle(fontSize: 12, color: _ink),
                ),
                IconButton(
                  tooltip: 'Next page',
                  onPressed: page + 1 == pageCount
                      ? null
                      : () => _changeHistoryPage(page + 1),
                  icon: const Icon(LucideIcons.chevronRight, size: 17),
                ),
                IconButton(
                  tooltip: 'Last page',
                  onPressed: page + 1 == pageCount
                      ? null
                      : () => _changeHistoryPage(pageCount - 1),
                  icon: const Icon(LucideIcons.chevronsRight, size: 17),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _referenceHistoryTile(Map<String, dynamic> transaction) {
    final change = _transactionNumber(transaction['quantity_change']);
    final type = transaction['transaction_type']?.toString() ?? 'adjustment';
    final label = type == 'checkout' || type == 'sale'
        ? 'Sale'
        : type == 'stock_in'
        ? 'Restock'
        : type.replaceAll('_', ' ');
    final profile = transaction['profiles'];
    final by =
        (profile is Map ? profile['name'] : null) ??
        transaction['user_name'] ??
        'Unknown';
    final balance = _transactionNumber(transaction['new_quantity']);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _warmBorder)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F0EC),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              change < 0
                  ? LucideIcons.arrowDownRight
                  : LucideIcons.arrowUpRight,
              size: 16,
              color: _warmMuted,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_transactionDate(transaction['created_at'])} · $by',
                  style: const TextStyle(fontSize: 11, color: _warmMuted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${change > 0 ? '+' : ''}${_qty(change)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'bal. ${_qty(balance)}',
                style: const TextStyle(fontSize: 11, color: _warmMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleReferenceStatus(InventoryItem item, bool disabled) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(disabled ? 'Restore product?' : 'Disable product?'),
        content: Text(
          disabled
              ? 'This product will return to the active inventory.'
              : 'This product will be hidden from active inventory.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(disabled ? 'Restore' : 'Disable'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isSaving = true);
    try {
      if (disabled) {
        await widget.controller.restoreItem(item.id);
      } else {
        await widget.controller.disableItem(item.id);
      }
      if (!mounted) return;
      AppToast.success(
        context,
        disabled ? 'Product restored' : 'Product disabled',
      );
      widget.onClose();
    } catch (error) {
      if (mounted)
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildEditForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Edit product information',
          style: TextStyle(
            fontFamily: _font,
            color: _ink,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Update the details below, then save your changes.',
          style: TextStyle(fontFamily: _font, fontSize: 11, color: _slate),
        ),
        const SizedBox(height: 18),
        _editField('Product name', _nameController, isRequired: true),
        const SizedBox(height: 13),
        Row(
          children: [
            Expanded(child: _editField('SKU', _skuController, readOnly: true)),
            const SizedBox(width: 10),
            Expanded(
              child: _editField(
                'Price (₱)',
                _priceController,
                isRequired: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 13),
        _editField(
          'Stock (managed through restock / write-off)',
          _stockDisplayController,
          readOnly: true,
        ),
        const SizedBox(height: 18),
        const Text(
          'Specifications',
          style: TextStyle(
            fontFamily: _font,
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _editField('Manufacturer', _manufacturerController),
            ),
            const SizedBox(width: 10),
            Expanded(child: _editField('Model', _modelController)),
          ],
        ),
        const SizedBox(height: 13),
        _editField('Product size', _sizeController),
        const SizedBox(height: 13),
        _editField('Description', _descriptionController, maxLines: 3),
        const SizedBox(height: 18),
        const Text(
          'Product image',
          style: TextStyle(
            fontFamily: _font,
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _isSaving ? null : _replaceEditImage,
          icon: const Icon(LucideIcons.imagePlus, size: 16),
          label: const Text('Replace image'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _blue,
            side: const BorderSide(color: _border),
          ),
        ),
        if (_chosenImageBytes != null ||
            _imageUrlController.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _isSaving ? null : _removeEditImage,
            icon: const Icon(LucideIcons.trash2, size: 16),
            label: const Text('Remove image'),
          ),
        ],
        if (_editError != null) ...[
          const SizedBox(height: 12),
          Text(
            _editError!,
            style: const TextStyle(
              fontFamily: _font,
              color: Color(0xFFDC2626),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _editField(
    String label,
    TextEditingController controller, {
    bool readOnly = false,
    bool isRequired = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isRequired ? '$label *' : label,
          style: const TextStyle(
            fontFamily: _font,
            color: _slate,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          readOnly: readOnly,
          maxLines: maxLines,
          keyboardType: keyboardType,
          onChanged: onChanged,
          style: const TextStyle(fontFamily: _font, fontSize: 13, color: _ink),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: readOnly ? const Color(0xFFF8FAFC) : Colors.white,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 13,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _blue, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _photo(InventoryItem item) {
    if (_isEditing && _chosenImageBytes != null) {
      return Image.memory(_chosenImageBytes!, fit: BoxFit.contain);
    }
    final url = _isEditing ? _imageUrlController.text.trim() : item.imageUrl;
    if (url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _photoPlaceholder(),
      );
    }
    return _photoPlaceholder();
  }

  Widget _photoPlaceholder() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(LucideIcons.package, size: 55, color: Color(0xFF94A3B8)),
        const SizedBox(height: 9),
        const Text(
          'No image uploaded',
          style: TextStyle(fontFamily: _font, fontSize: 11, color: _slate),
        ),
      ],
    ),
  );

  Widget _valueCard(String label, String value) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: _font,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: _slate,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: const TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
      ],
    ),
  );

  Widget _panel(String title, Widget body) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xFFF8FAFC),
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: _font,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: body,
        ),
      ],
    ),
  );

  Widget _buildLocationSection(InventoryItem item) {
    final hasLocation = item.locationId?.isNotEmpty == true;
    return _panel(
      'Store location',
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: hasLocation
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(LucideIcons.mapPin, color: _blue, size: 15),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Item location on store map',
                          style: TextStyle(
                            fontFamily: _font,
                            fontSize: 11,
                            color: _slate,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showFullscreenMap(item),
                        icon: const Icon(LucideIcons.maximize, size: 13),
                        label: const Text('Expand'),
                        style: TextButton.styleFrom(
                          foregroundColor: _blue,
                          textStyle: const TextStyle(
                            fontFamily: _font,
                            fontSize: 11,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: SizedBox(
                      width: double.infinity,
                      height: 220,
                      child: StoreMap(
                        controller: widget.controller,
                        mode: MapMode.view,
                         highlightId: _locationValue,
                         showItemPopup: false,
                        fitEntireMap: true,
                        compactZoomControls: true,
                        showMobileToolbar: false,
                      ),
                    ),
                  ),
                ],
              )
            : const Text(
                'This item is not assigned to a store map location.',
                style: TextStyle(
                  fontFamily: _font,
                  color: _slate,
                  fontSize: 12,
                ),
              ),
      ),
    );
  }

  void _showFullscreenMap(InventoryItem item) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: size.width < 900 ? size.width * 0.94 : 850,
            height: size.height * 0.82,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  height: 54,
                  color: const Color(0xFFF8FAFC),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.mapPin, size: 17, color: _blue),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'Location: ${item.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: _font,
                            color: _ink,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close map',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(LucideIcons.x, size: 19),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: StoreMap(
                    controller: widget.controller,
                    mode: MapMode.view,
                     highlightId: _locationValue,
                     showItemPopup: false,
                    fitEntireMap: true,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistorySection(InventoryItem item) {
    return _panel(
      'Transaction history',
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_historyLoading)
              const Padding(
                padding: EdgeInsets.all(22),
                child: Center(
                  child: SizedBox(
                    width: 23,
                    height: 23,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_historyFailed)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Could not load transactions.',
                      style: TextStyle(
                        fontFamily: _font,
                        fontSize: 11,
                        color: _slate,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_loadHistory(force: true)),
                    child: const Text('Retry'),
                  ),
                ],
              )
            else if (_history.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    'No transaction history found.',
                    style: TextStyle(
                      fontFamily: _font,
                      fontSize: 12,
                      color: _slate,
                    ),
                  ),
                ),
              )
            else ...[
              ..._history.take(5).map(_transactionTile),
              if (_history.length > 5)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _showAllTransactions(item),
                    icon: const Icon(LucideIcons.chevronRight, size: 14),
                    label: Text('View all ${_history.length} transactions'),
                    style: TextButton.styleFrom(
                      foregroundColor: _blue,
                      textStyle: const TextStyle(
                        fontFamily: _font,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  double _transactionNumber(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _transactionDate(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return 'Date unknown';
    return '${date.month}/${date.day}/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _transactionTile(
    Map<String, dynamic> transaction, {
    bool expanded = false,
  }) {
    final quantity = _transactionNumber(transaction['quantity_change']);
    final isAdded = quantity >= 0;
    final color = isAdded ? const Color(0xFF168046) : const Color(0xFFDC2626);
    final type = transaction['transaction_type']?.toString() ?? 'Update';
    final typeLabel = type
        .split('_')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
    final profile = transaction['profiles'];
    final performedBy =
        (profile is Map ? profile['name'] : null) ??
        transaction['user_name'] ??
        'Unknown';
    final remaining = transaction['new_quantity'];

    return Container(
      padding: EdgeInsets.symmetric(vertical: expanded ? 14 : 11),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: expanded ? 40 : 32,
            height: expanded ? 40 : 32,
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isAdded ? LucideIcons.plus : LucideIcons.minus,
              color: color,
              size: expanded ? 17 : 15,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${isAdded ? '+' : ''}${_qty(quantity)}  ·  $typeLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: expanded ? 13 : 12,
                    color: _ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'By $performedBy  ·  '
                  '${_transactionDate(transaction['created_at'])}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: _font,
                    fontSize: expanded ? 11 : 10,
                    color: _slate,
                  ),
                ),
              ],
            ),
          ),
          if (remaining != null) ...[
            const SizedBox(width: 5),
            Text(
              'Qty: ${_qty(_transactionNumber(remaining))}',
              style: TextStyle(
                fontFamily: _font,
                fontSize: expanded ? 11 : 10,
                color: _slate,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showAllTransactions(InventoryItem item) {
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x990F172A),
      builder: (modalContext) {
        final screen = MediaQuery.of(modalContext).size;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: screen.width < 840 ? screen.width - 40 : 800,
            height: screen.height < 780 ? screen.height - 48 : 700,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'All transactions',
                              style: TextStyle(
                                fontFamily: _font,
                                color: _ink,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: _font,
                                color: _slate,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close transaction history',
                        onPressed: () => Navigator.pop(modalContext),
                        icon: const Icon(LucideIcons.x, size: 21, color: _ink),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _border),
                Expanded(
                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: _historyNotifier,
                    builder: (context, transactions, _) => transactions.isEmpty
                        ? const Center(
                            child: Text(
                              'No transaction history found.',
                              style: TextStyle(
                                fontFamily: _font,
                                color: _slate,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(22, 10, 22, 18),
                            itemCount: transactions.length,
                            itemBuilder: (context, index) => _transactionTile(
                              transactions[index],
                              expanded: true,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _spec(String label, String? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: _font,
            color: _slate,
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value == null || value.trim().isEmpty ? 'Not set' : value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: _font,
            color: _ink,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _infoRow(String label, String value, {bool last = false}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 11),
    decoration: BoxDecoration(
      border: last ? null : const Border(bottom: BorderSide(color: _border)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: _font,
              fontSize: 11,
              color: _slate,
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontFamily: _font,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
        ),
      ],
    ),
  );
}
