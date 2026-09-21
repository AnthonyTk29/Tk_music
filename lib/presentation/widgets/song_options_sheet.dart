import 'package:flutter/material.dart';

import 'package:tk_music/core/utils/formatters.dart';
import 'package:tk_music/domain/entities/playlist.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/services/favorites_store.dart';
import 'package:tk_music/services/playlist_store.dart';

/// Menú "más opciones" de una canción (me gusta, agregar a playlist, ver
/// detalles) — compartido entre [SongTile] (biblioteca/listas) y la
/// pantalla "Reproduciendo" (la canción actual), para que sea exactamente
/// el mismo menú en los dos lugares en vez de mantener dos copias.
/// [onPlay] es opcional: en "Reproduciendo" no tiene sentido ofrecer
/// reproducir la canción que ya está sonando.
void showSongOptionsSheet(
  BuildContext context, {
  required int mediaStoreId,
  required String title,
  String? artist,
  String? album,
  Duration? duration,
  required String filePath,
  VoidCallback? onPlay,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onPlay != null)
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Reproducir'),
              onTap: () {
                Navigator.of(context).pop();
                onPlay();
              },
            ),
          FutureBuilder<bool>(
            future: FavoritesStore.instance.isLiked(mediaStoreId),
            builder: (context, snapshot) {
              final liked = snapshot.data ?? false;
              return ListTile(
                leading:
                    Icon(liked ? Icons.thumb_up : Icons.thumb_up_outlined),
                title: Text(liked ? 'Quitar de favoritos' : 'Me gusta'),
                onTap: () {
                  Navigator.of(context).pop();
                  FavoritesStore.instance.toggle(mediaStoreId);
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Agregar a playlist'),
            onTap: () {
              Navigator.of(context).pop();
              _showAddToPlaylist(context, mediaStoreId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Ver detalles'),
            onTap: () {
              Navigator.of(context).pop();
              _showSongDetails(
                context,
                mediaStoreId: mediaStoreId,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                filePath: filePath,
              );
            },
          ),
        ],
      ),
    ),
  );
}

void _showAddToPlaylist(BuildContext context, int mediaStoreId) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: FutureBuilder<List<Playlist>>(
        future: PlaylistStore.instance.getAll(),
        builder: (context, snapshot) {
          final playlists = snapshot.data;
          if (playlists == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text('Agregar a playlist',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (playlists.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('Todavía no tienes playlists'),
                ),
              for (final playlist in playlists)
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(playlist.name),
                  trailing: playlist.songIds.contains(mediaStoreId)
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    PlaylistStore.instance.addSong(playlist.id, mediaStoreId);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Nueva playlist'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final name = await _promptPlaylistName(context);
                  if (name == null || name.isEmpty) return;
                  final playlist = await PlaylistStore.instance.create(name);
                  await PlaylistStore.instance.addSong(playlist.id, mediaStoreId);
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}

Future<String?> _promptPlaylistName(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Nueva playlist'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Nombre'),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
          label: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          icon: const Icon(Icons.add),
          label: const Text('Crear'),
        ),
      ],
    ),
  );
}

void _showSongDetails(
  BuildContext context, {
  required int mediaStoreId,
  required String title,
  String? artist,
  String? album,
  Duration? duration,
  required String filePath,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SongArtwork(songId: mediaStoreId, size: 64),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: theme.textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          artist ?? 'Desconocido',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _DetailRow(label: 'Álbum', value: album ?? 'Desconocido'),
              _DetailRow(
                label: 'Duración',
                value: duration != null ? formatDuration(duration) : 'Desconocida',
              ),
              _DetailRow(label: 'Archivo', value: filePath),
            ],
          ),
        ),
      );
    },
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
