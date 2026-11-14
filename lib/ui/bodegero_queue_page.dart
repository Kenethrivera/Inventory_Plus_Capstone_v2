import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import '../logic/order_work_progress.dart';
import 'scanner_search_page.dart';
import 'store_map.dart';

const _ink = Color(0xFF171717);
const _orange = Color(0xFFC83D08);
const _muted = Color(0xFF756D67);
const _line = Color(0xFFE1DCD5);
const _background = Color(0xFFF6F5F2);
const _font = 'Hellix';

class BodegeroQueuePage extends StatefulWidget {
  const BodegeroQueuePage({
    super.key,
    required this.controller,
    required this.onLogout,
  });

  final InventoryController controller;
  final VoidCallback onLogout;

  @override
  State<BodegeroQueuePage> createState() => _BodegeroQueuePageState();
}

class _BodegeroQueuePageState extends State<BodegeroQueuePage> {
  final _truckController = TextEditingController();
  final _searchController = TextEditingController();
  final _quantityControllers = <String, TextEditingController>{};
  late Stream<List<CustomerOrder>> _ordersStream;
  String? _selectedOrderId;
  String _search = '';
  Uint8List? _photoJpeg;
  CustomerOrder? _completedOrder;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ordersStream = widget.controller.streamOrders();
    unawaited(_loadMap());
  }

  Future<void> _loadMap() async {
    try {
      await widget.controller.fetchMapLayout();
      if (mounted) setState(() {});
    } catch (_) {
      // The loading checklist remains usable when no store map is configured.
    }
  }

  @override
  void didUpdateWidget(covariant BodegeroQueuePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _ordersStream = widget.controller.streamOrders();
      unawaited(_loadMap());
    }
  }

  @override
  void dispose() {
    _truckController.dispose();
    _searchController.dispose();
    for (final controller in _quantityControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  void _open(CustomerOrder order) {
    for (final controller in _quantityControllers.values) {
      controller.dispose();
    }
    _quantityControllers.clear();
    for (final item in order.items.where((item) => item.requiresLoading)) {
      _quantityControllers[item.productId] = TextEditingController();
    }
    _truckController.clear();
    setState(() {
      _selectedOrderId = order.id;
      _completedOrder = null;
      _photoJpeg = null;
    });
  }

  Future<void> _scan(CustomerOrder order, CustomerOrderItem expected) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (scannerContext) => ScannerSearchPage(
          controller: widget.controller,
          onSelectItem: (scanned) async {
            Navigator.pop(scannerContext);
            if (scanned.id != expected.productId) {
              _message('Wrong product. Scan ${expected.productName}.');
              return;
            }
            setState(() => _busy = true);
            try {
              await widget.controller.verifyHeavyOrderItem(
                order.id,
                expected.productId,
              );
              _message('${expected.productName} verified. Count the quantity.');
            } catch (error) {
              _message('Could not verify this item: $error');
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
        ),
      ),
    );
  }

  Future<void> _claim(CustomerOrder order) async {
    setState(() => _busy = true);
    try {
      final claimed = await widget.controller.claimOrderLoading(order.id);
      if (!mounted) return;
      _open(claimed);
      _message('Heavy order assigned to you. Scan each shelf QR.');
    } catch (error) {
      _message('Could not claim this order: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _capturePhoto() async {
    try {
      final image = await ImagePicker().pickImage(source: ImageSource.camera);
      if (image == null) return;
      final decoded = img.decodeImage(await image.readAsBytes());
      if (decoded == null) throw StateError('The photo could not be opened.');
      final resized = decoded.width > 1280 || decoded.height > 1280
          ? img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? 1280 : null,
              height: decoded.height > decoded.width ? 1280 : null,
            )
          : decoded;
      var quality = 72;
      var bytes = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      while (bytes.length > 1048576 && quality > 40) {
        quality -= 8;
        bytes = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
      }
      if (bytes.length > 1048576) {
        final smaller = img.copyResize(
          resized,
          width: resized.width >= resized.height ? 960 : null,
          height: resized.height > resized.width ? 960 : null,
        );
        bytes = Uint8List.fromList(img.encodeJpg(smaller, quality: 48));
      }
      if (bytes.length > 1048576) {
        throw StateError('Photo is too large. Retake it at lower resolution.');
      }
      if (mounted) setState(() => _photoJpeg = bytes);
    } catch (error) {
      _message('Photo capture failed: $error');
    }
  }

  Future<void> _finish(CustomerOrder order) async {
    final heavyItems = order.items
        .where((item) => item.requiresLoading)
        .toList();
    if (heavyItems.any((item) => !item.heavyVerified)) {
      _message('Scan every heavy product first.');
      return;
    }
    final plate = _truckController.text.trim();
    if (plate.isEmpty || _photoJpeg == null) {
      _message('Enter the truck plate and capture a loading photo.');
      return;
    }
    final quantities = <String, double>{};
    for (final item in heavyItems) {
      final count = double.tryParse(
        _quantityControllers[item.productId]?.text.trim() ?? '',
      );
      if (count == null || !count.isFinite || count != item.quantity) {
        _message(
          'Confirm exactly ${item.quantity} ${item.unit ?? ''} of ${item.productName}.',
        );
        return;
      }
      quantities[item.productId] = count;
    }
    setState(() => _busy = true);
    try {
      final updated = await widget.controller.finishOrderLoading(
        orderId: order.id,
        truckPlate: plate,
        loadedQuantities: quantities,
        photoJpeg: _photoJpeg!,
      );
      if (!mounted) return;
      setState(() {
        _selectedOrderId = null;
        _completedOrder = updated;
        _photoJpeg = null;
      });
      _message(
        updated.status == 'prepared'
            ? 'Loading verified. Order is ready for payment.'
            : 'Loading verified. Waiting for light items.',
      );
    } catch (error) {
      _message('Could not save loading proof: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shortId(CustomerOrder order) {
    final id = order.id.trim();
    return '#${(id.length <= 8 ? id : id.substring(0, 8)).toUpperCase()}';
  }

  List<CustomerOrderItem> _heavyItems(CustomerOrder order) =>
      order.items.where((item) => item.requiresLoading).toList(growable: false);

  String _location(CustomerOrderItem orderItem) {
    final product = widget.controller.findAnyItemById(orderItem.productId);
    if (product == null) return 'Find item in store';
    final matching = widget.controller.storeLayout.where(
      (element) => element.id == product.locationId,
    );
    final fixture = matching.isEmpty || matching.first.label.trim().isEmpty
        ? 'Store shelf'
        : matching.first.label.trim();
    final level = product.shelfLevel?.trim();
    return level == null || level.isEmpty ? fixture : '$fixture · Shelf $level';
  }

  PreferredSizeWidget _header() {
    final name = widget.controller.currentUserName?.trim() ?? 'Bodegero';
    final initials = name
        .split(RegExp(r'\s+'))
        .take(2)
        .map((part) => part.isEmpty ? '' : part[0].toUpperCase())
        .join();
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: const Color(0xFF211F1D),
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: 74,
      titleSpacing: 16,
      title: Row(
        children: [
          CircleAvatar(
            radius: 21,
            backgroundColor: const Color(0xFF45413E),
            child: Text(
              initials,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFamily: _font,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFamily: _font,
                  ),
                ),
                const Text(
                  'Bodegero · Heavy loading',
                  style: TextStyle(
                    color: Color(0xFFC2BCB7),
                    fontSize: 12,
                    fontFamily: _font,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh orders',
          onPressed: () => unawaited(widget.controller.retryOrdersSnapshot()),
          icon: const Icon(LucideIcons.refreshCw, size: 19),
        ),
        IconButton(
          tooltip: 'Log out',
          onPressed: widget.onLogout,
          icon: const Icon(Icons.logout_outlined, size: 22),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _statusPill(String label, {bool active = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: active ? const Color(0xFFE4EFFD) : const Color(0xFFF0EEEA),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: active ? const Color(0xFF245C9E) : _muted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        fontFamily: _font,
      ),
    ),
  );

  Widget _assignedCard(CustomerOrder order) {
    final items = _heavyItems(order);
    final scanned = items.where((item) => item.heavyVerified).length;
    final sharedProgress = OrderWorkProgress.fromOrder(order);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _open(order),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _shortId(order),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                  ),
                  _statusPill(
                    scanned > 0 ? 'Loading' : 'Assigned',
                    active: true,
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                items.map((item) => item.productName).join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 14,
                  fontFamily: _font,
                ),
              ),
              if (sharedProgress.isMixed) ...[
                const SizedBox(height: 8),
                Text(
                  'Shared order · Helper: ${sharedProgress.helperSummary}',
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontFamily: _font,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: items.isEmpty ? 0 : scanned / items.length,
                        minHeight: 7,
                        backgroundColor: const Color(0xFFECEAE6),
                        valueColor: const AlwaysStoppedAnimation(_orange),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$scanned/${items.length} QR verified',
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      fontFamily: _font,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      scanned > 0 ? 'Continue loading' : 'Start loading',
                      style: const TextStyle(
                        color: _orange,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: _font,
                      ),
                    ),
                  ),
                  const Icon(
                    LucideIcons.chevronRight,
                    size: 18,
                    color: _orange,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _openCard(CustomerOrder order) {
    final items = _heavyItems(order);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortId(order),
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    fontFamily: _font,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${items.length} heavy ${items.length == 1 ? 'item' : 'items'} · ${items.map((item) => item.productName).join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontFamily: _font,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _busy ? null : () => _claim(order),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF211F1D),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: Text(_busy ? 'Claiming…' : 'Claim'),
          ),
        ],
      ),
    );
  }

  Widget _queue(List<CustomerOrder> orders) {
    final myId = widget.controller.currentUserId;
    final matching = orders
        .where((order) {
          if (_search.trim().isEmpty) return true;
          final query = _search.trim().toLowerCase();
          return order.id.toLowerCase().contains(query) ||
              _heavyItems(
                order,
              ).any((item) => item.productName.toLowerCase().contains(query));
        })
        .toList(growable: false);
    final assigned = matching
        .where((order) => order.assignedBodegeroId == myId)
        .toList(growable: false);
    final open = matching
        .where((order) => order.assignedBodegeroId == null)
        .toList(growable: false);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 20 : 32,
            compact ? 24 : 32,
            compact ? 20 : 32,
            32,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Your loading orders',
                            style: TextStyle(
                              color: _ink,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              fontFamily: _font,
                            ),
                          ),
                        ),
                        Text(
                          '${assigned.length} assigned',
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 13,
                            fontFamily: _font,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _search = value),
                      decoration: InputDecoration(
                        hintText: 'Search order # or product',
                        prefixIcon: const Icon(LucideIcons.search, size: 18),
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _search = '');
                                },
                                icon: const Icon(Icons.close, size: 18),
                              ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _line),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (assigned.isEmpty)
                      _emptyCard(
                        _search.isNotEmpty
                            ? 'No assigned orders match your search.'
                            : 'No heavy loading tasks assigned.',
                        detail: _search.isEmpty
                            ? 'A new cashier order with a Heavy product will appear here.'
                            : null,
                      ),
                    for (final order in assigned) ...[
                      _assignedCard(order),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        const Text(
                          'Open orders',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            fontFamily: _font,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '${open.length}',
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 17,
                            fontFamily: _font,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Unassigned heavy orders can be claimed here.',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 13,
                        fontFamily: _font,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (open.isEmpty)
                      _emptyCard(
                        _search.isNotEmpty
                            ? 'No open orders match your search.'
                            : 'No open orders.',
                      ),
                    for (final order in open) ...[
                      _openCard(order),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _emptyCard(String title, {String? detail}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        const Icon(LucideIcons.package, color: _muted, size: 24),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _ink,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            fontFamily: _font,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 5),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontFamily: _font,
            ),
          ),
        ],
      ],
    ),
  );

  String _quantity(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  Widget _itemCard(CustomerOrder order, CustomerOrderItem item, int position) {
    final product = widget.controller.findAnyItemById(item.productId);
    final verified = item.heavyVerified;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: verified ? const Color(0xFF168047) : _ink,
                child: verified
                    ? const Icon(
                        LucideIcons.circleCheck,
                        color: Colors.white,
                        size: 18,
                      )
                    : Text(
                        '$position',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0EEEA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: product != null && product.imageUrl.isNotEmpty
                    ? Image.network(
                        product.imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const Icon(LucideIcons.package, color: _muted),
                      )
                    : const Icon(LucideIcons.package, color: _muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _location(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                    Text(
                      item.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 13,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Load exactly ${_quantity(item.quantity)} ${item.unit ?? 'pcs'}',
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFamily: _font,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!verified)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _scan(order, item),
                  icon: const Icon(LucideIcons.scanLine, size: 17),
                  label: const Text('Scan shelf QR'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _ink,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                )
              else
                const Row(
                  children: [
                    Icon(
                      LucideIcons.circleCheck,
                      size: 18,
                      color: Color(0xFF168047),
                    ),
                    SizedBox(width: 7),
                    Text(
                      'QR verified',
                      style: TextStyle(
                        color: Color(0xFF168047),
                        fontWeight: FontWeight.w700,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _quantityControllers[item.productId],
            enabled: verified && !_busy,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantity loaded (${item.unit ?? 'pcs'})',
              hintText: verified ? 'Enter counted quantity' : 'Scan QR first',
              filled: true,
              fillColor: const Color(0xFFFAF9F7),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _proofCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(LucideIcons.truck, size: 20, color: _orange),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Truck loading proof',
                style: TextStyle(
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  fontFamily: _font,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Record the truck and photograph the goods after loading.',
          style: TextStyle(color: _muted, fontSize: 13, fontFamily: _font),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _truckController,
          maxLength: 32,
          enabled: !_busy,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Truck plate / identifier',
            prefixIcon: const Icon(LucideIcons.truck, size: 18),
            filled: true,
            fillColor: const Color(0xFFFAF9F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _capturePhoto,
          icon: const Icon(LucideIcons.camera, size: 18),
          label: Text(
            _photoJpeg == null ? 'Capture loaded goods' : 'Retake photo',
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: _orange,
            side: const BorderSide(color: _line),
          ),
        ),
        if (_photoJpeg != null) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              _photoJpeg!,
              height: 190,
              width: double.infinity,
              fit: BoxFit.contain,
            ),
          ),
        ],
      ],
    ),
  );

  bool _countsMatch(List<CustomerOrderItem> items) => items.every((item) {
    final count = double.tryParse(
      _quantityControllers[item.productId]?.text.trim() ?? '',
    );
    return count != null && count.isFinite && count == item.quantity;
  });

  Widget _checklist(CustomerOrder order) {
    final items = _heavyItems(order);
    final sharedProgress = OrderWorkProgress.fromOrder(order);
    final scanned = items.where((item) => item.heavyVerified).length;
    final allScanned = scanned == items.length;
    final countsMatch = _countsMatch(items);
    final truckReady = _truckController.text.trim().isNotEmpty;
    final photoReady = _photoJpeg != null;
    final canFinish =
        order.assignedBodegeroId != null &&
        allScanned &&
        countsMatch &&
        truckReady &&
        photoReady;
    final nextLabel = _busy
        ? 'Saving loading proof…'
        : !allScanned
        ? 'Scan ${items.length - scanned} more ${items.length - scanned == 1 ? 'item' : 'items'}'
        : !countsMatch
        ? 'Confirm loaded quantities'
        : !truckReady || !photoReady
        ? 'Add truck and photo'
        : 'Confirm loaded onto truck';
    final markers = <PickStopMarker>[];
    for (var i = 0; i < items.length; i++) {
      final locationId = widget.controller
          .findAnyItemById(items[i].productId)
          ?.locationId;
      if (locationId != null && locationId.isNotEmpty) {
        markers.add(
          PickStopMarker(
            locationId: locationId,
            number: i + 1,
            label: _location(items[i]),
          ),
        );
      }
    }
    final nextItem = items.where((item) => !item.heavyVerified);
    final highlightId = nextItem.isEmpty
        ? null
        : widget.controller
              .findAnyItemById(nextItem.first.productId)
              ?.locationId;

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 12, 20, 14),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to queue',
                onPressed: _busy
                    ? null
                    : () => setState(() => _selectedOrderId = null),
                icon: const Icon(LucideIcons.arrowLeft, color: _muted),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _shortId(order),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
                      ),
                    ),
                    const Text(
                      'Load onto truck',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontFamily: _font,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$scanned/${items.length}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  fontFamily: _font,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (sharedProgress.isMixed) ...[
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Shared order · Helper: ${sharedProgress.helperSummary}',
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: _font,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (markers.isNotEmpty &&
                          widget.controller.storeLayout.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Store map · heavy item locations',
                                style: TextStyle(
                                  color: _ink,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  fontFamily: _font,
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 260,
                                child: StoreMap(
                                  controller: widget.controller,
                                  mode: MapMode.view,
                                  viewStyle: MapViewStyle.twoD,
                                  highlightId: highlightId,
                                  pickStopMarkers: markers,
                                  showProductCounts: false,
                                  showItemPopup: false,
                                  showMobileToolbar: false,
                                  showZoomControls: true,
                                  compactZoomControls: true,
                                  miniZoomControls: true,
                                  zoomAccentColor: _orange,
                                  itemAssignmentEnabled: false,
                                  fitEntireMap: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      const Text(
                        'Loading list · scan and count',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          fontFamily: _font,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (var i = 0; i < items.length; i++)
                        _itemCard(order, items[i], i + 1),
                      const SizedBox(height: 8),
                      _proofCard(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: _line)),
          ),
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    onPressed: canFinish && !_busy
                        ? () => _finish(order)
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: _orange,
                      disabledBackgroundColor: const Color(0xFFE9B79F),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      nextLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        fontFamily: _font,
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

  Widget _completion(CustomerOrder order) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(
              radius: 34,
              backgroundColor: Color(0xFFE8F5EC),
              child: Icon(
                LucideIcons.packageCheck,
                color: Color(0xFF168047),
                size: 32,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '${_shortId(order)} loading verified',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _ink,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                fontFamily: _font,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              order.status == 'prepared'
                  ? 'The order is ready for cashier release.'
                  : 'The Helper is finishing the light items.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _muted,
                fontSize: 14,
                fontFamily: _font,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () => setState(() => _completedOrder = null),
                style: FilledButton.styleFrom(backgroundColor: _orange),
                child: const Text('Back to queue'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    appBar: _header(),
    body: StreamBuilder<List<CustomerOrder>>(
      stream: _ordersStream,
      initialData: widget.controller.currentOrders,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Unable to load assigned orders.'),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () =>
                      unawaited(widget.controller.retryOrdersSnapshot()),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting &&
            (snapshot.data?.isEmpty ?? true)) {
          return const Center(child: CircularProgressIndicator(color: _orange));
        }
        if (_completedOrder != null) return _completion(_completedOrder!);

        final orders =
            (snapshot.data ?? const <CustomerOrder>[])
                .where(
                  (order) =>
                      (order.status == 'pending' ||
                          order.status == 'solo_picking') &&
                      order.loadingVerifiedAt == null &&
                      (order.assignedBodegeroId == null ||
                          order.assignedBodegeroId ==
                              widget.controller.currentUserId) &&
                      order.items.any((item) => item.requiresLoading),
                )
                .toList()
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

        CustomerOrder? selected;
        for (final order in orders) {
          if (order.id == _selectedOrderId) selected = order;
        }
        return selected == null ? _queue(orders) : _checklist(selected);
      },
    ),
  );
}
