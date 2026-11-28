import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import '../logic/product_level.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_styled_dropdown.dart';
import '../services/app_error_mapper.dart';
import 'store_map.dart';

const _accent = Color(0xFFC83D08);
const _ink = Color(0xFF211F1D);
const _slate = Color(0xFF756D67);
const _border = Color(0xFFE3DED7);
const _font = 'Hellix';
const _warmBackground = Color(0xFFF7F6F4);
const _warmBorder = Color(0xFFE6E1DC);
const _warmMuted = Color(0xFF817A75);
const _warmOrange = _accent;
const _warmRed = Color(0xFFDC2626);

String _qty(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

double _stockCoverageFraction(double onHand, double sevenDaySales) =>
    sevenDaySales <= 0 ? 0.0 : (onHand / sevenDaySales).clamp(0.0, 1.0);

String _stockCoverageLabel(double onHand, double sevenDaySales) {
  if (sevenDaySales <= 0) return 'No recent sales';
  final weeks = onHand <= 0 ? 0.0 : onHand / sevenDaySales;
  return '${weeks.toStringAsFixed(1)} wk cover';
}

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
  final Future<void> Function(InventoryItem) onUpdateItem;
  final void Function(List<InventoryItem>?) onQrLabels;
  final VoidCallback onNewItem;

  const InventoryRedesign({
    super.key,
    required this.controller,
    required this.onUpdateItem,
    required this.onQrLabels,
    required this.onNewItem,
  });

  @override
  State<InventoryRedesign> createState() => _InventoryRedesignState();
}

class _InventoryRedesignState extends State<InventoryRedesign> {
  final _search = TextEditingController();
  String _category = 'All';
  String _stockFilter = 'all';
  String _sortBy = 'nameAsc';
  int _page = 0;
  static const _perPage = 8;

  Widget _qrLabelsAction({List<InventoryItem>? items, bool enabled = true}) =>
      Tooltip(
        message: 'Download QR labels',
        child: SizedBox(
          width: 40,
          height: 40,
          child: OutlinedButton(
            onPressed: enabled
                ? () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    widget.onQrLabels(items);
                  }
                : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              backgroundColor: Colors.white,
              padding: EdgeInsets.zero,
              side: const BorderSide(color: _border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Icon(LucideIcons.qrCode, size: 18),
          ),
        ),
      );

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

