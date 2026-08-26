import 'package:audio_service/audio_service.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';

import 'package:tk_music/domain/entities/song.dart';

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
      );

  static MediaItem toMediaItem(Song song) => MediaItem(
        id: song.filePath,
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
        extras: {'songId': song.mediaStoreId},
      );
}
