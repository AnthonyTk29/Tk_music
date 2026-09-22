import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';

import 'active_profile.dart';

/// Forma de onda (picos de amplitud normalizados 0.0-1.0) de una canción,
/// para mostrarla igual que VirtualDJ mientras suena. Se decodifica
/// nativamente (ver MainActivity.kt) empezando desde [positionFraction] —
/// el punto donde está el puntero de reproducción ahora mismo — hacia
/// adelante primero (como el pre-buffer de YouTube) y recién después se
/// completa hacia atrás, emitiendo actualizaciones parciales por
/// [onProgress] en vez de esperar al resultado completo. Se cachea por
/// canción y por perfil una vez terminado, ya que no cambia.
class WaveformStore {
  static const _channel = MethodChannel('tk_music/audio_analysis');
  static const _progressEvents =
      EventChannel('tk_music/audio_analysis/waveform_progress');
  // Resolución alta a propósito: el visor estilo VirtualDJ solo muestra una
  // ventana acercada de unas pocas decenas de barras a la vez, así que hace
  // falta bastante más detalle del que se ve comprimido en el ancho de
  // pantalla completo (lo que se usaba antes de mostrar toda la canción de
  // una). El tiempo de decodificación no cambia con esto — depende de la
  // duración del audio, no de en cuántos baldes se junten los picos.
  static const buckets = 1500;

  // `static`: un EventChannel solo admite un `receiveBroadcastStream()`
  // registrado por canal a la vez — si esto fuera de instancia, construir
  // WaveformStore más de una vez (aunque hoy solo lo hace WaveformLoader,
  // una vez) registraría una escucha nueva sobre el mismo canal, y al
  // cancelar la vieja el motor de Flutter tira "No active stream to
  // cancel" (visto con el mismo patrón en SpectrogramStore).
  static Stream<Map<String, dynamic>>? _progressStream;
  Stream<Map<String, dynamic>> get _progress {
    return _progressStream ??= _progressEvents
        .receiveBroadcastStream()
        .map((raw) => Map<String, dynamic>.from(raw as Map));
  }

  String get _key => '${ActiveProfile.instance.key}.waveforms';

  Future<List<double>?> waveformFor({
    required int mediaStoreId,
    required String filePath,
    double positionFraction = 0.0,
    void Function(List<double> partial)? onProgress,
  }) async {
    final cache = await _readCache();
    // El chequeo de longitud descarta entradas cacheadas con la resolución
    // vieja (240 baldes, de antes del visor estilo VirtualDJ) en vez de
    // romper el ventaneo asumiendo que tienen [buckets] elementos.
    final cached = cache[mediaStoreId];
    if (cached != null && cached.length == buckets) return cached;

    final waveform = await _analyze(
      path: filePath,
      mediaStoreId: mediaStoreId,
      positionFraction: positionFraction,
      onProgress: onProgress,
    );
    if (waveform == null) return null;

    cache[mediaStoreId] = waveform;
    await _writeCache(cache);
    return waveform;
  }

  Future<List<double>?> _analyze({
    required String path,
    required int mediaStoreId,
    required double positionFraction,
    void Function(List<double> partial)? onProgress,
  }) async {
    StreamSubscription<Map<String, dynamic>>? sub;
    try {
      if (onProgress != null) {
        sub = _progress.listen((event) {
          if ((event['mediaStoreId'] as num?)?.toInt() != mediaStoreId) return;
          final peaks = (event['peaks'] as List<dynamic>)
              .map((v) => (v as num).toDouble())
              .toList();
          onProgress(peaks);
        });
      }
      final result = await _channel.invokeListMethod<Object?>(
        'analyzeWaveform',
        {
          'path': path,
          'buckets': buckets,
          'mediaStoreId': mediaStoreId,
          'positionFraction': positionFraction,
        },
      );
      return result?.map((v) => (v as num).toDouble()).toList();
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
    }
  }

  Future<Map<int, List<double>>> _readCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return readJson(
      raw,
      (decoded) => (decoded as Map<String, dynamic>).map((k, v) => MapEntry(
            int.parse(k),
            (v as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
          )),
      fallback: const {},
      context: 'WaveformStore._readCache',
    );
  }

  Future<void> _writeCache(Map<int, List<double>> cache) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(cache.map((k, v) => MapEntry(k.toString(), v)));
    await prefs.setString(_key, raw);
  }
}
