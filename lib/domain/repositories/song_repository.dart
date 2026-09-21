import '../entities/song.dart';

abstract class SongRepository {
  Future<List<Song>> getSongs();
  Future<List<Song>> getWhatsAppAudios();
  Future<bool> requestPermission();
  Future<bool> get hasPermission;
}
