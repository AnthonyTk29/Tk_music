import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'artwork_bytes.dart';
import 'id3.dart';
import 'mp3_link_downloader.dart';

/// Una canción de la sección Online.
class OnlineTrack {
  const OnlineTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.streamUrl,
    required this.downloadable,
    this.artworkUrl,
    this.genre,
  });

  final String id;
  final String title;
  final String artist;
  final Duration duration;
  final String streamUrl;
  final String? artworkUrl;
  final String? genre;

  /// El artista permite bajarla (sin condiciones). Si no, solo se escucha.
  final bool downloadable;

  MediaItem toMediaItem() => MediaItem(
        id: streamUrl,
        title: title,
        artist: artist,
        genre: genre,
        duration: duration,
        artUri: artworkUrl == null ? null : Uri.parse(artworkUrl!),
        extras: {
          'online': true,
          'onlineId': id,
          if (artworkUrl != null) 'artworkUrl': artworkUrl,
          'downloadable': downloadable,
        },
      );
}

/// Si lo que suena es de la sección Online.
bool isOnlineItem(MediaItem? item) => item?.extras?['online'] == true;

/// Carátula por URL de un tema de la sección Online (null para los de la
/// biblioteca, que tienen `songId`).
String? artworkUrlOf(MediaItem? item) => item?.extras?['artworkUrl'] as String?;

/// Un género para filtrar: [label] se muestra, [key] es el del catálogo.
class OnlineGenre {
  const OnlineGenre(this.label, this.key);
  final String label;
  final String? key;
}

/// Música para escuchar por internet, gratis y con permiso de sus
/// artistas: se busca, suena directo (streaming) y se puede bajar a la
/// biblioteca solo cuando el artista lo permite. Hoy sale del catálogo
/// abierto de Audius, pero el resto de la app no lo sabe: acá se podría
/// sumar o cambiar la fuente sin tocar las pantallas.
class OnlineCatalog {
  OnlineCatalog._();
  static final instance = OnlineCatalog._();

  static const _host = 'api.audius.co';
  static const _appName = 'TK_MUSIC';
  static const _cacheFor = Duration(minutes: 10);

  static const genres = [
    OnlineGenre('Todo', null),
    OnlineGenre('Latina', 'Latin'),
    OnlineGenre('Pop', 'Pop'),
    OnlineGenre('Urbano', 'Hip-Hop/Rap'),
    OnlineGenre('Electrónica', 'Electronic'),
    OnlineGenre('Reggae', 'Reggae'),
    OnlineGenre('Dancehall', 'Dancehall'),
    OnlineGenre('R&B', 'R&B/Soul'),
    OnlineGenre('Rock', 'Rock'),
    OnlineGenre('Jazz', 'Jazz'),
    OnlineGenre('Acústica', 'Acoustic'),
    OnlineGenre('Lo-Fi', 'Lo-Fi'),
  ];

  final Map<String, (DateTime, List<OnlineTrack>)> _cache = {};

  /// Lo más escuchado del momento, de todos los géneros o de [genre].
  Future<List<OnlineTrack>> popular({String? genre}) => _tracks(
        '/v1/tracks/trending',
        {'time': 'week', if (genre != null) 'genre': genre, 'limit': '60'},
      );

  Future<List<OnlineTrack>> search(String query) {
    final text = query.trim();
    if (text.isEmpty) return Future.value(const []);
    return _tracks('/v1/tracks/search', {'query': text, 'limit': '50'});
  }

  Future<List<OnlineTrack>> _tracks(
      String path, Map<String, String> params) async {
    final uri = Uri.https(_host, path, {...params, 'app_name': _appName});
    final key = uri.toString();
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheFor) {
      return cached.$2;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final response = await (await client.getUrl(uri))
          .close()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw OnlineCatalogException(
            'El servicio de música no respondió (${response.statusCode}). '
            'Probá en un rato.');
      }
      final body = jsonDecode(await response.transform(utf8.decoder).join());
      final tracks = parseOnlineTracks(body);
      _cache[key] = (DateTime.now(), tracks);
      return tracks;
    } on OnlineCatalogException {
      rethrow;
    } catch (e) {
      debugPrint('Catálogo online sin respuesta: $e');
      throw const OnlineCatalogException(
          'No hay conexión. Revisá tu internet y probá de nuevo.');
    } finally {
      client.close(force: true);
    }
  }

  /// Baja [track] a la biblioteca como MP3, con título, artista y carátula
  /// guardados adentro. Solo si [OnlineTrack.downloadable].
  Future<String> download(
    OnlineTrack track, {
    required Mp3LinkDownloader downloader,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (!track.downloadable) {
      throw const Mp3LinkException(
          'El artista no permite descargar esta canción; solo se puede '
          'escuchar en línea.');
    }
    final mp3 = await downloader.download(
      track.streamUrl,
      onProgress: onProgress,
      title: track.title,
      artist: track.artist,
    );
    try {
      final cover = track.artworkUrl == null
          ? null
          : await ArtworkBytes.forUrl(track.artworkUrl!);
      await writeMp3Tags(mp3.file.path,
          title: track.title,
          artist: track.artist,
          genre: track.genre,
          cover: cover);
    } catch (e) {
      // Sin etiquetas igual sirve: el nombre del archivo ya las tiene.
      debugPrint('No se pudieron guardar los datos en el MP3: $e');
    }
    return downloader.saveToLibrary(mp3);
  }
}

class OnlineCatalogException implements Exception {
  const OnlineCatalogException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Convierte la respuesta del catálogo en canciones que se pueden escuchar
/// enteras: se descartan las bloqueadas, borradas y los fragmentos cortos
/// (muestras de menos de un minuto).
List<OnlineTrack> parseOnlineTracks(Object? body) {
  final data = body is Map ? body['data'] : null;
  if (data is! List) return const [];
  final tracks = <OnlineTrack>[];
  final seen = <String>{};
  for (final raw in data.whereType<Map>()) {
    final id = raw['id'] as String?;
    final title = (raw['title'] as String?)?.trim();
    final duration = (raw['duration'] as num?)?.toInt() ?? 0;
    final access = raw['access'] is Map ? raw['access'] as Map : const {};
    if (id == null || title == null || title.isEmpty || !seen.add(id)) {
      continue;
    }
    if (raw['is_delete'] == true ||
        raw['is_available'] == false ||
        raw['is_stream_gated'] == true ||
        access['stream'] == false ||
        duration < 60) {
      continue;
    }
    final user = raw['user'] is Map ? raw['user'] as Map : const {};
    final artwork = raw['artwork'] is Map ? raw['artwork'] as Map : const {};
    tracks.add(OnlineTrack(
      id: id,
      title: title,
      artist: ((user['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (user['name'] as String).trim()
          : 'Artista desconocido',
      duration: Duration(seconds: duration),
      streamUrl: Uri.https(OnlineCatalog._host, '/v1/tracks/$id/stream',
          {'app_name': OnlineCatalog._appName}).toString(),
      artworkUrl: (artwork['480x480'] ??
          artwork['1000x1000'] ??
          artwork['150x150']) as String?,
      genre: (raw['genre'] as String?)?.trim(),
      downloadable: raw['is_downloadable'] == true &&
          raw['is_download_gated'] != true &&
          access['download'] != false,
    ));
  }
  return tracks;
}
