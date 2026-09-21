import 'package:audio_service/audio_service.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/data/models/song_mapper.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';
import 'package:tk_music/services/audio_handler.dart';
import 'package:tk_music/services/external_storage_service.dart';

/// Reproduce [song] arrancando desde la biblioteca completa (no desde una
/// playlist ni un álbum/artista).
///
/// Reproducir desde una playlist o un álbum/artista reemplaza toda la cola
/// por esas pocas canciones (ver PlaylistDetailScreen y SongGroupScreen).
/// Si después de eso se usara `skipToQueueItem` con un índice calculado
/// sobre la biblioteca completa, apuntaría a la cola equivocada (más corta)
/// y no pasaría nada, o sonaría otra canción. Por eso Accesos directos,
/// Biblioteca, Buscar y Favoritos rearman la cola completa cada vez, en
/// vez de asumir que ya está cargada.
Future<void> playFromLibrary(SongProvider provider, Song song) async {
  if (!isAudioAvailable) return;
  final index = provider.songs.indexOf(song);
  if (index < 0) return;

  final handler = sl<AudioHandler>() as MyAudioHandler;
  final items = provider.songs.map(SongMapper.toMediaItem).toList();
  await handler.setQueue(items, startIndex: index);
  await handler.play();
}

/// Reproduce audios de un pendrive/almacenamiento externo. Cola separada de
/// la biblioteca del teléfono: estas canciones no tienen `mediaStoreId`, así
/// que no se pueden marcar como favoritas ni sumar a playlists (por ahora).
Future<void> playFromExternalFolder(
  List<ExternalEntry> audioFiles,
  int index,
) async {
  if (!isAudioAvailable) return;
  if (index < 0 || index >= audioFiles.length) return;

  final handler = sl<AudioHandler>() as MyAudioHandler;
  final items = audioFiles
      .map((entry) => MediaItem(
            id: entry.uri,
            title: _titleFrom(entry.name),
          ))
      .toList();
  await handler.setQueue(items, startIndex: index);
  await handler.play();
}

String _titleFrom(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}
