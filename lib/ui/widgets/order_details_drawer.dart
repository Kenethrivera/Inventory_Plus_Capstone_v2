import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/inventory.dart';
import 'app_styled_dropdown.dart';

/// Read-only details for a dashboard order card.
class OrderDetailsDrawer extends StatelessWidget {
  const OrderDetailsDrawer({
    super.key,
    required this.order,
    required this.inventory,
    required this.onOpenQueue,
    this.loadHelpers,
    this.onAssignHelper,
    this.onCancelOrder,
  });

  final CustomerOrder order;
  final List<InventoryItem> inventory;
  final VoidCallback onOpenQueue;
  final Future<List<({String id, String name})>> Function()? loadHelpers;
  final Future<void> Function(CustomerOrder order, String helperId)?
  onAssignHelper;
  final Future<void> Function(CustomerOrder order)? onCancelOrder;

  static const _ink = Color(0xFF201D1A);
  static const _muted = Color(0xFF827B75);
  static const _line = Color(0xFFE7E1DB);
  static const _orange = Color(0xFFC83D08);

  static Future<void> show(
    BuildContext context, {
    required CustomerOrder order,
    required List<InventoryItem> inventory,
    required VoidCallback onOpenQueue,
    Stream<List<CustomerOrder>>? orderUpdates,
    Future<List<({String id, String name})>> Function()? loadHelpers,
    Future<void> Function(CustomerOrder order, String helperId)? onAssignHelper,
    Future<void> Function(CustomerOrder order)? onCancelOrder,
  }) => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close order details',
    barrierColor: Colors.black.withValues(alpha: 0.24),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (dialogContext, _, _) {
      final screenSize = MediaQuery.sizeOf(dialogContext);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: screenSize.width < 1200
              ? screenSize.width
              : screenSize.width / 3,
          height: screenSize.height,
          child: StreamBuilder<List<CustomerOrder>>(
            stream: orderUpdates,
            initialData: <CustomerOrder>[order],
            builder: (context, snapshot) {
              final current = snapshot.data?.where(
                (value) => value.id == order.id,
              );
              return OrderDetailsDrawer(
                order: current != null && current.isNotEmpty
                    ? current.first
                    : order,
                inventory: inventory,
                onOpenQueue: onOpenQueue,
                loadHelpers: loadHelpers,
                onAssignHelper: onAssignHelper,
                onCancelOrder: onCancelOrder,
              );
            },
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final status = switch (order.status.toLowerCase()) {
      'solo_picking' => 'Preparing',
      'pending'
          when order.assignedHelperId != null &&
              order.items.any((item) => item.picked) =>
        'Preparing',
      'pending' when order.assignedHelperId != null => 'Assigned',
      'pending' => 'Waiting',
      'prepared' => 'Ready',
      'completed' => 'Completed',
      'cancelled' => 'Cancelled',
      'returned' => 'Returned',
      _ => order.status,
    };
    final statusColor = switch (order.status.toLowerCase()) {
      'prepared' => const Color(0xFF15803D),
      'completed' => _ink,
      'cancelled' || 'returned' => const Color(0xFFDC2626),
      'pending' when order.assignedHelperId != null => const Color(0xFF2556DB),
      _ => _orange,
    };
    final products = <String, InventoryItem>{
      for (final item in inventory) item.id: item,
    };
    final subtotal = order.totalAmount + order.discountAmount;
    final paymentEvent = order.paymentReference?.trim().isNotEmpty == true
        ? '${order.paymentMode ?? 'Payment'} ref ${order.paymentReference!.trim()}'
        : '${order.paymentMode ?? 'Payment'} payment received';

    return Material(
      color: Colors.white,
      elevation: 12,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 18, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _shortOrderId(order.id),
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 5,
                          children: [
                            _statusBadge(status, statusColor),
                            Text(
                              _date(order.createdAt),
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close order details',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: _ink, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _line),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 24, 30, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _summaryField(
                            'Cashier',
                            order.createdByName ?? '—',
                          ),
                        ),
                        Expanded(
                          child: _summaryField(
                            'Helper',
                            order.assignedHelperName?.trim().isNotEmpty == true
                                ? order.assignedHelperName!
                                : 'Unassigned',
                          ),
                        ),
                        Expanded(
                          child: _summaryField(
                            'Picked',
                            '${_pickedCount(order)} / ${order.items.length}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    _heading('Items'),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: _line),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < order.items.length; i++) ...[
                            _itemRow(
                              order.items[i],
                              products[order.items[i].productId],
                            ),
                            if (i < order.items.length - 1)
                              const Divider(height: 1, color: _line),
                          ],
                          if (order.items.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(18),
                              child: Text(
                                'No item details available',
                                style: TextStyle(color: _muted, fontSize: 13),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _amountRow('Subtotal', _money(subtotal)),
                    if (order.discountAmount > 0) ...[
                      const SizedBox(height: 9),
                      _amountRow(
                        'Discount',
                        '-${_money(order.discountAmount)}',
                      ),
                    ],
                    const SizedBox(height: 9),
                    _amountRow('Total', _money(order.totalAmount), bold: true),
                    const SizedBox(height: 30),
                    _heading('Payment'),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 15, 20, 15),
                      decoration: BoxDecoration(
                        border: Border.all(color: _line),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Column(
                        children: [
                          _paymentRow(
                            'Method',
                            order.paymentMode ?? 'Not recorded',
                          ),
                          if (order.cashGiven > 0) ...[
                            const SizedBox(height: 8),
                            _paymentRow('Tendered', _money(order.cashGiven)),
                            const SizedBox(height: 8),
                            _paymentRow('Change', _money(order.changeAmount)),
                          ],
                          if (order.paymentReference?.trim().isNotEmpty ==
                              true) ...[
                            const SizedBox(height: 8),
                            _paymentRow(
                              'Reference',
                              order.paymentReference!.trim(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),
                    _heading('Timeline'),
                    const SizedBox(height: 16),
                    _timelineEntry(
                      'Order created & paid',
                      order.createdAt,
                      '${order.createdByName ?? 'Cashier'} · $paymentEvent',
                      connected:
                          order.assignedAt != null || order.preparedAt != null,
                    ),
                    if (order.assignedAt != null)
                      _timelineEntry(
                        'Assigned',
                        order.assignedAt!,
                        '${order.assignedByAdminName ?? 'Auto-assigned'} · ${order.assignedHelperName ?? 'Helper'}',
                        connected:
                            order.preparedAt != null ||
                            order.completedAt != null,
                      ),
                    if (order.preparedAt != null)
                      _timelineEntry(
                        'Prepared',
                        order.preparedAt!,
                        'Prepared by ${order.preparedByName ?? order.assignedHelperName ?? 'helper'}',
                        connected: order.completedAt != null,
                      ),
                    if (order.completedAt != null)
                      _timelineEntry(
                        'Released to customer',
                        order.completedAt!,
                        'Completed by ${order.completedByName ?? 'staff'}',
                        highlight: true,
                      ),
                    if (order.cancelledAt != null)
                      _timelineEntry(
                        'Cancelled',
                        order.cancelledAt!,
                        order.cancelledByName ?? 'Order cancelled',
                      ),
                    if (order.returnedAt != null)
                      _timelineEntry(
                        'Returned',
                        order.returnedAt!,
                        order.returnReason ?? 'Order returned',
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: _line),
            if (onCancelOrder != null || onAssignHelper != null)
              _OrderActions(
                key: ValueKey(order.id),
                order: order,
                loadHelpers: loadHelpers,
                onAssignHelper: onAssignHelper,
                onCancelOrder: onCancelOrder,
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 12, 30, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onOpenQueue();
                    },
                    icon: const Icon(LucideIcons.list, size: 16),
                    label: const Text('Open order queue'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _orange,
                      textStyle: const TextStyle(fontSize: 13),
                      side: const BorderSide(color: _line),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      border: Border.all(color: color.withValues(alpha: 0.25)),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 12)),
  );

  Widget _summaryField(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
      const SizedBox(height: 6),
      Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _ink,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget _heading(String title) => Text(
    title,
    style: const TextStyle(
      color: _ink,
      fontSize: 14,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget _itemRow(CustomerOrderItem item, InventoryItem? product) => Padding(
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFF6F4F2),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: _line),
          ),
          clipBehavior: Clip.antiAlias,
          child: product?.imageUrl.trim().isNotEmpty == true
              ? Image.network(
                  product!.imageUrl.trim(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Icon(LucideIcons.package, size: 19, color: _muted),
                )
              : const Icon(LucideIcons.package, size: 19, color: _muted),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.productName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (product?.sku.isNotEmpty == true)
                Text(
                  product!.sku,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (item.lineTotal != null || item.unitPrice != null)
              Text(
                _money(item.lineTotal ?? item.quantity * item.unitPrice!),
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            Text(
              '${_quantity(item.quantity)} ${item.unit ?? product?.unit ?? 'pcs'}'
              '${item.unitPrice == null ? '' : ' × ${_money(item.unitPrice!)}'}',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(width: 10),
        Icon(
          LucideIcons.checkCircle2,
          size: 17,
          color: item.picked || _isFullyPicked(order)
              ? const Color(0xFF15803D)
              : const Color(0xFFC8C2BD),
        ),
      ],
    ),
  );

  Widget _amountRow(String label, String value, {bool bold = false}) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: bold ? _ink : _muted,
            fontSize: 13,
            fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
      Text(
        value,
        style: TextStyle(
          color: bold ? _ink : _muted,
          fontSize: 13,
          fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
        ),
      ),
    ],
  );

  Widget _paymentRow(String label, String value) => Row(
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 13)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          value,
          textAlign: TextAlign.right,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _ink, fontSize: 13),
        ),
      ),
    ],
  );

  Widget _timelineEntry(
    String title,
    DateTime when,
    String detail, {
    bool connected = false,
    bool highlight = false,
  }) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: Column(
            children: [
              const SizedBox(height: 5),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: highlight ? _orange : const Color(0xFFA9A19A),
                  shape: BoxShape.circle,
                ),
              ),
              if (connected) Expanded(child: Container(width: 1, color: _line)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_time(when)} · $detail',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  static String _shortOrderId(String id) =>
      id.length > 12 ? id.substring(0, 8).toUpperCase() : id;
  static bool _isFullyPicked(CustomerOrder order) =>
      order.status == 'prepared' || order.status == 'completed';
  static int _pickedCount(CustomerOrder order) => _isFullyPicked(order)
      ? order.items.length
      : order.items.where((item) => item.picked).length;
  static String _quantity(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
  static String _money(double amount) {
    final parts = amount.toStringAsFixed(2).split('.');
    final digits = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (match) => ',',
    );
    return '₱$digits.${parts[1]}';
  }

  static String _time(DateTime date) {
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    return '$hour:${date.minute.toString().padLeft(2, '0')} '
        '${date.hour < 12 ? 'AM' : 'PM'}';
  }

  static String _date(DateTime date) {
    final today = DateTime.now();
    final prefix =
        today.year == date.year &&
            today.month == date.month &&
            today.day == date.day
        ? 'Today'
        : '${date.month}/${date.day}/${date.year}';
    return '$prefix, ${_time(date)}';
  }
}

class _OrderActions extends StatefulWidget {
  const _OrderActions({
    super.key,
    required this.order,
    this.loadHelpers,
    this.onAssignHelper,
    this.onCancelOrder,
  });

  final CustomerOrder order;
  final Future<List<({String id, String name})>> Function()? loadHelpers;
  final Future<void> Function(CustomerOrder order, String helperId)?
  onAssignHelper;
  final Future<void> Function(CustomerOrder order)? onCancelOrder;

  @override
  State<_OrderActions> createState() => _OrderActionsState();
}

class _OrderActionsState extends State<_OrderActions> {
  Future<List<({String id, String name})>>? _helpers;
  String? _helperId;
  bool _busy = false;
  bool _assignmentSubmitted = false;

  @override
  void initState() {
    super.initState();
    if (widget.loadHelpers != null &&
        widget.order.status.toLowerCase() == 'pending' &&
        widget.order.assignedHelperId == null) {
      _helpers = widget.loadHelpers!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.order.status.toLowerCase();
    final cancellable =
        status == 'pending' || status == 'prepared' || status == 'solo_picking';
    final canAssign =
        status == 'pending' &&
        widget.order.assignedHelperId == null &&
        !_assignmentSubmitted &&
        widget.onAssignHelper != null;
    if (!cancellable) return const SizedBox.shrink();

    final cancelButton = OutlinedButton(
      onPressed: _busy ? null : _cancel,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFDC2626),
        textStyle: const TextStyle(fontSize: 13),
        side: const BorderSide(color: Color(0xFFE7E1DB)),
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 17),
      ),
      child: const Text('Cancel order'),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 12, 30, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 440;
          final assignment = Row(
            children: [
              Expanded(
                child: FutureBuilder<List<({String id, String name})>>(
                  future: _helpers,
                  builder: (context, snapshot) {
                    final helpers =
                        snapshot.data ?? const <({String id, String name})>[];
                    return AppStyledDropdown<String>(
                      key: ValueKey('helper-${widget.order.id}'),
                      initialValue: _helperId,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF201D1A),
                      ),
                      hint: Text(
                        snapshot.hasError
                            ? 'Helpers unavailable'
                            : snapshot.connectionState == ConnectionState.done
                            ? 'Choose helper...'
                            : 'Loading helpers...',
                        style: const TextStyle(fontSize: 13),
                      ),
                      items: [
                        for (final helper in helpers)
                          DropdownMenuItem(
                            value: helper.id,
                            child: Text(helper.name),
                          ),
                      ],
                      onChanged: _busy || helpers.isEmpty
                          ? null
                          : (value) => setState(() => _helperId = value),
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(9),
                          borderSide: const BorderSide(
                            color: Color(0xFFE7E1DB),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _busy || _helperId == null ? null : _assign,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFC83D08),
                  textStyle: const TextStyle(fontSize: 13),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 17,
                  ),
                ),
                child: const Text('Assign'),
              ),
            ],
          );
          if (canAssign && compact) {
            return Column(
              children: [
                assignment,
                if (widget.onCancelOrder != null) ...[
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: cancelButton),
                ],
              ],
            );
          }
          return Row(
            children: [
              if (canAssign) Expanded(child: assignment) else const Spacer(),
              if (canAssign && widget.onCancelOrder != null)
                const SizedBox(width: 10),
              if (widget.onCancelOrder != null) cancelButton,
            ],
          );
        },
      ),
    );
  }

  Future<void> _assign() async {
    final helperId = _helperId;
    if (helperId == null) return;
    setState(() => _busy = true);
    try {
      await widget.onAssignHelper!(widget.order, helperId);
      if (mounted) {
        setState(() => _assignmentSubmitted = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Helper assigned.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not assign helper: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this order?'),
        content: const Text(
          'The order will be cancelled and its stock returned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep order'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel order'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.onCancelOrder!(widget.order);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel order: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
