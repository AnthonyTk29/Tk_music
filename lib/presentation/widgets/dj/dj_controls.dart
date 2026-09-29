import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Colores del modo DJ, al estilo VirtualDJ: fondo casi negro, paneles
/// grises oscuros, deck A azul y deck B rojo anaranjado.
class DjColors {
  static const background = Color(0xFF0A0B0F);
  static const panel = Color(0xFF15171D);
  static const panelHigh = Color(0xFF1D2028);
  static const border = Color(0xFF2A2E38);
  static const text = Color(0xFFE6E8EE);
  static const muted = Color(0xFF8A90A0);
  static const deckA = Color(0xFF1FA2FF);
  static const deckB = Color(0xFFFF4D2E);
  static const cue = Color(0xFFFFB020);
  static const loop = Color(0xFF3DDC84);

  static const hotCues = [
    Color(0xFFFF3B5C),
    Color(0xFFFF9F1C),
    Color(0xFFFFE14D),
    Color(0xFF3DDC84),
    Color(0xFF20C6E6),
    Color(0xFF4F7CFF),
    Color(0xFFB45CFF),
    Color(0xFFFF5CD6),
  ];

  static Color forDeck(String label) => label == 'A' ? deckA : deckB;
}

/// Botón cuadrado tipo pad de controlador: se ilumina con [color] cuando
/// está activo. Clic derecho o mantener apretado = [onSecondary].
class DjPad extends StatelessWidget {
  const DjPad({
    super.key,
    required this.label,
    required this.color,
    this.active = false,
    this.onTap,
    this.onSecondary,
    this.icon,
    this.tooltip,
    this.dense = false,
  });

  final String label;
  final Color color;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onSecondary;
  final IconData? icon;
  final String? tooltip;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = active
        ? Colors.black
        : enabled
            ? color
            : DjColors.muted.withValues(alpha: 0.5);
    final pad = GestureDetector(
      onSecondaryTap: onSecondary,
      onLongPress: onSecondary,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(
                horizontal: dense ? 4 : 6, vertical: dense ? 4 : 6),
            decoration: BoxDecoration(
              color: active ? color : DjColors.panelHigh,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active
                    ? color
                    : (enabled
                        ? color.withValues(alpha: 0.55)
                        : DjColors.border),
                width: 1.2,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                          color: color.withValues(alpha: 0.55), blurRadius: 12)
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: icon != null
                  ? Icon(icon, color: fg, size: dense ? 18 : 22)
                  : Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w800,
                        fontSize: dense ? 11 : 13,
                        letterSpacing: 0.5,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? pad : Tooltip(message: tooltip!, child: pad);
  }
}

/// Perilla giratoria (EQ, GAIN, volumen master): se arrastra hacia
/// arriba/abajo o con la rueda del mouse; doble clic la vuelve al centro.
/// El valor [center] (0 dB) queda siempre apuntando arriba al medio aunque
/// el rango no sea simétrico (el ecualizador va de -26 a +6): la mitad
/// izquierda del giro cubre de [min] a [center] y la derecha de [center] a
/// [max].
class DjKnob extends StatelessWidget {
  const DjKnob({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.label,
    required this.color,
    this.center = 0,
    this.size = 44,
  });

  final double value;
  final double min;
  final double max;
  final double center;
  final ValueChanged<double> onChanged;
  final String label;
  final Color color;
  final double size;

  double _toFraction(double v) => v <= center
      ? 0.5 * (v - min) / (center - min)
      : 0.5 + 0.5 * (v - center) / (max - center);

  double _fromFraction(double f) => f <= 0.5
      ? min + (center - min) * (f / 0.5)
      : center + (max - center) * ((f - 0.5) / 0.5);

