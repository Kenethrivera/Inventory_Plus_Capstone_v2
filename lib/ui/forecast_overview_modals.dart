part of 'forecasting_page.dart';

/// Uses the same white surface, outlined shape, header and close treatment as
/// Forecast Jobs details. The route supplied by showDialog owns focus and the
/// backdrop; the fixed body height keeps the page behind it stationary.
class _ForecastOverviewModalFrame extends StatelessWidget {
  const _ForecastOverviewModalFrame({required this.title, required this.subtitle,
    required this.icon, required this.child, this.preferredHeight = 760});

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  final double preferredHeight;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final availableHeight = max(180.0,
      size.height - MediaQuery.viewInsetsOf(context).bottom - 48);
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: .16),
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: _forecastLine)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: size.width < 752 ? size.width - 32 : 720,
        height: min(preferredHeight, min(size.height * .86, availableHeight)),
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Row(children: [
              Container(width: 42, height: 42,
                decoration: BoxDecoration(color: _forecastAccent.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 21, color: _forecastAccent)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _forecastInk, fontSize: 18,
                      fontWeight: FontWeight.w700)),
                  Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _forecastMuted, fontSize: 12)),
                ])),
              IconButton(tooltip: 'Close', onPressed: () {
                _ForecastDefinition.dismissOpen();
                Navigator.pop(context);
              }, icon: const Icon(LucideIcons.x, size: 19,
                color: _forecastMuted)),
            ])),
          const Divider(height: 1, color: _forecastLine),
          Expanded(child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _ForecastDefinition.dismissOpen();
              return false;
            },
            child: FocusTraversalGroup(child: child))),
        ]),
      ),
    );
  }
}

class _RestockingGuideDialog extends StatelessWidget {
  const _RestockingGuideDialog();

  @override
  Widget build(BuildContext context) => _ForecastOverviewModalFrame(
    title: 'Restocking Guide',
    subtitle: 'How to read provisional demand and restock estimates',
    icon: LucideIcons.info,
    preferredHeight: 570,
    child: Column(children: [
      Expanded(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Forecast models can disagree', style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: _forecastInk)),
          const SizedBox(height: 8),
          const Text('Each model interprets the same sales history differently. '
            'Their demand predictions may differ substantially.',
            style: TextStyle(fontSize: 13, height: 1.45, color: _forecastBody)),
          const SizedBox(height: 16),
          _model('Mean28', 'Uses recent average daily sales.'),
          _model('LightGBM', 'Predicts demand using learned sales patterns.'),
          _model('Calibrated Blend', 'Combines models and adjusts for historical forecasting bias.'),
          _model('Seasonal Experimental',
            'Investigates seasonal demand patterns and remains experimental.'),
          const SizedBox(height: 16),
          const Text('No model has yet been established as the most accurate '
            'through completed, comparable performance evaluation.',
            style: TextStyle(fontSize: 13, height: 1.45, color: _forecastBody)),
          const SizedBox(height: 10),
          const Text('A preliminary restock estimate is guidance, not an '
            'approved purchase quantity. Review inventory, suppliers, and '
            'the forecast comparison before deciding.',
            style: TextStyle(fontSize: 13, height: 1.45, color: _forecastBody)),
        ]))),
      const Divider(height: 1, color: _forecastLine),
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Align(alignment: Alignment.centerRight,
          child: FilledButton(onPressed: () => Navigator.pop(context, true),
            child: const Text('View Restock Priorities')))),
    ]),
  );

  static Widget _model(String title, String explanation) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13,
        fontWeight: FontWeight.w600, color: _forecastInk)),
      const SizedBox(height: 2),
      Text(explanation, style: const TextStyle(fontSize: 12,
        height: 1.4, color: _forecastMuted)),
    ]),
  );
}

class _CompactSalesEvidenceCard extends StatelessWidget {
  const _CompactSalesEvidenceCard({required this.savedCoverage,
    required this.onViewBreakdown});

  final Map<String, dynamic>? savedCoverage;
  final VoidCallback? onViewBreakdown;

