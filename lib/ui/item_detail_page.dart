// ui/item_detail_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../data/inventory.dart';
import '../../logic/inventory_controller.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:inventory_plus/ui/widgets/app_toast.dart';
import 'package:inventory_plus/ui/widgets/app_dialog.dart';
import 'store_map.dart'; // Adjust the path if necessary depending on your folder structure

const Color _primaryBlue = Color(0xFF2563EB);
const String _fontFam = 'Hellix';

class ItemDetailPage extends StatefulWidget {
  final InventoryItem item;
  final InventoryController controller;
  final VoidCallback onBack;
  final Future<void> Function(InventoryItem) onUpdate;
  final FutureOr<void> Function(String) onDelete;
  final VoidCallback? onStatusChanged;

  const ItemDetailPage({
    super.key,
    required this.item,
    required this.controller,
    required this.onBack,
    required this.onUpdate,
    required this.onDelete,
    this.onStatusChanged,
  });

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late InventoryItem _currentItem;
  List<Map<String, dynamic>> _transactionHistory = [];
  bool _isLoadingHistory = true;

  bool _isEditing = false;
  bool isReadOnly = false;

  bool _isSaving = false;
  bool get _isDisabled => widget.controller.isDisabled(_currentItem.id);
  
  String? _newImageUrl;
  XFile? _selectedImage;
  final ImagePicker _picker = ImagePicker();

  late TextEditingController _nameController;
  late TextEditingController _priceController;
  late TextEditingController _stockController;
  late TextEditingController _skuController;
  late TextEditingController _descController;
  late TextEditingController _manufacturerController;
  late TextEditingController _modelController;
  late TextEditingController _sizeController;