  void _nudge(double deltaFraction) {
    final f = (_toFraction(value) + deltaFraction).clamp(0.0, 1.0);
    // Engancha el centro al pasar cerca, como el "clic" de una perilla real.
    final snapped = (f - 0.5).abs() < 0.015 ? 0.5 : f;
    onChanged(_fromFraction(snapped).clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _nudge(-event.scrollDelta.dy / 2000);
            }
          },
          child: GestureDetector(
            onVerticalDragUpdate: (d) => _nudge(-d.delta.dy / 180),
            onDoubleTap: () => onChanged(center),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: CustomPaint(
                size: Size.square(size),
                painter: _KnobPainter(
                  fraction: _toFraction(value.clamp(min, max)),
                  centerFraction: 0.5,
                  color: color,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                color: DjColors.muted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8)),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter({
    required this.fraction,
    required this.centerFraction,
    required this.color,
  });

  final double fraction;
  final double centerFraction;
  final Color color;

  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final track = Paint()
      ..color = DjColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: c, radius: r - 3);
    canvas.drawArc(rect, _start, _sweep, false, track);
    final from = _start + _sweep * centerFraction;
    final to = _start + _sweep * fraction;
    canvas.drawArc(
      rect,
      math.min(from, to),
      (to - from).abs(),
      false,
      track..color = color,
    );
    canvas.drawCircle(
        c,
        r - 8,
        Paint()
          ..shader = const RadialGradient(
            colors: [Color(0xFF3A3F4B), Color(0xFF1B1E25)],
          ).createShader(Rect.fromCircle(center: c, radius: r - 8)));
    final angle = to;
    canvas.drawLine(
      c + Offset(math.cos(angle), math.sin(angle)) * (r * 0.2),
      c + Offset(math.cos(angle), math.sin(angle)) * (r - 10),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.fraction != fraction || old.color != color;
}

/// Fader vertical (volumen del canal, pitch).
class DjVerticalFader extends StatelessWidget {
  const DjVerticalFader({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.color,
    this.onDoubleTap,
    this.inverted = false,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback? onDoubleTap;
  final Color color;

  /// Pitch: arriba = más lento (como en los platos), abajo = más rápido.
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: color,
        inactiveTrackColor: DjColors.border,
        thumbColor: const Color(0xFFD9DCE3),
        overlayColor: color.withValues(alpha: 0.15),
        thumbShape: const _FaderThumb(),
        trackShape: const RectangularSliderTrackShape(),
      ),
      child: Slider(
        value: inverted ? (max + min - value) : value,
        min: min,
        max: max,
        onChanged: (v) => onChanged(inverted ? (max + min - v) : v),
      ),
    );
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _FaderScalePainter(
                centerMark: min < 0 && max > 0,
              ),
            ),
          ),
          RotatedBox(quarterTurns: 3, child: slider),
        ],
      ),
    );
  }
}

/// Riel del fader con marcas (y la del centro en el pitch), como el de un
/// controlador.
class _FaderScalePainter extends CustomPainter {
  const _FaderScalePainter({required this.centerMark});

  final bool centerMark;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    const inset = 14.0;
    final top = inset;
    final bottom = size.height - inset;
    if (bottom <= top) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(cx - 3, top, cx + 3, bottom),
        const Radius.circular(3),
      ),
      Paint()..color = DjColors.background,
    );
    final tick = Paint()
      ..color = DjColors.muted.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 0; i <= 10; i++) {
      final y = top + (bottom - top) * i / 10;
      final long = i % 5 == 0;
      canvas.drawLine(
          Offset(cx + 8, y), Offset(cx + (long ? 16 : 12), y), tick);
      canvas.drawLine(
          Offset(cx - 8, y), Offset(cx - (long ? 16 : 12), y), tick);
    }
    if (centerMark) {
      final y = (top + bottom) / 2;
      canvas.drawLine(
        Offset(cx - 18, y),
        Offset(cx + 18, y),
        Paint()
          ..color = DjColors.cue
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_FaderScalePainter old) => old.centerMark != centerMark;
}

class _FaderThumb extends SliderComponentShape {
  const _FaderThumb();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(14, 26);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final rect = Rect.fromCenter(center: center, width: 12, height: 26);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = const Color(0xFFD9DCE3),
    );
    canvas.drawLine(
      Offset(center.dx, rect.top + 3),
      Offset(center.dx, rect.bottom - 3),
      Paint()
        ..color = Colors.black87
        ..strokeWidth = 2,
    );
  }
}

/// Crossfader horizontal.
class DjCrossfader extends StatelessWidget {
  const DjCrossfader({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () => onChanged(0),
      child: SliderTheme(
        data: const SliderThemeData(
          trackHeight: 6,
          activeTrackColor: DjColors.border,
          inactiveTrackColor: DjColors.border,
          thumbColor: Color(0xFFD9DCE3),
          thumbShape: _CrossfaderThumb(),
          overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: Slider(value: value, min: -1, max: 1, onChanged: onChanged),
      ),
    );
  }
}

class _CrossfaderThumb extends SliderComponentShape {
  const _CrossfaderThumb();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(30, 22);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final rect = Rect.fromCenter(center: center, width: 30, height: 22);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFEDEFF3), Color(0xFFA9AEB9)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(center.dx, rect.top + 3),
      Offset(center.dx, rect.bottom - 3),
      Paint()
        ..color = Colors.black87
        ..strokeWidth = 2,
    );
  }
}

/// Panel oscuro con borde, como los bloques de VirtualDJ.
class DjPanel extends StatelessWidget {
  const DjPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(8),
    this.accent,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: DjColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: accent?.withValues(alpha: 0.45) ?? DjColors.border),
      ),
      child: child,
    );
  }
}
