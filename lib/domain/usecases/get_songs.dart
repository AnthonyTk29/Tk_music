import 'package:tk_music/domain/failures/failures.dart';

import '../entities/song.dart';
import '../repositories/song_repository.dart';

class GetSongs {
  const GetSongs(this._repository);
  final SongRepository _repository;

  Future<(List<Song>?, Failure?)> call() async {
    try {
      final songs = await _repository.getSongs();
      return (songs, null);
    } catch (e) {
      return (<Song>[], SongQueryFailure(e.toString()));
    }
  }
}
