import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/services/media_item_mapper.dart';
import 'package:tk_music/domain/entities/playlist.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/services/queue_capable_handler.dart';
import 'package:tk_music/services/playlist_store.dart';

class PlaylistDetailScreen extends StatelessWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlaylistStore.instance,
      builder: (context, _) {
        return FutureBuilder<List<Playlist>>(
          future: PlaylistStore.instance.getAll(),
          builder: (context, snapshot) {
            final playlists = snapshot.data;
            Playlist? playlist;
            if (playlists != null) {
              for (final p in playlists) {
                if (p.id == playlistId) {
                  playlist = p;
                  break;
                }
              }
            }

            if (playlists == null) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (playlist == null) {
              // Se borró (p. ej. desde otra pantalla) mientras esta estaba abierta.
              return Scaffold(
                appBar: AppBar(title: const AppHeaderTitle()),
                body: const Center(child: Text('Esta lista ya no existe')),
              );
            }

            return _PlaylistDetailBody(playlist: playlist);
          },
        );
      },
    );
  }
}

class _PlaylistDetailBody extends StatelessWidget {
  const _PlaylistDetailBody({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final songProvider = AppProviders.songOf(context);
    final byId = {for (final s in songProvider.songs) s.mediaStoreId: s};
    final songs =
        playlist.songIds.map((id) => byId[id]).whereType<Song>().toList();

    return Scaffold(
      appBar: AppBar(
        title: AppHeaderTitle(section: playlist.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) => _handleMenu(context, value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Cambiar nombre')),
              PopupMenuItem(value: 'delete', child: Text('Eliminar lista')),
            ],
          ),
        ],
      ),
      body: songs.isEmpty
          ? const Center(
              child: Text(
                  'Agregá canciones desde el menú de tres puntos de cualquier canción'))
          : isAudioAvailable
              ? StreamBuilder<MediaItem?>(
                  stream: sl<AudioHandler>().mediaItem,
                  builder: (context, snapshot) =>
                      _buildList(context, songs, snapshot.data?.id),
                )
              : _buildList(context, songs, null),
    );
  }

  Widget _buildList(BuildContext context, List<Song> songs, String? currentId) {
    return _PlaylistSongList(
      playlist: playlist,
      songs: songs,
      currentId: currentId,
    );
  }

  void _handleMenu(BuildContext context, String value) async {
    switch (value) {
      case 'rename':
        final controller = TextEditingController(text: playlist.name);
        final name = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Cambiar nombre'),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                label: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(controller.text.trim()),
                icon: const Icon(Icons.check),
                label: const Text('Guardar'),
              ),
            ],
          ),
        );
        if (name != null && name.isNotEmpty) {
          await PlaylistStore.instance.rename(playlist.id, name);
        }
        break;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('¿Eliminar la lista?'),
            content: Text(
                'Se eliminará "${playlist.name}". Las canciones no se borran de tu dispositivo.'),
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close),
                label: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Eliminar'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await PlaylistStore.instance.delete(playlist.id);
          if (context.mounted) Navigator.of(context).pop();
        }
        break;
    }
  }
}

class _PlaylistSongList extends StatefulWidget {
  const _PlaylistSongList({
    required this.playlist,
    required this.songs,
    required this.currentId,
  });

  final Playlist playlist;
  final List<Song> songs;
  final String? currentId;

  @override
  State<_PlaylistSongList> createState() => _PlaylistSongListState();
}

class _PlaylistSongListState extends State<_PlaylistSongList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final songs = widget.songs;

    return AlphabetIndexedList(
      labels: songs.map((s) => s.title).toList(),
      controller: _controller,
      listPadding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      child: ReorderableListView.builder(
        scrollController: _controller,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
        itemCount: songs.length,
        onReorder: (oldIndex, newIndex) {
          if (newIndex > oldIndex) newIndex -= 1;
          PlaylistStore.instance.reorder(playlist.id, oldIndex, newIndex);
        },
        itemBuilder: (context, index) {
          final song = songs[index];
          final isCurrent = song.filePath == widget.currentId;
          return Dismissible(
            key: ValueKey(song.mediaStoreId),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.onErrorContainer),
            ),
            onDismissed: (_) => PlaylistStore.instance
                .removeSong(playlist.id, song.mediaStoreId),
            child: ListTile(
              tileColor: isCurrent
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : null,
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SongArtwork(songId: song.mediaStoreId, size: 48),
              ),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  color:
                      isCurrent ? Theme.of(context).colorScheme.primary : null,
                ),
              ),
              subtitle: Text(song.artist ?? 'Desconocido',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: isCurrent
                  ? Icon(Icons.graphic_eq,
                      color: Theme.of(context).colorScheme.primary)
                  : const Icon(Icons.drag_handle),
              onTap:
                  isAudioAvailable ? () => _play(context, songs, index) : null,
            ),
          );
        },
      ),
    );
  }

  Future<void> _play(BuildContext context, List<Song> songs, int index) async {
    // Reproducir desde una playlist reemplaza la cola por las canciones de
    // esa playlist (en su propio orden), no la biblioteca completa.
    final handler = sl<AudioHandler>();
    final items = songs.map(MediaItemMapper.fromSong).toList();
    await (handler as QueueCapableHandler).setQueue(items, startIndex: index);
    await handler.play();
  }
}
