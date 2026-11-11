import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/inventory.dart';
import '../logic/inventory_controller.dart';
import '../services/classification_api_service.dart';
import '../services/forecasting_api_service.dart';

enum _ClassificationMode { existingInventory, newProduct }

class ClassificationTestPage extends StatefulWidget {
  const ClassificationTestPage({
    super.key,
    required this.controller,
    HardwareClassificationService? service,
  }) : _service = service;

  final InventoryController controller;
  final HardwareClassificationService? _service;

  @override
  State<ClassificationTestPage> createState() => _ClassificationTestPageState();
}

class _ClassificationTestPageState extends State<ClassificationTestPage> {
  late final HardwareClassificationService _service;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _categoryController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  StreamSubscription<List<InventoryItem>>? _inventorySubscription;

  _ClassificationMode _mode = _ClassificationMode.existingInventory;
  HardwareClassificationEngine _engine = HardwareClassificationEngine.existing;
  String? _selectedProductId;
  HardwareClassification? _result;
  String? _error;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _service =
        widget._service ?? HardwareClassificationApiClient.fromEnvironment();
    _inventorySubscription = widget.controller.inventorySnapshots.listen((_) {
      if (!mounted) return;
      final selectedStillExists = widget.controller.allItems.any(
        (item) => item.id == _selectedProductId,
      );
      setState(() {
        if (!selectedStillExists) _selectedProductId = null;
      });
    });
  }

  @override
  void dispose() {
    _inventorySubscription?.cancel();
    _searchController.dispose();
    _nameController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  InventoryItem? get _selectedProduct {
    final id = _selectedProductId;
    if (id == null) return null;
    for (final item in widget.controller.allItems) {
      if (item.id == id) return item;
    }
    return null;
  }

  List<InventoryItem> get _filteredProducts {
    final query = _searchController.text.trim().toLowerCase();
    final items = widget.controller.allItems.where((item) {
      if (query.isEmpty) return true;
      return item.name.toLowerCase().contains(query) ||
          item.sku.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query);
    }).toList();
    items.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return items;
  }

  void _setMode(_ClassificationMode mode) {
    if (_mode == mode || _isLoading) return;
    setState(() {
      _mode = mode;
      _result = null;
      _error = null;
    });
  }

  void _setEngine(HardwareClassificationEngine engine) {
    if (_engine == engine || _isLoading) return;
    setState(() {
      _engine = engine;
      _result = null;
      _error = null;
    });
  }

  Future<void> _classify() async {
    final InventoryItem? selected = _selectedProduct;
    final isExisting = _mode == _ClassificationMode.existingInventory;
    final productName = isExisting
        ? selected?.name ?? ''
        : _nameController.text;
    final category = isExisting
        ? selected?.category ?? ''
        : _categoryController.text;
    final description = isExisting
        ? selected?.description ?? ''
        : _descriptionController.text;
    if (productName.trim().isEmpty) {
      setState(() {
        _error = isExisting
            ? 'Select an inventory product first.'
            : 'Enter a product name first.';
        _result = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await _service.classify(
        productName: productName,
        category: category,
        description: description,
        sessionToken: widget.controller.currentSessionToken,
        engine: _engine,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on ForecastApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Unable to classify this product right now.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF4F6F8),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          children: [
            const Text(
              'Hardware Classification Test',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Test product identification and provisional seasonal relevance. '
              'Nothing entered here is saved.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 15),
            ),
            const SizedBox(height: 20),
            const Text(
              'Classification engine',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<HardwareClassificationEngine>(
                segments: HardwareClassificationEngine.values
                    .map(
                      (engine) => ButtonSegment(
                        value: engine,
                        label: Text(engine.label),
                      ),
                    )
                    .toList(growable: false),
                selected: {_engine},
                onSelectionChanged: (selection) => _setEngine(selection.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _engine == HardwareClassificationEngine.gemini
                  ? 'Gemini proposes an identity; the backend accepts only controlled taxonomy labels and applies local seasonal evidence.'
                  : 'Deterministic rules run first, followed by the local MiniLM taxonomy matcher.',
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_ClassificationMode>(
                segments: const [
                  ButtonSegment(
                    value: _ClassificationMode.existingInventory,
                    icon: Icon(LucideIcons.box),
                    label: Text('Existing Inventory'),
                  ),
                  ButtonSegment(
                    value: _ClassificationMode.newProduct,
                    icon: Icon(LucideIcons.flaskConical),
                    label: Text('New Product'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) => _setMode(selection.first),
              ),
            ),
            const SizedBox(height: 20),
            _Panel(
              child: _mode == _ClassificationMode.existingInventory
                  ? _buildExistingProductMode()
                  : _buildNewProductMode(),
            ),
            const SizedBox(height: 16),
            if (_error != null) _buildError(_error!),
            if (_result != null) _buildResult(_result!),
          ],
        ),
      ),
    );
  }

  Widget _buildExistingProductMode() {
    final selected = _selectedProduct;
    final products = _filteredProducts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Select an active inventory product',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Search name, SKU, or category',
            prefixIcon: Icon(LucideIcons.search),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          constraints: const BoxConstraints(maxHeight: 210),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: products.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No matching active inventory products.'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: products.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final product = products[index];
                    return ListTile(
                      selected: product.id == _selectedProductId,
                      title: Text(product.name),
                      subtitle: Text('${product.sku}  •  ${product.category}'),
                      trailing: product.id == _selectedProductId
                          ? const Icon(LucideIcons.circleCheck)
                          : null,
                      onTap: () {
                        setState(() {
                          _selectedProductId = product.id;
                          _result = null;
                          _error = null;
                        });
                      },
                    );
                  },
                ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 16),
          _readOnlyField('Product name', selected.name),
          const SizedBox(height: 10),
          _readOnlyField('Category', selected.category),
          const SizedBox(height: 10),
          _readOnlyField(
            'Description',
            selected.description.trim().isEmpty
                ? 'No description provided'
                : selected.description,
          ),
        ],
        const SizedBox(height: 16),
        _classifyButton(),
      ],
    );
  }

  Widget _buildNewProductMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter an unsaved product',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'This calls the same classifier as Existing Inventory and does not '
          'insert a product into Supabase.',
          style: TextStyle(color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          enabled: !_isLoading,
          decoration: const InputDecoration(
            labelText: 'Product name *',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _categoryController,
          enabled: !_isLoading,
          decoration: const InputDecoration(
            labelText: 'Category (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionController,
          enabled: !_isLoading,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Description (optional)',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _classifyButton(),
      ],
    );
  }

  Widget _classifyButton() {
    return FilledButton.icon(
      onPressed: _isLoading ? null : _classify,
      icon: _isLoading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(LucideIcons.scanSearch),
      label: Text(_isLoading ? 'Classifying…' : 'Classify Product'),
    );
  }

  Widget _readOnlyField(String label, String value) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
      ),
      child: Text(value),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        border: Border.all(color: const Color(0xFFFCA5A5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.circleAlert, color: Color(0xFFB91C1C)),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }

  Widget _buildResult(HardwareClassification result) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                result.isUnknown
                    ? LucideIcons.circleHelp
                    : LucideIcons.circleCheck,
                color: result.isUnknown
                    ? const Color(0xFFB45309)
                    : const Color(0xFF15803D),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  result.isUnknown ? 'UNKNOWN' : 'Classification result',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _resultRow('Product name', result.productName),
          _resultRow(
            'Identified product type',
            _pretty(result.identifiedProductType),
          ),
          _resultRow(
            'Suggested taxonomy category',
            result.suggestedTaxonomyCategory,
          ),
          _resultRow('Intended use', result.intendedUse),
          _resultRow(
            'Potential seasonal relevance',
            _seasonalRelevanceLabel(result.seasonalRelevance),
          ),
          _resultRow(
            'Seasonal relationship basis',
            _pretty(result.seasonalMatchType),
          ),
          if (result.seasonalHierarchy.isNotEmpty)
            _resultRow(
              'Seasonal evidence path',
              result.seasonalHierarchy.join(' → '),
            ),
          _resultRow(
            'Product-identification confidence',
            _pretty(result.identificationConfidence),
          ),
          _resultRow(
            'Identification method',
            _pretty(result.identificationMethod),
          ),
          _resultRow(
            'Seasonal-demand evidence level',
            _pretty(result.seasonalEvidenceLevel),
          ),
          const Divider(height: 28),
          const Text(
            'Why this result',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(result.explanation),
          if (result.clarificationNeeded) ...[
            const SizedBox(height: 10),
            const Text(
              'Add the material, form, or intended use and classify again.',
              style: TextStyle(
                color: Color(0xFFB45309),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: const Text(
              'Product-identification confidence is not evidence that this '
              'product sells more in a season. Provisional relevance has no '
              'demand percentage or forecasting effect.',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Supporting evidence',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (result.evidence.isEmpty)
            const Text(
              'No supporting seasonal-demand source is available.',
              style: TextStyle(color: Color(0xFF64748B)),
            )
          else
            ...result.evidence.map(
              (source) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (source.scope.isNotEmpty) Text(source.scope),
                    if (source.url.isNotEmpty)
                      SelectableText(
                        source.url,
                        style: const TextStyle(color: Color(0xFF2563EB)),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 210,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  static String _pretty(String value) {
    if (value.trim().isEmpty) return 'Unknown';
    final words = value.replaceAll('_', ' ').split(' ');
    return words
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  static String _seasonalRelevanceLabel(String value) {
    switch (value.trim().toLowerCase()) {
      case 'dry':
        return 'Potential dry-season relevance';
      case 'rainy':
        return 'Potential rainy-season relevance';
      case 'neutral':
        return 'Neutral / no established seasonality';
      default:
        return 'UNKNOWN';
    }
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}
