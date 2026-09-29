import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/presentation/widgets/dj/dj_visuals.dart';
import 'package:tk_music/services/dj/band_waveform.dart';

Int16List _tone(double freq, {double seconds = 1, int rate = 11025}) {
  final n = (seconds * rate).round();
  return Int16List.fromList([
    for (var i = 0; i < n; i++)
      (math.sin(2 * math.pi * freq * i / rate) * 20000).round(),
  ]);
}

/// Promedio de una banda en la mitad de la señal (sin el arranque de los
/// filtros).
double _avg(Uint8List band) {
  final part = band.sublist(band.length ~/ 4, band.length * 3 ~/ 4);
  return part.reduce((a, b) => a + b) / part.length;
}

void main() {
  test('100 puntos por segundo', () {
    final wave = analyzeBandWaveform(_tone(440, seconds: 180), 11025);
    // La duración de la onda coincide con la del audio (a 3 minutos, sin
    // correrse más de un punto).
    expect(wave.durationMs, closeTo(180000, 10));
    expect(wave.bucketsPerSecond, closeTo(100, 0.5));
  });

  test('cada frecuencia cae en su banda', () {
    final bass = analyzeBandWaveform(_tone(60), 11025);
    expect(_avg(bass.low), greaterThan(200));
    expect(_avg(bass.mid), lessThan(_avg(bass.low) / 3));
    expect(_avg(bass.high), lessThan(10));

    final mids = analyzeBandWaveform(_tone(900), 11025);
    expect(_avg(mids.mid), greaterThan(200));
    expect(_avg(mids.low), lessThan(_avg(mids.mid) / 3));
    expect(_avg(mids.high), lessThan(_avg(mids.mid) / 3));

    final highs = analyzeBandWaveform(_tone(4500), 11025);
    expect(_avg(highs.high), greaterThan(200));
    expect(_avg(highs.low), lessThan(10));
  });

  test('los golpes se ven: silencio entre medio queda en cero', () {
    const rate = 11025;
    final pcm = Int16List(rate); // 1 s
    for (final start in [0, rate ~/ 2]) {
      for (var i = 0; i < 800; i++) {
        pcm[start + i] =
            (math.sin(2 * math.pi * 60 * i / rate) * 25000 * (1 - i / 800))
                .round();
      }
    }
    final wave = analyzeBandWaveform(pcm, rate);
    expect(wave.low[2], greaterThan(100)); // golpe
    expect(wave.low[35], lessThan(5)); // silencio
    expect(wave.low[52], greaterThan(100)); // otro golpe
  });

  test('picos generales para el vúmetro y la vista completa', () {
    final wave = analyzeBandWaveform(_tone(60, seconds: 2), 11025);
    final peaks = wave.toPeaks(20);
    expect(peaks, hasLength(20));
    expect(peaks[10], greaterThan(0.7));
  });

  test('el color sigue a la banda que domina', () {
    final bass = bandColor(1, 0.1, 0);
    final bright = bandColor(0.1, 0.2, 1);
    expect(bass.r, greaterThan(bass.g * 2)); // rojo
    expect(bright.b, greaterThan(0.7)); // casi blanco
  });

  test('cada deck con su color: A naranja, B azul', () {
    final a = bandColor(0.3, 1, 0.1, BandPalette.forDeck('A'));
    final b = bandColor(0.3, 1, 0.1, BandPalette.forDeck('B'));
    expect(a.r, greaterThan(a.b)); // naranja
    expect(b.b, greaterThan(b.r)); // azul
  });
}
