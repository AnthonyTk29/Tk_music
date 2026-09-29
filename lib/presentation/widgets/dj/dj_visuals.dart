import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tk_music/services/dj/band_waveform.dart';
import 'package:tk_music/services/dj/dj_deck.dart';

import 'dj_controls.dart';

/// Colores de la onda por bandas de un deck: graves, medios y agudos (lo
/// que ya sonó se dibuja más apagado). Cada deck tiene los suyos para
/// distinguirlos de un vistazo: el A en rojo/naranja/crema, el B en
/// azul/celeste/blanco.
class BandPalette {
  const BandPalette(this.low, this.mid, this.high);

  final Color low;
  final Color mid;
  final Color high;

  static const deckA =
      BandPalette(Color(0xFFD7261E), Color(0xFFFF7F1E), Color(0xFFFFF4D6));
  static const deckB =
      BandPalette(Color(0xFF1740C8), Color(0xFF1FA2FF), Color(0xFFDDF3FF));

  static BandPalette forDeck(String label) => label == 'B' ? deckB : deckA;
}

/// Las tres bandas de [bands] entre [fromMs] y [toMs]: el pico de cada una
/// (0–1) en ese tramo.
(double, double, double) bandsBetween(
    BandWaveform bands, double fromMs, double toMs) {
  final bps = bands.bucketsPerSecond;
  var i0 = (fromMs * bps / 1000).floor();
  var i1 = (toMs * bps / 1000).ceil();
  if (i0 < 0) i0 = 0;
  if (i1 > bands.length) i1 = bands.length;
  if (i1 <= i0) i1 = i0 + 1;
  if (i0 >= bands.length) return (0, 0, 0);
  var l = 0, m = 0, h = 0;
  for (var i = i0; i < i1; i++) {
    if (bands.low[i] > l) l = bands.low[i];
    if (bands.mid[i] > m) m = bands.mid[i];
    if (bands.high[i] > h) h = bands.high[i];
  }
  return (l / 255, m / 255, h / 255);
}

/// Color de un instante según el peso de cada banda (al cuadrado, para
/// que se note cuál domina): rojo si mandan los graves, naranja/amarillo
/// los medios, blanco los agudos — como las ondas de color de los programas
/// de DJ.
Color bandColor(double l, double m, double h,
    [BandPalette palette = BandPalette.deckA]) {
  final wl = l * l * 1.6, wm = m * m, wh = h * h * 1.3;
  final total = wl + wm + wh;
  if (total <= 0) return palette.low;
  double channel(int Function(Color) of) =>
      (of(palette.low) * wl + of(palette.mid) * wm + of(palette.high) * wh) /
      total;
  int r(Color c) => (c.r * 255).round();
  int g(Color c) => (c.g * 255).round();
  int bl(Color c) => (c.b * 255).round();
  return Color.fromARGB(
      255, channel(r).round(), channel(g).round(), channel(bl).round());
}

/// Junta las columnas de una onda por bandas por color (de a tonos
/// redondeados, para dibujar pocas figuras por cuadro).
class BandWaveBuilder {
  BandWaveBuilder([this.palette = BandPalette.deckA]);

  final BandPalette palette;
  final _bodies = <int, Path>{};
  final _cores = Path();

  /// Una columna en [x] (ancho [width]): el cuerpo, del color de la mezcla,
  /// crece [up] hacia arriba y [down] hacia abajo de [baseline] según la
  /// banda más fuerte; adentro, un brillo blanco con los agudos (los
  /// golpes).
  void column(
      double x, double width, double baseline, (double, double, double) values,
      {required double up, required double down}) {
    final (l, m, h) = values;
    final v = math.max(l, math.max(m, h));
    if (v <= 0.004) return;
    final color = bandColor(l, m, h, palette);
    // Tonos de a 8 niveles por canal.
    final key = ((color.r * 31).round() << 10) |
        ((color.g * 31).round() << 5) |
        (color.b * 31).round();
    _bodies.putIfAbsent(key, Path.new).addRect(
        Rect.fromLTRB(x, baseline - v * up, x + width, baseline + v * down));
    final core = h * 0.55;
    if (core > 0.03) {
      _cores.addRect(Rect.fromLTRB(
          x, baseline - core * up, x + width, baseline + core * down));
    }
  }

  void paint(Canvas canvas, {double opacity = 1}) {
    for (final entry in _bodies.entries) {
      final k = entry.key;
      final color = Color.fromARGB(
        (255 * opacity).round(),
        ((k >> 10) & 31) * 255 ~/ 31,
        ((k >> 5) & 31) * 255 ~/ 31,
        (k & 31) * 255 ~/ 31,
      );
      canvas.drawPath(entry.value, Paint()..color = color);
    }
    canvas.drawPath(_cores,
        Paint()..color = palette.high.withValues(alpha: 0.75 * opacity));
  }
}

