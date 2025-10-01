import 'package:on_audio_query/on_audio_query.dart';

class MusicScanner {
  final OnAudioQuery _audioQuery = OnAudioQuery();

  Future<List<SongModel>> getAllMp3() async {
    // Pedir permisos
    bool permissionStatus = await _audioQuery.permissionsStatus();
    if (!permissionStatus) {
      permissionStatus = await _audioQuery.permissionsRequest();
      if (!permissionStatus) return [];
    }

    // Obtener todos los archivos de música
    List<SongModel> songs = await _audioQuery.querySongs(
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
      ignoreCase: true,
    );

    // Filtrar solo MP3
    songs = songs
        .where((song) => song.fileExtension.toLowerCase() == "mp3")
        .toList();
    return songs;
  }
}
