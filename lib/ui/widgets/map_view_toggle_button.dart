import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../store_map.dart';

/// Switches to the other map view using the orange outline used in loading.
class MapViewToggleButton extends StatelessWidget {
  const MapViewToggleButton({
    super.key,
    required this.viewStyle,
    required this.onChanged,
  });

  final MapViewStyle viewStyle;
  final ValueChanged<MapViewStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final showing3D = viewStyle == MapViewStyle.threeD;
    const orange = Color(0xFFC83D08);

    return OutlinedButton.icon(
      onPressed: () => onChanged(
        showing3D ? MapViewStyle.twoD : MapViewStyle.threeD,
      ),
      icon: Icon(showing3D ? LucideIcons.map : LucideIcons.box, size: 16),
      label: Text(showing3D ? '2D plan' : '3D view'),
      style: OutlinedButton.styleFrom(
        foregroundColor: orange,
        side: const BorderSide(color: orange),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
        ),
      ),
    );
  }
}
