import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../data/inventory.dart';
import '../../logic/inventory_controller.dart';

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

class ItemCard extends StatelessWidget {
  final InventoryItem item;
  final InventoryController controller;
  final Function(InventoryItem) onClick;

  const ItemCard({
    super.key,
    required this.item,
    required this.controller,
    required this.onClick,
  });

  Color _statusColor(StockStatus status) {
    switch (status) {
      case StockStatus.ok:
        return Colors.grey.shade600;
      case StockStatus.low:
        return Colors.orange; // Kept orange for semantic low-stock warning
      case StockStatus.critical:
      case StockStatus.out:
        return Colors.red; // Kept red for semantic out-of-stock warning
    }
  }

  String? _statusLabel(StockStatus status) {
    switch (status) {
      case StockStatus.ok:
        return null;
      case StockStatus.low:
        return 'LOW STOCK';
      case StockStatus.critical:
        return 'CRITICAL';
      case StockStatus.out:
        return 'OUT OF STOCK';
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = controller.stockStatusFor(item);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () => onClick(item),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade100),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildImage(status),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildNameAndPrice(),
                    const SizedBox(height: 8),
                    _buildStockAndLocation(status),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNameAndPrice() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                item.name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  fontFamily: _fontFam,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '₱${item.price.toStringAsFixed(2)}',
              style: const TextStyle(
                color: _primaryBlue,
                fontWeight: FontWeight.bold,
                fontSize: 14,
                fontFamily: _fontFam,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          item.sku,
          style: TextStyle(
            color: Colors.grey.shade500, 
            fontSize: 12,
            fontFamily: _fontFam,
          ),
        ),
      ],
    );
  }

  Widget _buildStockAndLocation(StockStatus status) {
    final isAlert = status != StockStatus.ok;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              const Icon(LucideIcons.package, size: 12),
              const SizedBox(width: 4),
              Text(
                "${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)}${item.unit}",
                style: TextStyle(
                  fontSize: 12,
                  color: _statusColor(status),
                  fontWeight: isAlert ? FontWeight.w600 : FontWeight.normal,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImage(StockStatus status) {
    final label = _statusLabel(status);

    return Stack(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              item.imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.image_not_supported, color: Colors.grey),
            ),
          ),
        ),
        if (label != null)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: _statusColor(status),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  fontFamily: _fontFam,
                ),
              ),
            ),
          ),
      ],
    );
  }
}