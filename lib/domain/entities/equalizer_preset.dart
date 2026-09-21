enum EqualizerPreset { normal, pop, rock, classic, custom }

extension EqualizerPresetLabel on EqualizerPreset {
  String get label => switch (this) {
        EqualizerPreset.normal => 'Normal',
        EqualizerPreset.pop => 'Pop',
        EqualizerPreset.rock => 'Rock',
        EqualizerPreset.classic => 'Clásica',
        EqualizerPreset.custom => 'Usuario',
      };
}

// Cada curva es una forma genérica (grave, medio-grave, medio, medio-agudo,
// agudo) en dB, el mismo tipo de perfil que trae cualquier ecualizador de
// fábrica. Los dispositivos Android no todos exponen la misma cantidad de
// bandas, así que [gainsForPreset] interpola sobre estos 5 puntos según la
// posición relativa de cada banda real, en vez de asumir un número fijo.
const _curves = <EqualizerPreset, List<double>>{
  EqualizerPreset.normal: [0.0, 0.0, 0.0, 0.0, 0.0],
  EqualizerPreset.pop: [-2.0, 0.0, 3.0, 2.0, 0.0],
  EqualizerPreset.rock: [5.0, 3.0, -3.0, 2.0, 4.0],
  EqualizerPreset.classic: [0.0, 1.0, 2.0, 1.0, -1.0],
};

/// Ganancia sugerida por banda para [preset], en el mismo orden que las
/// bandas reales del ecualizador del dispositivo (de graves a agudos).
/// [EqualizerPreset.custom] no tiene curva propia — significa "lo que el
/// usuario haya dejado a mano" — así que devuelve una lista vacía.
List<double> gainsForPreset(
  EqualizerPreset preset, {
  required int bandCount,
  required double minDb,
  required double maxDb,
}) {
  final curve = _curves[preset];
  if (curve == null || bandCount <= 0) return const [];

  return List.generate(bandCount, (i) {
    final t = bandCount <= 1 ? 0.0 : i / (bandCount - 1);
    return _interpolate(curve, t).clamp(minDb, maxDb);
  });
}

double _interpolate(List<double> curve, double t) {
  final scaled = t * (curve.length - 1);
  final lower = scaled.floor().clamp(0, curve.length - 1);
  final upper = scaled.ceil().clamp(0, curve.length - 1);
  if (lower == upper) return curve[lower];
  final frac = scaled - lower;
  return curve[lower] + (curve[upper] - curve[lower]) * frac;
}
