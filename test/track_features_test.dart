import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/track_features.dart';

const _rate = 11025;

/// Bombo sintético: un golpe grave que decae, cada 60/bpm segundos,
/// arrancando en [firstBeatMs], más un colchón de ruido suave.
Int16List _drums(double bpm, {double seconds = 30, double firstBeatMs = 0}) {
  final samples = Float64List((seconds * _rate).round());
  final random = math.Random(7);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = (random.nextDouble() - 0.5) * 300;
  }
  final period = 60 / bpm;
  for (var t = firstBeatMs / 1000; t < seconds; t += period) {
    final start = (t * _rate).round();
    for (var i = 0; i < _rate * 0.12 && start + i < samples.length; i++) {
      final time = i / _rate;
      samples[start + i] +=
          16000 * math.exp(-time * 35) * math.sin(2 * math.pi * 70 * time);
    }
  }
  return Int16List.fromList(
      [for (final s in samples) s.round().clamp(-32768, 32767)]);
}

/// Progresión de acordes (cada uno 2 s), en senoidales.
Int16List _chords(List<List<double>> chords) {
  final perChord = 2 * _rate;
  final out = Int16List(perChord * chords.length * 3);
  var index = 0;
  for (var repeat = 0; repeat < 3; repeat++) {
    for (final chord in chords) {
      for (var i = 0; i < perChord; i++) {
        final t = i / _rate;
        var v = 0.0;
        for (final f in chord) {
          v += math.sin(2 * math.pi * f * t) +
              0.3 * math.sin(2 * math.pi * f * 2 * t);
        }
        out[index++] = (v * 3000).round().clamp(-32768, 32767);
      }
    }
  }
  return out;
}

double _note(int midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();
List<double> _triad(int root, {bool minor = false}) =>
    [_note(root), _note(root + (minor ? 3 : 4)), _note(root + 7)];

void main() {
  for (final bpm in [120.0, 128.0, 95.0]) {
    test('detecta $bpm BPM', () {
      final features = analyzeTrackFeatures(_drums(bpm), _rate, 0);
      expect(features.bpm, closeTo(bpm, 1.5));
    });
  }

  test('ubica los pulsos (fase) aunque el tramo arranque a mitad de canción',
      () {
    // Pulsos a 120 BPM (cada 500 ms) desde los 200 ms del tramo, y el tramo
    // arranca en el segundo 60,1 de la canción → pulsos en ...300 ms.
    final features =
        analyzeTrackFeatures(_drums(120, firstBeatMs: 200), _rate, 60100);
    final period = features.beatPeriodMs;
    final error = ((features.firstBeatMs - 300) % period + period) % period;
    expect(math.min(error, period - error), lessThan(40));
  });

  test('detecta La menor (Am - Dm - E)', () {
    final pcm = _chords([
      _triad(57, minor: true),
      _triad(62, minor: true),
      _triad(64),
      _triad(57, minor: true)
    ]);
    final features = analyzeTrackFeatures(pcm, _rate, 0);
    expect(features.keyName, 'La menor');
    expect(features.camelot, '8A');
  });

  test('detecta Do mayor (C - F - G - C)', () {
    final pcm = _chords([_triad(60), _triad(65), _triad(67), _triad(60)]);
    final features = analyzeTrackFeatures(pcm, _rate, 0);
    expect(features.keyName, 'Do mayor');
    expect(features.camelot, '8B');
  });

  test('el orden para mezclar encadena tempos y tonos parecidos', () {
    const a = TrackFeatures(
        bpm: 124, firstBeatMs: 0, keyIndex: 21, energy: 0.5); // Am 8A
    const b = TrackFeatures(
        bpm: 90, firstBeatMs: 0, keyIndex: 1, energy: 0.3); // Do# mayor
    const c = TrackFeatures(
        bpm: 125, firstBeatMs: 0, keyIndex: 0, energy: 0.55); // C 8B
    const d = TrackFeatures(
        bpm: 126, firstBeatMs: 0, keyIndex: 16, energy: 0.6); // Em 9A
    final order = orderForMixing(
        ['a', 'b', 'c', 'd'], (id) => {'a': a, 'b': b, 'c': c, 'd': d}[id]);
    expect(order.first, 'a');
    expect(order.last, 'b', reason: 'la de tempo muy distinto queda al final');
  });

  test('se guarda y se lee igual', () {
    const features = TrackFeatures(
        bpm: 128.04, firstBeatMs: 312.4, keyIndex: 21, energy: 0.7123);
    final copy = TrackFeatures.fromJson(features.toJson());
    expect(copy.bpm, 128.04);
    expect(copy.camelot, '8A');
    expect(copy.summary, '128 BPM · 8A');
  });
}
