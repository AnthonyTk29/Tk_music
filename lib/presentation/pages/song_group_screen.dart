import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/data/models/song_mapper.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/presentation/widgets/song_tile.dart';
import 'package:tk_music/services/audio_handler.dart';

/// Pantalla genérica para mostrar un grupo de canciones (un álbum o un
/// artista) con su propia portada y encabezado. Tocar una canción arma la
/// cola con las canciones de este grupo únicamente, en su orden — no la
/// biblioteca completa.
class SongGroupScreen extends StatefulWidget {
  const SongGroupScreen({
    super.key,
    required this.title,
    required this.songs,
    this.subtitle,
    this.icon = Icons.album,
  });

  final String title;
  final String? subtitle;
  final List<Song> songs;
  final IconData icon;

  @override
  State<SongGroupScreen> createState() => _SongGroupScreenState();
}

class _SongGroupScreenState extends State<SongGroupScreen> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.title;
    final subtitle = widget.subtitle;
    final songs = widget.songs;
    final icon = widget.icon;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AlphabetIndexedList(
        // El primer ítem es el encabezado (portada + título), no una
        // canción: una etiqueta vacía para que nunca matchee ninguna letra.
        labels: ['', ...songs.map((s) => s.title)],
        controller: _controller,
        listPadding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
        child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
        itemCount: songs.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: songs.isNotEmpty
                        ? SongArtwork(
                            songId: songs.first.mediaStoreId,
                            size: 80,
                            borderRadius: 10,
                          )
                        : Container(
                            width: 80,
                            height: 80,
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: theme.textTheme.titleLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        if (subtitle != null)
                          Text(subtitle,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        Text('${songs.length} canciones',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          final song = songs[index - 1];
          return SongTile(
            song: song,
            isCurrent: false,
            onTap: isAudioAvailable ? () => _play(context, index - 1) : null,
          );
        },
        ),
      ),
    );
  }

  Future<void> _play(BuildContext context, int index) async {
    final handler = sl<AudioHandler>() as MyAudioHandler;
    final items = widget.songs.map(SongMapper.toMediaItem).toList();
    await handler.setQueue(items, startIndex: index);
    await handler.play();
  }
}
