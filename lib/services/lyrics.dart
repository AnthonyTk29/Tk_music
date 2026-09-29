import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'id3.dart';
import 'playback_settings.dart';
import 'song_identity.dart';

class LyricLine {
  const LyricLine(this.time, this.text);

  /// `null` en letras sin sincronizar.
  final Duration? time;
  final String text;
}

class Lyrics {
  const Lyrics(
      {required this.lines,
      required this.synced,
      required this.source,
      required this.raw});

  final List<LyricLine> lines;
  final bool synced;

  /// De dónde salió: "archivo .lrc", "etiqueta del MP3", "LRCLIB".
  final String source;

  /// Texto original (formato LRC si es sincronizada), para mandarla tal
  /// cual a otros dispositivos.
  final String raw;

  bool get isEmpty => lines.isEmpty;

  /// Renglón que corresponde a [position] (-1 antes del primero).
  int indexAt(Duration position) {
    if (!synced) return -1;
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      final time = lines[i].time;
      if (time != null && time <= position) {
        index = i;
      } else if (time != null && time > position) {
        break;
      }
    }
    return index;
  }
}

final _timestamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _offsetTag = RegExp(r'^\[offset:\s*([+-]?\d+)\]', caseSensitive: false);
final _metaTag = RegExp(r'^\[[a-zA-Z]+:.*\]$');

/// Lee letras en formato LRC ("[01:23.45]texto", varias marcas por
/// renglón, [offset:±ms]). Si no hay ninguna marca de tiempo, la devuelve
/// como letra sin sincronizar.
Lyrics? parseLyrics(String text, {required String source}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  var offsetMs = 0;
  final timed = <LyricLine>[];
  final plain = <LyricLine>[];
  for (final rawLine in const LineSplitter().convert(trimmed)) {
    final line = rawLine.trim();
    final offset = _offsetTag.firstMatch(line);
    if (offset != null) {
      offsetMs = int.parse(offset.group(1)!);
      continue;
    }
    final stamps = _timestamp.allMatches(line).toList();
    if (stamps.isEmpty) {
      if (_metaTag.hasMatch(line)) continue; // [ar:...], [ti:...]
      plain.add(LyricLine(null, line));
      continue;
    }
    final content = line.substring(stamps.last.end).trim();
    for (final stamp in stamps) {
      final minutes = int.parse(stamp.group(1)!);
      final seconds = int.parse(stamp.group(2)!);
      final fraction = stamp.group(3) ?? '0';
      final millis = int.parse(fraction.padRight(3, '0').substring(0, 3));
      timed.add(LyricLine(
        Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: millis - offsetMs),
        content,
      ));
    }
  }
  if (timed.isNotEmpty) {
    timed.sort((a, b) => a.time!.compareTo(b.time!));
    return Lyrics(lines: timed, synced: true, source: source, raw: trimmed);
  }
  final lines =
      plain.where((l) => l.text.isNotEmpty || plain.length < 200).toList();
  if (lines.every((l) => l.text.isEmpty)) return null;
  return Lyrics(lines: lines, synced: false, source: source, raw: trimmed);
}

/// Busca la letra de una canción: `.lrc` al lado del archivo, la letra
/// embebida en el MP3 y, si está activado en Ajustes, LRCLIB (servicio
/// gratuito de letras sincronizadas: solo recibe artista, título, álbum y
/// duración). Lo encontrado se guarda en el dispositivo.
class LyricsStore {
  LyricsStore._();
  static final instance = LyricsStore._();

  final Map<String, Future<Lyrics?>> _memory = {};
  static const _retryNotFound = Duration(days: 7);

  /// Marca de "se buscó y no hay". La versión cambia cuando la búsqueda
  /// mejora, así se vuelven a probar las que antes no se encontraban.
  static const _noneMark = '#none2 ';

  Future<Lyrics?> lyricsFor({
    required String path,
    required String title,
    String? artist,
    String? album,
    int? durationMs,
  }) {
    return _memory[path] ??= _find(path, title, artist, album, durationMs);
  }

  /// Letra recibida de otro dispositivo (sesión compartida).
  void remember(String key, Lyrics lyrics) =>
      _memory[key] = Future.value(lyrics);

