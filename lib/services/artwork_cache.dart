import 'dart:io';

import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

import 'artwork_bytes.dart';
import 'tag_overrides_store.dart';

class ArtworkCache {
  ArtworkCache({OnAudioQuery? query}) : _query = query ?? OnAudioQuery();

  final OnAudioQuery _query;
  final Map<int, Uri?> _uris = {};
  Directory? _dir;

  /// Olvida lo resuelto para [songId] (se cambió su carátula).
  void forget(int songId) => _uris.remove(songId);

  Future<Uri?> uriFor(int songId) async {
    if (_uris.containsKey(songId)) return _uris[songId];

    // Carátula elegida en el editor de tags.
    final custom = TagOverridesStore.instance.coverFile(songId);
    if (custom != null) return _uris[songId] = Uri.file(custom.path);

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
        // Sin carátula en el teléfono: la de internet (si está activado).
        final image = bytes == null || bytes.isEmpty
            ? await ArtworkBytes.fromInternet(songId)
            : bytes;
        if (image == null || image.isEmpty) {
          _uris[songId] = null;
          return null;
        }
        await file.writeAsBytes(image);
      }

      final uri = Uri.file(file.path);
      _uris[songId] = uri;
      return uri;
    } catch (_) {
      _uris[songId] = null;
      return null;
    }
  }
}
