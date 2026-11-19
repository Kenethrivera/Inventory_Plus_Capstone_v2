import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/ui/widgets/history_period_controls.dart';

void main() {
  const orange = Color(0xFFC83D08);

  for (final mode in [HistoryPeriodMode.daily, HistoryPeriodMode.monthly]) {
    testWidgets('${mode.label} picker uses the staff orange theme', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(700, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final selection = HistoryPeriodSelection.current(mode: mode);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: HistoryPeriodControls(
                selection: selection,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip(selection.displayLabel));
      await tester.pumpAndSettle();

      expect(
        find.text(
          mode == HistoryPeriodMode.daily ? 'Select date' : 'Select month',
        ),
        findsOneWidget,
      );
      final select = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Select'),
      );
      expect(select.style?.backgroundColor?.resolve({}), orange);
    });
  }
}
