from pathlib import Path
from datetime import datetime
import tempfile
import sys

# ---------------------------------------------------------------------------
# Inventory Plus / Chapter 4 UI prototype
# This script ONLY edits lib/ui/forecasting_page.dart in your current checkout.
# It inserts two clearly marked ILLUSTRATIVE demo-only Flutter widgets.
# Real forecasting, restock recommendations, and sales evidence are unchanged.
# ---------------------------------------------------------------------------

TARGET = Path('lib/ui/forecasting_page.dart')
FLAG_ANCHOR = "const _forecastOverviewTrace = bool.fromEnvironment('FORECAST_OVERVIEW_TRACE');"
FLAG = '''

// FORECAST_OVERVIEW_DEMO_START
// TEMPORARY UI PROTOTYPE FOR CHAPTER 4 SCREENSHOT ONLY.
// Data for Restock Priorities and Sales History Coverage is HARD-CODED.
// Enable ONLY with --dart-define=FORECAST_OVERVIEW_DEMO=true.
// This MUST NOT be treated as live forecasting/recommendation output.
// TODO(FORECAST_OVERVIEW_DEMO): Remove demo flag, cards, and wiring after the
// authoritative store-wide, model-independent APIs become operational.
const bool _forecastOverviewDemoEnabled = bool.fromEnvironment(
  'FORECAST_OVERVIEW_DEMO',
  defaultValue: false,
);
// FORECAST_OVERVIEW_DEMO_END
'''
OLD_PRIORITIES = '''            final priorities = _PlanningPriorityCard(
              pageScoped: savedPage != null,
              unavailable: savedPage != null || products.where((item) =>
                  selectedScope == null || selectedScope.productIds.contains(item.id))
                  .any((item) => !analyses.containsKey(item.id)),
              priorities: value.priorities.where((item) =>
                  selectedScope == null || selectedScope.productIds.contains(item.productId)).toList(growable: false),
              onSelectProduct: onSelectProduct,
            );'''
NEW_PRIORITIES = '''            // FORECAST_OVERVIEW_DEMO: demo-only placeholder; live card is kept.
            final priorities = _forecastOverviewDemoEnabled
                ? const _DemoRestockPrioritiesCard()
                : _PlanningPriorityCard(
                    pageScoped: savedPage != null,
                    unavailable: savedPage != null || products.where((item) =>
                        selectedScope == null || selectedScope.productIds.contains(item.id))
                        .any((item) => !analyses.containsKey(item.id)),
                    priorities: value.priorities.where((item) =>
                        selectedScope == null || selectedScope.productIds.contains(item.productId)).toList(growable: false),
                    onSelectProduct: onSelectProduct,
                  );'''
OLD_COVERAGE = '''                _SalesEvidenceCard(
                  savedCoverage: loading ? null : savedPage?.salesHistoryCoverage,
                  evidenceAvailable: savedPage == null,
                  analyses: analyses.values.toList(growable: false),
                  products: products.where((item) => selectedScope == null || selectedScope.productIds.contains(item.id)).toList(growable: false),
                ),'''
NEW_COVERAGE = '''                // FORECAST_OVERVIEW_DEMO: demo-only placeholder; live card is kept.
                if (_forecastOverviewDemoEnabled)
                  const _DemoSalesHistoryCoverageCard()
                else
                  _SalesEvidenceCard(
                    savedCoverage: loading ? null : savedPage?.salesHistoryCoverage,
                    evidenceAvailable: savedPage == null,
                    analyses: analyses.values.toList(growable: false),
                    products: products.where((item) => selectedScope == null || selectedScope.productIds.contains(item.id)).toList(growable: false),
                  ),'''

