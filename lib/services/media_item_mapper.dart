import 'package:audio_service/audio_service.dart';

import 'package:tk_music/domain/entities/song.dart';

/// Pasa una canción del dominio al formato del reproductor (audio_service):
/// es lo que se pone en la cola y lo que muestran la notificación y los
/// controles del sistema.
class MediaItemMapper {
  const MediaItemMapper._();

  static MediaItem fromSong(Song song) => MediaItem(
        id: song.filePath,
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
        extras: {'songId': song.mediaStoreId},
      );
}
