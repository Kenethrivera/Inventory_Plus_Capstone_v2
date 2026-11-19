import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:inventory_plus/ui/widgets/qr_scanner.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import '../data/inventory.dart'; 
import '../logic/inventory_controller.dart';

class ScannerSearchPage extends StatefulWidget {
  final InventoryController controller; 
  final Function(InventoryItem) onSelectItem;

  const ScannerSearchPage({
    super.key,
    required this.controller,
    required this.onSelectItem,
  });

  @override
  State<ScannerSearchPage> createState() => _ScannerSearchPageState();
}

class _ScannerSearchPageState extends State<ScannerSearchPage> {
  bool _isScanning = true;


  void _handleRealScan(String scannedValue) async {
    if (!_isScanning) return;
    setState(() => _isScanning = false);

    try {
      final cleanValue = scannedValue.trim();

      final foundItem = widget.controller.allItems.firstWhere(
        (item) => item.sku == cleanValue || item.id == cleanValue,
      );
      // If an item is found, immediately use the callback.
      widget.onSelectItem(foundItem);
    } catch (_) {
      // If firstWhere throws, no item was found. Show an error and reset.
      if (!mounted) return;
      AppToast.error(context, 'No inventory item matches this code.');
      // Keep detection paused while the user reads the error toast.
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _isScanning = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            // SIMPLIFIED: Always show the QR Scanner. The result view is no longer needed.
            child: QRScanner(
              key: ValueKey(_isScanning), // Ensures scanner restarts correctly
              onScan: _handleRealScan,
              isScanning: _isScanning,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeader(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.only(top: 40, bottom: 20, left: 16, right: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF0F172A),
            const Color(0xFF0F172A).withOpacity(0.8),
            Colors.transparent,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // UPDATED: Placed the Title and the new Object Scanner Button in a Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  IconButton(
                    icon:
                        const Icon(LucideIcons.chevronLeft, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    "Hardware Inventory",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

}
