import 'dart:io';

import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

class ArtworkCache {
  ArtworkCache({OnAudioQuery? query}) : _query = query ?? OnAudioQuery();

  final OnAudioQuery _query;
  final Map<int, Uri?> _uris = {};
  Directory? _dir;

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
      _uris[songId] = null;
      return null;
    }
  }
}
