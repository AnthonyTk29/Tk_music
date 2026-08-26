import 'package:on_audio_query_forked/on_audio_query.dart';

import 'package:tk_music/domain/entities/song.dart';

class SongMapper {
  const SongMapper._();

  static Song fromMediaStore(SongModel model, int index) => Song(
        id: index,
        mediaStoreId: model.id,
        title: model.title,
        filePath: model.data,
        artist: model.artist,
        album: model.album,
        duration: model.duration != null
            ? Duration(milliseconds: model.duration!)
            : null,
      );
}
