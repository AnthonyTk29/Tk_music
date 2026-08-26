import 'package:flutter/material.dart';

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';

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
    return ListTile(
      leading: SongArtwork(songId: song.mediaStoreId),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        song.artist ?? 'Desconocido',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: isCurrent,
      trailing: isCurrent
          ? const Icon(Icons.equalizer, color: Colors.blueAccent)
          : null,
      onTap: onTap,
    );
  }
}