/// Forma de onda que se desplaza con la canción, con la aguja fija en el
/// medio (como arriba en VirtualDJ): grilla de pulsos (más marcada en cada
/// compás), cue, hot cues y el loop sombreado. El ancho representa
/// [windowSeconds] de tiempo real, así dos canciones sincronizadas muestran
/// los pulsos alineados aunque tengan distinto BPM original.
class DjScrollingWaveform extends StatelessWidget {
  const DjScrollingWaveform({
    super.key,
    required this.deck,
    required this.frame,
    this.windowSeconds = 8,
    this.flip = false,
  });

  final DjDeck deck;

  /// Avisa en cada cuadro de pantalla (para dibujar a 60 fps).
  final Listenable frame;
  final double windowSeconds;

  /// Crece hacia arriba desde el borde de abajo (los dos decks, así los
  /// picos se comparan de un vistazo); sin esto, hacia abajo desde arriba.
  final bool flip;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Arrastrar mueve la canción (con el deck frenado, como en VirtualDJ).
      onHorizontalDragUpdate: (d) {
        final box = context.findRenderObject() as RenderBox?;
        final width = box?.size.width ?? 1;
        final ms = -d.delta.dx / width * windowSeconds * 1000 * deck.tempo;
        deck.seekMs(deck.positionMs + ms);
      },
      child: CustomPaint(
        painter: _ScrollingPainter(
          deck: deck,
          repaint: frame,
          windowSeconds: windowSeconds,
          flip: flip,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _ScrollingPainter extends CustomPainter {
  _ScrollingPainter({
    required this.deck,
    required Listenable repaint,
    required this.windowSeconds,
    required this.flip,
  }) : super(repaint: repaint);

  final DjDeck deck;
  final double windowSeconds;
  final bool flip;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = DjColors.background);
    final color = DjColors.forDeck(deck.label);
    final mid = size.width / 2;
    final baseline = flip ? size.height : 0.0;
    if (!deck.loaded) {
      _centerLine(canvas, size, mid);
      return;
    }
    final pos = deck.positionMs;
    final duration = deck.durationMs;
    // ms de canción por pixel (el tempo acelera lo que pasa por pantalla).
    final msPerPx = windowSeconds * 1000 * deck.tempo / size.width;
    double xFor(double ms) => mid + (ms - pos) / msPerPx;

    // Loop sombreado.
    final loop = deck.loop;
    if (loop != null) {
      final l = xFor(loop.startMs);
      final r = xFor(loop.endMs);
      canvas.drawRect(Rect.fromLTRB(l, 0, r, size.height),
          Paint()..color = DjColors.loop.withValues(alpha: 0.16));
      final edge = Paint()
        ..color = DjColors.loop
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(l, 0), Offset(l, size.height), edge);
      canvas.drawLine(Offset(r, 0), Offset(r, size.height), edge);
    }

    // Forma de onda: por bandas (detallada, en colores) si ya se calculó;
    // si no, la simple de antes.
    final peaks = deck.peaks;
    final bands = deck.bands;
    if (bands != null && bands.length > 0) {
      final palette = BandPalette.forDeck(deck.label);
      final builders = [BandWaveBuilder(palette), BandWaveBuilder(palette)];
      final reach = size.height * 0.96;
      for (var x = 0.0; x < size.width; x += 1) {
        final ms = pos + (x - mid) * msPerPx;
        if (ms + msPerPx < 0 || ms > duration) continue;
        builders[x < mid ? 0 : 1].column(
          x,
          1,
          baseline,
          bandsBetween(bands, ms, ms + msPerPx),
          up: flip ? reach : 0,
          down: flip ? 0 : reach,
        );
      }
      // Lo que ya sonó, más apagado.
      builders[0].paint(canvas, opacity: 0.6);
      builders[1].paint(canvas);
    } else if (peaks != null && peaks.isNotEmpty && duration > 0) {
      final played = Paint()..color = color.withValues(alpha: 0.45);
      final upcoming = Paint()..color = color;
      final core = Paint()..color = Colors.white.withValues(alpha: 0.75);
      for (var x = 0.0; x < size.width; x += 2) {
        final ms = pos + (x - mid) * msPerPx;
        if (ms < 0 || ms > duration) continue;
        final exact = ms / duration * (peaks.length - 1);
        final i = exact.floor().clamp(0, peaks.length - 1);
        final j = math.min(i + 1, peaks.length - 1);
        final t = exact - i;
        final v = peaks[i] * (1 - t) + peaks[j] * t;
        final h = v * size.height * 0.95;
        final rect = flip
            ? Rect.fromLTWH(x, baseline - h, 1.6, h)
            : Rect.fromLTWH(x, baseline, 1.6, h);
        canvas.drawRect(rect, x < mid ? played : upcoming);
        // "Brillo" central, como el color más claro de los picos fuertes.
        if (v > 0.55) {
          final hc = (v - 0.55) * size.height * 1.2;
          canvas.drawRect(
              flip
                  ? Rect.fromLTWH(x, baseline - hc, 1.6, hc)
                  : Rect.fromLTWH(x, baseline, 1.6, hc),
              core);
        }
      }
    }

    // Grilla de pulsos.
    final f = deck.features;
    if (f != null && f.hasTempo) {
      final period = f.beatPeriodMs;
      final firstVisible = pos - mid * msPerPx;
      var k = ((firstVisible - f.firstBeatMs) / period).floor();
      final beatPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 1;
      final barPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.5;
      while (true) {
        final ms = f.firstBeatMs + k * period;
        final x = xFor(ms);
        if (x > size.width) break;
        if (x >= 0 && ms >= 0) {
          final isBar = k % 4 == 0;
          final h = isBar ? size.height : size.height * 0.35;
          canvas.drawLine(
            Offset(x, flip ? size.height - h : 0),
            Offset(x, flip ? size.height : h),
            isBar ? barPaint : beatPaint,
          );
        }
        k++;
      }
    }

    // Cue y hot cues.
    void marker(double? ms, Color c) {
      if (ms == null) return;
      final x = xFor(ms);
      if (x < -6 || x > size.width + 6) return;
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = c
            ..strokeWidth = 2);
      final tip = flip ? size.height : 0.0;
      final dir = flip ? -1.0 : 1.0;
      canvas.drawPath(
        Path()
          ..moveTo(x - 5, tip)
          ..lineTo(x + 5, tip)
          ..lineTo(x, tip + 7 * dir)
          ..close(),
        Paint()..color = c,
      );
    }

