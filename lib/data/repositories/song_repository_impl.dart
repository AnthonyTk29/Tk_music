import 'package:tk_music/data/datasources/song_local_datasource.dart';
import 'package:tk_music/data/models/song_mapper.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/repositories/song_repository.dart';

class SongRepositoryImpl implements SongRepository {
  SongRepositoryImpl({SongLocalDatasource? datasource})
      : _datasource = datasource ?? SongLocalDatasource();

  final SongLocalDatasource _datasource;

  @override
  Future<List<Song>> getSongs() async {
    final models = await _datasource.fetchSongs();
    return models.map(SongMapper.fromMediaStore).toList();
  }

  @override
  Future<List<Song>> getWhatsAppAudios() async {
    final models = await _datasource.fetchWhatsAppAudios();
    return models.map(SongMapper.fromMediaStore).toList();
  }

  @override
  Future<bool> requestPermission() => _datasource.requestPermission();

  @override
  Future<bool> get hasPermission => _datasource.hasPermission;
}
