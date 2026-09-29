import 'package:flutter/services.dart';

import 'package:tk_music/core/errors/app_error_code.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/repositories/audio_import_repository.dart';

/// Android: copia por MediaStore a Música/TK Music/… (ver
/// `MainActivity.kt`, canal `tk_music/media_import`), así el sistema los
/// indexa como música normal.
class AndroidAudioImportRepository implements AudioImportRepository {
  static const _channel = MethodChannel('tk_music/media_import');

  @override
  Future<String> importWhatsAppAudio(
    Song source, {
    required String fileName,
    required String mimeType,
  }) =>
      _invoke(fileName, 'importWhatsAppAudio', {
        // Las notas de voz vienen de la carpeta de WhatsApp habilitada
        // (uri content://); los reenviados, de MediaStore (id).
        if (source.filePath.startsWith('content://'))
          'sourceUri': source.filePath
        else
          'mediaStoreId': source.mediaStoreId,
        'fileName': fileName,
        'mimeType': mimeType,
      });

  @override
  Future<String> saveDownloadedSong(
    String path, {
    required String fileName,
    required String mimeType,
  }) =>
      _invoke(fileName, 'importFileToMusic', {
        'path': path,
        'fileName': fileName,
        'mimeType': mimeType,
      });

  Future<String> _invoke(
      String fileName, String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<String>(method, args) ?? fileName;
    } on PlatformException catch (e) {
      throw AppException(
        AppErrorCode.storageImportFailed,
        userMessage: '$fileName — ${_describe(e)}',
        technicalMessage: '$method(${e.code}): ${e.message}',
      );
    }
  }

  static String _describe(PlatformException e) => switch (e.code) {
        'INSERT_FAILED' => 'No se pudo crear el archivo en Música',
        'SOURCE_NOT_FOUND' => 'No se encontró el audio original',
        'SOURCE_UNREADABLE' => 'Sin permiso para leer el audio original',
        'OUTPUT_FAILED' => 'No se pudo escribir en la carpeta Música',
        _ => e.message ?? e.code,
      };
}