  Future<Lyrics?> _find(String path, String title, String? artist,
      String? album, int? durationMs) async {
    final cacheFile = await _cacheFile(path);
    try {
      if (await cacheFile.exists()) {
        final cached = await cacheFile.readAsString();
        if (cached.startsWith('#none')) {
          final when = cached.startsWith(_noneMark)
              ? DateTime.tryParse(cached.substring(_noneMark.length).trim())
              : null;
          if (when != null &&
              DateTime.now().difference(when) < _retryNotFound) {
            return null;
          }
        } else {
          final lines = cached.split('\n');
          final source = lines.first.startsWith('#source ')
              ? lines.first.substring(8)
              : 'guardada';
          return parseLyrics(lines.skip(1).join('\n'), source: source);
        }
      }
    } catch (e) {
      debugPrint('Caché de letra ilegible: $e');
    }

    var found = await _fromSidecar(path) ?? await _fromTag(path);
    if (found == null) {
      // Sin buscar en internet no se anota como "no tiene letra": al
      // prender el ajuste se busca enseguida.
      if (!PlaybackSettings.instance.onlineLyrics) {
        _memory.remove(path);
        return null;
      }
      final (online, reached) =
          await _fromLrclib(title, artist, album, durationMs);
      found = online;
      if (!reached) {
        // Sin internet: se reintenta la próxima vez que se abra.
        _memory.remove(path);
        return null;
      }
    }
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(found == null
          ? '$_noneMark${DateTime.now().toIso8601String()}'
          : '#source ${found.source}\n${found.raw}');
    } catch (e) {
      debugPrint('No se pudo guardar la letra: $e');
    }
    return found;
  }

  Future<Lyrics?> _fromSidecar(String path) async {
    if (path.startsWith('content://')) return null;
    final dot = path.lastIndexOf('.');
    if (dot <= 0) return null;
    try {
      final file = File('${path.substring(0, dot)}.lrc');
      if (!await file.exists()) return null;
      return parseLyrics(await file.readAsString(), source: 'archivo .lrc');
    } catch (_) {
      return null; // Android sin acceso a archivos que no son audio
    }
  }

  Future<Lyrics?> _fromTag(String path) async {
    if (!path.toLowerCase().endsWith('.mp3')) return null;
    try {
      final tag = await Id3Tag.readFile(path);
      final text = tag?.lyrics;
      return text == null
          ? null
          : parseLyrics(text, source: 'etiqueta del MP3');
    } catch (_) {
      return null;
    }
  }

  /// (letra encontrada, si LRCLIB llegó a responder).
  Future<(Lyrics?, bool)> _fromLrclib(
      String title, String? artist, String? album, int? durationMs) async {
    final id = songIdentity(title: title, artist: artist, album: album);
    if (id == null) return (null, true);
    final songArtist = id.artist;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      Future<dynamic> getJson(Uri uri) async {
        final request = await client.getUrl(uri);
        request.headers
            .set(HttpHeaders.userAgentHeader, 'TK Music (app de música)');
        final response =
            await request.close().timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) {
          await response.drain<void>();
          return null;
        }
        return jsonDecode(await response.transform(utf8.decoder).join());
      }

      Map<String, dynamic>? match;
      if (songArtist != null) {
        final exact = await getJson(Uri.https('lrclib.net', '/api/get', {
          'track_name': id.title,
          'artist_name': songArtist,
          if (id.album != null) 'album_name': id.album!,
          if (durationMs != null && durationMs > 0)
            'duration': '${(durationMs / 1000).round()}',
        }));
        if (exact is Map<String, dynamic>) match = exact;
      }
      if (match == null ||
          (match['syncedLyrics'] == null && match['plainLyrics'] == null)) {
        // Sin artista conocido se busca con el nombre entero y solo vale un
        // resultado cuyo artista aparezca escrito en él.
        final results = await getJson(Uri.https(
            'lrclib.net',
            '/api/search',
            songArtist != null
                ? {'track_name': id.title, 'artist_name': songArtist}
                : {'q': id.title}));
        if (results is List) {
          final candidates = results
              .whereType<Map<String, dynamic>>()
              .where((r) {
            final seconds = (r['duration'] as num?)?.toDouble();
            return durationMs == null ||
                seconds == null ||
                (seconds * 1000 - durationMs).abs() < 4000;
          }).where((r) {
            if (songArtist != null) return true;
            return artistNamedIn(r['artistName'] as String? ?? '', id.title) >
                0;
          }).toList()
            ..sort((a, b) =>
                (b['syncedLyrics'] != null ? 1 : 0) -
                (a['syncedLyrics'] != null ? 1 : 0));
          match = candidates.isEmpty ? null : candidates.first;
        }
      }
      if (match == null) return (null, true);
      final text = (match['syncedLyrics'] ?? match['plainLyrics']) as String?;
      return (
        text == null ? null : parseLyrics(text, source: 'LRCLIB'),
        true,
      );
    } catch (e) {
      debugPrint('LRCLIB no respondió: $e');
      return (null, false);
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _cacheFile(String path) async {
    var hash = 0x811c9dc5;
    for (final unit in path.toLowerCase().codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    final dir = await getApplicationSupportDirectory();
    return File(
        '${dir.path}${Platform.pathSeparator}lyrics${Platform.pathSeparator}${hash.toRadixString(16)}.lrc');
  }
}
