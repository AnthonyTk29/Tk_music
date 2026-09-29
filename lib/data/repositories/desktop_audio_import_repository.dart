import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:tk_music/core/errors/app_error_code.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/repositories/audio_import_repository.dart';
import 'package:tk_music/services/desktop_library_scanner.dart';

/// Desktop: copia el archivo a `Música\TK Music\<subcarpeta>` y lo suma a
/// la biblioteca al instante, sin pisar uno que ya exista con el mismo
/// nombre.
class DesktopAudioImportRepository implements AudioImportRepository {
  DesktopAudioImportRepository({String? musicFolder, this.onAdded})
      : _musicFolder = musicFolder;

  final String? _musicFolder;

  /// Qué hacer con lo copiado (por defecto, sumarlo a la biblioteca).
  final Future<void> Function(List<String> paths)? onAdded;

  /// Música\TK Music: donde la app guarda lo que agrega.
  static String get defaultMusicFolder {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return p.join(home, 'Music', 'TK Music');
  }

  String get musicFolder => _musicFolder ?? defaultMusicFolder;

  @override
  Future<String> importWhatsAppAudio(
    Song source, {
    required String fileName,
    required String mimeType,
  }) =>
      _copy(source.filePath, fileName, 'Audios de WhatsApp');

  @override
  Future<String> saveDownloadedSong(
    String path, {
    required String fileName,
    required String mimeType,
  }) =>
      _copy(path, fileName, 'Descargas');

  Future<String> _copy(
      String sourcePath, String fileName, String subfolder) async {
    try {
      final targetDir = Directory(p.join(musicFolder, subfolder));
      await targetDir.create(recursive: true);
      final base = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      var target = p.join(targetDir.path, fileName);
      for (var n = 2; await File(target).exists(); n++) {
        target = p.join(targetDir.path, '$base ($n)$ext');
      }
      await File(sourcePath).copy(target);
      await (onAdded ?? DesktopLibraryScanner.instance.addFiles)([target]);
      return target;
    } on FileSystemException catch (e) {
      throw AppException(
        AppErrorCode.storageImportFailed,
        userMessage: '$fileName — ${e.osError?.message ?? e.message}',
        technicalMessage: 'copy $sourcePath -> $subfolder: $e',
      );
    }
  }
}
