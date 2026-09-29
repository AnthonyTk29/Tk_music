import 'dart:math' as math;
import 'dart:typed_data';

/// Rasgos musicales de una canción, para mezclar como un DJ: tempo (BPM) y
/// dónde caen los pulsos, tonalidad (con su código Camelot, el que usan los
/// DJs para saber qué tonos combinan) y energía. Los calcula
/// [analyzeTrackFeatures] a partir de un tramo de audio decodificado.
class TrackFeatures {
  const TrackFeatures({
    required this.bpm,
    required this.firstBeatMs,
    required this.keyIndex,
    required this.energy,
  });

  factory TrackFeatures.fromJson(Map<String, dynamic> json) => TrackFeatures(
        bpm: (json['bpm'] as num).toDouble(),
        firstBeatMs: (json['beat'] as num).toDouble(),
        keyIndex: (json['key'] as num).toInt(),
        energy: (json['energy'] as num).toDouble(),
      );

  /// 0 si no se pudo detectar un pulso claro.
  final double bpm;

  /// Posición (ms desde el inicio de la canción) del primer pulso; los
  /// siguientes caen cada [beatPeriodMs].
  final double firstBeatMs;

  /// 0-11 = Do..Si mayor, 12-23 = Do..Si menor; -1 si no se detectó.
  final int keyIndex;

  /// 0 (tranquila) a 1 (muy intensa).
  final double energy;

  double get beatPeriodMs => bpm > 0 ? 60000 / bpm : 0;
  bool get hasTempo => bpm > 0;
  bool get hasKey => keyIndex >= 0;
  bool get isMinor => keyIndex >= 12;
  int get pitchClass => keyIndex % 12;

  static const _names = [
    'Do',
    'Do#',
    'Re',
    'Mi♭',
    'Mi',
    'Fa',
    'Fa#',
    'Sol',
    'La♭',
    'La',
    'Si♭',
    'Si'
  ];
  static const _camelotMinor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10];
  static const _camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1];

  /// "La menor", "Do mayor"…
  String? get keyName =>
      hasKey ? '${_names[pitchClass]} ${isMinor ? 'menor' : 'mayor'}' : null;

  /// "8A" (menores) / "8B" (mayores).
  String? get camelot => hasKey
      ? '${isMinor ? _camelotMinor[pitchClass] : _camelotMajor[pitchClass]}${isMinor ? 'A' : 'B'}'
      : null;

  int? get camelotNumber => hasKey
      ? (isMinor ? _camelotMinor[pitchClass] : _camelotMajor[pitchClass])
      : null;

  /// "128 BPM · 8A"
  String get summary => [
        if (hasTempo) '${bpm.round()} BPM',
        if (camelot != null) camelot!,
      ].join(' · ');

  /// Próximo pulso en o después de [positionMs].
  double nextBeatAfter(double positionMs) {
    final period = beatPeriodMs;
    if (period <= 0) return positionMs;
    final k = ((positionMs - firstBeatMs) / period).ceil();
    return firstBeatMs + k * period;
  }

  Map<String, dynamic> toJson() => {
        'bpm': double.parse(bpm.toStringAsFixed(2)),
        'beat': double.parse(firstBeatMs.toStringAsFixed(1)),
        'key': keyIndex,
        'energy': double.parse(energy.toStringAsFixed(3)),
      };
}

/// Analiza [pcm] (mono, 16 bits, a [sampleRate] Hz) que arranca en
/// [startMs] de la canción. Pensado para correr en un isolate aparte.
TrackFeatures analyzeTrackFeatures(
    Int16List pcm, int sampleRate, double startMs) {
  final tempo = _detectTempo(pcm, sampleRate);
  final key = _detectKey(pcm, sampleRate);

  var sumSquares = 0.0;
  for (final s in pcm) {
    sumSquares += s * s.toDouble();
  }
  final rms = pcm.isEmpty ? 0.0 : math.sqrt(sumSquares / pcm.length);
  final db = rms > 0 ? 20 * math.log(rms / 32768) / math.ln10 : -90.0;
  final loudness = ((db + 30) / 22).clamp(0.0, 1.0);
  final pace = tempo.bpm > 0 ? ((tempo.bpm - 70) / 100).clamp(0.0, 1.0) : 0.3;
  final energy = (0.55 * loudness + 0.25 * pace + 0.2 * tempo.pulseStrength)
      .clamp(0.0, 1.0);

  var firstBeat = 0.0;
  if (tempo.bpm > 0) {
    final period = 60000 / tempo.bpm;
    firstBeat = (startMs + tempo.phaseMs) % period;
  }
  return TrackFeatures(
      bpm: tempo.bpm, firstBeatMs: firstBeat, keyIndex: key, energy: energy);
}

