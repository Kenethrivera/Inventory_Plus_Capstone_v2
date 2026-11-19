import 'package:flutter/material.dart';

/// Keeps camera controls at the edges while the primary action stays centered.
class CameraFooter extends StatelessWidget {
  const CameraFooter({
    super.key,
    required this.leading,
    required this.center,
    required this.trailing,
  });

  final Widget leading;
  final Widget center;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 52, height: 52, child: Center(child: leading)),
        Expanded(child: Center(child: center)),
        SizedBox(width: 52, height: 52, child: Center(child: trailing)),
      ],
    );
  }
}
