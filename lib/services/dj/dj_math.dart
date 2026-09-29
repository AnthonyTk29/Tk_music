import 'dart:math' as math;

import 'package:tk_music/services/track_features.dart';

/// Cuentas del modo DJ, separadas de los reproductores para poder
/// probarlas: sincronizar tempo y fase, empatar tonalidad, la grilla de
/// pulsos, el auto loop y la curva del crossfader.

/// Rangos del pitch, como en un controlador: ±8 %, ±16 %, ±32 %.
const djPitchRanges = [0.08, 0.16, 0.32];

/// Tempo (1 = normal) que tiene que tener una canción de [followerBpm] para
/// sonar a [masterBpm]. Si una está al doble o a la mitad de la otra (p. ej.
/// 70 y 140 BPM), se empareja con la del doble/mitad, que es el mismo pulso.
double tempoForSync(double followerBpm, double masterBpm) {
  if (followerBpm <= 0 || masterBpm <= 0) return 1;
  final base = masterBpm / followerBpm;
  var best = base;
  for (final candidate in [base * 2, base / 2]) {
    if ((candidate - 1).abs() < (best - 1).abs()) best = candidate;
  }
  return best;
}

/// El rango de pitch más chico donde entra [tempo], o `null` si ni ±32 %
/// alcanza.
double? pitchRangeFor(double tempo) {
  final needed = (tempo - 1).abs();
  for (final range in djPitchRanges) {
    if (needed <= range + 1e-9) return range;
  }
  return null;
}

/// Fracción del pulso (0 a 1) en la que está [positionMs].
double beatPhase(TrackFeatures features, double positionMs) {
  final period = features.beatPeriodMs;
  if (period <= 0) return 0;
  final beats = (positionMs - features.firstBeatMs) / period;
  return beats - beats.floorToDouble();
}

/// Lleva una diferencia de fase a [-0.5, 0.5): "cuánto pulso" adelante (+)
/// o atrás (-).
double wrapPhase(double phase) {
  final wrapped = phase - phase.roundToDouble();
  return wrapped == 0.5 ? -0.5 : wrapped;
}

/// Adónde mover la canción que sigue ([follower], en [followerMs]) para que
/// sus pulsos caigan junto con los de [master] (en [masterMs]).
double alignedPosition({
  required TrackFeatures follower,
  required double followerMs,
  required TrackFeatures master,
  required double masterMs,
}) {
  final delta =
      wrapPhase(beatPhase(master, masterMs) - beatPhase(follower, followerMs));
  return followerMs + delta * follower.beatPeriodMs;
}

/// Desfase en milisegundos reales entre los pulsos de las dos canciones
/// (positivo = la que sigue va adelantada). [masterBpm] es el tempo con
/// el que suena el master.
double phaseErrorMs({
  required TrackFeatures follower,
  required double followerMs,
  required TrackFeatures master,
  required double masterMs,
  required double masterBpm,
}) {
  if (masterBpm <= 0) return 0;
  final beats =
      wrapPhase(beatPhase(follower, followerMs) - beatPhase(master, masterMs));
  return beats * 60000 / masterBpm;
}

/// Pulso más cercano a [positionMs] (para que los cue y loops caigan justo
/// en el pulso: "quantize").
double nearestBeat(TrackFeatures features, double positionMs) {
  final period = features.beatPeriodMs;
  if (period <= 0) return positionMs;
  final k = ((positionMs - features.firstBeatMs) / period).roundToDouble();
  return math.max(0, features.firstBeatMs + k * period);
}

/// Último pulso en o antes de [positionMs].
double beatAtOrBefore(TrackFeatures features, double positionMs) {
  final period = features.beatPeriodMs;
  if (period <= 0) return positionMs;
  final k = ((positionMs - features.firstBeatMs) / period).floorToDouble();
  return math.max(0, features.firstBeatMs + k * period);
}

/// Primer tiempo del compás (cada 4 pulsos) en o después de [positionMs].
double nextDownbeat(TrackFeatures features, double positionMs) {
  final bar = features.beatPeriodMs * 4;
  if (bar <= 0) return positionMs;
  final k = ((positionMs - features.firstBeatMs) / bar).ceilToDouble();
  return math.max(0, features.firstBeatMs + k * bar);
}

