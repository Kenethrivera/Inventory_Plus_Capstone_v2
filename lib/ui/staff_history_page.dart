import 'package:flutter/material.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const Color _darkText = Color(0xFF0F172A);
const Color _mutedText = Color(0xFF64748B);
const Color _pageBg = Color(0xFFF4F6F8);
const String _fontFam = 'Hellix';

class StaffHistoryPage extends StatefulWidget {
  final InventoryController controller;

  const StaffHistoryPage({super.key, required this.controller});

  @override
  State<StaffHistoryPage> createState() => _StaffHistoryPageState();
}

class _StaffHistoryPageState extends State<StaffHistoryPage> {
  String _searchQuery = '';
  String _selectedFilter = 'All';

  // Cashier only:
  // Orders = order history
  // Restocks = inventory restock history
  String _historySection = 'Orders';

  // Orders stay collapsed by default.
  final Set<String> _expandedOrderIds = {};

  Future<List<Map<String, dynamic>>>? _restockFuture;

  String get _role =>
      widget.controller.currentUserRole?.toLowerCase() ?? 'staff';

  String? get _currentUserId => widget.controller.currentUserId;

  bool get _isHelper => _role == 'helper';

  bool get _isCashier => _role == 'staff' || _role == 'cashier';

  @override
  void initState() {
    super.initState();

    if (_isCashier) {
      _restockFuture = widget.controller.fetchMyRestockHistory();
    }
  }

  void _refreshRestockHistory() {
    if (!_isCashier) return;

    setState(() {
      _restockFuture = widget.controller.fetchMyRestockHistory();
    });
  }

  List<String> get _filters {
    if (_isHelper) {
      return const ['All', 'Assigned', 'Prepared'];
    }

    return const ['All', 'Created', 'Completed', 'Cancelled'];
  }

  bool _sameUser(dynamic value) {
    final userId = _currentUserId;

    if (userId == null || userId.isEmpty || value == null) {
      return false;
    }

    return value.toString() == userId.toString();
  }

  bool _belongsToCurrentUser(CustomerOrder order) {
    if (_isHelper) {
      return _sameUser(order.assignedHelperId) || _sameUser(order.preparedById);
    }

    if (_isCashier) {
      return _sameUser(order.createdById) ||
          _sameUser(order.completedById) ||
          _sameUser(order.cancelledById) ||
          _sameUser(order.returnedById);
    }

    return false;
  }

  bool _matchesSelectedFilter(CustomerOrder order) {
    if (_selectedFilter == 'All') {
      return true;
    }

    if (_isHelper) {
      switch (_selectedFilter) {
        case 'Assigned':
          return _sameUser(order.assignedHelperId);

        case 'Prepared':
          return _sameUser(order.preparedById);

        default:
          return true;
      }
    }

    switch (_selectedFilter) {
      case 'Created':
        return _sameUser(order.createdById);

      case 'Completed':
        return _sameUser(order.completedById);

      case 'Cancelled':
        return _sameUser(order.cancelledById) || _sameUser(order.returnedById);

      default:
        return true;
    }
  }

  bool _matchesOrderSearch(CustomerOrder order) {
    final query = _searchQuery.trim().toLowerCase();

    if (query.isEmpty) {
      return true;
    }

    if (order.id.toLowerCase().contains(query)) {
      return true;
    }

    if (order.status.toLowerCase().contains(query)) {
      return true;
    }

    return order.items.any(
      (item) => item.productName.toLowerCase().contains(query),
    );
  }

  bool _matchesRestockSearch(Map<String, dynamic> transaction) {
    final query = _searchQuery.trim().toLowerCase();

    if (query.isEmpty) return true;

    final product = _readProductMap(transaction['products']);

    final productName =
        product?['product_name']?.toString().toLowerCase() ?? '';

    final sku = product?['sku']?.toString().toLowerCase() ?? '';

    return productName.contains(query) || sku.contains(query);
  }

  DateTime _activityDate(CustomerOrder order) {
    if (_isHelper) {
      if (_sameUser(order.preparedById) && order.preparedAt != null) {
        return order.preparedAt!;
      }

      if (_sameUser(order.assignedHelperId) && order.assignedAt != null) {
        return order.assignedAt!;
      }

      return order.createdAt;
    }

    if (_sameUser(order.completedById) && order.completedAt != null) {
      return order.completedAt!;
    }

    if (_sameUser(order.cancelledById) && order.cancelledAt != null) {
      return order.cancelledAt!;
    }

    if (_sameUser(order.returnedById) && order.returnedAt != null) {
      return order.returnedAt!;
    }

    return order.createdAt;
  }

