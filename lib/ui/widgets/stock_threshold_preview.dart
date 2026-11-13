import 'dart:math' as math;

import 'package:flutter/material.dart';

class StockThresholdPreview extends StatelessWidget {
  const StockThresholdPreview({
    super.key,
    required this.lowPercent,
    required this.criticalPercent,
  });

  final double? lowPercent;
  final double? criticalPercent;

  static const _critical = Color(0xFFDC2626);
  static const _low = Color(0xFFF59E0B);
  static const _healthy = Color(0xFF16A34A);
  static const _muted = Color(0xFF83776F);
  static const _line = Color(0xFFE9E2DC);

  @override
  Widget build(BuildContext context) {
    final low = lowPercent;
    final critical = criticalPercent;
    final hasNumbers =
        low != null && critical != null && low.isFinite && critical.isFinite;
    final criticalShare = hasNumbers ? critical.clamp(0, 100).toDouble() : 0.0;
    final lowShare = hasNumbers
        ? math.max(0.0, low.clamp(0, 100).toDouble() - criticalShare)
        : 0.0;
    final valid = hasNumbers && critical > 0 && critical < low && low <= 100;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Threshold preview',
            style: TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            height: 12,
            child: LayoutBuilder(
              builder: (context, limits) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    SizedBox(
                      key: const Key('stock-band-critical'),
                      width: limits.maxWidth * criticalShare / 100,
                      child: const ColoredBox(
                        color: _critical,
                        child: SizedBox(height: 12),
                      ),
                    ),
                    SizedBox(
                      key: const Key('stock-band-low'),
                      width: limits.maxWidth * lowShare / 100,
                      child: const ColoredBox(
                        color: _low,
                        child: SizedBox(height: 12),
                      ),
                    ),
                    Expanded(
                      key: const Key('stock-band-healthy'),
                      child: ColoredBox(
                        color: hasNumbers ? _healthy : _line,
                        child: SizedBox(height: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _BandLegend(
                color: _critical,
                textColor: Color(0xFF991B1B),
                label: 'Critical',
              ),
              _BandLegend(
                color: _low,
                textColor: Color(0xFF92400E),
                label: 'Low',
              ),
              _BandLegend(
                color: _healthy,
                textColor: Color(0xFF166534),
                label: 'Healthy',
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            valid
                ? 'For 200 sold in 7 days: out at 0, critical through '
                      '${(200 * critical / 100).ceil()}, low through '
                      '${(200 * low / 100).ceil()}, and healthy above that.'
                : !hasNumbers
                ? 'Enter both percentages to preview stock levels.'
                : critical >= low
                ? 'Critical must be below Low; otherwise no product can have a Low status.'
                : 'Use percentages from 0 to 100, with Critical above 0.',
            style: TextStyle(color: valid ? _muted : _critical, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _BandLegend extends StatelessWidget {
  const _BandLegend({
    required this.color,
    required this.textColor,
    required this.label,
  });

  final Color color;
  final Color textColor;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      border: Border.all(color: color.withValues(alpha: .18)),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
