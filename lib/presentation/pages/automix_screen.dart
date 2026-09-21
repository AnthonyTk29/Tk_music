import 'package:flutter/material.dart';

import 'package:tk_music/domain/entities/playlist.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/scrolling_waveform_view.dart';
import 'package:tk_music/services/automix_engine.dart';
import 'package:tk_music/services/playlist_store.dart';

/// Mezclador automático, al estilo "Automix" de VirtualDJ: elegís una
/// playlist y arranca a cruzar canciones sola, ajustando el volumen de cada
/// una según su sonoridad real para que ningún cruce se sienta más fuerte o
/// más flojo que el anterior.
///
/// Es una sesión aparte de la reproducción normal (dos reproductores
/// propios, necesarios para el crossfade), pero mientras suena "toma
/// prestada" la notificación del reproductor principal — ver
/// [AutomixEngine.start] — así que sí sobrevive en segundo plano y se ve en
/// la notificación como cualquier otra reproducción. Eso recién pasa al
/// arrancar a sonar, no con solo abrir esta pantalla a elegir playlist.
///
/// [AutomixEngine.instance] es un singleton: salir de esta pantalla (volver
/// a Biblioteca, Favoritos, etc.) no corta la mezcla, solo cierra la
/// pantalla — por eso hay un botón flotante en las pantallas principales
/// para volver acá mientras sigue sonando (ver [AutomixStatusButton]).
class AutomixScreen extends StatefulWidget {
  const AutomixScreen({super.key});

  @override
  State<AutomixScreen> createState() => _AutomixScreenState();
}

class _AutomixScreenState extends State<AutomixScreen> {
  final _engine = AutomixEngine.instance;
  late final Future<List<Playlist>> _playlistsFuture;
  Playlist? _selectedPlaylist;
  bool _shuffle = true;

  @override
  void initState() {
    super.initState();
    _playlistsFuture = PlaylistStore.instance.getAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mezclador automático')),
      body: AnimatedBuilder(
        animation: _engine,
        builder: (context, _) {
          if (_engine.status == AutomixStatus.idle) {
            return _SetupView(
              playlistsFuture: _playlistsFuture,
              selectedPlaylist: _selectedPlaylist,
              shuffle: _shuffle,
              onPlaylistChanged: (p) => setState(() => _selectedPlaylist = p),
              onShuffleChanged: (v) => setState(() => _shuffle = v),
              onStart: _start,
            );
          }
          return _MixingView(engine: _engine, onStop: _stopAndReset);
        },
      ),
    );
  }

  Future<void> _start() async {
    final playlist = _selectedPlaylist;
    if (playlist == null || playlist.songIds.isEmpty) return;

    final allSongs = AppProviders.songOf(context).songs;
    final byId = {for (final s in allSongs) s.mediaStoreId: s};
    final queue = playlist.songIds
        .map((id) => byId[id])
        .whereType<Song>()
        .toList();
    if (_shuffle) queue.shuffle();
    if (queue.isEmpty) return;

    await _engine.start(queue);
  }

  Future<void> _stopAndReset() async {
    await _engine.stop();
    setState(() {});
  }
}

class _SetupView extends StatelessWidget {
  const _SetupView({
    required this.playlistsFuture,
    required this.selectedPlaylist,
    required this.shuffle,
    required this.onPlaylistChanged,
    required this.onShuffleChanged,
    required this.onStart,
  });