// ---------------------------------------------------------------------------
// Tempo: flujo espectral (cuánto "aparece" de energía nueva en cada instante)
// → autocorrelación para el período más probable → fase de los pulsos.
// ---------------------------------------------------------------------------

class _Tempo {
  const _Tempo(this.bpm, this.phaseMs, this.pulseStrength);
  final double bpm;
  final double phaseMs;
  final double pulseStrength;
}

_Tempo _detectTempo(Int16List pcm, int sampleRate) {
  const frameSize = 1024;
  const hop = 256;
  if (pcm.length < frameSize * 8) return const _Tempo(0, 0, 0);
  final fps = sampleRate / hop;
  final window = _hann(frameSize);
  final frames = (pcm.length - frameSize) ~/ hop;
  final onset = Float64List(frames);
  var previous = Float64List(frameSize ~/ 2);
  final re = Float64List(frameSize);
  final im = Float64List(frameSize);
  for (var f = 0; f < frames; f++) {
    final offset = f * hop;
    for (var i = 0; i < frameSize; i++) {
      re[i] = pcm[offset + i] * window[i];
      im[i] = 0;
    }
    _fft(re, im);
    final current = Float64List(frameSize ~/ 2);
    var flux = 0.0;
    for (var b = 1; b < frameSize ~/ 2; b++) {
      final magnitude =
          math.log(1 + math.sqrt(re[b] * re[b] + im[b] * im[b]) / 64);
      current[b] = magnitude;
      final rise = magnitude - previous[b];
      if (rise > 0) flux += rise;
    }
    onset[f] = flux;
    previous = current;
  }

  // Se resta el promedio local (~0.5s) para quedarse con los golpes y no
  // con el volumen general.
  final smooth = (fps * 0.25).round();
  final envelope = Float64List(frames);
  var runningSum = 0.0;
  for (var i = 0; i < frames; i++) {
    runningSum += onset[i];
    if (i > 2 * smooth) runningSum -= onset[i - 2 * smooth - 1];
    final count = math.min(i + 1, 2 * smooth + 1);
    final center = i - smooth;
    if (center >= 0) {
      envelope[center] = math.max(0, onset[center] - runningSum / count);
    }
  }

  // Autocorrelación entre 60 y 200 BPM, con preferencia suave por tempos
  // "bailables" (~120) para no confundir el doble o la mitad del pulso.
  final minLag = (60 * fps / 200).floor();
  final maxLag = (60 * fps / 60).ceil();
  if (maxLag >= frames ~/ 2) return const _Tempo(0, 0, 0);
  var zeroLag = 0.0;
  for (var i = 0; i < frames; i++) {
    zeroLag += envelope[i] * envelope[i];
  }
  if (zeroLag <= 0) return const _Tempo(0, 0, 0);
  final scores = Float64List(maxLag + 2);
  var bestLag = 0;
  var bestScore = double.negativeInfinity;
  for (var lag = minLag; lag <= maxLag + 1; lag++) {
    var sum = 0.0;
    for (var i = 0; i + lag < frames; i++) {
      sum += envelope[i] * envelope[i + lag];
    }
    final ac = sum / (frames - lag);
    final bpm = 60 * fps / lag;
    final octaves = math.log(bpm / 120) / math.ln2;
    final weight = math.exp(-0.5 * octaves * octaves / (0.9 * 0.9));
    scores[lag] = ac * weight;
    if (lag <= maxLag && scores[lag] > bestScore) {
      bestScore = scores[lag];
      bestLag = lag;
    }
  }
  if (bestLag <= 0) return const _Tempo(0, 0, 0);

  // Interpolación parabólica para afinar el período entre dos frames.
  var lag = bestLag.toDouble();
  if (bestLag > minLag && bestLag < maxLag) {
    final a = scores[bestLag - 1];
    final b = scores[bestLag];
    final c = scores[bestLag + 1];
    final denominator = a - 2 * b + c;
    if (denominator != 0) lag += 0.5 * (a - c) / denominator;
  }
  final bpm = 60 * fps / lag;

  // Fase: el corrimiento que hace coincidir más golpes con la grilla.
  var bestPhase = 0;
  var bestPhaseScore = -1.0;
  var totalPhaseScore = 0.0;
  final steps = lag.floor();
  for (var phase = 0; phase < steps; phase++) {
    var sum = 0.0;
    for (var t = phase.toDouble(); t < frames; t += lag) {
      sum += envelope[t.round().clamp(0, frames - 1)];
    }
    totalPhaseScore += sum;
    if (sum > bestPhaseScore) {
      bestPhaseScore = sum;
      bestPhase = phase;
    }
  }
  final meanPhaseScore = steps > 0 ? totalPhaseScore / steps : 0.0;
  final strength = bestPhaseScore > 0 && meanPhaseScore > 0
      ? ((bestPhaseScore / meanPhaseScore - 1) / 3).clamp(0.0, 1.0)
      : 0.0;
  // El pico de flujo espectral cae medio frame después del golpe real.
  final phaseMs = (bestPhase + frameSize / hop / 2) / fps * 1000;
  return _Tempo(double.parse(bpm.toStringAsFixed(1)), phaseMs, strength);
}

