import 'dart:io';

import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

/// Extrae las carátulas de MediaStore y las guarda en disco.
///
/// La notificación de `audio_service` necesita un `artUri`, no bytes, así que
/// la imagen tiene que existir como archivo. Se cachea en memoria y en el
/// directorio temporal para no volver a consultarla en cada cambio de canción.
class ArtworkCache {
  ArtworkCache({OnAudioQuery? query}) : _query = query ?? OnAudioQuery();

  final OnAudioQuery _query;
  final Map<int, Uri?> _uris = {};
  Directory? _dir;

  /// Devuelve el `file://` de la carátula, o `null` si la canción no tiene.
  Future<Uri?> uriFor(int songId) async {
    if (_uris.containsKey(songId)) return _uris[songId];

    try {
      final dir = _dir ??= await getTemporaryDirectory();
      final file = File('${dir.path}/artwork_$songId.jpg');

      if (!await file.exists()) {
        final bytes = await _query.queryArtwork(
          songId,
          ArtworkType.AUDIO,
          format: ArtworkFormat.JPEG,
          size: 512,
        );
        if (bytes == null || bytes.isEmpty) {
          _uris[songId] = null;
          return null;
        }
        await file.writeAsBytes(bytes);
      }

      final uri = Uri.file(file.path);
      _uris[songId] = uri;
      return uri;
    } catch (_) {
      // Una carátula ilegible no debe romper la reproducción.
      _uris[songId] = null;
      return null;
    }
  }
}
