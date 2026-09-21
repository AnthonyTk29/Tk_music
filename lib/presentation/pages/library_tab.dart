import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/entities/sort_option.dart';
import 'package:tk_music/presentation/models/library_groups.dart';
import 'package:tk_music/presentation/pages/song_group_screen.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';
import 'package:tk_music/presentation/utils/playback_actions.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/presentation/widgets/song_tile.dart';

enum _ViewMode { songs, albums, artists }

/// Pestaña "Biblioteca": lista completa, o agrupada por álbum/artista.
/// El orden y el filtro de género solo aplican a la vista de canciones; no
/// se ve afectada por la búsqueda (eso vive en su propia pestaña).
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  _ViewMode _mode = _ViewMode.songs;

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
            FilledButton.icon(
              onPressed: provider.loadSongs,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (provider.songs.isEmpty) {
      return const Center(child: Text('No se encontraron canciones'));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedButton<_ViewMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _ViewMode.songs, label: Text('Canciones')),
              ButtonSegment(value: _ViewMode.albums, label: Text('Álbumes')),
              ButtonSegment(value: _ViewMode.artists, label: Text('Artistas')),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) =>
                setState(() => _mode = selection.first),
          ),
        ),
        Expanded(
          child: switch (_mode) {
            _ViewMode.songs => _SongsView(provider: provider),
            _ViewMode.albums => _AlbumsGrid(songs: provider.songs),
            _ViewMode.artists => _ArtistsList(songs: provider.songs),
          },
        ),
      ],
    );
  }
}

class _SongsView extends StatelessWidget {
  const _SongsView({required this.provider});

  final SongProvider provider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Toolbar(provider: provider),
        Expanded(
          child: isAudioAvailable
              ? StreamBuilder<MediaItem?>(
                  stream: sl<AudioHandler>().mediaItem,
                  builder: (context, snapshot) =>
                      _SongListView(provider: provider, currentId: snapshot.data?.id),
                )
              : _SongListView(provider: provider, currentId: null),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.provider});

  final SongProvider provider;

  @override
  Widget build(BuildContext context) {
    final genres = provider.availableGenres;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Text('${provider.sortedLibrary.length} canciones',
                  style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              PopupMenuButton<SortOption>(
                tooltip: 'Ordenar',
                icon: const Icon(Icons.sort),
                initialValue: provider.sort,
                onSelected: provider.updateSort,
                itemBuilder: (context) => SortOption.values
                    .map((o) => PopupMenuItem(value: o, child: Text(o.label)))
                    .toList(),
              ),
            ],
          ),
        ),
        // Chips de género real (etiqueta ID3); si ningún archivo trae
        // género, la lista viene vacía y no se muestra nada.
        if (genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: const Text('Todas'),
                      selected: provider.genreFilter == null,
                      onSelected: (_) => provider.updateGenreFilter(null),
                    ),
                  ),
                  for (final genre in genres)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(genre),
                        selected: provider.genreFilter == genre,
                        onSelected: (_) => provider.updateGenreFilter(genre),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SongListView extends StatefulWidget {
  const _SongListView({required this.provider, required this.currentId});

  final SongProvider provider;
  final String? currentId;

  @override
  State<_SongListView> createState() => _SongListViewState();
}

class _SongListViewState extends State<_SongListView> {
  // Vive acá (no en el build de un StatelessWidget) para no perder la
  // posición del scroll cada vez que este widget se reconstruye (pasa
  // seguido: cada canción que arranca a sonar dispara un rebuild).
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.provider.sortedLibrary;

    if (songs.isEmpty) {
      return const Center(child: Text('Sin resultados para este filtro'));
    }

    return AlphabetIndexedList(
      labels: songs.map((s) => s.title).toList(),
      controller: _controller,
      listPadding: const EdgeInsets.fromLTRB(8, 0, 8, 116),
      child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 116),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          return SongTile(
            song: song,
            isCurrent: song.filePath == widget.currentId,
            onTap: isAudioAvailable
                ? () => playFromLibrary(widget.provider, song)
                : null,
          );
        },
      ),
    );
  }
}

class _AlbumsGrid extends StatelessWidget {
  const _AlbumsGrid({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final albums = groupByAlbum(songs);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 116),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SongGroupScreen(
                title: album.name,
                subtitle: album.artist,
                songs: album.songs,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SongArtwork(
                    songId: album.songs.first.mediaStoreId,
                    size: 200,
                    borderRadius: 0,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              if (album.artist != null)
                Text(album.artist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        );
      },
    );
  }
}

class _ArtistsList extends StatelessWidget {
  const _ArtistsList({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final artists = groupByArtist(songs);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.person),
          ),
          title: Text(artist.name),
          subtitle: Text('${artist.songs.length} canciones'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SongGroupScreen(
                title: artist.name,
                icon: Icons.person,
                songs: artist.songs,
              ),
            ),
          ),
        );
      },
    );
  }
}
