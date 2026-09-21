import 'package:flutter/material.dart';

/// Barras de un analizador de espectro en vivo: reaccionan a [bands]
/// (magnitud 0.0-1.0 por banda de frecuencia) a medida que van llegando
/// datos reales del audio que está sonando, no una animación de mentira.
class SpectrumVisualizer extends StatelessWidget {
  const SpectrumVisualizer({
    super.key,
    required this.bands,
    this.height = 110,
    this.barCount = 24,
  });

  final List<double>? bands;
  final double height;
  final int barCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = bands ?? List<double>.filled(barCount, 0.0);

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  curve: Curves.easeOut,
                  height: (v.clamp(0.0, 1.0) * height).clamp(3.0, height),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
