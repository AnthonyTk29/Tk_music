import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';
import 'package:tk_music/presentation/utils/playback_actions.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/song_tile.dart';

/// Pestaña "Buscar": campo de búsqueda propio + resultados, separado de la
/// biblioteca completa para no mezclar ambas vistas.
class SearchTab extends StatelessWidget {
  const SearchTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = AppProviders.songOf(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            autofocus: false,
            decoration: const InputDecoration(
              hintText: 'Buscar en tu música',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: provider.updateSearch,
          ),
        ),
        Expanded(child: _Results()),
      ],
    );
  }
}

class _Results extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final provider = AppProviders.songOf(context);
    final theme = Theme.of(context);

    if (provider.search.isEmpty) {
      return Center(
        child: Text(
          'Escribe para buscar canciones, artistas o álbumes',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      );
    }

    final results = provider.visibleSongs;
    if (results.isEmpty) {
      return const Center(child: Text('Sin resultados'));
    }

    if (!isAudioAvailable) {
      return _buildList(context, provider, results, null);
    }

    return StreamBuilder<MediaItem?>(
      stream: sl<AudioHandler>().mediaItem,
      builder: (context, snapshot) =>
          _buildList(context, provider, results, snapshot.data?.id),
    );
  }

  Widget _buildList(BuildContext context, SongProvider provider,
      List<Song> results, String? currentId) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 116),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final song = results[index];
        return SongTile(
          song: song,
          isCurrent: song.filePath == currentId,
          onTap: isAudioAvailable
              ? () => playFromLibrary(provider, song)
              : null,
        );
      },
    );
  }
}
