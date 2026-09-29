import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tk_music/core/platform.dart';

/// Tags de un archivo de audio leídos del sistema (en Android esto lo da
/// MediaStore).
class DesktopTags {
  const DesktopTags(
      {this.title, this.artist, this.album, this.genre, this.durationMs});

  factory DesktopTags.fromMap(Map<dynamic, dynamic> map) => DesktopTags(
        title: map['title'] as String?,
        artist: map['artist'] as String?,
        album: map['album'] as String?,
        genre: map['genre'] as String?,
        durationMs: (map['durationMs'] as num?)?.toInt(),
      );

  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final int? durationMs;

  Map<String, dynamic> toJson() => {
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (genre != null) 'genre': genre,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

/// Metadatos de la biblioteca de desktop — ver
/// windows/runner/desktop_media_plugin.cpp. Solo Windows por ahora; en
/// Linux/macOS devuelve vacío y la biblioteca usa el nombre de archivo.
class DesktopMediaService {
  DesktopMediaService._();
  static final instance = DesktopMediaService._();

  static const _channel = MethodChannel('tk_music/desktop_media');
  static const _batchSize = 200;

  Map<String, dynamic>? _cache;
  bool _cacheDirty = false;

  /// Tags de [paths] (en el mismo orden; `null` si no se pudieron leer).
  /// Se cachean en disco por ruta + fecha de modificación: leer los tags de
  /// toda la biblioteca en cada arranque tardaba varios segundos.
  Future<List<DesktopTags?>> tagsFor(
      List<(String path, DateTime modified)> files) async {
    if (!hasWindowsMediaIntegration || files.isEmpty) {
      return List.filled(files.length, null);
    }
    final cache = await _loadCache();
    final result = List<DesktopTags?>.filled(files.length, null);
    final missing = <int>[];
    for (var i = 0; i < files.length; i++) {
      final (path, modified) = files[i];
      final entry = cache[path];
      if (entry is Map && entry['m'] == modified.millisecondsSinceEpoch) {
        result[i] = DesktopTags.fromMap(entry);
      } else {
        missing.add(i);
      }
    }

    for (var start = 0; start < missing.length; start += _batchSize) {
      final batch =
          missing.sublist(start, (start + _batchSize).clamp(0, missing.length));
      List<Object?>? raw;
      try {
        raw = await _channel.invokeListMethod<Object?>(
          'readTags',
          {
            'paths': [for (final i in batch) files[i].$1]
          },
        );
      } catch (e) {
        debugPrint('No se pudieron leer los tags: $e');
      }
      if (raw == null) continue;
      for (var j = 0; j < batch.length && j < raw.length; j++) {
        final map = raw[j];
        if (map is! Map) continue;
        final index = batch[j];
        final tags = DesktopTags.fromMap(map);
        result[index] = tags;
        cache[files[index].$1] = {
          ...tags.toJson(),
          'm': files[index].$2.millisecondsSinceEpoch,
        };
        _cacheDirty = true;
      }
    }
    await _saveCache();
    return result;
  }

  /// Carátula embebida en [path] como JPEG, o `null` si no tiene.
  Future<Uint8List?> artwork(String path, {int size = 300}) async {
    if (!hasWindowsMediaIntegration) return null;
    try {
      return await _channel
          .invokeMethod<Uint8List>('artwork', {'path': path, 'size': size});
    } catch (e) {
      debugPrint('Carátula de $path no disponible: $e');
      return null;
    }
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}desktop_tags_cache.json');
  }

  Future<Map<String, dynamic>> _loadCache() async {
    final cached = _cache;
    if (cached != null) return cached;
    var loaded = <String, dynamic>{};
    try {
      final file = await _cacheFile();
      if (await file.exists()) {
        loaded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } catch (e) {
      // Caché corrupto: se vuelve a leer todo, no rompe nada.
      debugPrint('Caché de tags descartado: $e');
    }
    return _cache = loaded;
  }

  Future<void> _saveCache() async {
    final cache = _cache;
    if (cache == null || !_cacheDirty) return;
    _cacheDirty = false;
    try {
      final file = await _cacheFile();
      await file.writeAsString(jsonEncode(cache));
    } catch (e) {
      debugPrint('No se pudo guardar el caché de tags: $e');
    }
  }
}
