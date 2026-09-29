import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'playback_settings.dart';
import 'song_identity.dart';

/// Carátulas buscadas en internet para las canciones que no traen imagen
/// adentro del archivo: la búsqueda pública de iTunes (gratis, sin cuenta;
/// solo recibe artista y álbum o título). Se guardan en el dispositivo por
/// álbum (todas las canciones de un álbum comparten la misma), y lo que no
/// se encuentra no se vuelve a buscar por una semana. Se apaga en Ajustes.
class OnlineArtwork {
  OnlineArtwork._();
  static final instance = OnlineArtwork._();

  static const _retryNotFound = Duration(days: 7);

  /// El servicio permite unos 20 pedidos por minuto: se hacen de a uno y
  /// espaciados, así una biblioteca grande no se queda sin respuestas.
  static const _spacing = Duration(milliseconds: 3200);

  final Map<String, Future<Uint8List?>> _memory = {};
  final List<(ArtworkQuery, Completer<(Uint8List?, bool)>)> _pending = [];
  bool _working = false;
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// Olvida lo pedido en esta sesión (p. ej. al prender el ajuste).
  void clearMemory() => _memory.clear();

  /// Carátula de la canción, o `null` si no hay (o está apagado en Ajustes).
  Future<Uint8List?> find(
      {required String title, String? artist, String? album}) {
    if (!PlaybackSettings.instance.onlineArtwork) return Future.value(null);
    final query = artworkQuery(title: title, artist: artist, album: album);
    if (query == null) return Future.value(null);
    return _memory[query.key] ??= _cachedOrFetch(query);
  }

  Future<Uint8List?> _cachedOrFetch(ArtworkQuery query) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}covers_online');
    final name = _hash(query.key);
    final image = File('${dir.path}${Platform.pathSeparator}$name.jpg');
    final none = File('${dir.path}${Platform.pathSeparator}$name.none');
    try {
      if (await image.exists()) return await image.readAsBytes();
      if (await none.exists()) {
        final when = DateTime.tryParse(await none.readAsString());
        if (when != null && DateTime.now().difference(when) < _retryNotFound) {
          return null;
        }
      }
    } catch (e) {
      debugPrint('Caché de carátulas ilegible: $e');
    }

    final completer = Completer<(Uint8List?, bool)>();
    _pending.add((query, completer));
    unawaited(_work());
    final (bytes, reached) = await completer.future;

    try {
      await dir.create(recursive: true);
      if (bytes != null) {
        await image.writeAsBytes(bytes);
      } else if (reached) {
        await none.writeAsString(DateTime.now().toIso8601String());
      } else {
        // Sin internet: se vuelve a intentar más adelante.
        _memory.remove(query.key);
      }
    } catch (e) {
      debugPrint('No se pudo guardar la carátula: $e');
    }
    return bytes;
  }

  /// Atiende los pedidos de a uno, empezando por el más reciente: lo que
  /// está en pantalla o sonando ahora no espera detrás de toda la
  /// biblioteca.
  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_pending.isNotEmpty) {
        final wait = _spacing - DateTime.now().difference(_lastRequest);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        final (query, completer) = _pending.removeLast();
        _lastRequest = DateTime.now();
        completer.complete(await _fetch(query));
      }
    } finally {
      _working = false;
    }
  }

  /// (imagen, si el servicio llegó a responder).
  Future<(Uint8List?, bool)> _fetch(ArtworkQuery query) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.https('itunes.apple.com', '/search', {
        'term': query.term,
        'media': 'music',
        'entity': query.byAlbum ? 'album' : 'song',
        'limit': '8',
      });
      final request = await client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        await response.drain<void>();
        // 403/429: límite de pedidos, no "no existe".
        return (null, response.statusCode == 404);
      }
      final body = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final results =
          (body['results'] as List? ?? const []).cast<Map<String, dynamic>>();
      final best = pickBestArtworkResult(results,
          artist: query.artist,
          term: query.term,
          artistInTerm: query.artistInTerm);
      final url = (best?['artworkUrl100'] as String?)
          ?.replaceAll('100x100bb', '600x600bb');
      if (url == null) return (null, true);

      final imageRequest = await client.getUrl(Uri.parse(url));
      final imageResponse =
          await imageRequest.close().timeout(const Duration(seconds: 10));
      if (imageResponse.statusCode != 200) {
        await imageResponse.drain<void>();
        return (null, true);
      }
      final builder = BytesBuilder(copy: false);
      await imageResponse.forEach(builder.add);
      return (builder.takeBytes(), true);
    } catch (e) {
      debugPrint('Búsqueda de carátula sin respuesta: $e');
      return (null, false);
    } finally {
      client.close(force: true);
    }
  }

  static String _hash(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }
}

/// Qué buscar para una canción. Por álbum si se conoce (todas sus canciones
/// comparten la carátula); si no, por artista + título. Muchos MP3 no traen
/// etiquetas y el nombre del archivo es "007. Artista - Tema": se
/// aprovecha. Si ni eso, se busca con el nombre entero y solo se acepta un
/// resultado cuyo artista aparezca escrito en ese nombre ([artistInTerm]).
class ArtworkQuery {
  const ArtworkQuery({
    required this.term,
    required this.key,
    required this.byAlbum,
    this.artist,
    this.artistInTerm = false,
  });

  final String term;
  final String key;
  final bool byAlbum;
  final String? artist;
  final bool artistInTerm;
}

ArtworkQuery? artworkQuery(
    {required String title, String? artist, String? album}) {
  final id = songIdentity(title: title, artist: artist, album: album);
  if (id == null) return null;
  final songArtist = id.artist;
  if (songArtist == null) {
    // Sin artista: se busca con el nombre entero y se valida después.
    return ArtworkQuery(
      term: id.title,
      key: 'free|${id.title.toLowerCase()}',
      byAlbum: false,
      artistInTerm: true,
    );
  }
  final songAlbum = id.album;
  if (songAlbum != null) {
    return ArtworkQuery(
      term: '$songArtist $songAlbum',
      key: 'album|${songArtist.toLowerCase()}|${songAlbum.toLowerCase()}',
      byAlbum: true,
      artist: songArtist,
    );
  }
  return ArtworkQuery(
    term: '$songArtist ${id.title}',
    key: 'song|${songArtist.toLowerCase()}|${id.title.toLowerCase()}',
    byAlbum: false,
    artist: songArtist,
  );
}

/// El resultado cuyo artista más se parece al de la canción (para no poner
/// la carátula de otro artista con un tema del mismo nombre). Con
/// [artistInTerm], el artista del resultado tiene que aparecer escrito en
/// [term] (búsquedas por nombre de archivo, sin artista conocido).
Map<String, dynamic>? pickBestArtworkResult(
  List<Map<String, dynamic>> results, {
  String? artist,
  String? term,
  bool artistInTerm = false,
}) {
  if (results.isEmpty) return null;
  final reference = artistInTerm ? term : artist;
  if (reference == null) return null;
  final wanted = searchWords(reference);
  Map<String, dynamic>? best;
  var bestScore = 0;
  for (final result in results) {
    final name = result['artistName'] as String? ?? '';
    final score = artistInTerm
        ? artistNamedIn(name, reference)
        : searchWords(name).intersection(wanted).length;
    if (score > bestScore) {
      bestScore = score;
      best = result;
    }
  }
  return best;
}