// ---------------------------------------------------------------------------
// Tonalidad: croma (energía por nota Do..Si en todas las octavas) contra
// los perfiles de Krumhansl–Schmuckler de las 24 tonalidades.
// ---------------------------------------------------------------------------

const _majorProfile = [
  6.35,
  2.23,
  3.48,
  2.33,
  4.38,
  4.09,
  2.52,
  5.19,
  2.39,
  3.66,
  2.29,
  2.88
];
const _minorProfile = [
  6.33,
  2.68,
  3.52,
  5.38,
  2.60,
  3.53,
  2.54,
  4.75,
  3.98,
  2.69,
  3.34,
  3.17
];

int _detectKey(Int16List pcm, int sampleRate) {
  const frameSize = 4096;
  const hop = 2048;
  if (pcm.length < frameSize * 2) return -1;
  final window = _hann(frameSize);
  final chroma = Float64List(12);
  final re = Float64List(frameSize);
  final im = Float64List(frameSize);
  final binPitch = List<int>.filled(frameSize ~/ 2, -1);
  for (var b = 1; b < frameSize ~/ 2; b++) {
    final freq = b * sampleRate / frameSize;
    if (freq < 60 || freq > 2100) continue;
    final midi = 69 + 12 * math.log(freq / 440) / math.ln2;
    binPitch[b] = midi.round() % 12;
  }
  for (var offset = 0; offset + frameSize <= pcm.length; offset += hop) {
    for (var i = 0; i < frameSize; i++) {
      re[i] = pcm[offset + i] * window[i];
      im[i] = 0;
    }
    _fft(re, im);
    final frameChroma = Float64List(12);
    var total = 0.0;
    for (var b = 1; b < frameSize ~/ 2; b++) {
      final pc = binPitch[b];
      if (pc < 0) continue;
      final magnitude = math.sqrt(re[b] * re[b] + im[b] * im[b]);
      frameChroma[pc] += magnitude;
      total += magnitude;
    }
    if (total <= 0) continue;
    for (var pc = 0; pc < 12; pc++) {
      chroma[pc] += frameChroma[pc] / total;
    }
  }
  if (chroma.every((v) => v == 0)) return -1;

  var bestKey = -1;
  var bestCorrelation = -2.0;
  for (var tonic = 0; tonic < 12; tonic++) {
    for (final minor in [false, true]) {
      final profile = minor ? _minorProfile : _majorProfile;
      final rotated =
          List.generate(12, (pc) => profile[(pc - tonic + 12) % 12]);
      final correlation = _pearson(chroma, rotated);
      if (correlation > bestCorrelation) {
        bestCorrelation = correlation;
        bestKey = tonic + (minor ? 12 : 0);
      }
    }
  }
  return bestCorrelation > 0.2 ? bestKey : -1;
}