DEMO_WIDGETS = r'''
// ---------------------------------------------------------------------------
// FORECAST_OVERVIEW_DEMO_START - HARDCODED UI / SCREENSHOT PROTOTYPE ONLY
// Source of values below: illustrative design fixtures, NOT Supabase, stored
// snapshots, actual demand, or restocking recommendations. Remove this entire
// section together with _forecastOverviewDemoEnabled and its two call sites.
// IMPORTANT: Keep the "DEMO DATA" indicators visible in Chapter 4 screenshots.
// ---------------------------------------------------------------------------
class _DemoRestockPriority {
  const _DemoRestockPriority(this.name, this.category, this.status, this.note);

  final String name;
  final String category;
  final String status;
  final String note;
}

class _DemoRestockPrioritiesCard extends StatelessWidget {
  const _DemoRestockPrioritiesCard();

  // HARDCODED FIXTURES — NOT LIVE RESTOCK RECOMMENDATIONS.
  static const _items = <_DemoRestockPriority>[
    _DemoRestockPriority(
      'Adjustable Wrench', 'Hand Tools', 'Restock Suggested',
      'Check replenishment quantity against current stock.',
    ),
    _DemoRestockPriority(
      'Padlock 40 mm', 'Security Hardware', 'Review Replenishment',
      'Confirm supplier lead time and safety stock.',
    ),
    _DemoRestockPriority(
      'Tile Adhesive', 'Tile Installation', 'Approaching Suggested Stock Level',
      'Inventory is nearing a planning threshold.',
    ),
    _DemoRestockPriority(
      'Hand Drill', 'Hand Tools', 'Monitor Stock Level',
      'Continue monitoring; no urgent action established.',
    ),
    _DemoRestockPriority(
      'Cement 40 kg', 'Masonry Materials', 'Recommendation Unavailable',
      'Review product history and replenishment limitations.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _forecastLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              const Text(
                'Restock priorities',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                    color: _forecastInk),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _forecastAccentSoft,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text('DEMO DATA',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                      color: _forecastAccentDark)),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Text(
            'Intended store-wide, model-independent planning view. '
            'The entries below are illustrative, not live recommendations.',
            style: TextStyle(fontSize: 11, color: _forecastMuted, height: 1.4),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 490;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact)
                  const ColoredBox(
                    color: _forecastBackground,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 3, child: Text('PRODUCT',
                            style: TextStyle(fontSize: 10, color: _forecastMuted))),
                        SizedBox(width: 8),
                        Expanded(flex: 4, child: Text('STATUS / DESCRIPTION',
                            style: TextStyle(fontSize: 10, color: _forecastMuted))),
                        SizedBox(width: 90, child: Text('ACTION',
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 10, color: _forecastMuted))),
                      ]),
                    ),
                  ),
                for (final item in _items)
                  _DemoPriorityRow(item: item, compact: compact),
              ],
            );
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Text(
            'UI prototype only. No stock action is calculated or submitted here.',
            style: TextStyle(fontSize: 11, color: _forecastMuted),
          ),
        ),
      ],
    ),
  );
}

class _DemoPriorityRow extends StatelessWidget {
  const _DemoPriorityRow({required this.item, required this.compact});
  final _DemoRestockPriority item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: _forecastInk)),
        Text(item.category, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: _forecastMuted)),
      ],
    );
    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ForecastDefinition(
          label: item.status,
          definition: _restockStatusDefinitions[item.status] ?? item.note,
        ),
        Text(item.note, maxLines: compact ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: _forecastMuted)),
      ],
    );
    final action = TextButton(
      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
          'Demo data only. No live restock recommendation is attached to this row.',
        )),
      ),
      style: TextButton.styleFrom(
        foregroundColor: _forecastAccentDark,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        minimumSize: const Size(0, 32),
      ),
      child: const Text('View details',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
    );

    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _forecastHairline)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                name,
                const SizedBox(height: 8),
                status,
                Align(alignment: Alignment.centerRight, child: action),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 3, child: name),
                const SizedBox(width: 8),
                Expanded(flex: 4, child: status),
                SizedBox(width: 90, child: action),
              ],
            ),
    );
  }
}

class _DemoSalesHistoryCoverageCard extends StatelessWidget {
  const _DemoSalesHistoryCoverageCard();

  // HARDCODED ILLUSTRATIVE COUNTS — 7 + 14 + 18 + 3 = 42.
  // They do not reflect actual recorded sales or model readiness.
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _forecastLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Expanded(
            child: Text('Sales History Coverage',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  color: _forecastInk)),
          ),
          const _ForecastDefinition(
            label: 'Coverage definitions',
            iconOnly: true,
            definition: 'This card is a prototype. The final implementation '
                'will evaluate all store products independent of selected '
                'forecast model or product scope, using verified completed-sales '
                'history and explicit not-evaluated states.',
          ),
          IconButton(
            onPressed: null,
            tooltip: 'Demo card: refresh unavailable',
            icon: const Icon(LucideIcons.refreshCw,
                size: 16, color: _forecastFaint),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
        ]),
        const SizedBox(height: 3),
        const Text('Store-wide · independent of selected model',
          style: TextStyle(fontSize: 11, color: _forecastMuted)),
        const SizedBox(height: 10),
        const Text('42 products assessed (illustrative)',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: _forecastInk)),
        const SizedBox(height: 10),
        const _DemoCoverageBullet(count: '7', label: 'No recorded sales',
            color: Color(0xFFB45309)),
        const _DemoCoverageBullet(count: '14', label: 'Limited sales history',
            color: Color(0xFFB45309)),
        const _DemoCoverageBullet(count: '18', label: 'Sufficient sales history',
            color: Color(0xFF15803D)),
        const _DemoCoverageBullet(count: '3', label: 'Not evaluated',
            color: _forecastMuted),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(color: _forecastAccentSoft,
              borderRadius: BorderRadius.circular(5)),
          child: const Text('DEMO DATA · not connected to sales history',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                color: _forecastAccentDark)),
        ),
      ],
    ),
  );
}

class _DemoCoverageBullet extends StatelessWidget {
  const _DemoCoverageBullet({
    required this.count, required this.label, required this.color,
  });
  final String count;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Icon(LucideIcons.circle, size: 7, color: color),
      const SizedBox(width: 9),
      Expanded(child: Text(label,
        style: const TextStyle(fontSize: 12, color: _forecastBody))),
      Text(count, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
          color: color)),
    ]),
  );
}
// FORECAST_OVERVIEW_DEMO_END
// ---------------------------------------------------------------------------
'''


