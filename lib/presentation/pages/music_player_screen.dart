import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/mini_player.dart';
import 'package:tk_music/presentation/widgets/song_tile.dart';

class MusicPlayerScreen extends StatelessWidget {
  const MusicPlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reproductor Android'),
        actions: [
          if (isAudioAvailable)
            StreamBuilder<PlaybackState>(
              stream: sl<AudioHandler>().playbackState,
              builder: (context, snapshot) {
                final shuffle = snapshot.data?.shuffleMode ==
                    AudioServiceShuffleMode.all;
                return IconButton(
                  tooltip: 'Shuffle',
                  onPressed: () => sl<AudioHandler>().setShuffleMode(shuffle
                      ? AudioServiceShuffleMode.none
                      : AudioServiceShuffleMode.all),
                  icon: Icon(Icons.shuffle,
                      color: shuffle
                          ? Theme.of(context).colorScheme.primary
                          : null),
                );
              },
            ),
        ],
      ),
      body: Column(
        children: [
          _SearchBar(),
          Expanded(child: _SongList()),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = AppProviders.songOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        decoration: const InputDecoration(
          hintText: 'Buscar canción, artista o álbum',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        onChanged: provider.updateSearch,
      ),
    );
  }
}

class _SongList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = AppProviders.songOf(context);

    if (provider.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (provider.failure != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(provider.failure!.message),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: provider.loadSongs,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (provider.songs.isEmpty) {
      return const Center(child: Text('No se encontraron canciones'));
    }

    if (!isAudioAvailable) {
      return _buildSongList(context, provider, null);
    }

    return StreamBuilder<MediaItem?>(
      stream: sl<AudioHandler>().mediaItem,
      builder: (context, snapshot) {
        return _buildSongList(context, provider, snapshot.data?.id);
      },
    );
  }

  Widget _buildSongList(
      BuildContext context, dynamic provider, String? currentId) {
    final visibleSongs = provider.visibleSongs;

    if (visibleSongs.isEmpty) {
      return const Center(child: Text('Sin resultados'));
    }

    return ListView.builder(
      itemCount: visibleSongs.length,
      itemBuilder: (context, index) {
        final song = visibleSongs[index];
        return SongTile(
          song: song,
          isCurrent: song.filePath == currentId,
          onTap: isAudioAvailable
              ? () async {
                  final audioHandler = sl<AudioHandler>();
                  final globalIndex = provider.songs.indexOf(song);
                  await audioHandler.skipToQueueItem(globalIndex);
                  await audioHandler.play();
                }
              : null,
        );
      },
    );
  }
}
