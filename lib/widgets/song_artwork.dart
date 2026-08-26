import 'package:flutter/material.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';

/// Carátula de una canción de MediaStore, con un marcador de posición
/// cuando el archivo no tiene imagen embebida.
class SongArtwork extends StatelessWidget {
  const SongArtwork({
    super.key,
    required this.songId,
    this.size = 56,
    this.borderRadius = 8,
  });

  final int songId;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return QueryArtworkWidget(
      id: songId,
      type: ArtworkType.AUDIO,
      artworkWidth: size,
      artworkHeight: size,
      artworkBorder: radius,
      artworkFit: BoxFit.cover,
      quality: 100,
      size: size > 200 ? 512 : 200,
      keepOldArtwork: true,
      nullArtworkWidget: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Icon(
          Icons.music_note,
          size: size * 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