double _pearson(List<double> a, List<double> b) {
  final n = a.length;
  final meanA = a.reduce((x, y) => x + y) / n;
  final meanB = b.reduce((x, y) => x + y) / n;
  var num = 0.0;
  var denA = 0.0;
  var denB = 0.0;
  for (var i = 0; i < n; i++) {
    final da = a[i] - meanA;
    final db = b[i] - meanB;
    num += da * db;
    denA += da * da;
    denB += db * db;
  }
  if (denA == 0 || denB == 0) return 0;
  return num / math.sqrt(denA * denB);
}

// ---------------------------------------------------------------------------
// Orden para mezclar: cada canción seguida de la que mejor "encaja" (tempo
// parecido o doble/mitad, tonalidad compatible en la rueda Camelot, energía
// que sube de a poco), como armaría un set un DJ.
// ---------------------------------------------------------------------------

/// Costo de pasar de [from] a [to] (0 = transición perfecta).
double mixTransitionCost(TrackFeatures? from, TrackFeatures? to) {
  if (from == null || to == null) return 0.8;
  var tempo = 0.6;
  if (from.hasTempo && to.hasTempo) {
    tempo = [1.0, 2.0, 0.5]
            .map((ratio) => (to.bpm * ratio - from.bpm).abs() / from.bpm)
            .reduce(math.min) *
        4;
  }
  var key = 0.4;
  final a = from.camelotNumber;
  final b = to.camelotNumber;
  if (a != null && b != null) {
    final wheel = math.min((a - b).abs(), 12 - (a - b).abs());
    final sameMode = from.isMinor == to.isMinor;
    key = switch ((wheel, sameMode)) {
      (0, true) => 0.0,
      (0, false) || (1, true) => 0.15,
      (2, true) => 0.35,
      _ => 0.5 + wheel * 0.04,
    };
  }
  final energy = (to.energy - (from.energy + 0.03)).abs();
  return tempo + key + energy;
}

/// Reordena [items] (dejando fijos los primeros [keepFirst]) para que cada
/// uno encadene lo mejor posible con el anterior. Greedy: siempre elige la
/// siguiente de menor costo.
List<T> orderForMixing<T>(
  List<T> items,
  TrackFeatures? Function(T item) featuresOf, {
  int keepFirst = 1,
}) {
  if (items.length - keepFirst < 2) return List.of(items);
  final result = items.sublist(0, keepFirst.clamp(0, items.length));
  final pending = items.sublist(result.length);
  if (result.isEmpty) result.add(pending.removeAt(0));
  while (pending.isNotEmpty) {
    final last = featuresOf(result.last);
    var bestIndex = 0;
    var bestCost = double.infinity;
    for (var i = 0; i < pending.length; i++) {
      final cost = mixTransitionCost(last, featuresOf(pending[i]));
      if (cost < bestCost) {
        bestCost = cost;
        bestIndex = i;
      }
    }
    result.add(pending.removeAt(bestIndex));
  }
  return result;
}

// ---------------------------------------------------------------------------

Float64List _hann(int size) {
  final window = Float64List(size);
  for (var i = 0; i < size; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1));
  }
  return window;
}

void _fft(Float64List re, Float64List im) {
  final n = re.length;
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    while (j & bit != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j |= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final angle = -2 * math.pi / len;
    final wr = math.cos(angle);
    final wi = math.sin(angle);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var curWr = 1.0;
      var curWi = 0.0;
      for (var k = 0; k < half; k++) {
        final a = i + k;
        final b = a + half;
        final vRe = re[b] * curWr - im[b] * curWi;
        final vIm = re[b] * curWi + im[b] * curWr;
        re[b] = re[a] - vRe;
        im[b] = im[a] - vIm;
        re[a] += vRe;
        im[a] += vIm;
        final nextWr = curWr * wr - curWi * wi;
        curWi = curWr * wi + curWi * wr;
        curWr = nextWr;
      }
    }
  }
}