    marker(deck.cueMs, DjColors.cue);
    for (var i = 0; i < deck.hotCues.length; i++) {
      marker(deck.hotCues[i], DjColors.hotCues[i]);
    }
    _centerLine(canvas, size, mid);
  }

  void _centerLine(Canvas canvas, Size size, double mid) {
    canvas.drawLine(
      Offset(mid, 0),
      Offset(mid, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_ScrollingPainter old) => true;
}

/// La canción entera en miniatura, con lo ya escuchado atenuado; tocar
/// salta ahí.
class DjOverview extends StatelessWidget {
  const DjOverview({super.key, required this.deck, required this.frame});

  final DjDeck deck;
  final Listenable frame;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTapDown: (d) {
          if (deck.durationMs <= 0) return;
          deck.seekMs(
              d.localPosition.dx / constraints.maxWidth * deck.durationMs);
        },
        child: CustomPaint(
          painter: _OverviewPainter(deck: deck, repaint: frame),
          size: Size(constraints.maxWidth, constraints.maxHeight),
        ),
      ),
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({required this.deck, required Listenable repaint})
      : super(repaint: repaint);

  final DjDeck deck;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
      Paint()..color = DjColors.background,
    );
    final peaks = deck.peaks;
    final bands = deck.bands;
    final duration = deck.durationMs;
    if ((peaks == null || peaks.isEmpty) && bands == null || duration <= 0) {
      return;
    }
    final color = DjColors.forDeck(deck.label);
    final progress = (deck.positionMs / duration).clamp(0.0, 1.0);
    final mid = size.height / 2;
    if (bands != null && bands.length > 0) {
      // En colores, espejada arriba y abajo; lo escuchado, apagado.
      final palette = BandPalette.forDeck(deck.label);
      final builders = [BandWaveBuilder(palette), BandWaveBuilder(palette)];
      final msPerPx = duration / size.width;
      for (var x = 0.0; x < size.width; x += 1) {
        builders[x / size.width < progress ? 0 : 1].column(
            x, 1, mid, bandsBetween(bands, x * msPerPx, (x + 1) * msPerPx),
            up: mid * 0.95, down: mid * 0.95);
      }
      builders[0].paint(canvas, opacity: 0.4);
      builders[1].paint(canvas);
    } else {
      final step = size.width / peaks!.length;
      final played = Paint()..color = color.withValues(alpha: 0.35);
      final upcoming = Paint()..color = color.withValues(alpha: 0.9);
      for (var i = 0; i < peaks.length; i += math.max(1, (1 / step).floor())) {
        final x = i * step;
        final h = peaks[i] * mid * 0.95;
        canvas.drawRect(
            Rect.fromLTRB(x, mid - h, x + math.max(step, 1), mid + h),
            x / size.width < progress ? played : upcoming);
      }
    }
    final loop = deck.loop;
    if (loop != null) {
      canvas.drawRect(
        Rect.fromLTRB(loop.startMs / duration * size.width, 0,
            loop.endMs / duration * size.width, size.height),
        Paint()..color = DjColors.loop.withValues(alpha: 0.35),
      );
    }
    for (var i = 0; i < deck.hotCues.length; i++) {
      final ms = deck.hotCues[i];
      if (ms == null) continue;
      final x = ms / duration * size.width;
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = DjColors.hotCues[i]
            ..strokeWidth = 1.5);
    }
    final cx = progress * size.width;
    canvas.drawLine(
        Offset(cx, 0),
        Offset(cx, size.height),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_OverviewPainter old) => true;
}