  @override
  Widget build(BuildContext context) {
    final value = savedCoverage;
    final valid = value != null && value['available'] == true &&
      const ['total', 'no_sales', 'limited', 'sufficient', 'not_evaluated']
        .every((key) => value[key] is num);
    final counts = valid ? <String, int>{
      for (final key in const ['no_sales', 'limited', 'sufficient', 'not_evaluated'])
        key: (value![key] as num).toInt(),
    } : const <String, int>{};
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white,
        border: Border.all(color: _forecastLine),
        borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sales History Coverage', style: TextStyle(fontSize: 14,
          fontWeight: FontWeight.w600, color: _forecastInk)),
        const SizedBox(height: 12),
        if (!valid)
          const Text('Historical evidence is unavailable for this scope.',
            style: TextStyle(fontSize: 12, color: _forecastMuted))
        else ...[
          _historyCount('No recorded sales', counts['no_sales']!),
          _historyCount('Limited history', counts['limited']!),
          _historyCount('Sufficient history', counts['sufficient']!),
          _historyCount('Not evaluated', counts['not_evaluated']!),
          const SizedBox(height: 5),
          TextButton(onPressed: onViewBreakdown,
            style: TextButton.styleFrom(foregroundColor: _forecastAccentDark,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5)),
            child: const Text('View breakdown', style: TextStyle(fontSize: 12,
              fontWeight: FontWeight.w600))),
        ],
      ]),
    );
  }

  static Widget _historyCount(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 12,
        color: _forecastBody))),
      Text('$value', style: const TextStyle(fontSize: 12,
        fontWeight: FontWeight.w700, color: _forecastInk)),
    ]),
  );
}

class _RestockPrioritiesDialog extends StatefulWidget {
  const _RestockPrioritiesDialog({required this.api, required this.sessionToken,
    required this.scopeLabel, required this.initial, this.unit,
    this.category, this.productId, this.scopeSearch});

  final ForecastingApiService api;
  final String sessionToken;
  final String scopeLabel;
  final StoreRestockPage initial;
  final String? unit;
  final String? category;
  final String? productId;
  final String? scopeSearch;

  @override
  State<_RestockPrioritiesDialog> createState() => _RestockPrioritiesDialogState();
}

