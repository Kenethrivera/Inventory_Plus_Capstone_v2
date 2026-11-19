import 'package:flutter/material.dart';

class StartupRestorationSurface extends StatelessWidget {
  const StartupRestorationSurface({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Color(0xFFF7F6F4),
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
                  color: Color(0xFF171717),
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Restoring your session\u2026',
                style: TextStyle(color: Color(0xFF83776F), fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _StartupMark extends StatefulWidget {
  const _StartupMark();

  @override
  State<_StartupMark> createState() => _StartupMarkState();
}

class _StartupMarkState extends State<_StartupMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 64,
    decoration: const BoxDecoration(
      color: Color(0xFFC83D08),
      borderRadius: BorderRadius.all(Radius.circular(12)),
      boxShadow: [
        BoxShadow(
          color: Color(0x33C83D08),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    clipBehavior: Clip.antiAlias,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _RestockingMarkPainter(
          progress: Curves.easeOutCubic.transform(_controller.value),
        ),
      ),
    ),
  );
}

class _RestockingMarkPainter extends CustomPainter {
  const _RestockingMarkPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024, size.height / 1024);

    final whiteLine = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 58
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final package = Path()
      ..moveTo(512, 252)
      ..lineTo(760, 380)
      ..lineTo(512, 512)
      ..lineTo(264, 380)
      ..close()
      ..moveTo(264, 380)
      ..lineTo(264, 660)
      ..lineTo(512, 796)
      ..lineTo(760, 660)
      ..lineTo(760, 380)
      ..moveTo(512, 512)
      ..lineTo(512, 796);

    canvas.save();
    canvas.translate(0, -70 * (1 - progress));
    canvas.drawPath(package, whiteLine);
    canvas.restore();

    whiteLine.color = Colors.white.withValues(alpha: 0.7 + 0.3 * progress);
    canvas.drawLine(const Offset(264, 855), const Offset(760, 855), whiteLine);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RestockingMarkPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
