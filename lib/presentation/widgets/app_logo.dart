import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'package:tk_music/core/theme/app_theme.dart';

/// Logo de la app: un ícono de auriculares dibujado a mano con [CustomPainter]
/// dentro de una insignia circular, usado en el splash screen.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppTheme.accentGradient,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1046D6).withValues(alpha: 0.45),
            blurRadius: size * 0.35,
            spreadRadius: size * 0.02,
          ),
        ],
      ),
      padding: EdgeInsets.all(size * 0.24),
      child: CustomPaint(
        painter: _HeadphonesPainter(color: Colors.white),
        size: Size.square(size),
      ),
    );
  }
}

class _HeadphonesPainter extends CustomPainter {
  const _HeadphonesPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w / 2, h * 0.46);
    final radius = w * 0.36;

    final bandPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.14
      ..strokeCap = StrokeCap.round;

    // Diadema: mitad superior de un círculo.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi,
      false,
      bandPaint,
    );

    final cupPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final cupWidth = w * 0.22;
    final cupHeight = h * 0.34;
    final cupY = center.dy + radius * 0.55;

    final leftCup = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx - radius, cupY),
        width: cupWidth,
        height: cupHeight,
      ),
      Radius.circular(cupWidth / 2),
    );
    final rightCup = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx + radius, cupY),
        width: cupWidth,
        height: cupHeight,
      ),
      Radius.circular(cupWidth / 2),
    );

    canvas.drawRRect(leftCup, cupPaint);
    canvas.drawRRect(rightCup, cupPaint);
  }

  @override
  bool shouldRepaint(covariant _HeadphonesPainter oldDelegate) =>
      oldDelegate.color != color;
}
