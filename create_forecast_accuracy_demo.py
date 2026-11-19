"""Reversible UI-only Forecast Accuracy demonstration patch for Inventory Plus.

Run from repository root: python create_forecast_accuracy_demo.py
Enable only when taking clearly labeled prototype screenshots:
  --dart-define=FORECAST_ACCURACY_DEMO=true

No forecasting, sales, persistence, tracking, or accuracy calculations are changed.
"""

from pathlib import Path
import shutil
import tempfile

SOURCE = Path('lib/ui/forecasting_page.dart')
FLAG_ANCHOR = "const _forecastOverviewTrace = bool.fromEnvironment('FORECAST_OVERVIEW_TRACE');"
VIEW_ANCHOR = """            if (_selectedProductId == null)
              const _MessageCard("""
WIDGET_ANCHOR = 'class _TrackingForecastAccuracy extends StatefulWidget {'

FLAG = """// FORECAST_ACCURACY_DEMO_START (UI PROTOTYPE ONLY — NOT LIVE DATA)
// TODO(FORECAST_ACCURACY_DEMO): Remove this flag, demo widget, and view branch
// after saved 28-day forecast evaluations are available for verification.
// This intentionally has NO influence on live forecasting or evaluation logic.
const bool _forecastAccuracyDemoEnabled = bool.fromEnvironment(
  'FORECAST_ACCURACY_DEMO',
  defaultValue: false,
);
// FORECAST_ACCURACY_DEMO_END
"""

VIEW = """            // FORECAST_ACCURACY_DEMO_START: Replace only Accuracy content
            // with unmistakably illustrative UI when explicitly enabled.
            if (_forecastAccuracyDemoEnabled)
              _ForecastAccuracyDemo(
                productName: _items
                        .where((item) => item.id == _selectedProductId)
                        .map((item) => item.name)
                        .firstOrNull ??
                    'Selected product',
                unit: _items
                        .where((item) => item.id == _selectedProductId)
                        .map((item) => item.unit)
                        .firstOrNull ??
                    'pcs',
              )
            // FORECAST_ACCURACY_DEMO_END: normal live behavior below.
            else if (_selectedProductId == null)
              const _MessageCard("""

