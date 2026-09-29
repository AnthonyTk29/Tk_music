import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/media_artwork.dart';
import 'package:tk_music/services/mp3_link_downloader.dart';
import 'package:tk_music/services/online_catalog.dart';
import 'package:tk_music/services/queue_capable_handler.dart';

/// Pestaña "Online": canciones para escuchar por internet sin bajarlas, y
/// bajarlas a la biblioteca cuando el artista lo permite. Solo se ven las
/// canciones (título, artista, carátula), no de qué servicio vienen.
class OnlineTab extends StatefulWidget {
  const OnlineTab({super.key});

  @override
  State<OnlineTab> createState() => _OnlineTabState();
}

class _OnlineTabState extends State<OnlineTab> {
  final _catalog = OnlineCatalog.instance;
  final _search = TextEditingController();
  Timer? _debounce;

  OnlineGenre _genre = OnlineCatalog.genres.first;
  String _query = '';
  late Future<List<OnlineTrack>> _tracks;

  /// id → avance de la descarga (null = todavía sin total).
  final Map<String, double?> _downloading = {};
  final Map<String, Mp3LinkDownloader> _downloaders = {};
  final Set<String> _downloaded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    for (final d in _downloaders.values) {
      d.cancel();
    }
    super.dispose();
  }

  void _load() {
    _tracks = _query.isNotEmpty
        ? _catalog.search(_query)
        : _catalog.popular(genre: _genre.key);
  }

  void _onSearchChanged(String value) {
    setState(() {}); // muestra/oculta el botón de borrar
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || value.trim() == _query) return;
      setState(() {
        _query = value.trim();
        _load();
      });
    });
  }

  Future<void> _play(List<OnlineTrack> tracks, int index) async {
    if (!isAudioAvailable) return;
    final handler = sl<AudioHandler>();
    await (handler as QueueCapableHandler).setQueue(
      tracks.map((t) => t.toMediaItem()).toList(),
      startIndex: index,
    );
    await handler.play();
  }

  Future<void> _download(OnlineTrack track) async {
    if (_downloading.containsKey(track.id)) {
      _downloaders[track.id]?.cancel();
      return;
    }
    final songs = AppProviders.songOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final downloader = Mp3LinkDownloader();
    setState(() {
      _downloading[track.id] = null;
      _downloaders[track.id] = downloader;
    });
    try {
      await _catalog.download(
        track,
        downloader: downloader,
        onProgress: (received, total) {
          if (!mounted || total == null) return;
          setState(() => _downloading[track.id] = received / total);
        },
      );
      await songs.loadSongs();
      if (!mounted) return;
      setState(() => _downloaded.add(track.id));
      messenger.showSnackBar(
          SnackBar(content: Text('"${track.title}" ya está en tu biblioteca')));
    } on Mp3LinkException catch (e) {
      if (!downloader.cancelled) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloading.remove(track.id);
          _downloaders.remove(track.id);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) => setState(() {
              _query = value.trim();
              _load();
            }),
            decoration: InputDecoration(
              hintText: 'Buscar canciones o artistas',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Borrar',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                        _load();
                      }),
                    ),
            ),
          ),
        ),
        if (_query.isEmpty)
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              itemCount: OnlineCatalog.genres.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final genre = OnlineCatalog.genres[index];
                return ChoiceChip(
                  label: Text(genre.label),
                  selected: genre == _genre,
                  onSelected: (_) => setState(() {
                    _genre = genre;
                    _load();
                  }),
                );
              },
            ),
          ),
        Expanded(
          child: FutureBuilder<List<OnlineTrack>>(
            future: _tracks,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _Message(
                  icon: Icons.cloud_off,
                  text: snapshot.error is OnlineCatalogException
                      ? (snapshot.error as OnlineCatalogException).message
                      : 'No se pudo cargar la música en línea.',
                  action: 'Reintentar',
                  onAction: () => setState(_load),
                );
              }
              final tracks = snapshot.data ?? const [];
              if (tracks.isEmpty) {
                return _Message(
                  icon: Icons.search_off,
                  text: _query.isEmpty
                      ? 'No hay canciones para mostrar ahora.'
                      : 'No se encontró nada para "$_query".',
                );
              }
              return RefreshIndicator(
                onRefresh: () async {
                  setState(_load);
                  await _tracks.catchError((_) => const <OnlineTrack>[]);
                },
                child: _TrackList(
                  tracks: tracks,
                  title: _query.isEmpty
                      ? (_genre.key == null
                          ? 'Lo más escuchado'
                          : 'Lo más escuchado · ${_genre.label}')
                      : 'Resultados',
                  downloading: _downloading,
                  downloaded: _downloaded,
                  onPlay: (index) => _play(tracks, index),
                  onDownload: _download,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.tracks,
    required this.title,
    required this.downloading,
    required this.downloaded,
    required this.onPlay,
    required this.onDownload,
  });

  final List<OnlineTrack> tracks;
  final String title;
  final Map<String, double?> downloading;
  final Set<String> downloaded;
  final void Function(int index) onPlay;
  final void Function(OnlineTrack track) onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handler = isAudioAvailable ? sl<AudioHandler>() : null;
    return StreamBuilder<MediaItem?>(
      stream: handler?.mediaItem,
      builder: (context, snapshot) {
        final playingId = snapshot.data?.id;
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: tracks.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title, style: theme.textTheme.titleMedium),
                    ),
                    TextButton.icon(
                      onPressed: () => onPlay(0),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Reproducir todo'),
                    ),
                  ],
                ),
              );
            }
            final track = tracks[index - 1];
            final isPlaying = track.streamUrl == playingId;
            return ListTile(
              selected: isPlaying,
              leading: track.artworkUrl == null
                  ? const Icon(Icons.music_note)
                  : UrlArtwork(url: track.artworkUrl!, size: 48),
              title: Text(track.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${track.artist} · ${_duration(track.duration)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _DownloadButton(
                track: track,
                progress: downloading[track.id],
                busy: downloading.containsKey(track.id),
                done: downloaded.contains(track.id),
                onPressed: () => onDownload(track),
              ),
              onTap: () => onPlay(index - 1),
            );
          },
        );
      },
    );
  }

  static String _duration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.track,
    required this.progress,
    required this.busy,
    required this.done,
    required this.onPressed,
  });

  final OnlineTrack track;
  final double? progress;
  final bool busy;
  final bool done;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!track.downloadable) {
      return const Tooltip(
        message: 'Solo para escuchar en línea',
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.cloud_outlined, size: 20),
        ),
      );
    }
    if (done) {
      return const Tooltip(
        message: 'Ya está en tu biblioteca',
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Icon(Icons.download_done),
        ),
      );
    }
    if (busy) {
      return IconButton(
        tooltip: 'Cancelar descarga',
        onPressed: onPressed,
        icon: SizedBox(
          width: 24,
          height: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(value: progress, strokeWidth: 2.5),
              const Icon(Icons.close, size: 14),
            ],
          ),
        ),
      );
    }
    return IconButton(
      tooltip: 'Descargar',
      onPressed: onPressed,
      icon: const Icon(Icons.download_outlined),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