/// Semitonos para llevar la tonalidad [followerKey] a la de [masterKey] en
/// la rueda Camelot (0-11 mayores, 12-23 menores, como [TrackFeatures]).
/// Acepta la misma casilla o una vecina (±1, las que mezclan bien) y se
/// queda con la que pide mover menos el tono. `null` si falta alguna.
int? semitonesToMatchKey(int followerKey, int masterKey) {
  if (followerKey < 0 || masterKey < 0) return null;
  // Menor → su relativa mayor (La menor = Do mayor): misma casilla Camelot.
  int asMajor(int key) => key >= 12 ? (key % 12 + 3) % 12 : key % 12;
  int normalize(int semis) {
    final m = ((semis % 12) + 12) % 12;
    return m > 6 ? m - 12 : m;
  }

  final exact = normalize(asMajor(masterKey) - asMajor(followerKey));
  // Una casilla de la rueda = una quinta (7 semitonos).
  final options = [exact, normalize(exact + 7), normalize(exact - 7)];
  options.sort((a, b) => a.abs().compareTo(b.abs()));
  return options.first;
}

/// Ganancias (A, B) del crossfader en [position] (-1 = todo A, 1 = todo B),
/// con curva de potencia constante: en el medio suenan las dos sin bajón.
({double a, double b}) crossfaderGains(double position) {
  final x = ((position.clamp(-1.0, 1.0) + 1) / 2) * math.pi / 2;
  return (a: math.cos(x), b: math.sin(x));
}

/// Dónde armar un loop de [beats] pulsos cerca de [positionMs]: prueba el
/// compás actual y los tres siguientes, y elige el tramo con volumen más
/// parejo y presente (una parte "musical", sin cortes ni silencios), según
/// la forma de onda [peaks] (0-1, repartida en toda la canción).
double suggestAutoLoopStart({
  required TrackFeatures features,
  required List<double>? peaks,
  required double durationMs,
  required double positionMs,
  required int beats,
}) {
  final period = features.beatPeriodMs;
  if (period <= 0) return positionMs;
  final bar = period * 4;
  final first = beatAtOrBefore(features, positionMs);
  // Arranca en un compás si el actual está cerca; si no, en el pulso actual.
  final currentBar = nextDownbeat(features, positionMs) - bar;
  final base = positionMs - currentBar < period ? currentBar : first;
  final length = beats * period;
  final candidates = [
    base,
    for (var i = 1; i <= 3; i++)
      nextDownbeat(features, positionMs) + (i - 1) * bar,
  ].where((s) => s >= 0 && s + length <= durationMs).toList();
  if (candidates.isEmpty) return base;
  if (peaks == null || peaks.isEmpty || durationMs <= 0) {
    return candidates.first;
  }

  final loudest = peaks.reduce(math.max);
  double score(double start) {
    final from = (start / durationMs * peaks.length).floor();
    final to = ((start + length) / durationMs * peaks.length)
        .ceil()
        .clamp(from + 1, peaks.length);
    final window = peaks.sublist(from.clamp(0, peaks.length - 1), to);
    final mean = window.reduce((a, b) => a + b) / window.length;
    if (mean < loudest * 0.25) return 0;
    final variance =
        window.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
            window.length;
    return mean / (0.05 + math.sqrt(variance));
  }

  var best = candidates.first;
  var bestScore = score(best);
  for (final start in candidates.skip(1)) {
    final s = score(start);
    // Más adelante solo si es claramente mejor: lo más cerca es lo que el
    // DJ espera.
    if (s > bestScore * 1.15) {
      best = start;
      bestScore = s;
    }
  }
  return best;
}

/// Volumen de mpv (0-400) para una ganancia lineal [gain] (1 = original).
/// mpv aplica (volumen/100)³, así que hay que sacar la raíz cúbica.
double mpvVolumeFor(double gain) =>
    gain <= 0 ? 0 : 100 * math.pow(gain, 1 / 3).toDouble();

/// "1:23.4" (con décimas si [tenths]).
String formatDjTime(double ms, {bool tenths = true}) {
  final safe = ms.isFinite ? ms.abs() : 0.0;
  final minutes = safe ~/ 60000;
  final seconds = (safe % 60000) / 1000;
  final text = tenths
      ? seconds.toStringAsFixed(1).padLeft(4, '0')
      : seconds.floor().toString().padLeft(2, '0');
  return '$minutes:$text';
}