  String _myActionLabel(CustomerOrder order) {
    if (_isHelper) {
      if (_sameUser(order.preparedById)) {
        return 'Prepared by you';
      }

      if (_sameUser(order.assignedHelperId)) {
        return 'Assigned to you';
      }

      return 'Your order task';
    }

    if (_sameUser(order.completedById)) {
      return 'Completed by you';
    }

    if (_sameUser(order.cancelledById)) {
      return 'Cancelled by you';
    }

    if (_sameUser(order.returnedById)) {
      return 'Returned by you';
    }

    if (_sameUser(order.createdById)) {
      return 'Created by you';
    }

    return 'Your transaction';
  }

  String _shortOrderId(String id) {
    if (id.length <= 8) {
      return id.toUpperCase();
    }

    return id.substring(0, 8).toUpperCase();
  }

  String _money(num value) {
    return '₱${value.toStringAsFixed(2)}';
  }

  String _formatDateTime(DateTime date) {
    final local = date.toLocal();

    final hour = local.hour > 12
        ? local.hour - 12
        : (local.hour == 0 ? 12 : local.hour);

    final minute = local.minute.toString().padLeft(2, '0');

    final suffix = local.hour >= 12 ? 'PM' : 'AM';

    return '${local.month}/${local.day}/${local.year} '
        '$hour:$minute $suffix';
  }

  String _formatHistoryQty(num value) {
    final number = value.toDouble();

    if (number == number.roundToDouble()) {
      return number.toInt().toString();
    }

    return number.toStringAsFixed(2);
  }

  String _statusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return 'Pending';

      case 'prepared':
        return 'Prepared';

      case 'completed':
        return 'Completed';

      case 'cancelled':
        return 'Cancelled';

      case 'returned':
        return 'Returned';

      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Colors.orange;

      case 'prepared':
        return _primaryBlue;

      case 'completed':
        return Colors.green;

      case 'cancelled':
        return Colors.red;

      case 'returned':
        return Colors.deepOrange;

