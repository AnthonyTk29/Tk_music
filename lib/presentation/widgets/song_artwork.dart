import 'package:flutter/material.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';

class SongArtwork extends StatelessWidget {
  const SongArtwork({
    super.key,
    required this.songId,
    this.size = 48,
    this.borderRadius = 24,
  });

  final int songId;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return QueryArtworkWidget(
      id: songId,
      type: ArtworkType.AUDIO,
      artworkBorder: BorderRadius.circular(borderRadius),
      artworkHeight: size,
      artworkWidth: size,
      nullArtworkWidget: Container(
        height: size,
        width: size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(borderRadius),
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
