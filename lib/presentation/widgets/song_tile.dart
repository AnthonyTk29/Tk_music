import 'package:flutter/material.dart';

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/presentation/widgets/song_options_sheet.dart';

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.isCurrent,
    this.onTap,
  });

  final Song song;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: isCurrent ? theme.colorScheme.surfaceContainerHighest : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SongArtwork(songId: song.mediaStoreId, size: 52),
        ),
        title: Text(
          song.title,
          style: TextStyle(
            color: isCurrent ? theme.colorScheme.primary : null,
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          song.artist ?? 'Desconocido',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        selected: isCurrent,
        // Un IconButton propio consume el tap antes de que llegue al
        // ListTile: se puede abrir el menú sin disparar onTap (reproducir).
        trailing: isCurrent
            ? Icon(Icons.graphic_eq, color: theme.colorScheme.primary)
            : IconButton(
                icon: const Icon(Icons.more_vert),
                tooltip: 'Más opciones',
                onPressed: () => _showSongOptions(context),
              ),
        onTap: onTap,
      ),
    );
  }

  void _showSongOptions(BuildContext context) {
    showSongOptionsSheet(
      context,
      mediaStoreId: song.mediaStoreId,
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration,
      filePath: song.filePath,
      onPlay: onTap,
    );
  }
}
