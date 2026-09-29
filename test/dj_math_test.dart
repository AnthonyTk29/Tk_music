import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/dj/dj_math.dart';
import 'package:tk_music/services/track_features.dart';

TrackFeatures _track(double bpm, {double firstBeat = 0, int key = -1}) =>
    TrackFeatures(bpm: bpm, firstBeatMs: firstBeat, keyIndex: key, energy: .5);

void main() {
  group('sincronizar BPM', () {
    test('lleva una canción al tempo de la otra', () {
      expect(tempoForSync(120, 126), closeTo(1.05, 1e-9));
      expect(tempoForSync(128, 120), closeTo(0.9375, 1e-9));
    });

    test('doble o mitad de tempo se empareja por el mismo pulso', () {
      expect(tempoForSync(70, 140), closeTo(1.0, 1e-9));
      expect(tempoForSync(172, 88), closeTo(88 * 2 / 172, 1e-9));
    });

    test('elige el rango de pitch justo', () {
      expect(pitchRangeFor(1.05), 0.08);
      expect(pitchRangeFor(0.88), 0.16);
      expect(pitchRangeFor(1.25), 0.32);
      expect(pitchRangeFor(1.5), isNull);
    });
  });

  group('fase de los pulsos', () {
    final master = _track(120, firstBeat: 100); // pulso cada 500 ms
    final follower = _track(120, firstBeat: 40);

    test('alinea la que sigue con el master', () {
      // Master a 1/4 de pulso; la otra en su pulso exacto.
      final aligned = alignedPosition(
          follower: follower, followerMs: 1040, master: master, masterMs: 1225);
      expect(beatPhase(follower, aligned), closeTo(0.25, 1e-9));
      expect((aligned - 1040).abs(), lessThanOrEqualTo(250));
    });

    test('el desfase se mide en ms reales y con signo', () {
      final ahead = phaseErrorMs(
          follower: follower,
          followerMs: 1040 + 20,
          master: master,
          masterMs: 1100,
          masterBpm: 120);
      expect(ahead, closeTo(20, 1e-6));
      final behind = phaseErrorMs(
          follower: follower,
          followerMs: 1040 - 30,
          master: master,
          masterMs: 1100,
          masterBpm: 120);
      expect(behind, closeTo(-30, 1e-6));
    });

    test('grilla: pulso cercano, anterior y próximo compás', () {
      expect(nearestBeat(master, 840), 600);
      expect(nearestBeat(master, 860), 1100);
      expect(beatAtOrBefore(master, 1099), 600);
      expect(nextDownbeat(master, 150), 2100);
      expect(nextDownbeat(master, 100), 100);
    });
  });

  group('tonalidad', () {
    test('misma casilla Camelot, sin mover', () {
      // La menor (21) y Do mayor (0) son 8A y 8B: la misma casilla.
      expect(semitonesToMatchKey(21, 0), 0);
      expect(semitonesToMatchKey(0, 0), 0);
    });

    test('mueve lo mínimo, aceptando casillas vecinas', () {
      // Re mayor (2) a Do mayor (0): -2 semitonos.
      expect(semitonesToMatchKey(2, 0), -2);
      // Fa# mayor (6) a Do mayor (0): el opuesto de la rueda. En vez de
      // mover 6, va a la vecina (Sol mayor o Fa mayor): ±1.
      expect(semitonesToMatchKey(6, 0)!.abs(), 1);
      expect(semitonesToMatchKey(-1, 0), isNull);
    });
  });

  test('crossfader de potencia constante', () {
    final left = crossfaderGains(-1);
    expect(left.a, closeTo(1, 1e-9));
    expect(left.b, closeTo(0, 1e-9));
    final middle = crossfaderGains(0);
    expect(middle.a * middle.a + middle.b * middle.b, closeTo(1, 1e-9));
    expect(crossfaderGains(1).b, closeTo(1, 1e-9));
  });

  group('auto loop', () {
    final features = _track(120, firstBeat: 0); // compás = 2000 ms
    test('arranca en el compás y dura lo pedido', () {
      final start = suggestAutoLoopStart(
          features: features,
          peaks: null,
          durationMs: 60000,
          positionMs: 10100,
          beats: 4);
      expect(start, 10000);
    });

    test('evita un tramo con silencio y elige uno parejo', () {
      // 60 s en 600 baldes (100 ms cada uno): silencio entre 10 y 12 s.
      final peaks = List<double>.generate(
          600, (i) => i >= 100 && i < 120 ? 0.0 : (i.isEven ? 0.8 : 0.7));
      final start = suggestAutoLoopStart(
          features: features,
          peaks: peaks,
          durationMs: 60000,
          positionMs: 10100,
          beats: 4);
      expect(start, isNot(10000));
      expect(start % 2000, 0, reason: 'siempre en un compás');
    });
  });

  test('volumen de mpv (escala cúbica) para una ganancia real', () {
    expect(mpvVolumeFor(1), closeTo(100, 1e-9));
    expect(mpvVolumeFor(0.125), closeTo(50, 1e-9)); // -18 dB
    expect(mpvVolumeFor(4), closeTo(158.74, 0.01)); // +12 dB
    expect(mpvVolumeFor(0), 0);
  });

  test('tiempo con formato de DJ', () {
    expect(formatDjTime(83400), '1:23.4');
    expect(formatDjTime(5000, tenths: false), '0:05');
  });
}
