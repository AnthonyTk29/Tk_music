import 'package:on_audio_query_forked/on_audio_query.dart';

import 'package:tk_music/domain/entities/song.dart';

/// Pasa una canción de MediaStore (on_audio_query) a la del dominio.
class SongMapper {
  const SongMapper._();

  static Song fromMediaStore(SongModel model) => Song(
        mediaStoreId: model.id,
        title: model.title,
        filePath: model.data,
        artist: model.artist,
        album: model.album,
        duration: model.duration != null
            ? Duration(milliseconds: model.duration!)
            : null,
        // MediaStore.DATE_ADDED viene en segundos, no milisegundos (a
        // diferencia de la mayoría de los otros campos de fecha de Android).
        dateAdded: model.dateAdded != null
            ? DateTime.fromMillisecondsSinceEpoch(model.dateAdded! * 1000)
            : null,
        genre:
            (model.genre?.trim().isEmpty ?? true) ? null : model.genre!.trim(),
      );
}