class _RestockPrioritiesDialogState extends State<_RestockPrioritiesDialog> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  StoreRestockPage? _data;
  String? _error;
  bool _loading = false;
  bool _showUnavailable = false;
  int _page = 1;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); });
  }

  @override
  void dispose() {
    _ForecastDefinition.dismissOpen();
    _generation++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() { _loading = true; _error = null; _data = null; });
    try {
      final raw = await widget.api.loadRestockPriorities(
        sessionToken: widget.sessionToken, page: _page, pageSize: 25,
        view: _showUnavailable ? 'unavailable' : 'actionable',
        unit: widget.unit, scopeCategory: widget.category,
        scopeProductId: widget.productId, search: _search.text.trim(),
        scopeSearch: widget.scopeSearch);
      if (!mounted || generation != _generation) return;
      final result = StoreRestockPage.fromJson(raw);
      if (result.page != _page ||
          result.view != (_showUnavailable ? 'unavailable' : 'actionable')) {
        throw const FormatException('Unexpected priority page.');
      }
      setState(() => _data = result);
    } on ForecastApiException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } catch (_) {
      if (mounted && generation == _generation) setState(() =>
        _error = 'Store priorities could not be loaded. Try again.');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _searchChanged(String _) {
    _generation++;
    _debounce?.cancel();
    setState(() { _page = 1; _data = null; _loading = true; });
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedView = _showUnavailable ? 'unavailable' : 'actionable';
    final data = _data?.view == selectedView ? _data : null;
    final summary = widget.initial;
    return _ForecastOverviewModalFrame(title: 'Store Restock Priorities',
      subtitle: 'Provisional LightGBM Restock Guidance · ${widget.scopeLabel}',
      icon: LucideIcons.packagePlus,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Wrap(spacing: 12, runSpacing: 6, children: [
            Text('Current ${summary?.currentCount ?? '—'}'),
            Text('Actionable ${summary?.totalCount ?? '—'}'),
            Text('Stale ${summary?.staleCount ?? '—'}'),
            Text('Unavailable ${summary?.unavailableCount ?? '—'}'),
          ].map((child) => DefaultTextStyle(style: const TextStyle(
            color: _forecastMuted, fontSize: 12), child: child)).toList())),
        Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: TextField(controller: _search, onChanged: _searchChanged,
            decoration: InputDecoration(
              labelText: 'Search product or SKU', prefixIcon: const Icon(LucideIcons.search, size: 18),
              isDense: true, border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)))),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, runSpacing: 2, children: [
            _priorityTab('Ranked priorities', !_showUnavailable, () {
              setState(() { _showUnavailable = false; _page = 1; });
              _load();
            }),
            _priorityTab('Unavailable (${summary?.unavailableCount ?? '—'})',
              _showUnavailable, () {
                setState(() { _showUnavailable = true; _page = 1; });
                _load();
              }),
          ])),
        const Divider(height: 1, color: _forecastLine),
        const _RestockModalTableHeader(),
        if (_error != null) Padding(padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12))),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ])),
        if (_loading) const LinearProgressIndicator(color: _forecastAccent, minHeight: 2),
        Expanded(child: _showUnavailable
          ? data == null || data.unavailableItems.isEmpty
            ? Center(child: Text(_loading ? 'Loading unavailable products...'
              : _error != null ? 'Unable to display unavailable products.'
              : 'No unavailable recommendations match this search.',
              style: const TextStyle(color: _forecastMuted)))
            : ListView.builder(key: ValueKey('restock-unavailable-$_page'),
                itemCount: data.unavailableItems.length,
                itemBuilder: (context, index) {
                  final item = data.unavailableItems[index];
                  return _RestockModalTableRow(
                    productName: item.productName,
                    sku: item.sku,
                    status: Column(crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min, children: [
                        const Text('Unavailable', style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w600, color: Colors.red)),
                        const SizedBox(height: 3),
                        Text(item.reason, style: const TextStyle(
                          fontSize: 12, color: _forecastMuted, height: 1.4)),
                      ]),
                    onOpen: () => Navigator.pop(context, item.productId),
                  );
                })
          : data == null || data.items.isEmpty
            ? Center(child: Text(_loading ? 'Loading ranked priorities...'
              : _error != null ? 'Unable to display ranked priorities.'
              : 'No actionable priorities match this search.',
              style: const TextStyle(color: _forecastMuted)))
            : ListView.builder(key: ValueKey('restock-page-$_page'),
                itemCount: data.items.length,
                itemBuilder: (context, index) {
                  final item = data.items[index];
                  final statusLabel = item.status == 'recommend_order'
                    ? 'Restock Suggested' : 'Review Replenishment';
                  return _RestockModalTableRow(
                    productName: item.productName,
                    sku: item.sku,
                    status: _ForecastDefinition(label: statusLabel,
                      definition: _restockStatusDefinitions[statusLabel]!),
                    onOpen: () => Navigator.pop(context, item.productId),
                  );
                })),
        if (data != null)
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: [
              Expanded(child: Text('Page $_page of ${max(1, data.pageCount)} · '
                '${_showUnavailable ? data.unavailableCount : data.totalCount} ${_showUnavailable ? 'unavailable' : 'actionable'}',
                style: const TextStyle(color: _forecastMuted, fontSize: 11))),
              IconButton(tooltip: 'Previous page', onPressed: _loading || _page <= 1 ? null : () {
                setState(() => _page--); _load();
              }, icon: const Icon(LucideIcons.chevronLeft, size: 18)),
              IconButton(tooltip: 'Next page', onPressed: _loading || _page >= data.pageCount ? null : () {
                setState(() => _page++); _load();
              }, icon: const Icon(LucideIcons.chevronRight, size: 18)),
            ])),
      ]),
    );
  }

  Widget _priorityTab(String label, bool selected, VoidCallback onSelect) =>
    Semantics(selected: selected, child: Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(
        color: selected ? _forecastAccent : Colors.transparent, width: 2))),
      child: TextButton(onPressed: selected ? null : onSelect,
        style: TextButton.styleFrom(foregroundColor: _forecastBody,
          disabledForegroundColor: _forecastAccentDark,
          textStyle: TextStyle(fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        child: Text(label))));
}