WIDGET = r'''
// FORECAST_ACCURACY_DEMO_START -------------------------------------------------
// TEMPORARY HARDCODED CHAPTER 4 UI PROTOTYPE — DEMO DATA, NOT REAL EVALUATIONS.
// These values have NOT been calculated from Supabase, saved forecasts or sales.
// This widget is gated by --dart-define=FORECAST_ACCURACY_DEMO=true.
// TODO(FORECAST_ACCURACY_DEMO): Delete the widget and demo branch once genuine
// completed saved-forecast evaluations can populate the existing live widgets.
// Illustrative math: (|112-100| + |95-105|) / (100+105) *100 = 10.7% WAPE;
// bias: ((112+95) - (100+105)) / (100+105) *100 = +1.0% (rounded).
class _ForecastAccuracyDemo extends StatefulWidget {
  const _ForecastAccuracyDemo({
    required this.productName,
    required this.unit,
  });

  final String productName;
  final String unit;

  @override
  State<_ForecastAccuracyDemo> createState() => _ForecastAccuracyDemoState();
}

class _ForecastAccuracyDemoState extends State<_ForecastAccuracyDemo> {
  bool _showMethodology = false;

  Widget _card(Widget child) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _trackingLine),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );

  Widget _label(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: _trackingMuted)),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(
          fontSize: 19, fontWeight: FontWeight.w600, color: _trackingInk,
        )),
      ],
    ),
  );

  Widget _monitorRow(String period, String progress, double fraction) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LayoutBuilder(builder: (context, limits) {
          final label = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.productName, maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w600, color: _trackingInk)),
              const SizedBox(height: 3),
              Text(period, style: const TextStyle(fontSize: 12,
                  color: _trackingMuted)),
              const SizedBox(height: 3),
              const Text('Eligibility: Awaiting period completion',
                  style: TextStyle(fontSize: 11, color: _trackingAccentStrong)),
            ],
          );
          final meter = Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(progress, style: const TextStyle(fontSize: 12,
                  color: _trackingBody)),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 5,
                  color: _trackingAccent,
                  backgroundColor: _trackingLine,
                ),
              ),
            ],
          );
          if (limits.maxWidth < 390) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [label, const SizedBox(height: 10), meter],
            );
          }
          return Row(children: [
            Expanded(child: label),
            const SizedBox(width: 14),
            SizedBox(width: 116, child: meter),
          ]);
        }),
      );

  Widget _tableRow(List<String> values, List<int> widths,
      {bool header = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: header ? _trackingSubtle : Colors.white,
        border: const Border(bottom: BorderSide(color: _trackingLine)),
      ),
      child: Row(children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            flex: widths[i],
            child: Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 9),
              child: Text(
                values[i],
                maxLines: header ? 3 : 4,
                overflow: TextOverflow.ellipsis,
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: TextStyle(
                  fontSize: header ? 11 : 12,
                  color: header ? _trackingMuted : _trackingInk,
                  fontWeight: header ? FontWeight.w500 : FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _horizontalTable({required double minimumWidth,
      required List<Widget> rows}) => _card(
    LayoutBuilder(builder: (context, limits) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: max(minimumWidth, limits.maxWidth),
          child: Column(children: rows),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.insights_outlined, color: _trackingAccent,
                        size: 25),
                    SizedBox(width: 10),
                    Text('Forecast performance preview', style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600,
                      color: _trackingInk,
                    )),
                  ]),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _trackingAccentSoft,
                      border: Border.all(color: _trackingAccent),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('DEMO DATA · NOT LIVE',
                      style: TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _trackingAccentStrong)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Illustrative interface for monitoring saved 28-day forecasts '
                'and evaluating completed periods against recorded customer sales.',
                style: TextStyle(fontSize: 12, height: 1.45,
                    color: _trackingMuted),
              ),
              const SizedBox(height: 18),
              LayoutBuilder(builder: (context, limits) {
                final values = [
                  _label('Saved forecasts monitored', '4'),
                  _label('Completed eligible evaluations', '2'),
                  _label('Current status', '2 awaiting evaluation'),
                ];
                if (limits.maxWidth < 540) {
                  return Wrap(spacing: 22, runSpacing: 14,
                    children: [for (final value in values)
                      SizedBox(width: limits.maxWidth < 350
                        ? limits.maxWidth
                        : (limits.maxWidth - 22) / 2,
                        child: value)],
                  );
                }
                return Row(children: [
                  for (final value in values) Expanded(child: value),
                ]);
              }),
              const SizedBox(height: 16),
              const Divider(color: _trackingLine),
              const SizedBox(height: 12),
              const Text('Monitored 28-day forecasts', style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: _trackingInk)),
              _monitorRow('Nov 1–28, 2026', '19 / 28 days', 19 / 28),
              const Divider(height: 1, color: _trackingLine),
              _monitorRow('Nov 15–Dec 12, 2026', '5 / 28 days', 5 / 28),
              const SizedBox(height: 5),
              const Text('Example monitoring progress only. Periods and '
                'percentages are not linked to saved forecasts.',
                style: TextStyle(fontSize: 11, color: _trackingMuted)),
            ],
          ),
        )),
        const SizedBox(height: 20),
        const Text('Historical Forecast Performance',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              color: _trackingInk)),
        const SizedBox(height: 5),
        const Text('Sample evaluation summary by inventory unit · '
          'not measured system accuracy',
          style: TextStyle(fontSize: 12, color: _trackingMuted)),
        const SizedBox(height: 10),
        _horizontalTable(minimumWidth: 610, rows: [
          _tableRow(['Inventory Unit', 'Eligible Evaluations', 'WAPE',
            'Forecast Bias'], [25, 27, 23, 25], header: true),
          _tableRow([widget.unit, '2', '10.7%', '+1.0%'],
            [25, 27, 23, 25]),
        ]),
        const SizedBox(height: 18),
        const Text('Completed forecast evaluations · sample records',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
              color: _trackingInk)),
        const SizedBox(height: 10),
        _horizontalTable(minimumWidth: 850, rows: [
          _tableRow(['Saved / Product', 'Forecast Period',
             'Forecasted Demand', 'Actual Sales', 'Status'],
             [29, 23, 17, 16, 15], header: true),
          _tableRow(['Jul 31, 2026\n${widget.productName}',
             'Aug 1–28, 2026', '112 ${widget.unit}',
             '100 ${widget.unit}', 'Evaluated'],
             [29, 23, 17, 16, 15]),
          _tableRow(['Aug 31, 2026\n${widget.productName}',
             'Sep 1–28, 2026', '95 ${widget.unit}',
             '105 ${widget.unit}', 'Evaluated'],
             [29, 23, 17, 16, 15]),
        ]),
        const SizedBox(height: 14),
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() =>
                  _showMethodology = !_showMethodology),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 13),
                child: Row(children: [
                  const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('How is forecast performance measured?',
                        style: TextStyle(fontWeight: FontWeight.w600,
                          color: _trackingInk, fontSize: 13)),
                      SizedBox(height: 3),
                      Text('Data eligibility, WAPE and Bias',
                        style: TextStyle(color: _trackingMuted,
                          fontSize: 12)),
                    ],
                  )),
                  Icon(_showMethodology
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                      color: _trackingMuted),
                ]),
              ),
            ),
            if (_showMethodology)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(color: _trackingLine),
                    SizedBox(height: 12),
                    Text('WAPE = Σ|forecast − actual| ÷ Σactual × 100',
                      style: TextStyle(fontSize: 12, color: _trackingInk)),
                    SizedBox(height: 8),
                    Text('Bias = (Σforecast − Σactual) ÷ Σactual × 100',
                      style: TextStyle(fontSize: 12, color: _trackingInk)),
                    SizedBox(height: 9),
                    Text('Example: forecast totals 207 and actual sales '
                      'total 205, so WAPE = 22/205 = 10.7% and Bias = '
                      '2/205 = +1.0%. A saved 28-day period must finish '
                      'before real sales can be evaluated.',
                      style: TextStyle(fontSize: 12, height: 1.45,
                        color: _trackingMuted)),
                  ],
                ),
              ),
          ],
        )),
        const SizedBox(height: 10),
        const Text('DEMONSTRATION ONLY: Values above are hardcoded '
          'illustrations for a UI prototype, not measured forecast results.',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: _trackingAccentStrong)),
      ],
    );
  }
}
// FORECAST_ACCURACY_DEMO_END ---------------------------------------------------

'''


