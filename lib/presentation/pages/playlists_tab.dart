import 'package:flutter/material.dart';

import 'package:tk_music/domain/entities/playlist.dart';
import 'package:tk_music/presentation/pages/playlist_detail_screen.dart';
import 'package:tk_music/services/playlist_store.dart';

/// Pestaña "Playlists": crear, ver y entrar a cada playlist del perfil.
class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: PlaylistStore.instance,
        builder: (context, _) {
          return FutureBuilder<List<Playlist>>(
            future: PlaylistStore.instance.getAll(),
            builder: (context, snapshot) {
              final playlists = snapshot.data;
              if (playlists == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (playlists.isEmpty) {
                return _EmptyState(onCreate: () => _createPlaylist(context));
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.queue_music),
                    ),
                    title: Text(playlist.name),
                    subtitle: Text('${playlist.songIds.length} canciones'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createPlaylist(context),
        tooltip: 'Nueva playlist',
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
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
    if (name != null && name.isNotEmpty) {
      await PlaylistStore.instance.create(name);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Todavía no tienes playlists',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Crear playlist'),
            ),
          ],
        ),
      ),
    );
  }
}
