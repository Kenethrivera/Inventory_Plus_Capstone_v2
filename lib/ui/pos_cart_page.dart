import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'widgets/order_checklist_view.dart';
import 'visual_search_page.dart';

const double _kSnapFull = 0.75;
const double _kBaseChromeHeight = 320.0;

class PosCartPage extends StatefulWidget {
  final InventoryController controller;

  const PosCartPage({super.key, required this.controller});

  @override
  State<PosCartPage> createState() => _PosCartPageState();
}

class _PosCartPageState extends State<PosCartPage>
    with SingleTickerProviderStateMixin {
  String _searchQuery = '';
  String _selectedCategory = 'All';
  final Map<String, double> _cart = {};
  bool? _isGridView;
  bool _isProcessingCart = false;

  double _discountValue = 0.0;
  bool _isDiscountPercentage = true;
  String _discountReason = '';

  double _cartHeightFraction = 0.0;
  late AnimationController _snapAnim;
  late Animation<double> _snapAnimation;
  double _dragStart = 0;
  double _fractionAtDragStart = 0;

  double _kBaseChromeHeight = 368.0; // was 320

  bool _soloMode = false;

  @override
  void initState() {
    super.initState();
    _snapAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final mq = MediaQuery.of(context);
      final totalHeight = mq.size.height - mq.padding.top;
      if (totalHeight <= 0) return;
      setState(() {
        final minHeight = _kBaseChromeHeight + mq.padding.bottom;
        _cartHeightFraction = (minHeight / totalHeight).clamp(0.0, _kSnapFull);
      });
    });
  }

  @override
  void dispose() {
    _snapAnim.dispose();
    super.dispose();
  }

  void _snapTo(double target) {
    final start = _cartHeightFraction;
    _snapAnimation =
        Tween<double>(begin: start, end: target).animate(
          CurvedAnimation(
            parent: _snapAnim,
            curve: const Cubic(0.25, 0.46, 0.45, 0.94),
          ),
        )..addListener(() {
          setState(() => _cartHeightFraction = _snapAnimation.value);
        });
    _snapAnim
      ..reset()
      ..forward();
  }

  void _onDragEnd(DragEndDetails details) {
    final mq = MediaQuery.of(context);
    final safeHeight = mq.size.height - mq.padding.top - mq.padding.bottom - 56;
    final totalHeight = mq.size.height - mq.padding.top;
    if (totalHeight <= 0) return;

    final minHeight = _kBaseChromeHeight + mq.padding.bottom;
    final floorFraction = (minHeight / totalHeight).clamp(0.0, _kSnapFull);
    final safeMax = (safeHeight / totalHeight).clamp(floorFraction, _kSnapFull);

    final velocity = details.primaryVelocity ?? 0;
    double target;

    if (velocity < -800) {
      target = safeMax;
    } else if (velocity > 800) {
      target = floorFraction;
    } else {
      target =
          (_cartHeightFraction - floorFraction).abs() <
              (_cartHeightFraction - safeMax).abs()
          ? floorFraction
          : safeMax;
    }
    _snapTo(target.clamp(floorFraction, safeMax));
  }

  List<InventoryItem> get _filteredItems => widget.controller.filterInventory(
    query: _searchQuery,
    category: _selectedCategory,
  );

  bool _addToCart(InventoryItem item) {
    if (_isProcessingCart) return false;
    final currentQty = _cart[item.id] ?? 0;
    if (currentQty >= item.quantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cannot add more of ${item.name}. Stock limit reached.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }
    setState(() => _cart[item.id] = currentQty + 1);
    return true;
  }

  void _setCartQuantity(String itemId, double qty) {
    if (_isProcessingCart) return;
    try {
      final item = widget.controller.allItems.firstWhere((i) => i.id == itemId);
      if (qty > item.quantity) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Cannot set quantity to $qty. Only ${item.quantity} in stock.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
        qty = item.quantity;
      }
    } catch (_) {}

    setState(() {
      if (qty <= 0) {
        _cart.remove(itemId);
      } else {
        _cart[itemId] = qty;
      }

      if (_cart.isEmpty) {
        _discountValue = 0.0;
        _discountReason = '';
      }
    });
  }

  Future<void> _processOrder() async {
    if (_cart.isEmpty || _isProcessingCart) return;
    setState(() => _isProcessingCart = true);
    try {
      final items = _cart.entries.map((entry) {
        final item = widget.controller.allItems.firstWhere(
          (i) => i.id == entry.key,
        );
        return CustomerOrderItem(
          productId: item.id,
          productName: item.name,
          quantity: entry.value,
        );
      }).toList();

      final double subtotal = _calculateTotal();
      double discountAmt = _isDiscountPercentage
          ? (subtotal * (_discountValue / 100))
          : _discountValue;
      if (discountAmt > subtotal) discountAmt = subtotal;
      final double totalDue = subtotal - discountAmt;

      // NOTE: createCustomerOrder needs to return the created CustomerOrder
      // (with its generated id) so Solo Mode can open the checklist for it.
      final CustomerOrder? createdOrder = await widget.controller
          .createCustomerOrder(
            items,
            totalAmount: totalDue,
            discountAmount: discountAmt,
            soloHandled: _soloMode,
          );
      if (createdOrder == null) {
        throw Exception('Order could not be created.');
      }

      if (!mounted) return;

      setState(() {
        _cart.clear();
        _discountValue = 0.0;
        _discountReason = '';
      });

      if (_soloMode) {
        await _runSoloCheckout(createdOrder);
      } else {
        AppToast.success(context, 'Order sent to Helper!');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, "Couldn't process the order: $e");
    } finally {
      if (mounted) setState(() => _isProcessingCart = false);
    }
  }

  Future<void> _completeOrderFlow(
    CustomerOrder order, {
    VoidCallback? onCompleted,
  }) async {
    final double orderSubtotal = order.totalAmount + order.discountAmount;
    double orderQty = 0;
    for (final item in order.items) {
      orderQty += item.quantity;
    }

    final paymentData = await _showPaymentDialog(
      subtotal: orderSubtotal,
      discountAmt: order.discountAmount,
      totalDue: order.totalAmount,
      itemsCount: order.items.length,
      totalQty: orderQty,
    );

    if (paymentData == null || paymentData['confirmed'] != true) return;
  
    ({DateTime createdAt, DateTime completedAt})? times;
    try {
      times = await widget.controller.completeOrder(
        order,
        paymentMode: paymentData['paymentMode'],
        cashGiven: paymentData['cashReceived'],
        changeAmount: paymentData['change'],
      );
    } catch (e) {
      if (mounted) AppToast.error(context, "Couldn't complete the order: $e");
      return;
    }
    if (times == null) return; // already completed elsewhere

    onCompleted?.call();

    if (mounted) {
      _showReceiptDialog(
        order,
        paymentMode: paymentData['paymentMode'],
        cashReceived: paymentData['cashReceived'],
        change: paymentData['change'],
        orderedAt: times.createdAt,
        completedAt: times.completedAt,
      );
    }
  }

 Future<void> _runSoloCheckout(CustomerOrder order) async {
    final result = await showOrderChecklistModal(
      context: context,
      order: order,
      controller: widget.controller,
      finishLabel: "PROCEED TO PAYMENT",
      onCancelOrder: () => _cancelOrderAndRestoreCart(order),
    );
    if (!mounted) return;

    switch (result) {
      case ChecklistResult.finished:
        await widget.controller.updateOrderStatus(order.id, 'prepared');
        var paid = false;
        await _completeOrderFlow(order, onCompleted: () => paid = true);
        if (!paid && mounted) {
          AppToast.success(
            context,
            "Payment not completed — order is waiting in Pending Orders",
          );
        }
        break;
      case ChecklistResult.dismissed:
        // Closed mid-picking: hand it to the helper queue instead of orphaning it.
        await widget.controller.updateOrderStatus(order.id, 'pending');
        if (mounted)
          AppToast.success(context, "Order moved to the Helper queue");
        break;
      case ChecklistResult.cancelled:
        break; // cart already restored
    }
  }

  Future<bool> _cancelOrderAndRestoreCart(
    CustomerOrder order, {
    bool fromQueue = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.undo2,
        color: Colors.red.shade600,
        title: "Cancel & Edit This Order?",
        subtitle: "#${order.id.substring(0, 8).toUpperCase()}",
        child: Text(
          fromQueue
              ? "This cancels the order and puts its items back in your cart. "
                    "If your helper is already picking it, let them know."
              : "This cancels the order and puts its items back in your cart so "
                    "you can change quantities before checking out again.",
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Keep It"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              "Cancel Order",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

      if (confirmed != true) return false;

  try {
    await widget.controller.cancelOrder(order); // now takes the order, restores stock
    if (!mounted) return true;
    setState(() {
        for (final item in order.items) {
          _cart[item.productId] = (_cart[item.productId] ?? 0) + item.quantity;
        }
        if (order.discountAmount > 0 && _discountValue == 0) {
          _discountValue = order.discountAmount;
          _isDiscountPercentage = false;
        }
      });
    AppToast.success(context, "Order cancelled — items are back in your cart");
    return true;
  } catch (e) {
    if (mounted) AppToast.error(context, "Couldn't cancel the order: $e");
    return false;
  }
}



  double _calculateTotal() {
    double total = 0;
    for (var entry in _cart.entries) {
      try {
        final item = widget.controller.allItems.firstWhere(
          (i) => i.id == entry.key,
        );
        total += item.price * entry.value;
      } catch (_) {}
    }
    return total;
  }

  void _openAIObjectScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VisualSearchPage(
          controller: widget.controller,
          onSelectItem: (item) {
            if (_addToCart(item)) {
              Navigator.pop(context);
              AppToast.success(context, '${item.name} added to cart!');
            }
          },
        ),
      ),
    );
  }

  void _showDiscountDialog(BuildContext context) {
    final valueCtrl = TextEditingController(
      text: _discountValue > 0
          ? (_discountValue.truncateToDouble() == _discountValue
                ? _discountValue.toInt().toString()
                : _discountValue.toStringAsFixed(2))
          : '',
    );
    final reasonCtrl = TextEditingController(text: _discountReason);
    bool isPercent = _isDiscountPercentage;
    String? errorMessage; // Local error state for the modal

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setModalState) {
          void applyDiscount() {
            final textVal = valueCtrl.text.trim();
            if (textVal.isEmpty) {
              setState(() {
                _discountValue = 0.0;
                _isDiscountPercentage = isPercent;
                _discountReason = '';
              });
              Navigator.pop(dialogContext);
              return;
            }

            final val = double.tryParse(textVal);
            if (val == null || val < 0) {
              setModalState(
                () => errorMessage = 'Please enter a valid positive number.',
              );
              return;
            }
            if (isPercent && val > 100) {
              setModalState(
                () => errorMessage = 'Percentage cannot exceed 100%.',
              );
              return;
            }

            setState(() {
              _discountValue = val;
              _isDiscountPercentage = isPercent;
              _discountReason = reasonCtrl.text;
            });
            Navigator.pop(dialogContext);
          }

          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            backgroundColor: Colors.white,
            child: SizedBox(
              width: 340,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Add Discount",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            LucideIcons.x,
                            size: 20,
                            color: Colors.grey,
                          ),
                          onPressed: () => Navigator.pop(dialogContext),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  setModalState(() => isPercent = true),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isPercent
                                      ? Colors.white
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: isPercent
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(
                                              0.05,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ]
                                      : [],
                                ),
                                child: Center(
                                  child: Text(
                                    "Percent %",
                                    style: TextStyle(
                                      fontWeight: isPercent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: isPercent
                                          ? Colors.black87
                                          : Colors.grey,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () =>
                                  setModalState(() => isPercent = false),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: !isPercent
                                      ? Colors.white
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: !isPercent
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(
                                              0.05,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ]
                                      : [],
                                ),
                                child: Center(
                                  child: Text(
                                    "Amount ₱",
                                    style: TextStyle(
                                      fontWeight: !isPercent
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: !isPercent
                                          ? Colors.black87
                                          : Colors.grey,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Display Local Error Message
                    if (errorMessage != null) ...[
                      Text(
                        errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],

                    TextField(
                      controller: valueCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      onSubmitted: (_) => applyDiscount(),
                      decoration: InputDecoration(
                        prefixText: isPercent ? "%" : "₱ ",
                        prefixStyle: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      hintText: isPercent ? "Enter % Discount" : "Enter Amount",
                      hintStyle: TextStyle(color: Colors.grey.shade400),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.orange),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reasonCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      onSubmitted: (_) => applyDiscount(),
                      decoration: InputDecoration(
                        hintText: "Reason (Optional)",
                        hintStyle: TextStyle(color: Colors.grey.shade400),
                        filled: true,
                        fillColor: const Color(0xFF374151),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        onPressed: applyDiscount,
                        child: const Text(
                          "Apply Discount",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<Map<String, dynamic>?> _showPaymentDialog({
    required double subtotal,
    required double discountAmt,
    required double totalDue,
    required int itemsCount,
    required double totalQty,
  }) {
    String paymentMode = 'Cash';
    final cashCtrl = TextEditingController();
    double cashReceived = 0.0;

    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          double change = cashReceived - totalDue;
          if (change < 0) change = 0;

          Widget buildPaymentTile(String title, IconData icon) {
            bool isSelected = paymentMode == title;
            return Expanded(
              child: GestureDetector(
                onTap: () => setDialogState(() => paymentMode = title),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.orange.shade50 : Colors.white,
                    border: Border.all(
                      color: isSelected ? Colors.orange : Colors.grey.shade300,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        icon,
                        color: isSelected
                            ? Colors.orange
                            : Colors.grey.shade400,
                        size: 20,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.orange
                              : Colors.grey.shade600,
                          fontSize: 12,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          String qtyStr = totalQty.truncateToDouble() == totalQty
              ? totalQty.toInt().toString()
              : totalQty.toStringAsFixed(2);

          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            backgroundColor: Colors.white,
            child: SizedBox(
              width: 400,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Confirm Order",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "$itemsCount items - $qtyStr total qty",
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 20),

                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Subtotal',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                '₱${subtotal.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),

                          if (discountAmt > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Discount',
                                  style: TextStyle(fontSize: 12),
                                ),
                                Text(
                                  "-₱${discountAmt.toStringAsFixed(2)}",
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],

                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'TOTAL',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                "₱${totalDue.toStringAsFixed(2)}",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),
                    Text(
                      "MODE OF PAYMENT",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade500,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        buildPaymentTile('Cash', LucideIcons.banknote),
                        const SizedBox(width: 8),
                        buildPaymentTile('GCash', LucideIcons.smartphone),
                        const SizedBox(width: 8),
                        buildPaymentTile('Card', LucideIcons.creditCard),
                      ],
                    ),

                    if (paymentMode == 'Cash') ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text(
                            "Cash Received",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextField(
                              controller: cashCtrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'^\d*\.?\d*'),
                                ), // Blocks letters completely
                              ],
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                hintText: "0.00",
                                hintStyle: TextStyle(
                                  color: Colors.grey.shade400,
                                  fontWeight: FontWeight.normal,
                                ),
                                filled: true,
                                fillColor: Colors
                                    .transparent, // Transparent as requested
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: BorderSide(
                                    color: Colors.grey.shade400,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: BorderSide(
                                    color: Colors.grey.shade400,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide: const BorderSide(
                                    color: Colors.orange,
                                    width: 2,
                                  ), // Highlighting the input
                                ),
                                isDense: true,
                              ),
                              onChanged: (val) {
                                setDialogState(() {
                                  cashReceived = double.tryParse(val) ?? 0.0;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "Change",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                          Text(
                            "₱${change.toStringAsFixed(2)}",
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 24),
                    Row(
                      children: [
                        const Icon(
                          LucideIcons.check,
                          color: Colors.green,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Payment is received',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          LucideIcons.check,
                          color: Colors.green,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Receipt will be generated',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context, null),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.black87,
                              side: BorderSide(color: Colors.grey.shade300),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text("Cancel"),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed:
                                (paymentMode == 'Cash' &&
                                    cashReceived < totalDue)
                                ? null
                                : () => Navigator.pop(context, {
                                    'confirmed': true,
                                    'paymentMode': paymentMode,
                                    'cashReceived': paymentMode == 'Cash'
                                        ? cashReceived
                                        : totalDue,
                                    'change': paymentMode == 'Cash'
                                        ? (cashReceived - totalDue)
                                        : 0.0,
                                  }),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              disabledBackgroundColor: Colors.green.shade200,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              elevation: 0,
                            ),
                            child: const Text(
                              "Confirm",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

   String _fmtReceiptDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    final hr = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final min = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} $hr:$min $ampm';
  }

  void _showReceiptDialog(
    CustomerOrder o, {
    String? paymentMode,
    double? cashReceived,
    double? change,
    DateTime? orderedAt,
    DateTime? completedAt,
  }) {
    double subtotal = 0;
    List<Widget> itemRows = [];

    for (var item in o.items) {
      double price = 0;
      String unit = 'pcs';
      try {
        final dbItem = widget.controller.allItems.firstWhere(
          (i) => i.id == item.productId,
        );
        price = dbItem.price;
        unit = dbItem.unit;
      } catch (_) {}

      double itemTotal = price * item.quantity;
      subtotal += itemTotal;

      String qtyStr = item.quantity.truncateToDouble() == item.quantity
          ? item.quantity.toInt().toString()
          : item.quantity.toStringAsFixed(2);

      itemRows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.productName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      '$qtyStr $unit x ₱${price.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Text(
                '₱${itemTotal.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    String cashierName = widget.controller.currentUserName ?? "Admin";

    final DateTime completedTime = completedAt ?? DateTime.now();
    final String completedStr = _fmtReceiptDate(completedTime);
    final String? orderedStr =
        (orderedAt != null &&
            orderedAt.difference(completedTime).inMinutes.abs() >= 1)
        ? _fmtReceiptDate(orderedAt)
        : null;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min, // Wraps content tightly
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.check,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Order Completed',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    Text(
                      'Transaction #${o.id.substring(0, 8).toUpperCase()}',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              // Body
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'INVENTORY PLUS',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'SPRJ Paint Center - San Pedro, Laguna',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const _DashedDivider(),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Order #',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              o.id.substring(0, 8).toUpperCase(),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                                                if (orderedStr != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Ordered',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 11,
                                ),
                              ),
                              Text(
                                orderedStr,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Completed',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              completedStr,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Cashier',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              cashierName,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const _DashedDivider(),
                        const SizedBox(height: 16),
                        ...itemRows,
                        const SizedBox(height: 16),
                        const _DashedDivider(),
                        const SizedBox(height: 16),

                        // Exact ordered requested layout for total metrics
                        if (paymentMode == 'Cash' && cashReceived != null) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Cash Given',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                '₱${cashReceived.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                        ],

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Subtotal',
                              style: TextStyle(fontSize: 12),
                            ),
                            Text(
                              '₱${subtotal.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),

                        if (o.discountAmount > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Discount',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                '-₱${o.discountAmount.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],

                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'TOTAL',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              '₱${o.totalAmount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),

                        if (paymentMode == 'Cash' && change != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Change',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green,
                                ),
                              ),
                              Text(
                                '₱${change.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: Colors.green,
                                ),
                              ),
                            ],
                          ),
                        ],

                        if (paymentMode != null) ...[
                          const SizedBox(height: 16),
                          const _DashedDivider(),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Mode of Payment',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 11,
                                ),
                              ),
                              Text(
                                paymentMode,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],

                        const SizedBox(height: 24),
                        Text(
                          'Thank you for your purchase!',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        Text(
                          'This serves as your official receipt.',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Footer buttons - Stay pinned to the bottom
              Padding(
                padding: const EdgeInsets.only(
                  left: 24,
                  right: 24,
                  bottom: 24,
                  top: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showQRModal(
                            o.id,
                            paymentMode: paymentMode,
                            cashReceived: cashReceived,
                            change: change,
                          );
                        },
                        icon: const Icon(
                          LucideIcons.qrCode,
                          color: Colors.white,
                          size: 16,
                        ),
                        label: const Text(
                          'QR Receipt',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F172A),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.black87,
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text(
                          'Done',
                          style: TextStyle(fontWeight: FontWeight.bold),
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
  }


  void _showQRModal(
    String orderId, {
    String? paymentMode,
    double? cashReceived,
    double? change,
  }) {
    String publicReceiptUrl =
        "https://inventoryplusreceipt.netlify.app/?id=$orderId";

    // Append payment parameters so the digital receipt can display them too
    if (paymentMode != null) {
      publicReceiptUrl += "&mode=${Uri.encodeComponent(paymentMode)}";
    }
    if (cashReceived != null && cashReceived > 0) {
      publicReceiptUrl += "&cash=${cashReceived.toStringAsFixed(2)}";
    }
    if (change != null && change > 0) {
      publicReceiptUrl += "&change=${change.toStringAsFixed(2)}";
    }

    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Scan Digital Receipt",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // Warning Banner
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFEEBA)),
                ),
                child: const Text(
                  "⚠️ This receipt will expire in 48 hours. Ask customer to screenshot.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF856404),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // QR Code Generator
              QrImageView(
                data: publicReceiptUrl,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
              ),

              const SizedBox(height: 16),
              Text(
                "Order #${orderId.substring(0, 8).toUpperCase()}",
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    "Close",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPendingOrdersModal(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: Colors.white,
          child: Container(
            width: 480,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Pending Orders',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            LucideIcons.x,
                            size: 18,
                            color: Colors.grey,
                          ),
                          onPressed: () => Navigator.pop(dialogContext),
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: StreamBuilder<List<CustomerOrder>>(
                    stream: widget.controller.streamOrders(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Colors.orange,
                          ),
                        );
                      }
                      final pendingOrders = snapshot.data!
                          .where(
                            (o) =>
                                o.status == 'prepared' || o.status == 'pending',
                          )
                          .toList();

                      if (pendingOrders.isEmpty) {
                        return const Center(
                          child: Text(
                            'No pending orders.',
                            style: TextStyle(color: Colors.grey, fontSize: 15),
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.all(20),
                        itemCount: pendingOrders.length,
                        itemBuilder: (context, index) {
                          final o = pendingOrders[index];
                          final isReady = o.status == 'prepared';
                          final mainColor = isReady
                              ? Colors.green
                              : Colors.orange;
                          final bgColor = isReady
                              ? Colors.green.shade50
                              : Colors.orange.shade50;
                          final iconData = isReady
                              ? LucideIcons.check
                              : LucideIcons.clock;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade200),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.03),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Container(width: 6, color: mainColor),
                                  Expanded(
                                    child: Theme(
                                      data: Theme.of(context).copyWith(
                                        dividerColor: Colors.transparent,
                                      ),
                                      child: ExpansionTile(
                                        tilePadding: const EdgeInsets.only(
                                          left: 12,
                                          right: 16,
                                          top: 4,
                                          bottom: 4,
                                        ),
                                        leading: Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: bgColor,
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            iconData,
                                            color: mainColor,
                                            size: 16,
                                          ),
                                        ),
                                        title: Text(
                                          'Order #${o.id.substring(0, 8)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                        subtitle: Text(
                                          isReady
                                              ? "Ready for Pickup"
                                              : "Being Prepared",
                                          style: TextStyle(
                                            color: mainColor,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        trailing: SizedBox(
                                          width: 70,
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              Text(
                                                '${o.items.length} item${o.items.length == 1 ? '' : 's'}',
                                                style: TextStyle(
                                                  color: Colors.grey.shade600,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Icon(
                                                Icons.arrow_drop_down,
                                                color: Colors.grey.shade400,
                                                size: 20,
                                              ),
                                            ],
                                          ),
                                        ),
                                        childrenPadding: const EdgeInsets.only(
                                          left: 16,
                                          right: 16,
                                          bottom: 16,
                                        ),
                                        children: [
                                          ...o.items.map(
                                            (item) => Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 6.0,
                                                  ),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      item.productName,
                                                      style: const TextStyle(
                                                        fontSize: 13,
                                                        color: Color(
                                                          0xFF0F172A,
                                                        ),
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  Text(
                                                    'Qty: ${item.quantity.truncateToDouble() == item.quantity ? item.quantity.toInt() : item.quantity}',
                                                    style: const TextStyle(
                                                      fontSize: 13,
                                                      color: Color(0xFF0F172A),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (isReady) ...[
                                            const SizedBox(height: 16),
                                            SizedBox(
                                              width: double.infinity,
                                              height: 44,
                                              child: ElevatedButton.icon(
                                                icon: const Icon(
                                                  LucideIcons.check,
                                                  color: Colors.white,
                                                  size: 18,
                                                ),
                                                label: const Text(
                                                  'Complete Transaction',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.green,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  elevation: 0,
                                                ),
                                                onPressed: () =>
                                                    _completeOrderFlow(
                                                      o,
                                                      onCompleted: () {
                                                        if (dialogContext
                                                            .mounted)
                                                          Navigator.pop(
                                                            dialogContext,
                                                          );
                                                      },
                                                    ),
                                              ),
                                            ),
                                          ],
                                                                                    const SizedBox(height: 10),
                                          SizedBox(
                                            width: double.infinity,
                                            height: 40,
                                            child: OutlinedButton.icon(
                                              icon: Icon(
                                                LucideIcons.undo2,
                                                size: 16,
                                                color: Colors.red.shade400,
                                              ),
                                              label: Text(
                                                'Cancel & Edit',
                                                style: TextStyle(
                                                  color: Colors.red.shade400,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                side: BorderSide(
                                                  color: Colors.red.shade100,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                              ),
                                              onPressed: () async {
                                                final ok =
                                                    await _cancelOrderAndRestoreCart(
                                                      o,
                                                      fromQueue: true,
                                                    );
                                                if (ok &&
                                                    dialogContext.mounted) {
                                                  Navigator.pop(dialogContext);
                                                }
                                              },
                                            ),
                                          ),
                                        ],
                                      ),

                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
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

  Widget _buildImage(String imageUrl) {
    if (imageUrl.isEmpty) {
      return Container(
        color: Colors.grey.shade100,
        child: const Center(
          child: Icon(LucideIcons.image, color: Colors.grey, size: 40),
        ),
      );
    }
    if (kIsWeb || imageUrl.startsWith('http')) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: Colors.grey.shade100,
          child: const Center(
            child: Icon(LucideIcons.image, color: Colors.grey),
          ),
        ),
      );
    } else {
      return Image.file(
        File(imageUrl),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: Colors.grey.shade100,
          child: const Center(
            child: Icon(LucideIcons.image, color: Colors.grey),
          ),
        ),
      );
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 800;
          _isGridView ??= isDesktop;

          if (isDesktop) {
            return Row(
              children: [
                Expanded(flex: 2, child: _buildItemList()),
                const VerticalDivider(width: 1, color: Colors.grey),
                Expanded(flex: 1, child: _buildCartPanel()),
              ],
            );
          }

          final bottomInset = MediaQuery.of(context).padding.bottom;
          final totalHeight = constraints.maxHeight;
          final maxCartHeight = (totalHeight - 56 - bottomInset).clamp(
            0.0,
            totalHeight * _kSnapFull,
          );
          final minCartHeight = (_kBaseChromeHeight + bottomInset).clamp(
            0.0,
            maxCartHeight,
          );
          final cartHeight = (totalHeight * _cartHeightFraction).clamp(
            minCartHeight,
            maxCartHeight,
          );

          return Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(bottom: cartHeight),
                  child: _buildItemList(),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: cartHeight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bottomInset),
                    child: _DraggableCartSheet(
                      onDragStart: (details) {
                        _snapAnim.stop();
                        _dragStart = details.globalPosition.dy;
                        _fractionAtDragStart = cartHeight / totalHeight;
                      },
                      onDragUpdate: (details) {
                        final delta = _dragStart - details.globalPosition.dy;
                        final newFraction =
                            _fractionAtDragStart + delta / totalHeight;
                        setState(() {
                          _cartHeightFraction = newFraction.clamp(
                            minCartHeight / totalHeight,
                            maxCartHeight / totalHeight,
                          );
                        });
                      },
                      onDragEnd: _onDragEnd,
                      child: _buildCartPanel(),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Item list ──────────────────────────────────────────────────────────────
  Widget _buildItemList() {
    final categories = [
      'All',
      ...widget.controller.getUniqueCategories().where(
        (c) => c.toLowerCase() != 'unassigned' && c.toLowerCase() != 'all',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: 16.0,
            right: 16.0,
            top: 16.0,
            bottom: 8.0,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search items...',
                    prefixIcon: const Icon(Icons.search, color: Colors.grey),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 0,
                      horizontal: 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val),
                ),
              ),
              const SizedBox(width: 12),
              StreamBuilder<List<CustomerOrder>>(
                stream: widget.controller.streamOrders(),
                builder: (context, snapshot) {
                  final pendingCount = snapshot.hasData
                      ? snapshot.data!
                            .where(
                              (o) =>
                                  o.status == 'prepared' ||
                                  o.status == 'pending',
                            )
                            .length
                      : 0;

                  return OutlinedButton.icon(
                    onPressed: () => _showPendingOrdersModal(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: BorderSide(color: Colors.orange.shade200),
                      backgroundColor: Colors.orange.shade50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                    icon: const Icon(LucideIcons.clock, size: 16),
                    label: Row(
                      children: [
                        const Text(
                          "Pending Orders",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (pendingCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: Colors.orange,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$pendingCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => setState(() => _isGridView = false),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: !_isGridView!
                              ? Colors.grey.shade100
                              : Colors.white,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(8),
                          ),
                        ),
                        child: Icon(
                          LucideIcons.list,
                          size: 18,
                          color: !_isGridView! ? Colors.black : Colors.grey,
                        ),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 24,
                      color: Colors.grey.shade300,
                    ),
                    InkWell(
                      onTap: () => setState(() => _isGridView = true),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: _isGridView!
                              ? Colors.grey.shade100
                              : Colors.white,
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(8),
                          ),
                        ),
                        child: Icon(
                          LucideIcons.layoutGrid,
                          size: 18,
                          color: _isGridView! ? Colors.black : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  icon: const Icon(LucideIcons.scanLine, color: Colors.white),
                  onPressed: _openAIObjectScanner,
                ),
              ),
            ],
            
          ),
        ),
        SizedBox(
          height: 50,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = _selectedCategory == cat;
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: InkWell(
                  onTap: () => setState(() => _selectedCategory = cat),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF0F172A)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Center(
                      child: Text(
                        cat,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : Colors.grey.shade600,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _isGridView!
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    int crossAxisCount = constraints.maxWidth > 800
                        ? 4
                        : (constraints.maxWidth > 600 ? 3 : 2);
                    return GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.70,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                      ),
                      itemCount: _filteredItems.length,
                      itemBuilder: (context, index) {
                        final item = _filteredItems[index];
                        final cartQty = _cart[item.id] ?? 0;
                        final availableStock = item.quantity - cartQty;

                        return Card(
                          elevation: 0,
                          color: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(12),
                                  ),
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: _buildImage(item.imageUrl),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                        color: Color(0xFF0F172A),
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        "Stock: ${availableStock.toStringAsFixed(availableStock.truncateToDouble() == availableStock ? 0 : 2)}${item.unit}",
                                        style: TextStyle(
                                          color: Colors.green.shade700,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          "₱${item.price.toStringAsFixed(2)}",
                                          style: const TextStyle(
                                            color: Colors.orange,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        InkWell(
                                          onTap: availableStock > 0
                                              ? () => _addToCart(item)
                                              : null,
                                          child: Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: availableStock > 0
                                                  ? Colors.orange
                                                  : Colors.grey.shade300,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: const Icon(
                                              Icons.add,
                                              color: Colors.white,
                                              size: 20,
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
                        );
                      },
                    );
                  },
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _filteredItems.length,
                  itemBuilder: (context, index) {
                    final item = _filteredItems[index];
                    final cartQty = _cart[item.id] ?? 0;
                    final availableStock = item.quantity - cartQty;

                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(12),
                            ),
                            child: SizedBox(
                              width: 100,
                              height: 100,
                              child: _buildImage(item.imageUrl),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                      color: Color(0xFF0F172A),
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade50,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      "Stock: ${availableStock.toStringAsFixed(availableStock.truncateToDouble() == availableStock ? 0 : 2)}${item.unit}",
                                      style: TextStyle(
                                        color: Colors.green.shade700,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  "₱${item.price.toStringAsFixed(2)}",
                                  style: const TextStyle(
                                    color: Colors.orange,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                InkWell(
                                  onTap: availableStock > 0
                                      ? () => _addToCart(item)
                                      : null,
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: availableStock > 0
                                          ? Colors.orange
                                          : Colors.grey.shade300,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      Icons.add,
                                      color: Colors.white,
                                      size: 20,
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
        ),
      ],
    );
  }

  // ── Cart panel ─────────────────────────────────────────────────────────────
  Widget _buildCartPanel() {
    int distinctItems = _cart.length;
    double totalQty = _cart.values.fold(0.0, (sum, val) => sum + val);
    String qtyDisplay = totalQty.truncateToDouble() == totalQty
        ? totalQty.toInt().toString()
        : totalQty.toStringAsFixed(2);

    double subtotal = _calculateTotal();
    double discountAmt = _isDiscountPercentage
        ? (subtotal * (_discountValue / 100))
        : _discountValue;
    if (discountAmt > subtotal) discountAmt = subtotal; // Cap discount
    double totalDue = subtotal - discountAmt;

    return ClipRect(
      child: Container(
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              color: Colors.orange,
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        LucideIcons.shoppingCart,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Current Order Cart',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$distinctItems items',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              LucideIcons.packageCheck,
                              size: 12,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$qtyDisplay qty',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final availH = constraints.maxHeight;
                  if (availH <= 0) return const SizedBox.shrink();
                  final opacity = (availH / 60.0).clamp(0.0, 1.0);

                  return AnimatedOpacity(
                    opacity: opacity,
                    duration: const Duration(milliseconds: 80),
                    child: ClipRect(
                      child: _cart.isEmpty
                          ? const Center(
                              child: Text(
                                'Cart is empty',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 16,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              itemCount: _cart.length,
                              itemBuilder: (context, index) {
                                final itemId = _cart.keys.elementAt(index);
                                final qty = _cart[itemId]!;
                                InventoryItem item;
                                try {
                                  item = widget.controller.allItems.firstWhere(
                                    (i) => i.id == itemId,
                                  );
                                } catch (_) {
                                  return const SizedBox.shrink();
                                }

                                bool isFractional = ![
                                  'pcs',
                                  'box',
                                  'pack',
                                  '',
                                ].contains(item.unit.toLowerCase());

                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 6,
                                  ),
                                  color: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Wrap(
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                spacing: 6,
                                                children: [
                                                  Text(
                                                    item.name,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 14,
                                                      color: Color(0xFF0F172A),
                                                    ),
                                                  ),
                                                  if (isFractional)
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 4,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors
                                                            .orange
                                                            .shade50,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              4,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        "BY WEIGHT",
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Colors
                                                              .orange
                                                              .shade800,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            Text(
                                              "₱${(item.price * qty).toStringAsFixed(2)}",
                                              style: const TextStyle(
                                                color: Colors.orange,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Text(
                                              "₱${item.price.toStringAsFixed(2)} / ${item.unit}",
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey.shade500,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            _QuantityStepper(
                                              initialValue: qty,
                                              unit: item.unit,
                                              onChanged: (newQty) =>
                                                  _setCartQuantity(
                                                    itemId,
                                                    newQty,
                                                  ),
                                            ),
                                            IconButton(
                                              icon: Icon(
                                                LucideIcons.trash2,
                                                color: Colors.red.shade400,
                                                size: 18,
                                              ),
                                              onPressed: () =>
                                                  _setCartQuantity(itemId, 0),
                                              constraints:
                                                  const BoxConstraints(),
                                              padding: const EdgeInsets.all(8),
                                              style: IconButton.styleFrom(
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  side: BorderSide(
                                                    color: Colors.red.shade100,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  );
                },
              ),
            ),

            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  if (_discountValue > 0) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade100),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isDiscountPercentage
                                      ? "${_discountValue.toStringAsFixed(_discountValue.truncateToDouble() == _discountValue ? 0 : 2)}% ${_discountReason.isEmpty ? 'Discount' : _discountReason}"
                                      : "₱${_discountValue.toStringAsFixed(_discountValue.truncateToDouble() == _discountValue ? 0 : 2)} ${_discountReason.isEmpty ? 'Discount' : _discountReason}",
                                  style: const TextStyle(
                                    color: Colors.orange,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  "Applied to subtotal",
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            "-₱${discountAmt.toStringAsFixed(2)}",
                            style: const TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 12),
                          InkWell(
                            onTap: () {
                              setState(() {
                                _discountValue = 0.0;
                                _discountReason = '';
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: Colors.orange.shade100,
                                ),
                              ),
                              child: const Icon(
                                LucideIcons.x,
                                size: 14,
                                color: Colors.orange,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else ...[
                    GestureDetector(
                      onTap: () => _showDiscountDialog(context),
                      child: CustomPaint(
                        painter: _DashedRectPainter(
                          color: Colors.grey.shade300,
                          strokeWidth: 1.5,
                          gap: 5.0,
                        ),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 16,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    LucideIcons.plus,
                                    size: 14,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    "Add Discount",
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              Icon(
                                LucideIcons.chevronRight,
                                size: 16,
                                color: Colors.grey.shade500,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Subtotal",
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        "₱${subtotal.toStringAsFixed(2)}",
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  if (_discountValue > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Discount",
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          "-₱${discountAmt.toStringAsFixed(2)}",
                          style: const TextStyle(
                            color: Colors.orange,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  const _DashedDivider(),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Total Due",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        "₱${totalDue.toStringAsFixed(2)}",
                        style: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _HandlingToggle(
                    packMyself: _soloMode,
                    enabled: !_isProcessingCart,
                    onChanged: (v) => setState(() => _soloMode = v),
                  ),
                  const SizedBox(height: 12),
                  
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _cart.isEmpty || _isProcessingCart 
                          ? null
                          : _processOrder,
                      icon: _isProcessingCart
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(
                              LucideIcons.check,
                              color: Colors.white,
                              size: 20,
                            ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        disabledBackgroundColor: Colors.grey.shade300,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
                      ),
                      label: Text(
                        _isProcessingCart
                            ? 'Processing...'
                            : (_soloMode ? 'Process & Pack' : 'Send to Helper'),
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashed Divider Widget
// ─────────────────────────────────────────────────────────────────────────────
class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.constrainWidth();
        const dashWidth = 5.0;
        const dashHeight = 1.0;
        final dashCount = (boxWidth / (2 * dashWidth)).floor();
        return Flex(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          direction: Axis.horizontal,
          children: List.generate(dashCount, (_) {
            return SizedBox(
              width: dashWidth,
              height: dashHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.grey.shade300),
              ),
            );
          }),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashed Border Container Painter
// ─────────────────────────────────────────────────────────────────────────────
class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;

  _DashedRectPainter({
    this.color = Colors.black,
    this.strokeWidth = 1.0,
    this.gap = 5.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(8),
        ),
      );

    final Path dashPath = Path();
    double distance = 0.0;
    for (PathMetric pathMetric in path.computeMetrics()) {
      while (distance < pathMetric.length) {
        dashPath.addPath(
          pathMetric.extractPath(distance, distance + gap),
          Offset.zero,
        );
        distance += gap * 2;
      }
      distance = 0.0;
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Draggable sheet wrapper
// ─────────────────────────────────────────────────────────────────────────────
class _DraggableCartSheet extends StatelessWidget {
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final Widget child;

  const _DraggableCartSheet({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 16,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      shadowColor: Colors.black26,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: onDragStart,
              onVerticalDragUpdate: onDragUpdate,
              onVerticalDragEnd: onDragEnd,
              child: Container(
                width: double.infinity,
                color: const Color(0xFFF5F5F5),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quantity stepper matching the image design
// ─────────────────────────────────────────────────────────────────────────────
class _QuantityStepper extends StatefulWidget {
  final double initialValue;
  final String unit;
  final ValueChanged<double> onChanged;

  const _QuantityStepper({
    required this.initialValue,
    required this.unit,
    required this.onChanged,
  });

  @override
  State<_QuantityStepper> createState() => _QuantityStepperState();
}

class _QuantityStepperState extends State<_QuantityStepper> {
  late TextEditingController _controller;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _formatDisplay(widget.initialValue),
    );
  }

  @override
  void didUpdateWidget(covariant _QuantityStepper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue && !_isFocused) {
      _controller.text = _formatDisplay(widget.initialValue);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isSolidItem() {
    final u = widget.unit.toLowerCase();
    return u == 'pcs' || u == 'box' || u == 'pack' || u == '';
  }

  String _formatDisplay(double val) {
    if (_isSolidItem()) return val.toInt().toString();
    return val.truncateToDouble() == val
        ? val.toInt().toString()
        : val
              .toString()
              .replaceAll(RegExp(r'0*$'), '')
              .replaceAll(RegExp(r'\.$'), '');
  }

  void _submit() {
    final val = double.tryParse(_controller.text);
    if (val != null && val > 0) {
      widget.onChanged(_isSolidItem() ? val.truncateToDouble() : val);
    } else {
      _controller.text = _formatDisplay(widget.initialValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSolid = _isSolidItem();
    final step = isSolid ? 1.0 : 0.25;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () {
              if (widget.initialValue > step) {
                widget.onChanged(widget.initialValue - step);
              }
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Icon(Icons.remove, size: 16, color: Colors.black),
            ),
          ),
          SizedBox(
            width: 40,
            child: Focus(
              onFocusChange: (hasFocus) {
                setState(() => _isFocused = hasFocus);
                if (!hasFocus) _submit();
              },
              child: TextField(
                controller: _controller,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
                keyboardType: TextInputType.numberWithOptions(
                  decimal: !isSolid,
                ),
                inputFormatters: isSolid
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d*'),
                        ),
                      ],
                onChanged: (val) {
                  final parsed = double.tryParse(val);
                  if (parsed != null && parsed > 0) {
                    widget.onChanged(
                      isSolid ? parsed.truncateToDouble() : parsed,
                    );
                  }
                },
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          if (!isSolid) ...[
            Text(
              widget.unit,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
          ],
          InkWell(
            onTap: () => widget.onChanged(widget.initialValue + step),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Icon(Icons.add, size: 16, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandlingToggle extends StatelessWidget {
  final bool packMyself;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _HandlingToggle({
    required this.packMyself,
    required this.enabled,
    required this.onChanged,
  });

  static const _dur = Duration(milliseconds: 220);

  Widget _label(String text, IconData icon, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Center(
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(
              end: selected ? Colors.orange : Colors.grey.shade600,
            ),
            duration: _dur,
            builder: (context, color, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: _dur,
            curve: Curves.easeOutCubic,
            alignment: packMyself
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1.0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              _label(
                "Helper packs",
                LucideIcons.users,
                !packMyself,
                () => onChanged(false),
              ),
              _label(
                "I'll pack it",
                LucideIcons.zap,
                packMyself,
                () => onChanged(true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
