import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math' as math;
import 'widgets/app_toast.dart';
import 'widgets/app_dialog.dart';
import 'dart:async';
import 'package:inventory_plus/services/app_error_mapper.dart';
import 'package:inventory_plus/services/app_logger.dart';

class AddItemPage extends StatefulWidget {
  final InventoryController controller;
  final Function(InventoryItem) onAdd;

  const AddItemPage({super.key, required this.controller, required this.onAdd});

  @override
  State<AddItemPage> createState() => _AddItemPageState();
}

class _AddItemPageState extends State<AddItemPage> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  late final String _submissionOperationId = widget.controller.newOperationId(
    'product-create',
  );
  String? _submissionSku;

  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _quantityController = TextEditingController();
  final _categoryController = TextEditingController();
  final _descController = TextEditingController();

  final _manufacturerController = TextEditingController();
  final _modelController = TextEditingController();
  final _sizeController = TextEditingController();

  String? _imageUrl;
  XFile? _selectedImage;
  final ImagePicker _picker = ImagePicker();

  // Selected unit symbol (comes from the `measurements` table)
  String _selectedUnit = 'pcs';
  static const String _addNewValue = '__add_new_unit__';
  int _unitFieldVersion = 0; // forces the dropdown to rebuild after the modal
  StreamSubscription<InventoryRuntimeSettingsSnapshot>?
  _runtimeSettingsSubscription;

  @override
  void initState() {
    super.initState();
    _runtimeSettingsSubscription = widget.controller
        .streamRuntimeSettings()
        .listen((_) {
          if (mounted) setState(() => _unitFieldVersion++);
        });
    _ensureUnitsLoaded();
  }

  Future<void> _ensureUnitsLoaded() async {
    if (widget.controller.availableMeasurements.isNotEmpty) return;
    try {
      await widget.controller.loadSystemSettings();
    } catch (_) {
      // Keep the fallback unit; the user can still add a unit manually.
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_runtimeSettingsSubscription?.cancel());
    _nameController.dispose();
    _priceController.dispose();
    _quantityController.dispose();
    _categoryController.dispose();
    _descController.dispose();
    _manufacturerController.dispose();
    _modelController.dispose();
    _sizeController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    // Camera only makes sense on phones/tablets, not web or desktop.
    final bool cameraAvailable =
        !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.imagePlus,
        color: Colors.orange,
        title: "Product Photo",
        subtitle: "Choose how to add an image",
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
            if (_imageUrl != null) ...[
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
            child: const Text("Cancel"),
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
          _imageUrl = null;
          _selectedImage = null;
        });
        AppToast.success(context, "Photo removed");
        break;
    }
  }

  Future<void> _pickFromSource(ImageSource source) async {
    try {
      final XFile? file = await _picker.pickImage(source: source);
      if (file == null || !mounted) return; // user cancelled
      setState(() {
        _selectedImage = file;
        _imageUrl = file.path;
      });
      AppToast.success(context, "Photo added");
    } catch (e, stackTrace) {
      AppLogger.error(
        'Item image selection failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        AppToast.error(
          context,
          AppErrorMapper.message(e, fallback: AppErrorCategory.upload),
        );
      }
    }
  }

  Widget _buildSourceOption({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
    Color color = Colors.orange,
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
                        color: color == Colors.orange
                            ? const Color(0xFF0F172A)
                            : color,
                      ),
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
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

  String _generateAutoSKU() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final math.Random rnd = math.Random();
    return 'SKU-' +
        String.fromCharCodes(
          Iterable.generate(
            8,
            (_) => chars.codeUnitAt(rnd.nextInt(chars.length)),
          ),
        );
  }

  void _showUrlInputDialog() {
    final urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialog(
        icon: LucideIcons.link,
        color: Colors.orange,
        title: "Image URL",
        subtitle: "Use an image hosted online",
        child: TextField(
          controller: urlController,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: "Paste link here (https://...)",
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
            child: const Text("Cancel"),
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
                AppToast.error(
                  context,
                  "Please enter a valid image link starting with http(s)://",
                );
                return; // keep the dialog open so they can fix it
              }

              setState(() {
                _imageUrl = url;
                _selectedImage = null;
              });
              Navigator.pop(dialogContext);
              AppToast.success(context, "Image URL added");
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
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
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _submitData() async {
    if (_isLoading) return;
    if (!_formKey.currentState!.validate()) {
      AppToast.error(context, "Please fix the errors before saving.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      String? finalImageUrl = _imageUrl;

      if (_imageUrl != null && !_imageUrl!.startsWith('http')) {
        final String fileName = _nameController.text.isNotEmpty
            ? '${_nameController.text}_image.jpg'
            : 'product_image.jpg';
        String? uploadedUrl;
        if (kIsWeb && _selectedImage != null) {
          final bytes = await _selectedImage!.readAsBytes();
          uploadedUrl = await widget.controller.uploadImageBytes(
            bytes,
            fileName,
          );
        } else {
          final File imageFile = File(_imageUrl!);
          uploadedUrl = await widget.controller.uploadProductImage(
            imageFile,
            fileName,
          );
        }
        if (uploadedUrl != null) finalImageUrl = uploadedUrl;
      }
      final String autoGeneratedSku = _submissionSku ??= _generateAutoSKU();

      final newItem = widget.controller.createNewItem(
        name: _nameController.text.trim(),
        sku: autoGeneratedSku,
        price: _priceController.text.trim(),
        quantity: _quantityController.text.trim(),
        maxQuantity: '0', // Default empty value
        category: _categoryController.text.trim(),
        description: _descController.text.trim(),
        manufacturer: _manufacturerController.text.trim(),
        model: _modelController.text.trim(),
        productSize: _sizeController.text.trim(),
        shelfLevel: '', // Default empty value
        binNumber: '', // Default empty value
        imageUrl: finalImageUrl ?? '',
        unit: _selectedUnit,
      );

      final savedItem = await widget.controller.addItem(
        newItem,
        operationId: _submissionOperationId,
      );
      if (mounted) {
        widget.onAdd(savedItem);
        Navigator.pop(context);
      }
    } catch (e, stackTrace) {
      AppLogger.error('Add item failed', error: e, stackTrace: stackTrace);
      String errorMessage = AppErrorMapper.message(
        e,
        fallback: AppErrorCategory.dataSave,
      );
      if (e is PostgrestException && e.code == '23505') {
        errorMessage =
            "An item with this SKU already exists! Please enter a unique SKU.";
      }
      if (mounted) AppToast.error(context, errorMessage);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          "Add New Product",
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        leading: IconButton(
          icon: const Icon(LucideIcons.chevronLeft, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : SingleChildScrollView(
              child: Column(
                children: [
                  _buildImageHeader(),
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionTitle("General Information"),
                          _buildTextField(
                            _nameController,
                            "Product Name",
                            LucideIcons.package,
                            customValidator: (v) => v!.trim().length < 2
                                ? 'Enter a valid name (min 2 chars)'
                                : null,
                          ),

                          const SizedBox(height: 24),
                          _buildSectionTitle("Technical Specifications"),
                          _buildTextField(
                            _manufacturerController,
                            "Brand / Manufacturer",
                            LucideIcons.factory,
                            isRequired: false,
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: _buildTextField(
                                  _modelController,
                                  "Model #",
                                  LucideIcons.info,
                                  isRequired: false,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildTextField(
                                  _sizeController,
                                  "Size",
                                  LucideIcons.maximize,
                                  isRequired: false,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 24),
                          _buildSectionTitle("Pricing & Inventory"),

                          Row(
                            children: [
                              Expanded(
                                child: _buildTextField(
                                  _priceController,
                                  "Price (₱)",
                                  LucideIcons.banknote,
                                  isNumber: true,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildTextField(
                                  _categoryController,
                                  "Category",
                                  LucideIcons.tag,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          _buildTextField(
                            _quantityController,
                            "Initial Stock",
                            LucideIcons.archive,
                            isNumber: true,
                          ),

                          const SizedBox(height: 16),
                          _buildUnitDropdown(),

                          const SizedBox(height: 16),
                          _buildTextField(
                            _descController,
                            "Detailed Description",
                            LucideIcons.fileText,
                            isMultiline: true,
                            isRequired: false,
                          ),

                          const SizedBox(height: 40),
                          _buildSaveButton(),
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // ─── UNIT DROPDOWN (reads from the `measurements` table) ──────────────────
  Widget _buildUnitDropdown() {
    final seen = <String>{};
    final items = <DropdownMenuItem<String>>[];

    for (final m in widget.controller.availableMeasurements) {
      final symbol = m['symbol'].toString();
      if (!seen.add(symbol)) continue; // dropdown asserts on duplicate values
      items.add(
        DropdownMenuItem(
          value: symbol,
          child: Text(
            '${m['name']} ($symbol)',
            style: const TextStyle(fontSize: 14),
          ),
        ),
      );
    }

    // Make sure the current value always exists in the list (e.g. 'pcs' before load)
    if (!seen.contains(_selectedUnit)) {
      items.insert(
        0,
        DropdownMenuItem(value: _selectedUnit, child: Text(_selectedUnit)),
      );
    }

    items.add(
      const DropdownMenuItem(
        value: _addNewValue,
        child: Row(
          children: [
            Icon(LucideIcons.plus, size: 16, color: Colors.orange),
            SizedBox(width: 8),
            Text(
              'Add new unit...',
              style: TextStyle(
                fontSize: 14,
                color: Colors.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    return DropdownButtonFormField<String>(
      key: ValueKey('$_selectedUnit-$_unitFieldVersion'),
      initialValue: _selectedUnit,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: "Unit of Measure",
        helperText:
            "Sets POS rules: Whole numbers (Pieces) vs. Decimals (Kilos).",
        helperMaxLines: 2,
        helperStyle: TextStyle(
          fontSize: 11,
          color: Colors.grey.shade600,
          fontStyle: FontStyle.italic,
        ),
        prefixIcon: const Icon(
          LucideIcons.scale,
          size: 18,
          color: Colors.orange,
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.orange, width: 2),
        ),
      ),
      items: items,
      onChanged: (val) {
        if (val == null) return;
        if (val == _addNewValue) {
          _showNewUnitModal();
        } else {
          setState(() => _selectedUnit = val);
        }
      },
    );
  }

  // ─── "ADD NEW UNIT" MODAL (inserts into DB, then auto-selects) ────────────
  Future<void> _showNewUnitModal() async {
    // Not disposed on purpose: disposing right after pop can throw while the
    // dialog's close animation is still building the TextFields.
    final nameCtrl = TextEditingController();
    final symbolCtrl = TextEditingController();
    String? nameError;
    String? symbolError;
    bool saving = false;

    final String? newSymbol = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> save() async {
            final name = nameCtrl.text.trim();
            final symbol = symbolCtrl.text.trim();

            setModalState(() {
              nameError = name.isEmpty ? "Measurement name is required" : null;
              symbolError = symbol.isEmpty ? "Symbol/Unit is required" : null;
            });
            if (name.isEmpty || symbol.isEmpty) return;

            // Already exists? Just select it instead of inserting a duplicate.
            final existing = widget.controller.availableMeasurements.where(
              (m) =>
                  m['symbol'].toString().toLowerCase() == symbol.toLowerCase(),
            );
            if (existing.isNotEmpty) {
              Navigator.pop(dialogContext, existing.first['symbol'].toString());
              return;
            }

            setModalState(() => saving = true);
            try {
              await widget.controller.addMeasurement(name, symbol);
              if (dialogContext.mounted) Navigator.pop(dialogContext, symbol);
            } catch (e, stackTrace) {
              AppLogger.error(
                'Measurement creation failed',
                error: e,
                stackTrace: stackTrace,
              );
              setModalState(() {
                saving = false;
                symbolError = AppErrorMapper.message(
                  e,
                  fallback: AppErrorCategory.dataSave,
                );
              });
            }
          }

          return AppDialog(
            icon: LucideIcons.scale,
            color: Colors.orange,
            title: "Add New Unit",
            subtitle: "Saved to your measurement units",
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: "Measurement Name (e.g. Pair)",
                    errorText: nameError,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: symbolCtrl,
                  decoration: InputDecoration(
                    labelText: "Symbol / Unit (e.g. pr)",
                    errorText: symbolError,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              OutlinedButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
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
              ElevatedButton(
                onPressed: saving ? null : save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "Save",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );

    if (!mounted) return;
    setState(() {
      if (newSymbol != null) _selectedUnit = newSymbol;
      _unitFieldVersion++; // resets dropdown, also on Cancel
    });

    if (newSymbol != null) AppToast.success(context, "Unit added");
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
              fontSize: 13,
            ),
          ),
          const Expanded(
            child: Divider(indent: 10, color: Colors.orange, thickness: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _buildImageHeader() {
    return GestureDetector(
      onTap: _pickImage,
      child: Container(
        width: double.infinity,
        height: 180,
        color: const Color(0xFF1E293B),
        child: _imageUrl != null
            ? ((kIsWeb || _imageUrl!.startsWith('http'))
                  ? Image.network(_imageUrl!, fit: BoxFit.cover)
                  : Image.file(File(_imageUrl!), fit: BoxFit.cover))
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    LucideIcons.imagePlus,
                    color: Colors.white.withOpacity(0.3),
                    size: 40,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Tap to Add Product Photo",
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 55,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _submitData,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: const Text(
          "Save to Database",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String hint,
    IconData icon, {
    bool isNumber = false,
    bool isMultiline = false,
    bool isRequired = true,
    String? Function(String?)? customValidator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: isNumber
          ? const TextInputType.numberWithOptions(decimal: true)
          : (isMultiline ? TextInputType.multiline : TextInputType.text),
      maxLines: isMultiline ? 3 : 1,
      validator:
          customValidator ??
          (value) {
            if (isRequired && (value == null || value.trim().isEmpty)) {
              return 'Required';
            }
            if (isNumber &&
                value != null &&
                value.trim().isNotEmpty &&
                double.tryParse(value.trim()) == null) {
              return 'Must be a number';
            }
            return null;
          },
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
        prefixIcon: Icon(icon, size: 18, color: Colors.orange),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 12,
          horizontal: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.orange, width: 2),
        ),
        errorStyle: const TextStyle(color: Colors.redAccent),
      ),
    );
  }
}
