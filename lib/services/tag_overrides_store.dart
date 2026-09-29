import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';
import 'package:tk_music/domain/entities/song.dart';

/// Corrección hecha a mano sobre los datos de una canción.
class TagOverride {
  const TagOverride(
      {this.title, this.artist, this.album, this.genre, this.coverPath});

  factory TagOverride.fromJson(Map<String, dynamic> json) => TagOverride(
        title: json['title'] as String?,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        genre: json['genre'] as String?,
        coverPath: json['cover'] as String?,
      );

  final String? title;
  final String? artist;
  final String? album;
  final String? genre;

  /// Carátula elegida por el usuario (JPEG en la carpeta de la app).
  final String? coverPath;

  bool get isEmpty =>
      title == null &&
      artist == null &&
      album == null &&
      genre == null &&
      coverPath == null;

  Map<String, dynamic> toJson() => {
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (genre != null) 'genre': genre,
        if (coverPath != null) 'cover': coverPath,
      };
}

/// Editor de tags: las correcciones (título, artista, álbum, género y
/// carátula) se guardan en la app y se aplican sobre lo que trae el archivo
/// en toda la app — biblioteca, colas, sesiones de sincronización,
/// controles del sistema. Así funciona con cualquier formato y en Android
/// sin permisos de escritura; en desktop, además, los MP3 se pueden
/// reescribir de verdad (ver id3.dart). Globales del dispositivo: son
/// datos del archivo, no preferencias de un perfil.
class TagOverridesStore extends ChangeNotifier {
  TagOverridesStore._();
  static final instance = TagOverridesStore._();

  static const _key = 'tagOverrides.v1';
  Map<int, TagOverride> _overrides = {};

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _overrides = readJson(
      prefs.getString(_key),
      (decoded) => (decoded as Map<String, dynamic>).map(
        (k, v) => MapEntry(
            int.parse(k), TagOverride.fromJson(v as Map<String, dynamic>)),
      ),
      fallback: <int, TagOverride>{},
      context: 'TagOverridesStore',
    );
    notifyListeners();
  }

  TagOverride? of(int songId) => _overrides[songId];

  /// [song] con las correcciones aplicadas.
  Song apply(Song song) {
    final o = _overrides[song.mediaStoreId];
    if (o == null) return song;
    return song.copyWith(
        title: o.title, artist: o.artist, album: o.album, genre: o.genre);
  }

  /// Carátula personalizada de [songId], si tiene (y el archivo existe).
  File? coverFile(int songId) {
    final path = _overrides[songId]?.coverPath;
    if (path == null) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  /// Guarda la corrección. Los textos vacíos o iguales al original vuelven
  /// al valor del archivo. [cover]: carátula nueva; [removeCover] vuelve a
  /// la del archivo.
  Future<void> save(
    Song original, {
    required String title,
    required String artist,
    required String album,
    required String genre,
    Uint8List? cover,
    bool removeCover = false,
  }) async {
    String? diff(String value, String? base) {
      final trimmed = value.trim();
      return trimmed.isEmpty || trimmed == (base ?? '') ? null : trimmed;
    }

    final previous = _overrides[original.mediaStoreId];
    var coverPath = removeCover ? null : previous?.coverPath;
    if (removeCover || cover != null) await _deleteCover(previous?.coverPath);
    if (cover != null) {
      coverPath = await _writeCover(original.mediaStoreId, cover);
    }

    final updated = TagOverride(
      title: diff(title, original.title),
      artist: diff(artist, original.artist),
      album: diff(album, original.album),
      genre: diff(genre, original.genre),
      coverPath: coverPath,
    );
    if (updated.isEmpty) {
      _overrides.remove(original.mediaStoreId);
    } else {
      _overrides[original.mediaStoreId] = updated;
    }
    await _persist();
    notifyListeners();
  }

  /// Borra todas las correcciones de [songId].
  Future<void> reset(int songId) async {
    await _deleteCover(_overrides.remove(songId)?.coverPath);
    await _persist();
    notifyListeners();
  }

  Future<String> _writeCover(int songId, Uint8List bytes) async {
    final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}covers');
    await dir.create(recursive: true);
    // Nombre nuevo en cada cambio: si se reusara la ruta, la imagen vieja
    // quedaría en la caché de imágenes de Flutter.
    final file = File(
        '${dir.path}${Platform.pathSeparator}${songId}_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<void> _deleteCover(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('No se pudo borrar la carátula $path: $e');
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_overrides.map((k, v) => MapEntry(k.toString(), v.toJson()))),
    );
  }
}
