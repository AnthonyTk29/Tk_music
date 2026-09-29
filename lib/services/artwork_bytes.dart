import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:tk_music/domain/entities/song.dart';

import 'desktop_media_service.dart';
import 'id3.dart';
import 'artwork_colors.dart';
import 'online_artwork.dart';
import 'playback_settings.dart';
import 'tag_overrides_store.dart';

/// Carátula de una canción de la biblioteca como bytes, igual en las dos
/// plataformas. En orden:
///  1. La elegida en el editor de tags.
///  2. La que trae el archivo: MediaStore en Android; en desktop, la
///     embebida en el MP3 (leída acá mismo) o la miniatura del sistema.
///  3. Si no tiene ninguna, la de internet ([OnlineArtwork]).
/// La usan las carátulas de desktop, el color según la carátula y
/// "Sincronizar con otro dispositivo" (que se la manda a los invitados).
class ArtworkBytes {
  ArtworkBytes._();

  /// id de canción → sus datos, para ubicar el archivo (en desktop el id es
  /// un hash de la ruta) y buscar en internet. Lo llena la biblioteca al
  /// cargar.
  static final Map<int, Song> _songs = {};

  static void registerSongs(Iterable<Song> songs) {
    for (final song in songs) {
      _songs[song.mediaStoreId] = song;
    }
    _watchSettings();
  }

  static bool _watching = false;
  static bool? _onlineWas;

  /// Al prender/apagar "Buscar carátulas en internet" se vuelven a pedir.
  static void _watchSettings() {
    if (_watching) return;
    _watching = true;
    final settings = PlaybackSettings.instance;
    _onlineWas = settings.onlineArtwork;
    settings.addListener(() {
      if (settings.onlineArtwork == _onlineWas) return;
      _onlineWas = settings.onlineArtwork;
      _cache.clear();
      OnlineArtwork.instance.clearMemory();
      ArtworkColors.clear();
    });
  }

  static const _maxCached = 300;
  static final Map<String, Future<Uint8List?>> _cache = {};

  /// Olvida lo cacheado de [songId] (se cambió su carátula).
  static void invalidate(int songId) =>
      _cache.removeWhere((key, _) => key.startsWith('$songId@'));

  static Future<Uint8List?> forSong(int songId, {int size = 300}) {
    final key = '$songId@$size';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // al final: usado hace poco
      return cached;
    }
    final future = _load(songId, size);
    _cache[key] = future;
    if (_cache.length > _maxCached) _cache.remove(_cache.keys.first);
    return future;
  }

  static Future<Uint8List?> _load(int songId, int size) async {
    try {
      final custom = TagOverridesStore.instance.coverFile(songId);
      if (custom != null) return await custom.readAsBytes();
      final own = await _fromFile(songId, size);
      if (own != null && own.isNotEmpty) return own;
      return await fromInternet(songId);
    } catch (e) {
      debugPrint('Carátula de $songId no disponible: $e');
      return null;
    }
  }

  static final Map<String, Future<Uint8List?>> _byUrl = {};

  /// Carátula de una canción de la sección Online (viene con su URL). Se
  /// guarda en el dispositivo para no bajarla de nuevo.
  static Future<Uint8List?> forUrl(String url) {
    final cached = _byUrl.remove(url);
    if (cached != null) return _byUrl[url] = cached;
    final future = _download(url);
    _byUrl[url] = future;
    if (_byUrl.length > _maxCached) _byUrl.remove(_byUrl.keys.first);
    return future;
  }

  static Future<Uint8List?> _download(String url) async {
    var hash = 0x811c9dc5;
    for (final unit in url.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    final file = File(p.join((await getApplicationSupportDirectory()).path,
        'covers_url', '${hash.toRadixString(16)}.jpg'));
    try {
      if (await file.exists()) return await file.readAsBytes();
    } catch (_) {}
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final response = await (await client.getUrl(Uri.parse(url)))
          .close()
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        await response.drain<void>();
        _byUrl.remove(url);
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      final bytes = builder.takeBytes();
      try {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      } catch (_) {}
      return bytes;
    } catch (e) {
      // Sin internet: se vuelve a intentar la próxima vez.
      _byUrl.remove(url);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Solo la de internet (para cuando el archivo no trae imagen).
  static Future<Uint8List?> fromInternet(int songId) {
    final song = _songs[songId];
    if (song == null) return Future.value(null);
    return OnlineArtwork.instance
        .find(title: song.title, artist: song.artist, album: song.album);
  }

  static Future<Uint8List?> _fromFile(int songId, int size) async {
    if (Platform.isAndroid) {
      return OnAudioQuery().queryArtwork(
        songId,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: size,
        quality: 80,
      );
    }
    final path = _songs[songId]?.filePath;
    if (path == null) return null;
    // MP3: la imagen embebida se lee directo de la etiqueta (no depende de
    // que Windows tenga generada su miniatura).
    if (path.toLowerCase().endsWith('.mp3')) {
      try {
        final picture = (await Id3Tag.readFile(path))?.picture;
        if (picture != null && picture.isNotEmpty) return picture;
      } catch (_) {
        // Etiqueta ilegible: se prueba con la miniatura del sistema.
      }
    }
    return DesktopMediaService.instance.artwork(path, size: size);
  }
}