/// Plato (jog wheel): gira con la canción a 33⅓ rpm. Arrastrarlo en círculo
/// con la canción sonando la apura o la frena un instante (para empatar a
/// mano); frenada, la mueve hacia adelante o atrás.
class DjJogWheel extends StatefulWidget {
  const DjJogWheel({super.key, required this.deck, required this.frame});

  final DjDeck deck;
  final Listenable frame;

  @override
  State<DjJogWheel> createState() => _DjJogWheelState();
}

class _DjJogWheelState extends State<DjJogWheel> {
  double? _lastAngle;

  double _angleOf(Offset local, Size size) =>
      math.atan2(local.dy - size.height / 2, local.dx - size.width / 2);

  void _onPan(Offset local, Size size) {
    final angle = _angleOf(local, size);
    final last = _lastAngle;
    _lastAngle = angle;
    if (last == null) return;
    var delta = angle - last;
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    final deck = widget.deck;
    if (deck.playing) {
      // Pitch bend: girar apura, girar al revés frena.
      deck.setBend((delta * 1.2).clamp(-0.08, 0.08));
    } else {
      // Una vuelta = 1,8 s (33⅓ rpm).
      deck.seekMs(deck.positionMs + delta / (2 * math.pi) * 1800);
    }
  }

  void _end() {
    _lastAngle = null;
    if (!widget.deck.autoSync) widget.deck.setBend(0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final side = math.min(constraints.maxWidth, constraints.maxHeight);
      final size = Size.square(side);
      return Center(
        child: GestureDetector(
          onPanStart: (d) => _lastAngle = _angleOf(d.localPosition, size),
          onPanUpdate: (d) => _onPan(d.localPosition, size),
          onPanEnd: (_) => _end(),
          onPanCancel: _end,
          child: CustomPaint(
            size: size,
            painter: _JogPainter(deck: widget.deck, repaint: widget.frame),
          ),
        ),
      );
    });
  }
}

class _JogPainter extends CustomPainter {
  _JogPainter({required this.deck, required Listenable repaint})
      : super(repaint: repaint);

  final DjDeck deck;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final color = DjColors.forDeck(deck.label);
    // Aro exterior con el avance de la canción.
    canvas.drawCircle(c, r - 2, Paint()..color = DjColors.panelHigh);
    final progress = deck.durationMs > 0
        ? (deck.positionMs / deck.durationMs).clamp(0.0, 1.0)
        : 0.0;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r - 4),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    // Plato.
    canvas.drawCircle(
      c,
      r - 12,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF2C313C), Color(0xFF12141A)],
          stops: [0.3, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r - 12)),
    );
    // Surcos.
    final groove = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < 6; i++) {
      canvas.drawCircle(c, (r - 12) * (0.4 + i * 0.1), groove);
    }
    // Marca que gira: 33⅓ rpm = 0,555 vueltas por segundo.
    final angle =
        deck.positionMs / 1000 * (100 / 3 / 60) * 2 * math.pi - math.pi / 2;
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      c + dir * (r * 0.3),
      c + dir * (r - 16),
      Paint()
        ..color = deck.playing ? color : DjColors.muted
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    // Centro con la letra del deck.
    canvas.drawCircle(c, r * 0.2, Paint()..color = DjColors.background);
    canvas.drawCircle(
        c,
        r * 0.2,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final text = TextPainter(
      text: TextSpan(
        text: deck.label,
        style: TextStyle(
            color: color, fontWeight: FontWeight.w900, fontSize: r * 0.18),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, c - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(_JogPainter old) => true;
}