      default:
        return _mutedText;
    }
  }

  void _toggleOrderExpanded(String orderId) {
    setState(() {
      if (_expandedOrderIds.contains(orderId)) {
        _expandedOrderIds.remove(orderId);
      } else {
        _expandedOrderIds.add(orderId);
      }
    });
  }

  Map<String, dynamic>? _readProductMap(dynamic value) {
    if (value == null) return null;

    try {
      if (value is Map<String, dynamic>) {
        return value;
      }

      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUserId == null || _currentUserId!.isEmpty) {
      return const Scaffold(
        backgroundColor: _pageBg,
        body: Center(child: CircularProgressIndicator(color: _primaryBlue)),
      );
    }

    return Scaffold(
      backgroundColor: _pageBg,
      body: StreamBuilder<List<CustomerOrder>>(
        stream: widget.controller.streamOrders(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: _primaryBlue),
            );
          }

          if (snapshot.hasError) {
            return const Center(
              child: Text(
                'Could not load your history.',
                style: TextStyle(color: _mutedText, fontFamily: _fontFam),
              ),
            );
          }

          final allOrders = snapshot.data ?? <CustomerOrder>[];

          final myOrders = allOrders.where(_belongsToCurrentUser).toList()
            ..sort((a, b) => _activityDate(b).compareTo(_activityDate(a)));

          final displayedOrders = myOrders
              .where(_matchesSelectedFilter)
              .where(_matchesOrderSearch)
              .toList();

          final activeCount = myOrders.where((order) {
            final status = order.status.toLowerCase();

            return status == 'pending' || status == 'prepared';
          }).length;

          final completedCount = _isHelper
              ? myOrders.where((order) => _sameUser(order.preparedById)).length
              : myOrders
                    .where((order) => _sameUser(order.completedById))
                    .length;

          final cancelledCount = _isHelper
              ? 0
              : myOrders.where((order) {
                  return _sameUser(order.cancelledById) ||
                      _sameUser(order.returnedById);
                }).length;

          return Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),

                const SizedBox(height: 22),

                _buildStats(
                  total: myOrders.length,
                  active: activeCount,
                  completed: completedCount,
                  cancelled: cancelledCount,
                ),

                const SizedBox(height: 18),

                if (!_isHelper) ...[
                  _buildHistorySectionSelector(),
                  const SizedBox(height: 18),
                ],

                _buildControls(),

                const SizedBox(height: 18),

                Expanded(
                  child: !_isHelper && _historySection == 'Restocks'
                      ? _buildMyRestockHistory()
                      : displayedOrders.isEmpty
                      ? _buildOrderEmptyState()
                      : ListView.separated(
                          itemCount: displayedOrders.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            return _buildHistoryCard(displayedOrders[index]);
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isHelper ? 'My Work History' : 'My Transaction History',
          style: const TextStyle(
            color: _darkText,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          _isHelper
              ? 'Orders assigned to or prepared by you.'
              : 'Your own orders and inventory activity.',
          style: const TextStyle(
            color: _mutedText,
            fontSize: 14,
            fontFamily: _fontFam,
          ),
        ),
      ],
    );
  }

  Widget _buildStats({
    required int total,
    required int active,
    required int completed,
    required int cancelled,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            title: 'My Records',
            value: '$total',
            icon: Icons.history,
            color: _primaryBlue,
          ),
        ),

        const SizedBox(width: 12),

        Expanded(
          child: _buildStatCard(
            title: 'Active',
            value: '$active',
            icon: Icons.schedule,
            color: Colors.orange,
          ),
        ),

        const SizedBox(width: 12),

        Expanded(
          child: _buildStatCard(
            title: _isHelper ? 'Prepared' : 'Completed',
            value: '$completed',
            icon: Icons.check_circle_outline,
            color: Colors.green,
          ),
        ),

        if (!_isHelper) ...[
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              title: 'Cancelled / Returned',
              value: '$cancelled',
              icon: Icons.cancel_outlined,
              color: Colors.red,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _mutedText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: _fontFam,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: _darkText,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistorySectionSelector() {
    return Row(
      children: [
        _buildHistorySectionButton(
          label: 'Orders',
          icon: Icons.receipt_long_outlined,
          selected: _historySection == 'Orders',
          onTap: () {
            setState(() {
              _historySection = 'Orders';
            });
          },
        ),

        const SizedBox(width: 8),

        _buildHistorySectionButton(
          label: 'Restocks',
          icon: Icons.add_box_outlined,
          selected: _historySection == 'Restocks',
          onTap: () {
            setState(() {
              _historySection = 'Restocks';
            });
          },
        ),
      ],
    );
  }

  Widget _buildHistorySectionButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _primaryBlue : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? _primaryBlue : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.white : _mutedText),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : _darkText,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
            decoration: InputDecoration(
              hintText: _historySection == 'Restocks' && !_isHelper
                  ? 'Search restocked item or SKU...'
                  : 'Search order or item...',
              prefixIcon: const Icon(Icons.search, color: _mutedText),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 13,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primaryBlue),
              ),
            ),
          ),
        ),

        if (_historySection == 'Orders' || _isHelper) ...[
          const SizedBox(width: 14),

          Wrap(
            spacing: 8,
            children: _filters.map((filter) {
              final selected = _selectedFilter == filter;

              return ChoiceChip(
                label: Text(filter),
                selected: selected,
                onSelected: (_) {
                  setState(() {
                    _selectedFilter = filter;
                  });
                },
                selectedColor: _primaryBlue.withOpacity(0.10),
                backgroundColor: Colors.white,
                side: BorderSide(
                  color: selected ? _primaryBlue : const Color(0xFFE5E7EB),
                ),
                labelStyle: TextStyle(
                  color: selected ? _primaryBlue : _mutedText,
                  fontWeight: FontWeight.w800,
                  fontFamily: _fontFam,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              );
            }).toList(),
          ),
        ],

        if (!_isHelper && _historySection == 'Restocks') ...[
          const SizedBox(width: 10),
          IconButton(
            tooltip: 'Refresh restocks',
            onPressed: _refreshRestockHistory,
            icon: const Icon(Icons.refresh, color: _primaryBlue),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------
  // COLLAPSIBLE ORDER HISTORY
  // ---------------------------------------------------------

  Widget _buildHistoryCard(CustomerOrder order) {
    final status = order.status.toLowerCase();

    final statusColor = _statusColor(status);

    final activityDate = _activityDate(order);

    final isExpanded = _expandedOrderIds.contains(order.id);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => _toggleOrderExpanded(order.id),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _isHelper
                          ? Icons.inventory_2_outlined
                          : Icons.receipt_long_outlined,
                      color: statusColor,
                      size: 21,
                    ),
                  ),

                  const SizedBox(width: 14),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Order #${_shortOrderId(order.id)}',
                                style: const TextStyle(
                                  color: _darkText,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  fontFamily: _fontFam,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                _statusLabel(status),
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  fontFamily: _fontFam,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 6),

                        Text(
                          _myActionLabel(order),
                          style: const TextStyle(
                            color: _primaryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            fontFamily: _fontFam,
                          ),
                        ),

                        const SizedBox(height: 8),

                        Wrap(
                          spacing: 16,
                          runSpacing: 7,
                          children: [
                            _buildMeta(
                              Icons.schedule,
                              _formatDateTime(activityDate),
                            ),

                            _buildMeta(
                              Icons.inventory_2_outlined,
                              '${order.items.length} '
                              'item${order.items.length == 1 ? '' : 's'}',
                            ),

                            if (!_isHelper)
                              _buildMeta(
                                Icons.payments_outlined,
                                _money(order.totalAmount),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(width: 12),

                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: _mutedText,
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),

          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: !isExpanded
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Divider(height: 1, color: Color(0xFFE5E7EB)),

                        const SizedBox(height: 14),

                        Row(
                          children: [
                            const Text(
                              'Order items',
                              style: TextStyle(
                                color: _darkText,
                                fontSize: 13,
                                fontWeight: FontWeight.w900,
                                fontFamily: _fontFam,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${order.items.length}',
                                style: const TextStyle(
                                  color: _mutedText,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  fontFamily: _fontFam,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        ...order.items.map(
                          (item) => Container(
                            margin: const EdgeInsets.only(bottom: 7),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFFE5E7EB),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.inventory_2_outlined,
                                  size: 15,
                                  color: _mutedText,
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    item.productName,
                                    style: const TextStyle(
                                      color: _darkText,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: _fontFam,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '× ${_formatHistoryQty(item.quantity)}',
                                  style: const TextStyle(
                                    color: _darkText,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------
  // CASHIER RESTOCK HISTORY
  // ---------------------------------------------------------

  Widget _buildMyRestockHistory() {
    final future = _restockFuture ?? widget.controller.fetchMyRestockHistory();

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: _primaryBlue),
          );
        }

        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Could not load restock history.',
              style: TextStyle(color: _mutedText, fontFamily: _fontFam),
            ),
          );
        }

        final allRestocks = snapshot.data ?? <Map<String, dynamic>>[];

        final restocks = allRestocks.where(_matchesRestockSearch).toList();

        if (restocks.isEmpty) {
          return _buildRestockEmptyState();
        }

        return ListView.separated(
          itemCount: restocks.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            return _buildRestockCard(restocks[index]);
          },
        );
      },
    );
  }

  Widget _buildRestockCard(Map<String, dynamic> transaction) {
    final product = _readProductMap(transaction['products']);

    final productName = product?['product_name']?.toString() ?? 'Unknown item';

    final sku = product?['sku']?.toString();

    final quantityChange =
        (transaction['quantity_change'] as num?)?.toDouble() ?? 0;

    final newQuantity = (transaction['new_quantity'] as num?)?.toDouble() ?? 0;

    final createdAt = DateTime.tryParse(
      transaction['created_at']?.toString() ?? '',
    );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.add_box_outlined,
              color: Colors.green,
              size: 21,
            ),
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _darkText,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    fontFamily: _fontFam,
                  ),
                ),

                const SizedBox(height: 5),

                const Text(
                  'Restocked by you',
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    fontFamily: _fontFam,
                  ),
                ),

                const SizedBox(height: 7),

                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [
                    if (createdAt != null)
                      _buildMeta(Icons.schedule, _formatDateTime(createdAt)),

                    if (sku != null && sku.isNotEmpty)
                      _buildMeta(Icons.qr_code, sku),

                    _buildMeta(
                      Icons.inventory_2_outlined,
                      'New stock: ${_formatHistoryQty(newQuantity)}',
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 16),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '+${_formatHistoryQty(quantityChange)}',
              style: const TextStyle(
                color: Colors.green,
                fontSize: 14,
                fontWeight: FontWeight.w900,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMeta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: _mutedText),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            color: _mutedText,
            fontSize: 12,
            fontFamily: _fontFam,
          ),
        ),
      ],
    );
  }

  Widget _buildOrderEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_toggle_off,
            size: 52,
            color: _mutedText.withOpacity(0.55),
          ),
          const SizedBox(height: 14),
          Text(
            _searchQuery.trim().isNotEmpty
                ? 'No matching records'
                : 'No history yet',
            style: const TextStyle(
              color: _darkText,
              fontSize: 17,
              fontWeight: FontWeight.w900,
              fontFamily: _fontFam,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _isHelper
                ? 'Your assigned and prepared orders will appear here.'
                : 'Your cashier transactions will appear here.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _mutedText,
              fontSize: 13,
              fontFamily: _fontFam,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRestockEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 48,
            color: _mutedText.withOpacity(0.55),
          ),
          const SizedBox(height: 12),
          Text(
            _searchQuery.trim().isNotEmpty
                ? 'No matching restocks'
                : 'No restocks yet',
            style: const TextStyle(
              color: _darkText,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              fontFamily: _fontFam,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Items you restock will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _mutedText,
              fontSize: 13,
              fontFamily: _fontFam,
            ),
          ),
        ],
      ),
    );
  }
}