class _RestockModalTableHeader extends StatelessWidget {
  const _RestockModalTableHeader();

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    if (constraints.maxWidth < 520) return const SizedBox.shrink();
    return const ColoredBox(color: _forecastBackground,
      child: Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          Expanded(flex: 3, child: Text('PRODUCT',
            style: TextStyle(fontSize: 11, color: _forecastMuted))),
          SizedBox(width: 8),
          Expanded(flex: 4, child: Text('STATUS',
            style: TextStyle(fontSize: 11, color: _forecastMuted))),
          SizedBox(width: 4),
          SizedBox(width: 94, child: Text('ACTION', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11, color: _forecastMuted))),
        ])));
  });
}

class _RestockModalTableRow extends StatelessWidget {
  const _RestockModalTableRow({required this.productName, required this.sku,
    required this.status, required this.onOpen});

  final String productName;
  final String sku;
  final Widget status;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final compact = constraints.maxWidth < 520;
    final productDetails = Column(crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, children: [
        Text(productName, style: const TextStyle(fontSize: 13,
          fontWeight: FontWeight.w600, color: _forecastInk)),
        if (sku.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sku, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: _forecastMuted)),
        ],
      ]);
    final action = TextButton(onPressed: onOpen,
      style: TextButton.styleFrom(foregroundColor: _forecastAccentDark,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        minimumSize: const Size(0, 34)),
      child: const Text('View details', style: TextStyle(fontSize: 11)));
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(border: Border(
        bottom: BorderSide(color: _forecastHairline))),
      child: compact
        ? Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
              productDetails,
              const SizedBox(height: 7),
              status,
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerRight, child: action),
            ])
        : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(flex: 3, child: productDetails),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: Align(alignment: Alignment.centerLeft,
              child: status)),
            const SizedBox(width: 4),
            SizedBox(width: 94, child: Align(alignment: Alignment.centerRight,
              child: action)),
          ]),
    );
  });
}

class _SalesHistoryCoverageDialog extends StatefulWidget {
  const _SalesHistoryCoverageDialog({required this.api, required this.sessionToken,
    required this.model, required this.scopeLabel, required this.coverage,
    this.unit, this.category, this.productId, this.scopeSearch});

  final ForecastingApiService api;
  final String sessionToken;
  final String model;
  final String scopeLabel;
  final Map<String, dynamic> coverage;
  final String? unit;
  final String? category;
  final String? productId;
  final String? scopeSearch;

  @override
  State<_SalesHistoryCoverageDialog> createState() => _SalesHistoryCoverageDialogState();
}

