import '../entities/song.dart';

/// Suma audios a la biblioteca copiándolos a la carpeta de música de la
/// app (Música/TK Music/…). Cada plataforma lo hace a su manera: Android por
/// MediaStore (para que el sistema los indexe), desktop copiando el archivo.
/// Nunca toca el original.
///
/// Si algo falla tira `AppException` con un mensaje para mostrar.
abstract class AudioImportRepository {
  /// Dónde quedan los audios importados de WhatsApp (para mostrarlo).
  static const whatsAppFolderLabel = 'Música/TK Music/Audios de WhatsApp';

  /// Copia un audio recibido por WhatsApp ([source]: por su ruta, su uri
  /// content:// o su id de MediaStore) con el nombre [fileName]. Devuelve
  /// dónde quedó.
  Future<String> importWhatsAppAudio(
    Song source, {
    required String fileName,
    required String mimeType,
  });

  /// Guarda un archivo ya descargado ([path], p. ej. un MP3 bajado de un
  /// enlace) en la biblioteca con el nombre [fileName]. Devuelve dónde
  /// quedó.
  Future<String> saveDownloadedSong(
    String path, {
    required String fileName,
    required String mimeType,
  });
}
