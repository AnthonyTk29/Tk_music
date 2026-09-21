import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/pages/now_playing_screen.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isAudioAvailable) return const SizedBox.shrink();

    final audioHandler = sl<AudioHandler>();

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) return const SizedBox.shrink();

        final songId = item.extras?['songId'] as int?;
        final theme = Theme.of(context);

        return Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16)],
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<Duration>(
                  stream: AudioService.position,
                  builder: (context, posSnapshot) {
                    final total = item.duration?.inMilliseconds ?? 0;
                    final pos = posSnapshot.data?.inMilliseconds ?? 0;
                    return LinearProgressIndicator(
                      value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0,
                      minHeight: 2,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  child: Row(
                    children: [
                      if (songId != null)
                        SongArtwork(
                            songId: songId, size: 48, borderRadius: 8),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              item.artist ?? 'Desconocido',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      StreamBuilder<PlaybackState>(
                        stream: audioHandler.playbackState,
                        builder: (context, stateSnapshot) {
                          final playing =
                              stateSnapshot.data?.playing ?? false;
                          return Row(
                            children: [
                              IconButton(
                                onPressed: playing
                                    ? audioHandler.pause
                                    : audioHandler.play,
                                icon: Icon(playing
                                    ? Icons.pause
                                    : Icons.play_arrow),
                              ),
                              IconButton(
                                onPressed: audioHandler.skipToNext,
                                icon: const Icon(Icons.skip_next),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
