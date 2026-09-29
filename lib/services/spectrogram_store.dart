import 'dart:async';

import 'package:flutter/services.dart';

/// Espectrograma completo de una canción: un array de bandas de frecuencia
/// (0.0-1.0) por cada [frameStepMs] de audio, calculado una sola vez por
/// MainActivity.kt decodificando el PCM y corriendo una FFT propia (no
/// depende del efecto Visualizer del sistema, que algunos fabricantes
/// rechazan). Para mostrarlo "en vivo" alcanza con indexar [frames] por la
/// posición de reproducción actual — no hace falta seguir decodificando
/// nada mientras suena.
class SpectrogramData {
  const SpectrogramData({required this.frames, required this.frameStepMs});

  final List<List<double>> frames;
  final int frameStepMs;

  List<double>? bandsAt(Duration position) {
    if (frames.isEmpty) return null;
    final index = (position.inMilliseconds / frameStepMs)
        .floor()
        .clamp(0, frames.length - 1);
    return frames[index];
  }
}

/// Igual que WaveformStore pero para el espectro: la única diferencia real
/// es que se cachea solo en memoria (no en SharedPreferences) porque un
/// espectrograma es mucho más pesado que la forma de onda — varios miles de
/// arrays de bandas por canción, no unos pocos miles de picos — y al ser
/// puramente derivado del archivo de audio no hace falta que sobreviva a un
/// reinicio de la app, se vuelve a calcular rápido la próxima vez.
class SpectrogramStore {
  static const _channel = MethodChannel('tk_music/spectrum_analysis');
  static const _progressEvents =
      EventChannel('tk_music/spectrum_analysis/progress');

  static final Map<int, SpectrogramData> _cache = {};

  // `static`, no de instancia: un EventChannel solo admite un único
  // `receiveBroadcastStream()` registrado por canal. SpectrogramStore se
  // crea de nuevo cada vez que se abre el Ecualizador (es un campo de
  // State, no un singleton), así que si esto fuera de instancia cada
  // apertura de pantalla registraba una escucha nueva sobre el mismo
  // canal — al cancelar la vieja, el motor de Flutter ya no la reconocía
  // y tiraba "No active stream to cancel".
  static Stream<Map<String, dynamic>>? _progressStream;
  Stream<Map<String, dynamic>> get _progress {
    return _progressStream ??= _progressEvents
        .receiveBroadcastStream()
        .map((raw) => Map<String, dynamic>.from(raw as Map));
  }

  Future<SpectrogramData?> spectrogramFor({
    required int mediaStoreId,
    required String filePath,
    double positionFraction = 0.0,
    void Function(SpectrogramData partial)? onProgress,
  }) async {
    final cached = _cache[mediaStoreId];
    if (cached != null) return cached;

    final data = await _analyze(
      path: filePath,
      mediaStoreId: mediaStoreId,
      positionFraction: positionFraction,
      onProgress: onProgress,
    );
    if (data == null) return null;

    _cache[mediaStoreId] = data;
    return data;
  }

  Future<SpectrogramData?> _analyze({
    required String path,
    required int mediaStoreId,
    required double positionFraction,
    void Function(SpectrogramData partial)? onProgress,
  }) async {
    StreamSubscription<Map<String, dynamic>>? sub;
    try {
      if (onProgress != null) {
        sub = _progress.listen((event) {
          if ((event['mediaStoreId'] as num?)?.toInt() != mediaStoreId) return;
          onProgress(_parse(event));
        });
      }
      final result = await _channel.invokeMapMethod<String, Object?>(
        'analyzeSpectrogram',
        {
          'path': path,
          'mediaStoreId': mediaStoreId,
          'positionFraction': positionFraction,
        },
      );
      if (result == null) return null;
      return _parse(result);
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
    }
  }

  SpectrogramData _parse(Map<dynamic, dynamic> raw) {
    final frames = (raw['frames'] as List<dynamic>)
        .map((frame) =>
            (frame as List<dynamic>).map((v) => (v as num).toDouble()).toList())
        .toList();
    final frameStepMs = (raw['frameStepMs'] as num).toInt();
    return SpectrogramData(frames: frames, frameStepMs: frameStepMs);
  }
}