  final Future<List<Playlist>> playlistsFuture;
  final Playlist? selectedPlaylist;
  final bool shuffle;
  final ValueChanged<Playlist?> onPlaylistChanged;
  final ValueChanged<bool> onShuffleChanged;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<Playlist>>(
      future: playlistsFuture,
      builder: (context, snapshot) {
        final playlists = snapshot.data;
        if (playlists == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (playlists.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq,
                      size: 40, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text(
                    'Creá una playlist primero: el Mezclador automático '
                    'arma la sesión a partir de una.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          );
        }

        final current = selectedPlaylist != null &&
                playlists.any((p) => p.id == selectedPlaylist!.id)
            ? selectedPlaylist
            : playlists.first;
        if (current != selectedPlaylist) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => onPlaylistChanged(current));
        }

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Playlist a mezclar', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              DropdownButtonFormField<Playlist>(
                value: current,
                items: playlists
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text('${p.name} (${p.songIds.length})'),
                        ))
                    .toList(),
                onChanged: (p) {
                  if (p != null) onPlaylistChanged(p);
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Orden aleatorio'),
                value: shuffle,
                onChanged: onShuffleChanged,
              ),
              const SizedBox(height: 16),
              Text(
                'Se ajusta automáticamente el volumen de cada canción según '
                'su sonoridad real, así los cruces no se sienten más fuertes '
                'ni más flojos de golpe. La primera vez que suena cada '
                'canción tarda unos segundos en analizarse; después queda '
                'guardado.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: current == null || current.songIds.isEmpty
                    ? null
                    : onStart,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Empezar mezcla automática'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MixingView extends StatelessWidget {
  const _MixingView({required this.engine, required this.onStop});

  final AutomixEngine engine;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = engine.currentSong;

    if (engine.status == AutomixStatus.finished || current == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('Se terminó la playlist'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.close),
              label: const Text('Volver'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: engine.status == AutomixStatus.loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _NowPlayingHeader(engine: engine, onStop: onStop),
        ),
        const Divider(height: 1),
        Expanded(child: _UpcomingList(engine: engine)),
      ],
    );
  }
}

/// Canción que está sonando ahora: onda, transporte y (si está cruzando)
/// hacia cuál está yendo.
class _NowPlayingHeader extends StatelessWidget {
  const _NowPlayingHeader({required this.engine, required this.onStop});

  final AutomixEngine engine;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = engine.currentSong!;
    final next = engine.nextSong;

    return Column(
      children: [
        Icon(
          engine.isCrossfading ? Icons.swap_horiz : Icons.graphic_eq,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 8),
        Text(
          current.title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
        if (current.artist != null)
          Text(
            current.artist!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        const SizedBox(height: 10),
        StreamBuilder<Duration>(
          stream: engine.positionStream,
          builder: (context, snapshot) {
            final position = snapshot.data ?? Duration.zero;
            final total = engine.duration ?? Duration.zero;
            final progress = total.inMilliseconds == 0
                ? 0.0
                : (position.inMilliseconds / total.inMilliseconds)
                    .clamp(0.0, 1.0);
            return ScrollingWaveformView(
              peaks: engine.currentPeaks,
              progress: progress,
              height: 52,
            );
          },
        ),
        if (next != null && engine.isCrossfading) ...[
          const SizedBox(height: 8),
          Text(
            'Cruzando a: ${next.title}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              iconSize: 28,
              onPressed: onStop,
              icon: const Icon(Icons.stop),
            ),
            const SizedBox(width: 16),
            IconButton.filled(
              iconSize: 34,
              onPressed: engine.togglePlayPause,
              icon: Icon(engine.isPlaying ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 16),
            IconButton.filledTonal(
              iconSize: 28,
              onPressed: next == null ? null : engine.skipToNext,
              icon: const Icon(Icons.skip_next),
            ),
          ],
        ),
      ],
    );
  }
}

/// Canciones que siguen después de la actual, reordenables arrastrando
/// (igual que "A continuación" del reproductor principal): reordenar acá
/// cambia directo cuál es la próxima en cruzar.
class _UpcomingList extends StatelessWidget {
  const _UpcomingList({required this.engine});

  final AutomixEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upcoming = engine.upcomingQueue;

    if (upcoming.isEmpty) {
      return Center(
        child: Text(
          'No hay más canciones después de esta',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Siguen (${upcoming.length})',
              style: theme.textTheme.labelLarge),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            itemCount: upcoming.length,
            onReorder: (oldIndex, newIndex) {
              if (newIndex > oldIndex) newIndex -= 1;
              engine.reorderUpcoming(oldIndex, newIndex);
            },
            itemBuilder: (context, index) {
              final song = upcoming[index];
              return ListTile(
                key: ValueKey('${song.mediaStoreId}_$index'),
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Text('${index + 1}'),
                ),
                title: Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: song.artist != null
                    ? Text(song.artist!,
                        maxLines: 1, overflow: TextOverflow.ellipsis)
                    : null,
                trailing: const Icon(Icons.drag_handle),
              );
            },
          ),
        ),
      ],
    );
  }
}
