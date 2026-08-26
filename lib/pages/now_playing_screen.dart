import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:tk_music/main.dart' show audioHandler;
import 'package:tk_music/widgets/seek_bar.dart';
import 'package:tk_music/widgets/song_artwork.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reproduciendo'),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, snapshot) {
          final item = snapshot.data;
          if (item == null) {
            return const Center(child: Text('Nada en reproducción'));
          }
          final songId = item.extras?['songId'] as int?;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(),
                  if (songId != null)
                    SongArtwork(songId: songId, size: 280, borderRadius: 16),
                  const SizedBox(height: 40),
                  Text(
                    item.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.artist ?? 'Desconocido',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  StreamBuilder<Duration>(
                    stream: AudioService.position,
                    builder: (context, posSnapshot) => SeekBar(
                      duration: item.duration ?? Duration.zero,
                      position: posSnapshot.data ?? Duration.zero,
                      onChangeEnd: audioHandler.seek,
                    ),
                  ),
                  const SizedBox(height: 8),
                  StreamBuilder<PlaybackState>(
                    stream: audioHandler.playbackState,
                   builder: (context, stateSnapshot) {
                      final playing = stateSnapshot.data?.playing ?? false;
                      final repeat = stateSnapshot.data?.repeatMode ??
                          AudioServiceRepeatMode.none;
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Repetición',
                            onPressed: () => audioHandler.setRepeatMode(
                              repeat == AudioServiceRepeatMode.one
                                  ? AudioServiceRepeatMode.none
                                  : AudioServiceRepeatMode.one,
                            ),
                            icon: Icon(Icons.repeat_one,
                                color: repeat == AudioServiceRepeatMode.one
                                    ? Theme.of(context).colorScheme.primary
                                    : null),
                          ),
                          IconButton(
                            iconSize: 44,
                            onPressed: audioHandler.skipToPrevious,
                            icon: const Icon(Icons.skip_previous),
                          ),
                          const SizedBox(width: 16),
                          IconButton.filled(
                            iconSize: 44,
                            onPressed:
                                playing ? audioHandler.pause : audioHandler.play,
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            iconSize: 44,
                            onPressed: audioHandler.skipToNext,
                            icon: const Icon(Icons.skip_next),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
