import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';
import 'package:tk_music/core/platform.dart';

import 'track_features.dart';

/// BPM, pulsos, tonalidad y energía de cada archivo, calculados una sola
/// vez y guardados (por ruta de archivo: no dependen del perfil). El audio
/// lo decodifica el análisis nativo (MainActivity.kt / Media Foundation en
/// Windows) y el cálculo corre en un isolate aparte para no trabar la UI.
class TrackFeaturesStore {
  TrackFeaturesStore._();
  static final instance = TrackFeaturesStore._();

  static const _channel = MethodChannel('tk_music/audio_analysis');
  static const _key = 'trackFeatures.v1';
  static const _sampleRate = 11025;
  static const _seconds = 45;

  Map<String, dynamic>? _cache;
  final Map<String, Future<TrackFeatures?>> _inFlight = {};
  Future<void> _queue = Future.value();

  /// Ya calculado (sin analizar nada nuevo).
  TrackFeatures? cached(String path) {
    final raw = _cache?[path];
    return raw is Map<String, dynamic> ? TrackFeatures.fromJson(raw) : null;
  }

  Future<void> warmUp() => _loadCache();

  /// Rasgos de [path]; los analiza si hace falta (de a uno por vez).
  /// [durationMs] ayuda a elegir un tramo representativo (el del medio).
  Future<TrackFeatures?> featuresFor(String path, {int? durationMs}) async {
    await _loadCache();
    final known = cached(path);
    if (known != null) return known;
    if (!hasNativeAudioAnalysis) return null;
    // Ojo: el `remove` va en un bloque. Con `() => _inFlight.remove(path)`
    // la función devolvía el mismo Future que se está completando (el que
    // guarda _inFlight) y `whenComplete` se quedaba esperándolo: el pedido
    // no terminaba nunca, aunque el análisis ya estuviera hecho (los decks
    // quedaban "analizando BPM" hasta rendirse).
    return _inFlight[path] ??= _enqueue(path, durationMs).whenComplete(() {
      _inFlight.remove(path);
    });
  }

  Future<TrackFeatures?> _enqueue(String path, int? durationMs) {
    final completer = Completer<TrackFeatures?>();
    _queue = _queue.then((_) async {
      final result = await _analyze(path, durationMs);
      completer.complete(result);
    });
    return completer.future;
  }

  Future<TrackFeatures?> _analyze(String path, int? durationMs) async {
    try {
      // El tramo del medio suele tener el ritmo y la armonía "de verdad"
      // (sin intro ni final).
      final startMs = durationMs != null && durationMs > (_seconds + 20) * 1000
          ? ((durationMs - _seconds * 1000) * 0.4).round()
          : 0;
      final result =
          await _channel.invokeMapMethod<String, Object?>('decodePcm', {
        'path': path,
        'startMs': startMs,
        'seconds': _seconds,
        'sampleRate': _sampleRate,
        // Tope: la cola es de toda la app; un pedido trabado no puede
        // dejar esperando para siempre a los que vienen detrás.
      }).timeout(const Duration(seconds: 45));
      final bytes = result?['pcm'] as Uint8List?;
      if (bytes == null || bytes.length < _sampleRate * 4) return null;
      final realStart =
          (result!['startMs'] as num?)?.toDouble() ?? startMs.toDouble();
      final pcm = bytes.buffer
          .asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
      final copy = Int16List.fromList(pcm);
      final features = await Isolate.run(
        () => analyzeTrackFeatures(copy, _sampleRate, realStart),
      );
      _cache![path] = features.toJson();
      await _save();
      return features;
    } catch (e) {
      debugPrint('Análisis de ritmo/tonalidad de $path falló: $e');
      return null;
    }
  }

  Future<void> _loadCache() async {
    if (_cache != null) return;
    final prefs = await SharedPreferences.getInstance();
    _cache = readJson(
      prefs.getString(_key),
      (decoded) => Map<String, dynamic>.from(decoded as Map),
      fallback: <String, dynamic>{},
      context: 'TrackFeaturesStore',
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_cache));
  }
}