def checked_replace(source: str, before: str, after: str, name: str) -> str:
    count = source.count(before)
    if count != 1:
        raise RuntimeError(f'Expected exactly one {name}, found {count}. No files changed.')
    return source.replace(before, after, 1)


def main() -> int:
    if not TARGET.is_file():
        raise RuntimeError('Run this script from the Inventory Plus repository root (folder containing lib/ui/forecasting_page.dart).')
    original_bytes = TARGET.read_bytes()
    original_line_endings = '\r\n' if b'\r\n' in original_bytes else '\n'
    original = original_bytes.decode('utf-8-sig').replace('\r\n', '\n')
    if '_forecastOverviewDemoEnabled' in original:
        raise RuntimeError('Demo patch appears to be installed already. No files changed.')
    updated = checked_replace(original, FLAG_ANCHOR, FLAG_ANCHOR + FLAG, 'flag anchor')
    updated = checked_replace(updated, OLD_PRIORITIES, NEW_PRIORITIES, 'restock card call site')
    updated = checked_replace(updated, OLD_COVERAGE, NEW_COVERAGE, 'coverage card call site')
    updated = checked_replace(updated, 'class _PlanningPriorityCard extends StatelessWidget {',
                              DEMO_WIDGETS + '\nclass _PlanningPriorityCard extends StatelessWidget {',
                              'demo widget insertion anchor')
    if '<<<<<<<' in updated or '>>>>>>> ' in updated:
        raise RuntimeError('The file contains unresolved Git conflict markers. No files changed.')
    temp_dir = Path(tempfile.gettempdir())
    backup = temp_dir / f'inventory_plus_forecasting_before_demo_{datetime.now():%Y%m%d_%H%M%S}.dart'
    backup.write_bytes(original_bytes)
    content = updated.replace('\n', original_line_endings).encode('utf-8')
    TARGET.write_bytes(content)
    print('SUCCESS: Forecasting Overview demo cards installed.')
    print(f'Edited: {TARGET.resolve()}')
    print(f'Original backed up at: {backup}')
    print('Enable demo only with --dart-define=FORECAST_OVERVIEW_DEMO=true')
    print('Demo affects only Restock Priorities and Sales History Coverage.')
    print('No forecasting models, controller logic, Supabase calls or backend code were changed.')
    print('Next: git diff --check; git diff --stat; then run Flutter in demo mode.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, UnicodeError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
