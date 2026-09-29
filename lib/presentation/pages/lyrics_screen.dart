import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/artwork_backdrop.dart';
import 'package:tk_music/presentation/widgets/lyrics_view.dart';
import 'package:tk_music/services/lyrics.dart';
import 'package:tk_music/services/playback_settings.dart';
import 'package:tk_music/services/player_position.dart';

/// Letra de lo que suena en el reproductor principal, sincronizada: el
/// renglón actual resaltado y tocar uno salta ahí.
class LyricsScreen extends StatelessWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = sl<AudioHandler>();
    return Scaffold(
      appBar: AppBar(title: const AppHeaderTitle(section: 'Letra')),
      body: ArtworkBackdrop(
        mediaItems: handler.mediaItem,
        child: StreamBuilder<MediaItem?>(
          stream: handler.mediaItem,
          builder: (context, snapshot) {
            final item = snapshot.data;
            if (item == null) {
              return const Center(child: Text('Nada en reproducción'));
            }
            return _LyricsForItem(
                key: ValueKey(item.id), item: item, handler: handler);
          },
        ),
      ),
    );
  }
}

class _LyricsForItem extends StatefulWidget {
  const _LyricsForItem({super.key, required this.item, required this.handler});

  final MediaItem item;
  final AudioHandler handler;

  @override
  State<_LyricsForItem> createState() => _LyricsForItemState();
}

class _LyricsForItemState extends State<_LyricsForItem> {
  late final Future<Lyrics?> _lyrics = LyricsStore.instance.lyricsFor(
    path: widget.item.id,
    title: widget.item.title,
    artist: widget.item.artist,
    album: widget.item.album,
    durationMs: widget.item.duration?.inMilliseconds,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Lyrics?>(
      future: _lyrics,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final lyrics = snapshot.data;
        if (lyrics == null || lyrics.isEmpty) {
          final hint = PlaybackSettings.instance.onlineLyrics
              ? 'Se buscó en un archivo .lrc al lado de la canción, en la '
                  'letra guardada dentro del MP3 y en LRCLIB (la base de '
                  'letras de internet), y no está en ninguno. Podés poner un '
                  'archivo .lrc con el mismo nombre al lado de la canción.'
              : 'Podés poner un archivo .lrc con el mismo nombre al lado de '
                  'la canción, o activar "Buscar letras en internet" en '
                  'Ajustes.';
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No se encontró la letra de "${widget.item.title}".\n\n$hint',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: StreamBuilder<Duration>(
              stream: PlayerPosition.stream,
              builder: (context, position) => LyricsView(
                lyrics: lyrics,
                position: position.data ?? Duration.zero,
                onSeek: widget.handler.seek,
              ),
            ),
          ),
        );
      },
    );
  }
}