class _SalesHistoryCoverageDialogState extends State<_SalesHistoryCoverageDialog> {
  static const _labels = <String, String>{
    'no_sales': 'No recorded sales', 'limited': 'Limited history',
    'sufficient': 'Sufficient history', 'not_evaluated': 'Not evaluated',
  };
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  String _state = 'no_sales';
  int _page = 1;
  int _pageCount = 0;
  int _total = 0;
  int _generation = 0;
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); });
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true; _error = null; _items = const [];
      _total = 0; _pageCount = 0;
    });
    try {
      final response = await widget.api.loadHistoryCoverageProducts(
        sessionToken: widget.sessionToken, model: widget.model,
        state: _state, page: _page, pageSize: 25,
        unit: widget.unit, scopeCategory: widget.category,
        scopeProductId: widget.productId, search: _search.text.trim(),
        scopeSearch: widget.scopeSearch);
      if (!mounted || generation != _generation) return;
      if (response['available'] != true || response['state'] != _state ||
          response['items'] is! List || response['total_count'] is! int ||
          response['page_count'] is! int || response['page'] != _page) {
        throw const FormatException('Invalid history breakdown response.');
      }
      final rows = <Map<String, dynamic>>[];
      for (final value in response['items'] as List) {
        if (value is! Map) throw const FormatException('Invalid history product.');
        final row = Map<String, dynamic>.from(value);
        if (row['state'] != _state || row['product_name'] is! String ||
            row['product_id'] is! String || row['reason'] is! String) {
          throw const FormatException('Invalid history classification.');
        }
        rows.add(row);
      }
      setState(() {
        _items = rows;
        _total = response['total_count'] as int;
        _pageCount = response['page_count'] as int;
      });
    } on ForecastApiException catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } catch (_) {
      if (mounted && generation == _generation) setState(() =>
        _error = 'Historical product details could not be loaded. Try again.');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _searchChanged(String _) {
    _generation++;
    _debounce?.cancel();
    setState(() { _page = 1; _items = const []; _loading = true; });
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  Widget build(BuildContext context) => _ForecastOverviewModalFrame(
    title: 'Sales History Coverage',
    subtitle: '${widget.scopeLabel} · ${widget.model == 'calibrated_blend' ? 'Calibrated Blend' : widget.model}',
    icon: LucideIcons.chartNoAxesCombined,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Wrap(spacing: 7, runSpacing: 7, children: [
          for (final entry in _labels.entries)
            ChoiceChip(label: Text('${entry.value} (${widget.coverage[entry.key] ?? 0})'),
              selected: _state == entry.key,
              selectedColor: _forecastAccentSoft,
              side: const BorderSide(color: _forecastLine),
              labelStyle: TextStyle(fontSize: 11,
                color: _state == entry.key ? _forecastAccentDark : _forecastBody),
              onSelected: (_) {
                setState(() { _state = entry.key; _page = 1; _items = const []; });
                _load();
              }),
        ])),
      Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: TextField(controller: _search, onChanged: _searchChanged,
          decoration: InputDecoration(labelText: 'Search product or SKU',
            prefixIcon: const Icon(LucideIcons.search, size: 18),
            isDense: true, border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8))))),
      const Divider(height: 1, color: _forecastLine),
      if (_error != null) Padding(padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12))),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ])),
      if (_loading) const LinearProgressIndicator(color: _forecastAccent, minHeight: 2),
      Expanded(child: _items.isEmpty
        ? Center(child: Text(_loading ? 'Loading ${_labels[_state]}...'
            : _error != null ? 'Unable to display historical products.'
            : 'No ${_labels[_state]?.toLowerCase()} products match this search.',
            style: const TextStyle(color: _forecastMuted)))
        : ListView.builder(key: ValueKey('history-$_state-$_page'),
            itemCount: _items.length,
            itemBuilder: (context, index) {
              final row = _items[index];
              final name = row['product_name'] as String;
              final sku = row['sku']?.toString() ?? '';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
                decoration: const BoxDecoration(border: Border(
                  bottom: BorderSide(color: _forecastHairline))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sku.isEmpty ? name : '$name · $sku',
                      style: const TextStyle(fontSize: 13,
                        fontWeight: FontWeight.w600, color: _forecastInk)),
                    const SizedBox(height: 4),
                    Text(row['reason'] as String,
                      style: const TextStyle(fontSize: 12, color: _forecastMuted)),
                  ]));
            })),
      Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Row(children: [
          Expanded(child: Text('$_total matching · page $_page of ${max(1, _pageCount)}',
            style: const TextStyle(color: _forecastMuted, fontSize: 11))),
          IconButton(tooltip: 'Previous page', onPressed: _loading || _page <= 1 ? null : () {
            setState(() => _page--); _load();
          }, icon: const Icon(LucideIcons.chevronLeft, size: 18)),
          IconButton(tooltip: 'Next page', onPressed: _loading || _page >= _pageCount ? null : () {
            setState(() => _page++); _load();
          }, icon: const Icon(LucideIcons.chevronRight, size: 18)),
        ])),
    ]),
  );
}
