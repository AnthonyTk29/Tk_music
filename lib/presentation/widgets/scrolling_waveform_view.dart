import 'package:flutter/material.dart';

/// Onda estilo VirtualDJ: en vez de comprimir la canción entera en el
/// ancho de pantalla, muestra una ventana acercada de [visibleBars]
/// alrededor del puntero de reproducción, con un cursor fijo en el centro
/// — la onda se desliza por debajo a medida que avanza la canción, igual
/// que el visor clásico de mezcladores de DJ.
class ScrollingWaveformView extends StatefulWidget {
  const ScrollingWaveformView({
    super.key,
    required this.peaks,
    required this.progress,
    this.onSeek,
    this.height = 72,
    this.visibleBars = 140,
  });

  /// Picos normalizados (0.0-1.0) de toda la canción. `null` mientras se
  /// está analizando.
  final List<double>? peaks;

  /// Posición actual como fracción (0.0-1.0) de la duración total.
  final double progress;

  /// Si no es null, tocar o arrastrar sobre la onda salta a esa posición
  /// (fracción 0.0-1.0).
  final ValueChanged<double>? onSeek;

  final double height;
  final int visibleBars;

  @override
  State<ScrollingWaveformView> createState() => _ScrollingWaveformViewState();
}

class _ScrollingWaveformViewState extends State<ScrollingWaveformView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _displayedCenter = 0;
  double _fromCenter = 0;
  double _toCenter = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        setState(() {
          _displayedCenter = _fromCenter +
              (_toCenter - _fromCenter) * _controller.value;
        });
      });
    _toCenter = _targetCenter();
    _fromCenter = _toCenter;
    _displayedCenter = _toCenter;
  }

  double _targetCenter() {
    final peaks = widget.peaks;
    if (peaks == null || peaks.isEmpty) return 0;
    return widget.progress.clamp(0.0, 1.0) * peaks.length;
  }

  @override
  void didUpdateWidget(covariant ScrollingWaveformView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newTarget = _targetCenter();
    if ((newTarget - _toCenter).abs() < 0.01) return;

    // Un salto grande (el usuario tocó la onda para saltar de posición, o
    // recién llegaron los picos) no tiene sentido animarlo deslizando: se
    // corta directo ahí en vez de "barrer" toda la canción visualmente.
    final jump = (newTarget - _displayedCenter).abs();
    final bigJump = jump > widget.visibleBars;

    _toCenter = newTarget;
    if (bigJump) {
      _fromCenter = newTarget;
      _displayedCenter = newTarget;
      _controller.stop();
    } else {
      _fromCenter = _displayedCenter;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peaks = widget.peaks;

    if (peaks == null) {
      return SizedBox(
        height: widget.height,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final painted = CustomPaint(
      size: Size(double.infinity, widget.height),
      painter: _ScrollingWaveformPainter(
        peaks: peaks,
        centerIndex: _displayedCenter,
        visibleBars: widget.visibleBars,
        playedColor: theme.colorScheme.primary,
        upcomingColor:
            theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
        cursorColor: theme.colorScheme.onSurface,
      ),
    );

    final sized =
        SizedBox(height: widget.height, width: double.infinity, child: painted);

    if (widget.onSeek == null) return sized;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _seekAt(context, details.localPosition.dx),
      onHorizontalDragUpdate: (details) =>
          _seekAt(context, details.localPosition.dx),
      child: sized,
    );
  }

  void _seekAt(BuildContext context, double dx) {
    final peaks = widget.peaks;
    if (peaks == null || peaks.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 1;
    final half = widget.visibleBars / 2;
    final barsFromLeft = (dx / width) * widget.visibleBars;
    final tappedIndex = _displayedCenter - half + barsFromLeft;
    widget.onSeek?.call((tappedIndex / peaks.length).clamp(0.0, 1.0));
  }
}

class _ScrollingWaveformPainter extends CustomPainter {
  _ScrollingWaveformPainter({
    required this.peaks,
    required this.centerIndex,
    required this.visibleBars,
    required this.playedColor,
    required this.upcomingColor,
    required this.cursorColor,
  });

  final List<double> peaks;
  final double centerIndex;
  final int visibleBars;
  final Color playedColor;
  final Color upcomingColor;
  final Color cursorColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || peaks.isEmpty) return;

    final half = visibleBars / 2;
    final startIndex = centerIndex - half;
    final barWidth = size.width / visibleBars;
    final centerY = size.height / 2;

    final playedPaint = Paint()..color = playedColor;
    final upcomingPaint = Paint()..color = upcomingColor;

    for (var i = 0; i < visibleBars; i++) {
      final index = (startIndex + i).round();
      if (index < 0 || index >= peaks.length) continue;

      final amplitude = peaks[index].clamp(0.03, 1.0);
      final barHeight = amplitude * size.height;
      final left = i * barWidth;
      final rect = Rect.fromLTWH(
        left,
        centerY - barHeight / 2,
        (barWidth - 1).clamp(1.0, barWidth),
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        index < centerIndex ? playedPaint : upcomingPaint,
      );
    }

    final cursorPaint = Paint()
      ..color = cursorColor
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      cursorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScrollingWaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.centerIndex != centerIndex ||
        oldDelegate.visibleBars != visibleBars ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.upcomingColor != upcomingColor;
  }
}