def main():
    if not SOURCE.is_file():
        raise SystemExit(f'[ERROR] File not found: {SOURCE}. Run this script from the repository root.')
    original = SOURCE.read_text(encoding='utf-8')
    if 'FORECAST_ACCURACY_DEMO_START' in original:
        raise SystemExit('[SAFE STOP] Forecast Accuracy demo markers already exist. Nothing changed.')
    anchors = [FLAG_ANCHOR, VIEW_ANCHOR, WIDGET_ANCHOR]
    for anchor in anchors:
        count = original.count(anchor)
        if count != 1:
            raise SystemExit(f'[SAFE STOP] Expected exactly one anchor, found {count}: {anchor[:85]}')
    backup_dir = Path(tempfile.mkdtemp(prefix='inventory_plus_accuracy_demo_backup_'))
    backup = backup_dir / 'forecasting_page.dart'
    shutil.copy2(SOURCE, backup)
    updated = original.replace(FLAG_ANCHOR, FLAG_ANCHOR + '\n\n' + FLAG, 1)
    updated = updated.replace(VIEW_ANCHOR, VIEW, 1)
    updated = updated.replace(WIDGET_ANCHOR, WIDGET + WIDGET_ANCHOR, 1)
    SOURCE.write_text(updated, encoding='utf-8')
    print('Forecast Accuracy demo UI added to lib/ui/forecasting_page.dart.')
    print(f'Original: {len(original.splitlines())} lines; updated: {len(updated.splitlines())} lines.')
    print(f'Backup: {backup}')
    print('Ctrl+F: FORECAST_ACCURACY_DEMO_START')
    print('Enable only for demo: --dart-define=FORECAST_ACCURACY_DEMO=true')
    print('Normal live Accuracy remains unchanged when demo flag is omitted.')
    print('Next: git diff --check; git diff -- lib/ui/forecasting_page.dart')


if __name__ == '__main__':
    main()
