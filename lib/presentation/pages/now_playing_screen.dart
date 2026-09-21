import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/pages/queue_screen.dart';
import 'package:tk_music/presentation/widgets/seek_bar.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/presentation/widgets/scrolling_waveform_view.dart';
import 'package:tk_music/presentation/widgets/song_options_sheet.dart';
import 'package:tk_music/services/audio_handler.dart';
import 'package:tk_music/services/waveform_loader.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isAudioAvailable) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reproduciendo')),
        body: const Center(child: Text('Audio no disponible')),
      );
    }

    final audioHandler = sl<AudioHandler>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('REPRODUCIENDO', style: TextStyle(fontSize: 13, letterSpacing: 1.2)),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          const _SleepTimerButton(),
          IconButton(
            tooltip: 'A continuación',
            icon: const Icon(Icons.queue_music),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const QueueScreen()),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.3,
            colors: [Color(0xFF0E1B33), Color(0xFF070B14)],
          ),
        ),
        child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, snapshot) {
          final item = snapshot.data;
          if (item == null) {
            return const Center(child: Text('Nada en reproducción'));
          }
          final songId = item.extras?['songId'] as int?;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const Spacer(),
                  if (songId != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: SongArtwork(songId: songId, size: 300, borderRadius: 18),
                    ),
                  const SizedBox(height: 32),
                  Text(
                    item.title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.artist ?? 'Desconocido',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  if (songId != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AnimatedBuilder(
                        animation: WaveformLoader.instance,
                        builder: (context, _) {
                          return StreamBuilder<Duration>(
                            stream: AudioService.position,
                            builder: (context, posSnapshot) {
                              final position = posSnapshot.data ?? Duration.zero;
                              final total = item.duration ?? Duration.zero;
                              final progress = total.inMilliseconds == 0
                                  ? 0.0
                                  : position.inMilliseconds / total.inMilliseconds;
                              return ScrollingWaveformView(
                                peaks: WaveformLoader.instance.peaks,
                                progress: progress,
                                onSeek: total == Duration.zero
                                    ? null
                                    : (t) => audioHandler.seek(total * t),
                              );
                            },
                          );
                        },
                      ),
                    ),
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
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            tooltip: switch (repeat) {
                              AudioServiceRepeatMode.all => 'Repetir todas',
                              AudioServiceRepeatMode.one => 'Repetir una',
                              _ => 'Repetición',
                            },
                            onPressed: () => audioHandler.setRepeatMode(
                              switch (repeat) {
                                AudioServiceRepeatMode.none =>
                                  AudioServiceRepeatMode.all,
                                AudioServiceRepeatMode.all =>
                                  AudioServiceRepeatMode.one,
                                _ => AudioServiceRepeatMode.none,
                              },
                            ),
                            icon: Icon(
                              repeat == AudioServiceRepeatMode.one
                                  ? Icons.repeat_one
                                  : Icons.repeat,
                              color: repeat != AudioServiceRepeatMode.none
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                          ),
                          IconButton(
                            iconSize: 36,
                            onPressed: audioHandler.skipToPrevious,
                            icon: const Icon(Icons.skip_previous),
                          ),
                          IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                              minimumSize: const Size(60, 60),
                            ),
                            iconSize: 32,
                            onPressed: playing
                                ? audioHandler.pause
                                : audioHandler.play,
                            icon:
                                Icon(playing ? Icons.pause : Icons.play_arrow),
                          ),
                          IconButton(
                            iconSize: 36,
                            onPressed: audioHandler.skipToNext,
                            icon: const Icon(Icons.skip_next),
                          ),
                          IconButton(
                            tooltip: 'Más opciones',
                            icon: const Icon(Icons.more_vert),
                            onPressed: songId == null
                                ? null
                                : () => showSongOptionsSheet(
                                      context,
                                      mediaStoreId: songId,
                                      title: item.title,
                                      artist: item.artist,
                                      album: item.album,
                                      duration: item.duration,
                                      filePath: item.id,
                                    ),
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
      ),
    );
  }
}

const _sleepTimerOptions = [
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(minutes: 45),
  Duration(hours: 1),
];

/// Temporizador de apagado: pausa la reproducción sola pasado el tiempo
/// elegido. El ícono se resalta mientras está activo.
class _SleepTimerButton extends StatelessWidget {
  const _SleepTimerButton();

  @override
  Widget build(BuildContext context) {
    final handler = sl<AudioHandler>() as MyAudioHandler;

    return ValueListenableBuilder<DateTime?>(
      valueListenable: handler.sleepTimerEndsAt,
      builder: (context, endsAt, _) {
        return IconButton(
          tooltip: 'Temporizador de apagado',
          icon: Icon(
            endsAt != null ? Icons.bedtime : Icons.bedtime_outlined,
            color: endsAt != null ? Theme.of(context).colorScheme.primary : null,
          ),
          onPressed: () => _showSheet(context, handler, endsAt),
        );
      },
    );
  }

  void _showSheet(BuildContext context, MyAudioHandler handler, DateTime? endsAt) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Temporizador de apagado',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (endsAt != null)
              _RemainingTimeTile(endsAt: endsAt, handler: handler)
            else
              for (final duration in _sleepTimerOptions)
                ListTile(
                  leading: const Icon(Icons.bedtime_outlined),
                  title: Text(_formatOption(duration)),
                  onTap: () {
                    handler.setSleepTimer(duration);
                    Navigator.of(context).pop();
                  },
                ),
          ],
        ),
      ),
    );
  }

  String _formatOption(Duration d) =>
      d.inMinutes < 60 ? '${d.inMinutes} minutos' : '${d.inHours} hora';
}

class _RemainingTimeTile extends StatefulWidget {
  const _RemainingTimeTile({required this.endsAt, required this.handler});

  final DateTime endsAt;
  final MyAudioHandler handler;

  @override
  State<_RemainingTimeTile> createState() => _RemainingTimeTileState();
}

class _RemainingTimeTileState extends State<_RemainingTimeTile> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.endsAt.difference(DateTime.now());
    final minutes = remaining.isNegative ? 0 : remaining.inMinutes;
    final seconds = remaining.isNegative ? 0 : remaining.inSeconds.remainder(60);

    return ListTile(
      leading: const Icon(Icons.bedtime),
      title: Text('Se pausa en $minutes:${seconds.toString().padLeft(2, '0')}'),
      trailing: TextButton.icon(
        onPressed: () {
          widget.handler.cancelSleepTimer();
          Navigator.of(context).pop();
        },
        icon: const Icon(Icons.close),
        label: const Text('Cancelar'),
      ),
    );
  }
}