  Color _statusColor(StockStatus status) {
    switch (status) {
      case StockStatus.ok:
        return _primaryBlue;
      case StockStatus.low:
        return Colors.orange;
      case StockStatus.critical:
      case StockStatus.out:
        return Colors.red;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    _initControllers();
    _loadHistory();
  }

  Future<void> _showRestockDialog() async {
    final qtyCtrl = TextEditingController();
    final unit = _currentItem.unit;
    final allowDecimals = const {
      'kg',
      'g',
      'l',
      'ml',
    }.contains(unit.toLowerCase());
    bool saving = false;
    bool touched = false;
    String? error;

    String? validate(String text) {
      final t = text.trim();
      if (t.isEmpty) return 'Enter the quantity received';
      final v = double.tryParse(t);
      if (v == null) return 'Enter a valid number';
      if (v <= 0) return 'Must be greater than 0';
      return null;
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final value = double.tryParse(qtyCtrl.text.trim());
          final newQty = (value != null && value > 0)
              ? _currentItem.quantity + value
              : null;

          Future<void> submit() async {
            touched = true;
            final err = validate(qtyCtrl.text);
            if (err != null) {
              setDialogState(() => error = err);
              return;
            }
            setDialogState(() {
              error = null;
              saving = true;
            });
            try {
              final qty = double.parse(qtyCtrl.text.trim());
              final updated = _currentItem.copyWith(
                quantity: _currentItem.quantity + qty,
              );
              await widget.onUpdate(updated);
              if (!mounted) return;
              setState(() {
                _currentItem = updated;
                _stockController.text = updated.quantity.toString();
              });
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              _toast(
                'Restocked ${_currentItem.name}: +${_fmt(qty)} $unit '
                '(now ${_fmt(updated.quantity)})',
              );
              _loadHistory();
            } catch (e) {
              if (dialogContext.mounted) setDialogState(() => saving = false);
              _toast('Restock failed: $e', isError: true);
            }
          }

          void addChip(int n) {
            final next = (double.tryParse(qtyCtrl.text.trim()) ?? 0) + n;
            final text = _fmt(next);
            qtyCtrl.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
            setDialogState(() {
              if (touched) error = validate(text);
            });
          }

          OutlineInputBorder border(Color c, [double w = 1]) =>
              OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c, width: w),
              );

          return AppDialog(
            icon: LucideIcons.packagePlus,
            color: _primaryBlue,
            title: 'Restock',
            subtitle: _currentItem.name,
            actions: [
              OutlinedButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.grey.shade300),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Cancel', style: TextStyle(fontFamily: _fontFam)),
              ),
              ElevatedButton(
                onPressed: saving ? null : submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primaryBlue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Add stock',
                        style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
                      ),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Current -> New summary
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _stockSummary(
                          'CURRENT',
                          '${_fmt(_currentItem.quantity)} $unit',
                          const Color(0xFF0F172A),
                        ),
                      ),
                      Icon(
                        LucideIcons.arrowRight,
                        size: 18,
                        color: Colors.grey.shade400,
                      ),
                      Expanded(
                        child: _stockSummary(
                          'NEW',
                          newQty == null ? '—' : '${_fmt(newQty)} $unit',
                          newQty == null ? Colors.grey : _primaryBlue,
                          alignEnd: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Quantity received',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFamily: _fontFam),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons.alertCircle,
                          size: 13,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            error!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: _fontFam,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: qtyCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: allowDecimals,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(allowDecimals ? r'[0-9.]' : r'[0-9]'),
                    ),
                  ],
                  onChanged: (text) => setDialogState(() {
                    if (touched) error = validate(text);
                  }),
                  onSubmitted: (_) => saving ? null : submit(),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFamily: _fontFam,
                  ),
                  decoration: InputDecoration(
                    hintText: '0',
                    hintStyle: const TextStyle(fontFamily: _fontFam),
                    suffixText: unit,
                    suffixStyle: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                      fontFamily: _fontFam,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    enabledBorder: border(
                      error != null ? Colors.red : Colors.grey.shade300,
                    ),
                    focusedBorder: border(
                      error != null ? Colors.red : _primaryBlue,
                      1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [1, 5, 10, 50]
                      .map(
                        (n) => ActionChip(
                          label: Text('+$n'),
                          labelStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFamily: _fontFam,
                          ),
                          backgroundColor: _primaryBlue.withOpacity(0.1),
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          onPressed: saving ? null : () => addChip(n),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          );
        },
      ),
    );

    qtyCtrl.dispose();
  }

  Widget _stockSummary(
    String label,
    String value,
    Color color, {
    bool alignEnd = false,
  }) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Colors.grey.shade500,
            fontFamily: _fontFam,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: color,
            fontFamily: _fontFam,
          ),
        ),
      ],
    );
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() => _isLoadingHistory = true);
    final history = await widget.controller.fetchTransactionHistory(
      _currentItem.id,
    );
    if (mounted) {
      setState(() {
        _transactionHistory = history;
        _isLoadingHistory = false;
      });
    }
  }

  void _initControllers() {
    _nameController = TextEditingController(text: _currentItem.name);
    _priceController = TextEditingController(
      text: _currentItem.price.toString(),
    );
    _stockController = TextEditingController(
      text: _currentItem.quantity.toString(),
    );
    _skuController = TextEditingController(text: _currentItem.sku);
    _descController = TextEditingController(text: _currentItem.description);

    _manufacturerController = TextEditingController(
      text: _currentItem.manufacturer ?? "",
    );
    _modelController = TextEditingController(text: _currentItem.model ?? "");
    _sizeController = TextEditingController(
      text: _currentItem.productSize ?? "",
    );
  }

  @override
  void didUpdateWidget(ItemDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item != widget.item) {
      _currentItem = widget.item;
      _initControllers(); 
      _loadHistory();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    _skuController.dispose();
    _descController.dispose();
    _manufacturerController.dispose();
    _modelController.dispose();
    _sizeController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (!_isEditing) return;

    // Camera only makes sense on phones/tablets, not web or desktop.
    final bool cameraAvailable =
        !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final bool hasImage = (_newImageUrl ?? _currentItem.imageUrl).isNotEmpty;

    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.imagePlus,
        color: _primaryBlue,
        title: "Product Photo",
        subtitle: "Choose how to change the image",
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (cameraAvailable) ...[
              _buildSourceOption(
                icon: LucideIcons.camera,
                title: "Take Photo",
                description: "Use your device camera",
                onTap: () => Navigator.pop(dialogContext, 'camera'),
              ),
              const SizedBox(height: 10),
            ],
            _buildSourceOption(
              icon: LucideIcons.image,
              title: "Choose from Gallery",
              description: "Pick an existing photo",
              onTap: () => Navigator.pop(dialogContext, 'gallery'),
            ),
            const SizedBox(height: 10),
            _buildSourceOption(
              icon: LucideIcons.link,
              title: "Enter Image URL",
              description: "Use an image hosted online",
              onTap: () => Navigator.pop(dialogContext, 'url'),
            ),
            if (hasImage) ...[
              const SizedBox(height: 10),
              _buildSourceOption(
                icon: LucideIcons.trash2,
                title: "Remove Photo",
                description: "Clear the current image",
                color: Colors.red.shade600,
                onTap: () => Navigator.pop(dialogContext, 'remove'),
              ),
            ],
          ],
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
          ),
        ],
      ),
    );

    if (!mounted || choice == null) return;

    switch (choice) {
      case 'camera':
        await _pickFromSource(ImageSource.camera);
        break;
      case 'gallery':
        await _pickFromSource(ImageSource.gallery);
        break;
      case 'url':
        _showUrlInputDialog();
        break;
      case 'remove':
        setState(() {
          _newImageUrl = ''; // empty string = "clear the image" on save
          _selectedImage = null;
        });
        _toast("Photo removed");
        break;
    }
  }

  Future<void> _pickFromSource(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(source: source);
      if (file == null || !mounted) return; // user cancelled
      setState(() {
        _selectedImage = file;
        _newImageUrl = file.path;
      });
      _toast("Photo added");
    } catch (e) {
      _toast("Couldn't load the image: $e", isError: true);
    }
  }

  Widget _buildSourceOption({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
    Color color = _primaryBlue,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: color == _primaryBlue
                            ? const Color(0xFF0F172A)
                            : color,
                        fontFamily: _fontFam,
                      ),
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontFamily: _fontFam,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: Colors.grey.shade400,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showUrlInputDialog() {
    final urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.link,
        color: _primaryBlue,
        title: "Image URL",
        subtitle: "Use an image hosted online",
        child: TextField(
          controller: urlController,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: const TextStyle(fontFamily: _fontFam),
          decoration: InputDecoration(
            hintText: "Paste link here (https://...)",
            hintStyle: const TextStyle(fontFamily: _fontFam),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text("Cancel", style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton(
            onPressed: () {
              final url = urlController.text.trim();
              final uri = Uri.tryParse(url);
              final valid =
                  uri != null &&
                  (uri.scheme == 'http' || uri.scheme == 'https') &&
                  uri.host.isNotEmpty;

              if (!valid) {
                _toast(
                  "Please enter a valid image link starting with http(s)://",
                  isError: true,
                );
                return; // keep the dialog open so they can fix it
              }

              setState(() {
                _newImageUrl = url;
                _selectedImage = null;
              });
              Navigator.pop(dialogContext);
              _toast("Image URL added");
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryBlue,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text(
              "OK",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontFamily: _fontFam,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSave() async {

    if (!_validate()) {
    _toast('Please fix the highlighted fields', isError: true);
    return;
  }

    setState(() => _isSaving = true);

    try {
      String finalImageUrl = _currentItem.imageUrl;

      if (_newImageUrl != null && _newImageUrl != _currentItem.imageUrl) {
        if (_newImageUrl!.isEmpty) {
           finalImageUrl = '';
        } else if (!_newImageUrl!.startsWith('http')) {
          final String fileName = _nameController.text.isNotEmpty
              ? '${_nameController.text}_image.jpg'
              : 'updated_product_image.jpg';
          String? uploadedUrl;
          if (kIsWeb && _selectedImage != null) {
            final bytes = await _selectedImage!.readAsBytes();
            uploadedUrl = await widget.controller.uploadImageBytes(
              bytes,
              fileName,
            );
          } else if (_newImageUrl != null) {
            final File imageFile = File(_newImageUrl!);
            uploadedUrl = await widget.controller.uploadProductImage(
              imageFile,
              fileName,
            );
          }
          if (uploadedUrl != null) finalImageUrl = uploadedUrl;
        } else {
          finalImageUrl = _newImageUrl!;
        }
      }

      final updated = widget.controller.prepareUpdatedItem(
        originalItem: _currentItem,
        newName: _nameController.text.trim(),
        newSku: _skuController.text,
        newPrice: _priceController.text,
        newStock: _stockController.text,
        newMaxStock: _currentItem.maxQuantity.toString(), // Passes existing back safely
        newDesc: _descController.text,
        manufacturer: _manufacturerController.text,
        model: _modelController.text,
        productSize: _sizeController.text,
        shelfLevel: _currentItem.shelfLevel ?? '', // Passes existing back safely
        binNumber: _currentItem.binNumber ?? '', // Passes existing back safely
        imageUrl: finalImageUrl,
      );

      await widget.onUpdate(updated);
      if (mounted) {
        setState(() {
          _currentItem = updated;
          _isEditing = false;
          _newImageUrl = null;
          _selectedImage = null;
        });
        await _loadHistory();
        _toast('Item updated successfully');
      }
    } catch (e) {
      if (mounted) {
        _toast('Error updating item: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  final Map<String, String> _errors = {};

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    isError
        ? AppToast.error(context, message)
        : AppToast.success(context, message);
  }

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  
  bool _validate() {
    final errors = <String, String>{};
    if (_nameController.text.trim().isEmpty)
      errors['name'] = 'Name is required';
    final price = double.tryParse(_priceController.text.trim());
    if (price == null || price < 0) errors['price'] = 'Enter a valid price';
    final stock = double.tryParse(_stockController.text.trim());
    if (stock == null || stock < 0) errors['stock'] = 'Enter a valid quantity';
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
    });
    return errors.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              _buildSliverAppBar(),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      if (_isDisabled)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.eyeOff,
                                size: 18,
                                color: Colors.orange.shade700,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'This item is disabled. It is hidden from POS and '
                                  'the inventory list. Restore it to sell it again.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.orange.shade900,
                                    fontFamily: _fontFam,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Row(
                        children: [
                          _buildStatCard(
                            "Price",
                            "₱${_currentItem.price.toStringAsFixed(2)}",
                            LucideIcons.banknote,
                            Colors.green,
                            _priceController,
                          ),
                          const SizedBox(width: 12),
                          _buildStatCard(
                            "Stock (Qty)",
                            _currentItem.quantity.toString(),
                            LucideIcons.package,
                            _statusColor(
                              widget.controller.stockStatusFor(_currentItem),
                            ),
                            _stockController,
                            isReadOnly: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _buildProductSpecsBox(),
                      const SizedBox(height: 24),
                      _buildDetailsBox(),
                      const SizedBox(height: 24),
                      _buildLocationMapBox(),
                      const SizedBox(height: 24),
                      _buildTransactionHistoryBox(),
                      const SizedBox(
                        height: 100,
                      ), // was 24: keeps content clear of the bottom bar
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (!_isEditing) _buildBottomActions(),
        ],
      ),
    );
  }

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      expandedHeight: 250,
      pinned: true,
      backgroundColor: const Color(0xFF1E293B),
      leading: IconButton(
        icon: const Icon(LucideIcons.chevronLeft, color: Colors.white),
        onPressed: widget.onBack,
      ),
      actions: [
        if (_isSaving)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          )
        else if (_isEditing)
          IconButton(
            icon: const Icon(LucideIcons.check, color: Colors.greenAccent),
            onPressed: _handleSave,
          )
        else if (widget.controller.currentUserRole?.toLowerCase() == 'admin' && !_isDisabled)
          IconButton(
            icon: const Icon(LucideIcons.pencil, color: Colors.white, size: 20),
            onPressed: () => setState(() => _isEditing = true),
          ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: GestureDetector(
          onTap: _isEditing ? _pickImage : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildImage(),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                  ),
                ),
              ),
              if (_isEditing)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.camera,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentItem.category.toUpperCase(),
                      style: const TextStyle(
                        color: _primaryBlue,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        fontFamily: _fontFam,
                      ),
                    ),
                    Text(
                      _currentItem.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        fontFamily: _fontFam,
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

  Widget _buildImage() {
    final imageUrl = _newImageUrl ?? _currentItem.imageUrl;

    if (imageUrl.isEmpty) {
  return Container(
    color: Colors.grey.shade200,
    child: const Icon(
      Icons.image_not_supported,
      color: Colors.grey,
      size: 50,
    ),
  );
}

    if (kIsWeb || imageUrl.startsWith('http')) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Colors.grey.shade200,
          child: const Icon(
            Icons.image_not_supported,
            color: Colors.grey,
            size: 50,
          ),
        ),
      );
    } else {
      return Image.file(
        File(imageUrl),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Colors.grey.shade200,
          child: const Icon(
            Icons.image_not_supported,
            color: Colors.grey,
            size: 50,
          ),
        ),
      );
    }
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
    TextEditingController controller, {
    String? errorKey,
    bool isReadOnly = false
  }) {
    final error = errorKey == null ? null : _errors[errorKey];
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: (_isEditing && error != null)
                ? Colors.red
                : Colors.grey.shade200,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: _fontFam),
                  ),
                  if (_isEditing && error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        error,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ),
                  (_isEditing && !isReadOnly)
                      ? TextField(
                          controller: controller,
                          keyboardType: TextInputType.number,
                          onChanged: (_) {
                            if (errorKey != null &&
                                _errors.containsKey(errorKey)) {
                              setState(() => _errors.remove(errorKey));
                            }
                          },
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            fontFamily: _fontFam,
                          ),
                        )
                      : Text(
                          value,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            fontFamily: _fontFam,
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

  Widget _buildProductSpecsBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.info, size: 16, color: Colors.grey),
              SizedBox(width: 8),
              Text(
                "Specifications",
                style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildField(
                  "Manufacturer",
                  _manufacturerController,
                  _currentItem.manufacturer ?? "N/A",
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildField(
                  "Model",
                  _modelController,
                  _currentItem.model ?? "N/A",
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildField(
            "Product Size",
            _sizeController,
            _currentItem.productSize ?? "Standard",
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(LucideIcons.tag, size: 16, color: Colors.grey),
              SizedBox(width: 8),
              Text(
                "Inventory Info",
                style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildField(
            "Name",
            _nameController,
            _currentItem.name,
            errorKey: 'name',
          ),
          const SizedBox(height: 16),
          _buildField("SKU", _skuController, _currentItem.sku, isReadOnly: true),
          const SizedBox(height: 16),
          _buildField(
            "Description",
            _descController,
            _currentItem.description,
            isMultiline: true,
          ),
        ],
      ),
    );
  }
  Widget _buildLocationMapBox() {
    final hasLocation = _currentItem.locationId != null && _currentItem.locationId!.isNotEmpty;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(LucideIcons.mapPin, size: 16, color: Colors.grey),
                    SizedBox(width: 8),
                    Text(
                      "Store Location",
                      style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
                    ),
                  ],
                ),
                if (hasLocation)
                  TextButton(
                    onPressed: _showFullscreenMap,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Row(
                      children: [
                        Text(
                          "Fullscreen",
                          style: TextStyle(
                            color: _primaryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFamily: _fontFam,
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(LucideIcons.maximize, size: 14, color: _primaryBlue),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (!hasLocation)
            const Padding(
              padding: EdgeInsets.only(left: 16, right: 16, bottom: 16),
              child: Text(
                "This item is not assigned to a physical location.",
                style: TextStyle(color: Colors.grey, fontFamily: _fontFam),
              ),
            )
          else
            Container(
              height: 250,
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: StoreMap(
                controller: widget.controller,
                mode: MapMode.view,
                selectedItemId: _currentItem.id, // Auto-opens the specific item's location
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTransactionHistoryBox() {
    final recentHistory = _transactionHistory.take(5).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.history, size: 16, color: Colors.grey),
                  SizedBox(width: 8),
                  Text(
                    "Transaction History",
                    style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
                  ),
                ],
              ),
              if (_transactionHistory.length > 5)
                TextButton(
                  onPressed: _showAllTransactionsModal,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Row(
                    children: [
                      Text(
                        "View All",
                        style: TextStyle(
                          color: _primaryBlue,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFamily: _fontFam,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(
                        LucideIcons.chevronRight,
                        size: 14,
                        color: _primaryBlue,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_isLoadingHistory)
            const Center(child: CircularProgressIndicator())
          else if (_transactionHistory.isEmpty)
            const Center(
              child: Text(
                "No transaction history found.",
                style: TextStyle(color: Colors.grey, fontFamily: _fontFam),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recentHistory.length,
              itemBuilder: (context, index) =>
                  _buildTransactionTile(recentHistory[index]),
            ),
        ],
      ),
    );
  }

  Widget _buildTransactionTile(Map<String, dynamic> transaction) {
    final date = DateTime.parse(transaction['created_at']).toLocal();
    final formattedDate =
        "${date.month}/${date.day}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}";
    final quantityChange = transaction['quantity_change'];
    final isPositive = quantityChange > 0;
    final type = transaction['transaction_type'] as String;
    final profileInfo = transaction['profiles'];
    final userName = profileInfo != null
        ? profileInfo['name']
        : (transaction['user_name'] ?? 'Unknown');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isPositive
              ? Colors.green.withOpacity(0.1)
              : Colors.red.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isPositive ? LucideIcons.plus : LucideIcons.minus,
          color: isPositive ? Colors.green : Colors.red,
          size: 16,
        ),
      ),
      title: Text(
        "${isPositive ? '+' : ''}$quantityChange  •  ${type.replaceAll('_', ' ').capitalize()}",
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, fontFamily: _fontFam),
      ),
      subtitle: Text(
        "By $userName  •  $formattedDate",
        style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontFamily: _fontFam),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          "Qty: ${transaction['new_quantity']}",
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, fontFamily: _fontFam),
        ),
      ),
    );
  }

  void _showAllTransactionsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "All Transactions",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            fontFamily: _fontFam,
                          ),
                        ),
                        Text(
                          _currentItem.name,
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 13,
                            fontFamily: _fontFam,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _primaryBlue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        "${_transactionHistory.length} records",
                        style: const TextStyle(
                          color: _primaryBlue,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          fontFamily: _fontFam,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: Colors.grey.shade200),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  itemCount: _transactionHistory.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: Colors.grey.shade100),
                  itemBuilder: (context, index) =>
                      _buildTransactionTile(_transactionHistory[index]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller,
    String displayValue, {
    bool isMultiline = false,
    bool isReadOnly = false,
    String? errorKey,
  }) {
    final error = errorKey == null ? null : _errors[errorKey];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey, fontFamily: _fontFam)),
        (_isEditing && !isReadOnly)
            ? TextField(
                controller: controller,
                maxLines: isMultiline ? null : 1,
                style: const TextStyle(fontFamily: _fontFam),
                onChanged: (_) {
                  if (errorKey != null && _errors.containsKey(errorKey)) {
                    setState(() => _errors.remove(errorKey));
                  }
                },
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  displayValue.isEmpty ? "N/A" : displayValue,
                  style: const TextStyle(fontSize: 14, fontFamily: _fontFam),
                ),
              ),
        if (_isEditing && error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: _fontFam,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomActions() {
  final isAdmin = widget.controller.currentUserRole?.toLowerCase() == 'admin';
  final disabled = _isDisabled;

  final buttons = <Widget>[];

  if (!disabled) {
    // Active item
    buttons.add(
      ElevatedButton.icon(
        onPressed: _showRestockDialog,
        icon: const Icon(LucideIcons.plus, size: 18),
        label: const Text("Restock", style: TextStyle(fontFamily: _fontFam)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
    if (isAdmin) {
      buttons.add(
        OutlinedButton.icon(
          onPressed: _currentItem.quantity > 0 ? _showWriteOffDialog : null,
          icon: const Icon(LucideIcons.packageMinus, size: 18),
          label: const Text("Write off", style: TextStyle(fontFamily: _fontFam)),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            side: const BorderSide(color: Colors.red),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      );
      buttons.add(
        OutlinedButton.icon(
          onPressed: _showDisableDialog,
          icon: const Icon(LucideIcons.eyeOff, size: 18),
          label: const Text("Disable", style: TextStyle(fontFamily: _fontFam)),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange.shade800,
            side: BorderSide(color: Colors.orange.shade600),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      );
    }
  } else if (isAdmin) {
    // Disabled item
    buttons.add(
      ElevatedButton.icon(
        onPressed: _restoreItem,
        icon: const Icon(LucideIcons.rotateCcw, size: 18),
        label: const Text("Restore", style: TextStyle(fontFamily: _fontFam)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
    buttons.add(
      OutlinedButton.icon(
        onPressed: _showDeleteDialog,
        icon: const Icon(LucideIcons.trash2, size: 18),
        label: const Text("Delete", style: TextStyle(fontFamily: _fontFam)),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red,
          side: const BorderSide(color: Colors.red),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  if (buttons.isEmpty) return const SizedBox.shrink();

  return Positioned(
    bottom: 0,
    left: 0,
    right: 0,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: buttons[i]),
          ],
        ],
      ),
    ),
  );
}


  Future<void> _showDisableDialog() async {
    final hasStock = _currentItem.quantity > 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.eyeOff,
        color: Colors.orange,
        title: 'Disable item?',
        subtitle: 'Hidden from POS and inventory',
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Cancel', style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(LucideIcons.eyeOff, size: 16),
            label: const Text(
              'Disable',
              style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentItem.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Color(0xFF0F172A),
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_currentItem.sku}  •  ${_fmt(_currentItem.quantity)} ${_currentItem.unit} in stock',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontFamily: _fontFam),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Past sales, history and reports keep this item. '
              'You can restore it anytime from Inventory > Show disabled.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700, fontFamily: _fontFam),
            ),
            if (hasStock) ...[
              const SizedBox(height: 10),
              Text(
                'It still has stock, so it will not appear in low-stock alerts while disabled.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w600,
                  fontFamily: _fontFam,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final overlay = Overlay.of(context, rootOverlay: true);
    final name = _currentItem.name;
    try {
      await widget.controller.disableItem(_currentItem.id);
      widget.onStatusChanged?.call();
      widget.onBack();
      AppToast.showOn(overlay, '"$name" disabled');
    } catch (e) {
      AppToast.showOn(
        overlay,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _restoreItem() async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final name = _currentItem.name;
    try {
      await widget.controller.restoreItem(_currentItem.id);
      widget.onStatusChanged?.call();
      widget.onBack();
      AppToast.showOn(overlay, '"$name" restored');
    } catch (e) {
      AppToast.showOn(
        overlay,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _showDeleteDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.trash2,
        color: Colors.red,
        title: 'Delete permanently?',
        subtitle: "This permanently removes the disabled item. Its past sales will show as Deleted item in the dashboard and activity log.",
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: BorderSide(color: Colors.grey.shade300),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Cancel', style: TextStyle(fontFamily: _fontFam)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(LucideIcons.trash2, size: 16),
            label: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withOpacity(0.15)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentItem.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Color(0xFF0F172A),
                      fontFamily: _fontFam,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_currentItem.sku}  •  ${_fmt(_currentItem.quantity)} ${_currentItem.unit} in stock',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontFamily: _fontFam),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'This permanently removes the item from your inventory.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700, fontFamily: _fontFam),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    // Grab the overlay before deleting: this page may be disposed afterwards.
    final overlay = Overlay.of(context, rootOverlay: true);
    final name = _currentItem.name;
    try {
      await widget.onDelete(_currentItem.id);
      AppToast.showOn(overlay, '"$name" deleted');
    } catch (e) {
      AppToast.showOn(overlay, 'Could not delete "$name": $e', isError: true);
    }
  }

  Future<void> _showWriteOffDialog() async {
    final qtyCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final unit = _currentItem.unit;

    const reasons = ['Damaged', 'Expired', 'Lost', 'Other'];
    String reason = reasons.first;
    bool saving = false;
    bool touched = false;
    String? error;

    String? validate(String text) {
      final t = text.trim();
      if (t.isEmpty) return 'Enter the quantity to remove';
      final v = double.tryParse(t);
      if (v == null) return 'Enter a valid number';
      if (v <= 0) return 'Must be greater than 0';
      if (v > _currentItem.quantity) {
        return 'Only ${_fmt(_currentItem.quantity)} $unit in stock';
      }
      return null;
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final value = double.tryParse(qtyCtrl.text.trim());
          final remaining =
              (value != null && value > 0 && value <= _currentItem.quantity)
              ? _currentItem.quantity - value
              : null;

          Future<void> submit() async {
            touched = true;
            final err = validate(qtyCtrl.text);
            if (err != null) {
              setDialogState(() => error = err);
              return;
            }
            setDialogState(() {
              error = null;
              saving = true;
            });
            try {
              final qty = double.parse(qtyCtrl.text.trim());
              await widget.controller.writeOffStock(
                _currentItem.id,
                qty,
                reason: reason,
                note: noteCtrl.text,
              );
              if (!mounted) return;
              final newQty = _currentItem.quantity - qty;
              setState(() {
                _currentItem = _currentItem.copyWith(quantity: newQty);
                _stockController.text = newQty.toString();
              });
              widget.onStatusChanged?.call();
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              _toast(
                'Removed ${_fmt(qty)} $unit of ${_currentItem.name} ($reason)',
              );
              _loadHistory();
            } catch (e) {
              if (dialogContext.mounted) setDialogState(() => saving = false);
              _toast(
                e.toString().replaceFirst('Exception: ', ''),
                isError: true,
              );
            }
          }

          OutlineInputBorder border(Color c, [double w = 1]) =>
              OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: c, width: w),
              );

          return AppDialog(
            icon: LucideIcons.packageMinus,
            color: Colors.red,
            title: 'Write off stock',
            subtitle: _currentItem.name,
            actions: [
              OutlinedButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  side: BorderSide(color: Colors.grey.shade300),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Cancel', style: TextStyle(fontFamily: _fontFam)),
              ),
              ElevatedButton(
                onPressed: saving ? null : submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Remove stock',
                        style: TextStyle(fontWeight: FontWeight.bold, fontFamily: _fontFam),
                      ),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _stockSummary(
                          'CURRENT',
                          '${_fmt(_currentItem.quantity)} $unit',
                          const Color(0xFF0F172A),
                        ),
                      ),
                      Icon(
                        LucideIcons.arrowRight,
                        size: 18,
                        color: Colors.grey.shade400,
                      ),
                      Expanded(
                        child: _stockSummary(
                          'AFTER',
                          remaining == null ? '—' : '${_fmt(remaining)} $unit',
                          remaining == null ? Colors.grey : Colors.red.shade700,
                          alignEnd: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Reason',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFamily: _fontFam),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: reasons
                      .map(
                        (r) => ChoiceChip(
                          label: Text(r),
                          selected: reason == r,
                          selectedColor: Colors.red.withOpacity(0.12),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: reason == r
                                ? Colors.red.shade700
                                : Colors.black87,
                            fontFamily: _fontFam,
                          ),
                          onSelected: saving
                              ? null
                              : (_) => setDialogState(() => reason = r),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Quantity to remove',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFamily: _fontFam),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons.alertCircle,
                          size: 13,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            error!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: _fontFam,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: qtyCtrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    // digits with at most one decimal point
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                  ],
                  onChanged: (text) => setDialogState(() {
                    if (touched) error = validate(text);
                  }),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFamily: _fontFam,
                  ),
                  decoration: InputDecoration(
                    hintText: '0',
                    hintStyle: const TextStyle(fontFamily: _fontFam),
                    suffixText: unit,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    enabledBorder: border(
                      error != null ? Colors.red : Colors.grey.shade300,
                    ),
                    focusedBorder: border(
                      error != null ? Colors.red : Colors.red.shade300,
                      1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLines: 2,
                  style: const TextStyle(fontFamily: _fontFam),
                  decoration: InputDecoration(
                    hintText: 'Note (optional), e.g. dropped during unloading',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                      fontFamily: _fontFam,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    enabledBorder: border(Colors.grey.shade300),
                    focusedBorder: border(Colors.red.shade300, 1.5),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    qtyCtrl.dispose();
    noteCtrl.dispose();
  }
  void _showFullscreenMap() {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 800,
          height: 600,
          child: Column(
            children: [
              Container(
                color: const Color(0xFF0F172A),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Location: ${_currentItem.name}',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: _fontFam),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(dialogContext),
                    )
                  ],
                ),
              ),
              Expanded(
                child: StoreMap(
                  controller: widget.controller,
                  mode: MapMode.view,
                  selectedItemId: _currentItem.id, // Auto-opens the specific item's location
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) {
      return "";
    }
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}