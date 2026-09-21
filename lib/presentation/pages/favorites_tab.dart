import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';
import 'package:tk_music/presentation/utils/playback_actions.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/song_tile.dart';
import 'package:tk_music/services/favorites_store.dart';

/// Pestaña "Favoritos": canciones marcadas con el botón de "me gusta" (desde
/// la notificación o desde acá). Se actualiza en vivo porque FavoritesStore
/// es un ChangeNotifier singleton compartido con el audio handler.
class FavoritesTab extends StatelessWidget {
  const FavoritesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final songProvider = AppProviders.songOf(context);

    return AnimatedBuilder(
      animation: FavoritesStore.instance,
      builder: (context, _) {
        return FutureBuilder<Set<int>>(
          future: FavoritesStore.instance.getAll(),
          builder: (context, snapshot) {
            final likedIds = snapshot.data;
            if (likedIds == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (likedIds.isEmpty) {
              return _EmptyState(theme: Theme.of(context));
            }

            final favorites = songProvider.songs
                .where((s) => likedIds.contains(s.mediaStoreId))
                .toList();

            if (favorites.isEmpty) {
              return _EmptyState(theme: Theme.of(context));
            }

            if (!isAudioAvailable) {
              return _buildList(context, songProvider, favorites, null);
            }

            return StreamBuilder<MediaItem?>(
              stream: sl<AudioHandler>().mediaItem,
              builder: (context, mediaSnapshot) => _buildList(
                  context, songProvider, favorites, mediaSnapshot.data?.id),
            );
          },
        );
      },
    );
  }

  Widget _buildList(BuildContext context, SongProvider songProvider,
      List<Song> favorites, String? currentId) {
    return _FavoritesListView(
      songProvider: songProvider,
      favorites: favorites,
      currentId: currentId,
    );
  }
}

class _FavoritesListView extends StatefulWidget {
  const _FavoritesListView({
    required this.songProvider,
    required this.favorites,
    required this.currentId,
  });

  final SongProvider songProvider;
  final List<Song> favorites;
  final String? currentId;

  @override
  State<_FavoritesListView> createState() => _FavoritesListViewState();
}

class _FavoritesListViewState extends State<_FavoritesListView> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlphabetIndexedList(
      labels: widget.favorites.map((s) => s.title).toList(),
      controller: _controller,
      listPadding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
        itemCount: widget.favorites.length,
        itemBuilder: (context, index) {
          final song = widget.favorites[index];
          return SongTile(
            song: song,
            isCurrent: song.filePath == widget.currentId,
            onTap: isAudioAvailable
                ? () => playFromLibrary(widget.songProvider, song)
                : null,
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.thumb_up_outlined,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Todavía no marcaste ninguna canción con "me gusta"',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
