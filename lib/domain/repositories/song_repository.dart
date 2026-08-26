import '../entities/song.dart';

abstract class SongRepository {
  Future<List<Song>> getSongs();
  Future<bool> requestPermission();
  Future<bool> get hasPermission;
}
