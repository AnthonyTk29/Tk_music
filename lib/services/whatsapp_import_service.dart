import 'package:flutter/services.dart';

import 'package:tk_music/domain/entities/song.dart';

/// Patrón de nombre que usa WhatsApp para notas de voz y audios reenviados
/// (AUD-20260127-WA0014.mp3). Se reutiliza acá para poder "limpiar" el
/// nombre al importar: si se copiara tal cual, [SongLocalDatasource] lo
/// volvería a excluir de la biblioteca por matchear el mismo patrón, aunque
/// ya no esté dentro de la carpeta de WhatsApp.
final _whatsappAudioPattern = RegExp(r'AUD-\d{8}-WA\d+', caseSensitive: false);

const _mimeByExtension = {
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'opus': 'audio/opus',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
};

/// Copia un audio recibido por WhatsApp a la carpeta Download del teléfono
/// para que MediaStore (y con eso, la biblioteca de la app) lo indexe como
/// una canción normal. No mueve el original: WhatsApp podría necesitarlo, y
/// borrar archivos de otra app requiere permisos que no vale la pena pedir
/// para esto.
class WhatsAppImportService {
  static const _channel = MethodChannel('tk_music/media_import');

  Future<void> importToDownloads(Song song) async {
    final extension = _extensionOf(song.filePath);
    final fileName = _cleanFileName(song.title, extension);
    final mimeType = _mimeByExtension[extension] ?? 'audio/*';

    await _channel.invokeMethod('importToDownloads', {
      'mediaStoreId': song.mediaStoreId,
      'fileName': fileName,
      'mimeType': mimeType,
    });
  }

  String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? 'mp3' : path.substring(dot + 1).toLowerCase();
  }

  String _cleanFileName(String title, String extension) {
    var name = title.replaceAll(_whatsappAudioPattern, '').trim();
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (name.isEmpty) {
      name = 'Audio importado ${DateTime.now().millisecondsSinceEpoch}';
    }
    return '$name.$extension';
  }
}
