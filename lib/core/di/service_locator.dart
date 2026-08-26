import 'package:get_it/get_it.dart';
import 'package:audio_service/audio_service.dart';

import 'package:tk_music/data/datasources/song_local_datasource.dart';
import 'package:tk_music/data/repositories/song_repository_impl.dart';
import 'package:tk_music/domain/repositories/song_repository.dart';
import 'package:tk_music/domain/usecases/get_songs.dart';
import 'package:tk_music/domain/usecases/request_permission.dart';

final sl = GetIt.instance;

Future<void> initServiceLocator(AudioHandler handler) async {
  sl.registerLazySingleton(SongLocalDatasource.new);
  sl.registerLazySingleton<SongRepository>(() => SongRepositoryImpl());
  sl.registerLazySingleton(() => GetSongs(sl()));
  sl.registerLazySingleton(() => RequestPermission(sl()));
  sl.registerLazySingleton<AudioHandler>(() => handler);
}
