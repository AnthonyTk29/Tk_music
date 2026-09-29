import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/entities/song_id.dart';
import 'package:tk_music/domain/repositories/song_repository.dart';
import 'package:tk_music/services/desktop_library_scanner.dart';
import 'package:tk_music/services/desktop_media_service.dart';
import 'package:tk_music/services/dj/music_files.dart'
    show libraryAudioExtensions;

/// Repositorio de canciones para desktop: no hay MediaStore acá (eso es un
/// concepto de Android), así que la biblioteca son **todas las canciones de
/// todos los discos** de la PC ([DesktopLibraryScanner]: el primer escaneo
/// se espera, después abre al instante con lo guardado y se revisa sola en
/// segundo plano). El id de cada canción es el hash de su ruta — alcanza
/// para que favoritos/recientes/playlists (que guardan un int) funcionen
/// igual que en Android.
///
/// No hay permiso que pedir en desktop: [hasPermission] es siempre true.
class DesktopSongRepositoryImpl implements SongRepository {
  /// Más cortos que esto no son canciones (efectos de sonido, avisos,
  /// notas de voz muy cortas).
  static const minSongDuration = Duration(seconds: 15);

  @override
  Future<List<Song>> getSongs() async {
    final files = await DesktopLibraryScanner.instance.files();

    // Título/artista/álbum/duración/género de los tags del archivo (lo
    // mismo que muestra el Explorador de Windows); si no tiene, el nombre
    // de archivo como título.
    final entries = [for (final f in files) (f.path, f.modified)];
    final tags = await DesktopMediaService.instance.tagsFor(entries);
    final songs = <Song>[];
    final seen = <int>{};
    for (var i = 0; i < entries.length; i++) {
      final (path, modified) = entries[i];
      final tag = tags[i];
      final durationMs = tag?.durationMs;
      if (durationMs != null && durationMs < minSongDuration.inMilliseconds) {
        continue;
      }
      final id = stableSongId(path);
      if (!seen.add(id)) continue;
      songs.add(Song(
        mediaStoreId: id,
        title: _nonEmpty(tag?.title) ?? p.basenameWithoutExtension(path),
        filePath: path,
        artist: _nonEmpty(tag?.artist),
        album: _nonEmpty(tag?.album),
        genre: _nonEmpty(tag?.genre),
        duration:
            durationMs == null ? null : Duration(milliseconds: durationMs),
        dateAdded: modified,
      ));
    }
    songs
        .sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return songs;
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  /// Audios recibidos por WhatsApp en la PC: los que guarda WhatsApp
  /// Desktop (app de la Microsoft Store) y los que se descargan desde
  /// WhatsApp Web a la carpeta Descargas ("WhatsApp Audio …", "WhatsApp
  /// Ptt …", "AUD-…-WA…").
  @override
  Future<List<Song>> getWhatsAppAudios() async {
    final found = <String, DateTime>{};

    Future<void> scan(String? dirPath,
        {required bool recursive, required bool onlyWhatsAppNames}) async {
      if (dirPath == null) return;
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      try {
        await for (final entity
            in dir.list(recursive: recursive, followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          final ext = p.extension(name).toLowerCase();
          final whatsAppName = _whatsAppFileName.hasMatch(name);
          final isAudio = libraryAudioExtensions.contains(ext) ||
              // WhatsApp Web a veces baja los audios como .mp4 (solo audio).
              (ext == '.mp4' &&
                  name.toLowerCase().startsWith('whatsapp audio'));
          if (!isAudio || (onlyWhatsAppNames && !whatsAppName)) continue;
          found[entity.path] = (await entity.stat()).modified;
        }
      } on FileSystemException {
        // Carpeta sin permiso de lectura: se sigue con lo que se pudo leer.
      }
    }

    final env = Platform.environment;
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null) {
      await scan(
        p.join(
            localAppData,
            'Packages',
            '5319275A.WhatsAppDesktop_cv1g1gvanyjgm',
            'LocalState',
            'shared',
            'transfers'),
        recursive: true,
        onlyWhatsAppNames: false,
      );
    }
    final home = env['USERPROFILE'] ?? env['HOME'];
    if (home != null) {
      await scan(p.join(home, 'Downloads'),
          recursive: false, onlyWhatsAppNames: true);
    }

    final songs = [
      for (final entry in found.entries)
        Song(
          mediaStoreId: stableSongId(entry.key),
          title: p.basenameWithoutExtension(entry.key),
          filePath: entry.key,
          dateAdded: entry.value,
        ),
    ];
    // Los más recientes primero, como en la pantalla de Android.
    songs.sort((a, b) => b.dateAdded!.compareTo(a.dateAdded!));
    return songs;
  }

  static final _whatsAppFileName =
      RegExp(r'^(WhatsApp (Audio|Ptt)|AUD-\d{8}-WA\d+)', caseSensitive: false);

  // En desktop no hay permiso que pedir: se leen todos los discos.
  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> get hasPermission async => true;
}
