import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';
import 'package:tk_music/domain/entities/song.dart';

import 'active_profile.dart';

/// Mide el volumen real (dB) de cada canción para que el Mezclador
/// automático pueda emparejar la sonoridad entre temas al cruzarlos, en vez
/// de que uno se escuche de golpe más fuerte o más flojo que el anterior —
/// como haría un DJ de verdad. El análisis decodifica solo ~20s de audio
/// (nativamente, ver MainActivity.kt) en vez de la canción entera, y el
/// resultado se cachea por perfil: solo se paga el costo una vez por
/// canción.
class LoudnessStore {
  static const _channel = MethodChannel('tk_music/audio_analysis');

  /// dB "neutro" que se usa si el análisis falla (archivo raro/corrupto),
  /// para no romper la mezcla por una sola canción problemática.
  static const neutralDb = -23.0;

  String get _key => '${ActiveProfile.instance.key}.loudnessDb';

  Future<double> dbFor(Song song) async {
    final cache = await _readCache();
    final cached = cache[song.mediaStoreId];
    if (cached != null) return cached;

    final db = await _analyze(song.filePath);
    cache[song.mediaStoreId] = db;
    await _writeCache(cache);
    return db;
  }

  Future<double> _analyze(String path) async {
    try {
      // Si el hilo nativo de análisis está ocupado (p. ej. terminando la
      // onda de otra canción) esto podría demorar; con este límite nunca
      // deja al Mezclador automático esperando para siempre por un volumen
      // que puede llegar tarde — usa el neutro y sigue.
      final result = await _channel
          .invokeMethod<double>('analyzeLoudness', {'path': path})
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      return result ?? neutralDb;
    } catch (_) {
      return neutralDb;
    }
  }

  Future<Map<int, double>> _readCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return readJson(
      raw,
      (decoded) => (decoded as Map<String, dynamic>)
          .map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())),
      fallback: const {},
      context: 'LoudnessStore._readCache',
    );
  }

  Future<void> _writeCache(Map<int, double> cache) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(cache.map((k, v) => MapEntry(k.toString(), v)));
    await prefs.setString(_key, raw);
  }
}
