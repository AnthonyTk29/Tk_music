import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/core/platform.dart';
import 'package:tk_music/services/track_features_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tk_music/audio_analysis');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// 45 s de golpes graves a 120 BPM, mono 16 bits a 11 025 Hz.
  Uint8List clickTrack() {
    const rate = 11025;
    final pcm = Int16List(rate * 45);
    const period = rate ~/ 2;
    for (var start = 0; start + 1200 < pcm.length; start += period) {
      for (var i = 0; i < 1200; i++) {
        pcm[start + i] =
            (math.sin(2 * math.pi * 70 * i / rate) * 24000 * (1 - i / 1200))
                .round();
      }
    }
    return pcm.buffer.asUint8List();
  }

  test('el pedido de BPM termina (no se queda esperándose a sí mismo)',
      () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return {'pcm': clickTrack(), 'startMs': 0};
    });
    final path =
        'C:/musica/prueba_${DateTime.now().microsecondsSinceEpoch}.mp3';
    // Antes esto nunca terminaba: el deck esperaba 75 s y mostraba "sin BPM".
    final features = await TrackFeaturesStore.instance
        .featuresFor(path, durationMs: 45000)
        .timeout(const Duration(seconds: 10));
    expect(features, isNotNull);
    expect(features!.bpm, closeTo(120, 2));
    expect(calls, 1);
    // Queda guardado: la segunda vez ni se decodifica.
    await TrackFeaturesStore.instance.featuresFor(path);
    expect(calls, 1);
  }, skip: !hasNativeAudioAnalysis);

  test('dos pedidos a la vez de la misma canción comparten el análisis',
      () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return {'pcm': clickTrack(), 'startMs': 0};
    });
    final path = 'C:/musica/doble_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final both = await Future.wait([
      TrackFeaturesStore.instance.featuresFor(path),
      TrackFeaturesStore.instance.featuresFor(path),
    ]).timeout(const Duration(seconds: 10));
    expect(both.every((f) => f != null), isTrue);
    expect(calls, 1);
  }, skip: !hasNativeAudioAnalysis);
}
