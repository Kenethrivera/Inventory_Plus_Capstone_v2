import 'package:flutter/material.dart';

class StartupRestorationSurface extends StatelessWidget {
  const StartupRestorationSurface({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Color(0xFFF4F6F8),
    body: Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StartupMark(),
          SizedBox(width: 14),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Inventory Plus',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Restoring your session\u2026',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _StartupMark extends StatelessWidget {
  const _StartupMark();

  @override
  Widget build(BuildContext context) => Container(
    width: 42,
    height: 42,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: Color(0xFF2563EB),
      borderRadius: BorderRadius.all(Radius.circular(12)),
      boxShadow: [
        BoxShadow(
          color: Color(0x382563EB),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: const Text(
      'I+',
      style: TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
