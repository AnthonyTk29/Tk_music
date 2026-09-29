import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/domain/repositories/audio_import_repository.dart';

import 'id3.dart';

/// Algo salió mal al descargar: [message] es para mostrar tal cual.
class Mp3LinkException implements Exception {
  const Mp3LinkException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Un MP3 ya descargado (en un archivo temporal) y lo que se sabe de él.
class DownloadedMp3 {
  const DownloadedMp3({
    required this.file,
    required this.fileName,
    this.title,
    this.artist,
  });

  final File file;
  final String fileName;
  final String? title;
  final String? artist;
}

/// Descarga una canción desde un enlace directo a un archivo MP3 (una
/// página, tu servidor, Google Drive o Dropbox compartidos) y la suma a la
/// biblioteca. Solo MP3: se revisa el contenido del archivo, no solo la
/// extensión, y cualquier otra cosa (una página web, un M4A, un ZIP…) se
/// rechaza sin guardarse.
class Mp3LinkDownloader {
  static const maxBytes = 300 * 1024 * 1024;

  HttpClient? _client;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  /// Descarga [link] a un archivo temporal. [onProgress] recibe los bytes
  /// recibidos y el total (null si el servidor no lo dice). [title] y
  /// [artist] se usan si el MP3 no los trae adentro.
  Future<DownloadedMp3> download(
    String link, {
    void Function(int received, int? total)? onProgress,
    String? title,
    String? artist,
  }) async {
    final url = normalizeMp3Link(link);
    if (url == null) {
      throw const Mp3LinkException(
          'Eso no es un enlace válido. Tiene que empezar con http:// o https://');
    }
    if (isStreamingPage(url)) {
      throw const Mp3LinkException(
          'Ese enlace es de una página de videos o de música en línea, no '
          'de un archivo. Solo se pueden descargar enlaces directos a '
          'archivos MP3.');
    }

    _cancelled = false;
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Mozilla/5.0 (TK Music)';
    final temp = File(p.join((await getTemporaryDirectory()).path,
        'tk_download_${DateTime.now().microsecondsSinceEpoch}.mp3'));
    IOSink? sink;
    try {
      final request = await client.getUrl(url);
      request.maxRedirects = 10;
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        throw Mp3LinkException(_statusMessage(response.statusCode));
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      if (total != null && total > maxBytes) {
        throw const Mp3LinkException(
            'El archivo es demasiado grande para ser una canción (más de '
            '300 MB).');
      }

      sink = temp.openWrite();
      final head = BytesBuilder(copy: true);
      var checked = false;
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) break;
        if (!checked) {
          head.add(chunk);
          if (head.length >= 4096) {
            checked = true;
            _checkHead(head.toBytes());
          }
        }
        received += chunk.length;
        if (received > maxBytes) {
          throw const Mp3LinkException(
              'El archivo es demasiado grande para ser una canción (más de '
              '300 MB).');
        }
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.close();
      sink = null;
      if (_cancelled) throw const Mp3LinkException('Descarga cancelada.');
      if (!checked) _checkHead(head.toBytes());
      if (received < 8 * 1024) {
        throw const Mp3LinkException(
            'El archivo está vacío o incompleto: no es una canción.');
      }

      final tag = await Id3Tag.readFile(temp.path).catchError((_) => null);
      final tagTitle = _nonEmpty(tag?.text('TIT2')) ?? _nonEmpty(title);
      final tagArtist = _nonEmpty(tag?.text('TPE1')) ?? _nonEmpty(artist);
      return DownloadedMp3(
        file: temp,
        fileName: mp3FileName(
          url: url,
          contentDisposition: response.headers.value('content-disposition'),
          title: tagTitle,
          artist: tagArtist,
        ),
        title: tagTitle,
        artist: tagArtist,
      );
    } on Mp3LinkException {
      await _discard(sink, temp);
      rethrow;
    } on TimeoutException {
      await _discard(sink, temp);
      throw const Mp3LinkException(
          'El servidor dejó de responder. Probá de nuevo más tarde.');
    } catch (e) {
      await _discard(sink, temp);
      if (_cancelled) throw const Mp3LinkException('Descarga cancelada.');
      throw Mp3LinkException(
          'No se pudo conectar con ese enlace. Revisá que tengas internet y '
          'que el enlace sea correcto.\n($e)');
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  /// Guarda el MP3 descargado en la biblioteca y devuelve dónde quedó:
  /// en Android, en Música/TK Music; en desktop, en la subcarpeta
  /// "Descargas" de la carpeta de música elegida.
  Future<String> saveToLibrary(DownloadedMp3 mp3) async {
    try {
      return await sl<AudioImportRepository>().saveDownloadedSong(
        mp3.file.path,
        fileName: mp3.fileName,
        mimeType: 'audio/mpeg',
      );
    } on AppException catch (e) {
      throw Mp3LinkException('No se pudo guardar la canción: ${e.userMessage}');
    } finally {
      try {
        await mp3.file.delete();
      } catch (_) {}
    }
  }

  Future<void> _discard(IOSink? sink, File temp) async {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
  }

  void _checkHead(Uint8List head) {
    final problem = mp3Problem(head);
    if (problem != null) throw Mp3LinkException(problem);
  }

  static String _statusMessage(int status) => switch (status) {
        404 || 410 => 'Ese archivo no existe (el enlace está roto o lo '
            'borraron).',
        401 || 403 => 'El servidor no deja descargar ese archivo: es privado '
            'o el enlace venció.',
        429 => 'El servidor recibió demasiados pedidos. Probá en un rato.',
        _ => 'El servidor respondió con un error ($status).',
      };

  static String? _nonEmpty(String? v) =>
      v == null || v.trim().isEmpty ? null : v.trim();
}

/// El enlace listo para descargar: los de Google Drive y Dropbox se pasan a
/// su versión de descarga directa. `null` si no es un enlace web.
Uri? normalizeMp3Link(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host == 'drive.google.com') {
    final id = RegExp(r'/file/d/([\w-]+)').firstMatch(uri.path)?.group(1) ??
        uri.queryParameters['id'];
    if (id != null) {
      return Uri.https('drive.usercontent.google.com', '/download',
          {'id': id, 'export': 'download', 'confirm': 't'});
    }
  }
  if (host == 'dropbox.com' || host.endsWith('.dropbox.com')) {
    return uri.replace(queryParameters: {...uri.queryParameters, 'dl': '1'});
  }
  return uri;
}

/// Páginas de videos o música en streaming: no son archivos para descargar.
bool isStreamingPage(Uri uri) {
  final host = uri.host.toLowerCase();
  const sites = [
    'youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
    'spotify.com',
    'soundcloud.com',
    'deezer.com',
    'music.apple.com',
    'tidal.com',
    'tiktok.com',
    'instagram.com',
    'facebook.com',
    'vimeo.com',
  ];
  return sites.any((s) => host == s || host.endsWith('.$s'));
}

/// `null` si los primeros bytes son de un MP3; si no, qué es en realidad.
String? mp3Problem(Uint8List head) {
  bool startsWith(String text) =>
      head.length >= text.length &&
      String.fromCharCodes(head.sublist(0, text.length)) == text;

  if (startsWith('ID3')) return null;
  // Algunos MP3 traen unos bytes en cero antes del primer cuadro de audio.
  var start = 0;
  while (start < head.length && start < 1024 && head[start] == 0) {
    start++;
  }
  final b = Uint8List.sublistView(head, start);
  if (b.length >= 3 &&
      b[0] == 0xFF &&
      b[1] & 0xE0 == 0xE0 &&
      (b[1] >> 1) & 0x3 == 1 && // Layer III
      (b[2] >> 4) != 0xF) {
    return null;
  }

  final text = String.fromCharCodes(head.take(512)).trimLeft().toLowerCase();
  if (text.startsWith('<')) {
    return 'El enlace lleva a una página web, no a un archivo MP3. Buscá el '
        'enlace de descarga directa (el que baja el archivo al tocarlo).';
  }
  if (head.length >= 8 && String.fromCharCodes(head.sublist(4, 8)) == 'ftyp') {
    return 'Es un archivo M4A/MP4, no un MP3. Solo se aceptan MP3.';
  }
  if (startsWith('OggS')) {
    return 'Es un archivo OGG, no un MP3. Solo se aceptan MP3.';
  }
  if (startsWith('fLaC')) {
    return 'Es un archivo FLAC, no un MP3. Solo se aceptan MP3.';
  }
  if (startsWith('RIFF')) {
    return 'Es un archivo WAV, no un MP3. Solo se aceptan MP3.';
  }
  if (startsWith('PK')) {
    return 'Es un archivo comprimido (ZIP), no un MP3. Descomprimilo y '
        'agregá las canciones desde tu carpeta de música.';
  }
  return 'Ese archivo no es un MP3. Solo se aceptan MP3.';
}

/// Nombre con el que se guarda: "Artista - Título.mp3" si el MP3 trae esos
/// datos; si no, el nombre que manda el servidor o el del enlace.
String mp3FileName({
  required Uri url,
  String? contentDisposition,
  String? title,
  String? artist,
}) {
  String? name;
  if (title != null && title.isNotEmpty) {
    name = artist != null && artist.isNotEmpty ? '$artist - $title' : title;
  }
  name ??= _dispositionName(contentDisposition);
  if (name == null && url.pathSegments.isNotEmpty) {
    final last =
        url.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
    if (last.isNotEmpty && last != 'download') name = last;
  }
  name ??= 'Descarga ${DateTime.now().millisecondsSinceEpoch}';

  name = name
      .replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length > 120) name = name.substring(0, 120).trim();
  if (name.isEmpty || name.replaceAll('.', '').isEmpty) {
    name = 'Descarga ${DateTime.now().millisecondsSinceEpoch}';
  }
  return '$name.mp3';
}

String? _dispositionName(String? header) {
  if (header == null) return null;
  final encoded = RegExp(r"filename\*\s*=\s*(?:UTF-8|utf-8)?''([^;]+)")
      .firstMatch(header)
      ?.group(1);
  if (encoded != null) {
    try {
      return Uri.decodeComponent(encoded.trim());
    } catch (_) {}
  }
  final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?').firstMatch(header);
  return plain?.group(1)?.trim();
}