    // Counts reflect the search and category outside this modal.
    final disabledItems = widget.controller.disabledItems;
    final disabledIds = disabledItems.map((item) => item.id).toSet();
    final matchingItems =
        <InventoryItem>[
          ...widget.controller.currentInventory.where(
            (item) => !disabledIds.contains(item.id),
          ),
          ...disabledItems,
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
                                "Dead stock  ${countForStatus('out')}",
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
                      color: Color(0xFFF8F7F5),
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
                            backgroundColor: _accent,
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
            color: selected ? const Color(0xFFFFF1E9) : Colors.white,
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: selected ? _accent : const Color(0xFFE3DED7),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: _font,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: selected ? _accent : const Color(0xFF211F1D),
            ),
          ),
        ),
      ),
    );
  }

  bool _matchesStatusFilter(InventoryItem item, String filter) {
    if (filter == 'all') return true;
    final disabled = widget.controller.isDisabled(item.id);
    if (disabled) return false;
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
    final source = <InventoryItem>[...active, ...disabled];
    final query = _search.text.trim().toLowerCase();
    List<InventoryItem> filterItems(List<InventoryItem> candidates) {
      final matches = candidates.where((item) {
        final matchesCategory =
            selectedCategory == 'All' || item.category == selectedCategory;
        final matchesSearch =
            query.isEmpty ||
            item.name.toLowerCase().contains(query) ||
            item.sku.toLowerCase().contains(query) ||
            item.category.toLowerCase().contains(query);
        return matchesCategory && matchesSearch && _matchesStockFilter(item);
      }).toList();
      if (_sortBy != 'none') matches.sort(_compareItems);
      return matches;
    }

    final filtered = filterItems(source);

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
      backgroundColor: _warmBackground,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            final mobileSource = <InventoryItem>[...active, ...disabled];
            return _buildMobileView(
              items: filterItems(mobileSource),
              source: mobileSource,
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
                        _qrLabelsAction(),
                        ElevatedButton.icon(
                          onPressed: widget.onNewItem,
                          icon: const Icon(LucideIcons.plus, size: 16),
                          label: const Text('New item'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
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
                            const Color(0xFFC83D08),
                            const Color(0xFFFFF1E9),
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
                            const Color(0xFF756D67),
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
                                  fillColor: const Color(0xFFF8F7F5),
                                  contentPadding: EdgeInsets.zero,
                                  enabledBorder: OutlineInputBorder(
                                    borderSide: const BorderSide(
                                      color: _border,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: const BorderSide(
                                      color: _accent,
                                    ),
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
                                      backgroundColor: const Color(0xFFF8F7F5),
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
                                        color: const Color(0xFFFFF1E9),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        '${page + 1}',
                                        style: const TextStyle(
                                          fontFamily: _font,
                                          color: _accent,
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
      final matchesStatus =
          _stockFilter == 'all' ||
          (!inactive && _matchesStatusFilter(item, _stockFilter));
      return matchesStatus &&
          (selectedCategory == 'All' || item.category == selectedCategory) &&
          (query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              item.sku.toLowerCase().contains(query) ||
              (item.manufacturer ?? '').toLowerCase().contains(query) ||
              (item.model ?? '').toLowerCase().contains(query) ||
              (item.color ?? '').toLowerCase().contains(query));
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
                  _qrLabelsAction(
                    items: filtered,
                    enabled: filtered.isNotEmpty,
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
                    _inventoryStatusTab('Dead stock', 'out', counts['out']!),
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
                          hintText: 'Name, SKU, brand, model, color',
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
                return limits.maxWidth < 1200
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
                                _inventoryHeading('Stock coverage (7d)', 4),
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
      if (shelf != null && shelf.isNotEmpty) 'Level $shelf',
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
    final sevenDaySales = widget.controller.baselineFor(item);
    final color = disabled ? _warmMuted : _statusColor(status);
    final label = disabled
        ? 'Inactive'
        : status == StockStatus.ok
        ? 'In stock'
        : status == StockStatus.low
        ? 'Low'
        : _statusLabel(status);
    final fraction = _stockCoverageFraction(item.quantity, sevenDaySales);
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
                            item.displayName,
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
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (sevenDaySales > 0)
                        Tooltip(
                          message: 'Full bar means at least 1 week of stock at the recent sales rate',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: fraction,
                              minHeight: 5,
                              backgroundColor: const Color(0xFFEEECE8),
                              valueColor: AlwaysStoppedAnimation<Color>(color),
                            ),
                          ),
                        )
                      else
                        const Text(
                          'Coverage unavailable',
                          style: TextStyle(fontSize: 10, color: _warmMuted),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        sevenDaySales <= 0
                            ? 'No sales in last 7 days'
                            : _stockCoverageLabel(item.quantity, sevenDaySales),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: _warmMuted),
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
      'out': 'Dead stock',
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
                      if (widget.controller.isAdmin) ...[
                        _qrLabelsAction(),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 40,
                          child: FilledButton.icon(
                            onPressed: widget.onNewItem,
                            icon: const Icon(LucideIcons.plus, size: 16),
                            label: const Text('Add item'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
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
                      Tooltip(
                        message: 'Filter inventory',
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: OutlinedButton(
                            onPressed: () => _openMobileFilterSheet(
                              source: source,
                              categories: categories,
                              selectedCategory: selectedCategory,
                            ),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: hasActiveFilters
                                  ? const Color(0xFFFFF1E9)
                                  : Colors.white,
                              foregroundColor: hasActiveFilters
                                  ? _accent
                                  : _ink,
                              padding: EdgeInsets.zero,
                              side: BorderSide(
                                color: hasActiveFilters ? _accent : _border,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Icon(Icons.tune, size: 18),
                          ),
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
                              color: _accent,
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
    final statusText = disabled ? 'Inactive' : _statusLabel(status);

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: item.imageUrl.trim().isEmpty
                            ? const ColoredBox(
                                color: Color(0xFFFFF1E9),
                                child: Icon(
                                  LucideIcons.package,
                                  color: _accent,
                                ),
                              )
                            : Image.network(
                                item.imageUrl,
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) =>
                                    const ColoredBox(
                                      color: Color(0xFFFFF1E9),
                                      child: Icon(
                                        LucideIcons.package,
                                        color: _accent,
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
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1, color: _border),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _mobileItemDetail(
                        'Category',
                        item.category.isEmpty ? '—' : item.category,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _mobileItemDetail(
                        'Location',
                        _inventoryLocation(item),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileItemDetail(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontFamily: _font, fontSize: 10, color: _slate),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: _font, fontSize: 11, color: _ink),
      ),
    ],
  );

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
              color: const Color(0xFFFFF1E9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _accent, size: 20),
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
        color: selected ? const Color(0xFFFFF1E9) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? const Color(0xFFF6C5AE) : _border),
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
                      color: selected ? _accent : _ink,
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
                  color: selected ? _accent : const Color(0xFF8D827C),
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
      ('out', 'Dead stock'),
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
                      style: TextButton.styleFrom(foregroundColor: _accent),
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
                          backgroundColor: _accent,
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
          fillColor: const Color(0xFFF8F7F5),
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
            borderSide: const BorderSide(color: _accent),
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
      color: const Color(0xFFF8F7F5),
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
    unawaited(
      showInventoryItemDetails(
        context: context,
        item: item,
        controller: widget.controller,
        onSave: widget.onUpdateItem,
        onQrLabel: () => widget.onQrLabels([item]),
      ),
    );
  }
}

Future<void> showInventoryItemDetails({
  required BuildContext context,
  required InventoryItem item,
  required InventoryController controller,
  required Future<void> Function(InventoryItem) onSave,
  required VoidCallback onQrLabel,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close item details',
  barrierColor: const Color(0x990F172A),
  transitionDuration: const Duration(milliseconds: 240),
  pageBuilder: (dialogContext, _, __) => Align(
    alignment: Alignment.centerRight,
    child: SizedBox(
      width: MediaQuery.sizeOf(dialogContext).width < 500
          ? MediaQuery.sizeOf(dialogContext).width
          : MediaQuery.sizeOf(dialogContext).width >= 900
          ? math.min(820, MediaQuery.sizeOf(dialogContext).width * 0.52)
          : 440,
      height: double.infinity,
      child: Material(
        color: Colors.white,
        child: _ItemDetailsDrawer(
          item: item,
          controller: controller,
          onClose: () => Navigator.of(dialogContext).pop(),
          onSave: onSave,
          onQrLabel: onQrLabel,
        ),
      ),
    ),
  ),
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  ),
);

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
  List<Map<String, dynamic>> _history = const [];
  bool _historyLoading = true;
  bool _historyFailed = false;
  int _historyRequestVersion = 0;
  int _historyPage = 0;
  final _historyPageTopKey = GlobalKey();
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _skuController = TextEditingController();
  final _stockDisplayController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _manufacturerController = TextEditingController();
  final _modelController = TextEditingController();
  final _sizeController = TextEditingController();
  final _colorController = TextEditingController();
  final _imageUrlController = TextEditingController();
  final _shelfController = TextEditingController();
  final ValueNotifier<int> _formRevision = ValueNotifier<int>(0);
  String _categoryValue = '';
  bool _requiresLoading = false;
  String? _locationValue;
  int _referenceTab = 0;
  bool _isSaving = false;
  String? _editError;
  XFile? _chosenImage;
  Uint8List? _chosenImageBytes;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.item.name;
    _priceController.text = widget.item.price.toStringAsFixed(2);
    _stockDisplayController.text =
        '${_qty(widget.item.quantity)} ${widget.item.unit}';
    _skuController.text = widget.item.sku;
    _descriptionController.text = widget.item.description;
    _manufacturerController.text = widget.item.manufacturer ?? '';
    _modelController.text = widget.item.model ?? '';
    _sizeController.text = widget.item.productSize ?? '';
    _colorController.text = widget.item.color ?? '';
    _imageUrlController.text = widget.item.imageUrl;
    _shelfController.text = widget.item.shelfLevel ?? '';
    _categoryValue = widget.item.category;
    _requiresLoading = widget.item.requiresLoading;
    _locationValue = widget.item.locationId;
    for (final controller in [
      _nameController,
      _priceController,
      _descriptionController,
      _manufacturerController,
      _modelController,
      _sizeController,
      _colorController,
      _imageUrlController,
      _shelfController,
    ]) {
      controller.addListener(_onFormTextChanged);
    }
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
      unawaited(_loadHistory());
    }
  }

  @override
  void dispose() {
    _historyRequestVersion++;
    unawaited(_historySubscription?.cancel());
    _formRevision.dispose();
    _nameController.dispose();
    _priceController.dispose();
    _skuController.dispose();
    _stockDisplayController.dispose();
    _descriptionController.dispose();
    _manufacturerController.dispose();
    _modelController.dispose();
    _sizeController.dispose();
    _colorController.dispose();
    _imageUrlController.dispose();
    _shelfController.dispose();
    super.dispose();
  }

  void _onFormTextChanged() => _formRevision.value++;

  bool _hasChanges(InventoryItem item) {
    String clean(String? value) => (value ?? '').trim();
    final price = double.tryParse(_priceController.text.trim());
    return clean(_nameController.text) != clean(item.name) ||
        price == null ||
        price != item.price ||
        clean(_descriptionController.text) != clean(item.description) ||
        clean(_manufacturerController.text) != clean(item.manufacturer) ||
        clean(_modelController.text) != clean(item.model) ||
        clean(_sizeController.text) != clean(item.productSize) ||
        clean(_colorController.text) != clean(item.color) ||
        _categoryValue != item.category ||
        clean(_shelfController.text) != clean(item.shelfLevel) ||
        _requiresLoading != item.requiresLoading ||
        _locationValue != item.locationId ||
        _chosenImageBytes != null ||
        clean(_imageUrlController.text) != clean(item.imageUrl);
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
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
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
                              (uri.scheme != 'https' && uri.scheme != 'http')) {
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
    if (_isSaving || !_hasChanges(item)) return;
    final name = _nameController.text.trim();
    final price = double.tryParse(_priceController.text.trim());
    final imageUrl = _imageUrlController.text.trim();

    if (!isValidProductLevel(_shelfController.text)) {
      setState(() => _editError = 'Choose a level from 1 to 10 or No level.');
      return;
    }

    if (name.isEmpty || price == null || !price.isFinite || price < 0) {
      setState(() => _editError = 'Enter a product name and a valid price.');
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
        newMaxStock: item.maxQuantity.toString(),
        newDesc: _descriptionController.text.trim(),
        manufacturer: _manufacturerController.text.trim(),
        model: _modelController.text.trim(),
        productSize: _sizeController.text.trim(),
        color: _colorController.text.trim(),
        category: _categoryValue,
        shelfLevel: _shelfController.text.trim(),
        binNumber: item.binNumber,
        imageUrl: savedImageUrl,
        requiresLoading: _requiresLoading,
      ).copyWith(
        locationId: _locationValue,
        clearLocation: _locationValue == null,
      );
      await widget.onSave(updated);
      if (!mounted) return;
      _imageUrlController.text = savedImageUrl;
      setState(() {
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
        if (MediaQuery.sizeOf(context).width < 600) {
          return _buildMobileReferenceDrawer(item, status, disabled);
        }
        return _buildReferenceDrawer(item, status, disabled);
      },
    );
  }

  Widget _buildMobileReferenceDrawer(
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
    final sevenDaySales = widget.controller.baselineFor(item);
    final statusColor = disabled ? _warmMuted : _statusColor(status);
    final canEdit = widget.controller.isAdmin;

    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: _warmBorder)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to inventory',
                  onPressed: widget.onClose,
                  icon: const Icon(LucideIcons.chevronLeft, size: 18),
                ),
                const SizedBox(width: 4),
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
                          color: _ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        item.sku,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _warmMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Material(
              color: _warmBackground,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_referenceTab != 2) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: _warmBorder),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _referencePhoto(item, size: 52),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          _badge(statusLabel, statusColor),
                                          const SizedBox(width: 5),
                                          Expanded(
                                            child: Text(
                                              [item.manufacturer, item.model]
                                                  .where(
                                                    (part) =>
                                                        part
                                                            ?.trim()
                                                            .isNotEmpty ==
                                                        true,
                                                  )
                                                  .join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: _warmMuted,
                                                fontSize: 10,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 5),
                                      Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: _money(item.price),
                                              style: const TextStyle(
                                                color: _ink,
                                                fontSize: 19,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            TextSpan(
                                              text: ' / ${item.unit}',
                                              style: const TextStyle(
                                                color: _warmMuted,
                                                fontSize: 10,
                                              ),
                                            ),
                                          ],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (sevenDaySales > 0)
                              Row(
                                children: [
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: _stockCoverageFraction(
                                        item.quantity,
                                        sevenDaySales,
                                      ),
                                      minHeight: 5,
                                      backgroundColor: const Color(0xFFEEECE8),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        statusColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _stockCoverageLabel(
                                      item.quantity,
                                      sevenDaySales,
                                    ),
                                    style: const TextStyle(
                                      color: _warmMuted,
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              )
                            else
                              const Text(
                                'Coverage unavailable · no sales in 7 days',
                                style: TextStyle(color: _warmMuted, fontSize: 9),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              '${_qty(item.quantity)} ${item.unit} on hand · '
                              '${_qty(sevenDaySales)} sold in 7 days',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _warmMuted,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEECE8),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: _referenceTabButton('Details', 0)),
                          Expanded(child: _referenceTabButton('Location', 1)),
                          Expanded(
                            child: _referenceTabButton(
                              'History ${_history.length}',
                              2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_referenceTab == 0) _referenceDetails(item, canEdit),
                    if (_referenceTab == 1) _referenceLocation(item, canEdit),
                    if (_referenceTab == 2) _referenceHistory(),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
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
                    OutlinedButton.icon(
                      onPressed: widget.onQrLabel,
                      icon: const Icon(LucideIcons.qrCode, size: 15),
                      label: const Text('QR label'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _warmOrange,
                        side: const BorderSide(color: _warmOrange),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    if (canEdit) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: ValueListenableBuilder<int>(
                          valueListenable: _formRevision,
                          builder: (context, _, _) => FilledButton(
                            onPressed: _isSaving || !_hasChanges(item)
                                ? null
                                : () => _saveEdit(item),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF1C1C1C),
                            ),
                            child: Text(_isSaving ? 'Saving…' : 'Save changes'),
                          ),
                        ),
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
    final sevenDaySales = widget.controller.baselineFor(item);
    final statusColor = disabled ? _warmMuted : _statusColor(status);
    final fraction = _stockCoverageFraction(item.quantity, sevenDaySales);
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
                                        item.color,
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
                            if (sevenDaySales > 0)
                              Row(
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: 'Full bar means at least 1 week of stock at the recent sales rate',
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: LinearProgressIndicator(
                                          value: fraction,
                                          minHeight: 7,
                                          backgroundColor: const Color(
                                            0xFFEEECE8,
                                          ),
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                statusColor,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  Text(
                                    _stockCoverageLabel(
                                      item.quantity,
                                      sevenDaySales,
                                    ),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: _warmMuted,
                                    ),
                                  ),
                                ],
                              )
                            else
                              const Text(
                                'Coverage unavailable · no sales in 7 days',
                                style: TextStyle(fontSize: 13, color: _warmMuted),
                              ),
                            const SizedBox(height: 5),
                            Text(
                              '${_qty(item.quantity)} ${item.unit} on hand · '
                              '${_qty(sevenDaySales)} sold in 7 days',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: _warmMuted,
                              ),
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
                    if (canEdit && disabled)
                      OutlinedButton(
                        onPressed: _isSaving
                            ? null
                            : () => _restoreReferenceProduct(item),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _warmOrange,
                        ),
                        child: const Text('Restore product'),
                      ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: widget.onQrLabel,
                      icon: const Icon(LucideIcons.qrCode, size: 16),
                      label: const Text('QR label'),
                    ),
                    if (canEdit) ...[
                      const SizedBox(width: 10),
                      ValueListenableBuilder<int>(
                        valueListenable: _formRevision,
                        builder: (context, _, _) => FilledButton(
                          onPressed: _isSaving || !_hasChanges(item)
                              ? null
                              : () => _saveEdit(item),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1C1C1C),
                          ),
                          child: Text(_isSaving ? 'Saving…' : 'Save changes'),
                        ),
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

  Widget _referencePhoto(InventoryItem item, {double size = 80}) {
    final imageUrl = _imageUrlController.text.trim();
    return Container(
      width: size,
      height: size,
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

  Widget _productImageEditor(InventoryItem item, {required bool canEdit}) {
    final hasImage =
        _chosenImageBytes != null || _imageUrlController.text.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _warmBackground,
        border: Border.all(color: _warmBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _referencePhoto(item),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Product image',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hasImage ? 'Image preview' : 'No image added',
                      style: const TextStyle(color: _warmMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (canEdit) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isSaving ? null : _replaceEditImage,
                  icon: const Icon(LucideIcons.imagePlus, size: 16),
                  label: const Text('Replace image'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _warmOrange,
                    side: const BorderSide(color: _warmOrange),
                  ),
                ),
                if (hasImage)
                  OutlinedButton.icon(
                    onPressed: _isSaving ? null : _removeEditImage,
                    icon: const Icon(LucideIcons.trash2, size: 16),
                    label: const Text('Remove image'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _warmRed,
                      side: const BorderSide(color: Color(0xFFFECACA)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            const Text(
              'Select Save changes to apply the image change.',
              style: TextStyle(color: _warmMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _referenceTabButton(String label, int index) {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return InkWell(
      onTap: () => setState(() => _referenceTab = index),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 5 : 13,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: _referenceTab == index ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: mobile ? 10 : 12,
            color: _referenceTab == index ? _ink : _warmMuted,
            fontWeight: _referenceTab == index
                ? FontWeight.w600
                : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _referenceDetails(InventoryItem item, bool canEdit) {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    final categories = <String>{
      item.category,
      ...widget.controller.allItems.map((product) => product.category),
    }.toList()..sort();
    final categoryField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Category', style: TextStyle(fontSize: 12, color: _ink)),
        const SizedBox(height: 7),
        AppStyledDropdown<String>(
          initialValue: categories.contains(_categoryValue)
              ? _categoryValue
              : item.category,
          decoration: _referenceInputDecoration(),
          items: categories
              .map(
                (category) =>
                    DropdownMenuItem(value: category, child: Text(category)),
              )
              .toList(),
          onChanged: canEdit
              ? (value) =>
                    setState(() => _categoryValue = value ?? item.category)
              : null,
        ),
      ],
    );
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
        if (mobile) ...[
          _referenceField('SKU', _skuController, readOnly: true),
          const SizedBox(height: 16),
          categoryField,
        ] else
          Row(
            children: [
              Expanded(
                child: _referenceField('SKU', _skuController, readOnly: true),
              ),
              const SizedBox(width: 18),
              Expanded(child: categoryField),
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
                'Color (optional)',
                _colorController,
                readOnly: !canEdit,
              ),
            ),
          ],
        ),
        SwitchListTile(
          title: const Text('Heavy / truck loading required'),
          subtitle: const Text('Bodegero verifies and loads this product.'),
          value: _requiresLoading,
          onChanged: canEdit
              ? (value) => setState(() => _requiresLoading = value)
              : null,
        ),
        const SizedBox(height: 16),
        _productImageEditor(item, canEdit: canEdit),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _referenceLevelField(canEdit)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Move to',
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
          height: MediaQuery.sizeOf(context).width < 600 ? 250 : 380,
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
            onElementSelected: canEdit
                ? (element) {
                    if (element.type == ElementType.rack ||
                        element.type == ElementType.shelf) {
                      setState(() => _locationValue = element.id);
                    }
                  }
                : null,
            fitEntireMap: true,
            compactZoomControls: true,
            showMobileToolbar: false,
          ),
        ),
        if (canEdit && MediaQuery.sizeOf(context).width < 600) ...[
          const SizedBox(height: 8),
          const Text(
            'Tap a shelf to move this item',
            style: TextStyle(color: _warmMuted, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _referenceLevelField(bool canEdit) {
    final level = _shelfController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Level', style: TextStyle(fontSize: 12, color: _ink)),
        const SizedBox(height: 7),
        if (!canEdit)
          InputDecorator(
            decoration: _referenceInputDecoration(),
            child: Text(
              level.isEmpty ? 'No level' : 'Level $level',
              style: const TextStyle(fontSize: 13, color: _ink),
            ),
          )
        else
          AppStyledDropdown<String>(
            value: level,
            decoration: _referenceInputDecoration(),
            items: [
              if (level.isNotEmpty && !isValidProductLevel(level))
                DropdownMenuItem<String>(
                  value: level,
                  enabled: false,
                  child: Text('Invalid level: $level'),
                ),
              const DropdownMenuItem<String>(
                value: '',
                child: Text('No level'),
              ),
              for (var number = 1; number <= maxProductLevel; number++)
                DropdownMenuItem<String>(
                  value: '$number',
                  child: Text('Level $number'),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _shelfController.text = value);
              }
            },
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
    final mobile = MediaQuery.sizeOf(context).width < 600;
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
                if (!mobile)
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
                if (!mobile)
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

  Future<void> _restoreReferenceProduct(InventoryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.rotateCcw,
        color: _accent,
        title: 'Restore product?',
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              side: const BorderSide(color: _border),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Restore'),
          ),
        ],
        child: const Text(
          'This product will return to the active inventory.',
          style: TextStyle(color: _slate, fontSize: 14, height: 1.5),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isSaving = true);
    try {
      await widget.controller.restoreItem(item.id);
      if (!mounted) return;
      AppToast.success(context, 'Product restored');
      widget.onClose();
    } catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(error, fallback: AppErrorCategory.dataSave),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
}
