import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/services/artwork_bytes.dart';
import 'package:tk_music/services/artwork_colors.dart';
import 'package:tk_music/services/online_catalog.dart';
import 'package:tk_music/services/playback_settings.dart';
import 'package:tk_music/services/tag_overrides_store.dart';

/// Tiñe lo que tiene adentro con el color de una carátula: el tema
/// (botones, barras, onda, resaltados) pasa a ese color y [builder] recibe
/// el color para usarlo en fondos. Cambia con una transición suave. La
/// carátula sale de una canción de la biblioteca ([songId]) o de una imagen
/// suelta ([artwork] + [artworkKey], p. ej. la que manda el anfitrión en una
/// sesión compartida). Se apaga desde Ajustes → "Colores según la
/// carátula".
class ArtworkTinted extends StatefulWidget {
  const ArtworkTinted({
    super.key,
    this.songId,
    this.artwork,
    this.artworkKey,
    this.artworkUrl,
    required this.builder,
  });

  final int? songId;
  final Uint8List? artwork;
  final String? artworkKey;

  /// Carátula por URL (canciones de la sección Online).
  final String? artworkUrl;
  final Widget Function(BuildContext context, Color? seed) builder;

  @override
  State<ArtworkTinted> createState() => _ArtworkTintedState();
}

class _ArtworkTintedState extends State<ArtworkTinted> {
  Color? _seed;
  Object? _source;

  @override
  void initState() {
    super.initState();
    PlaybackSettings.instance.addListener(_onSettings);
    TagOverridesStore.instance.addListener(_onCoverEdited);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ArtworkTinted oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  @override
  void dispose() {
    PlaybackSettings.instance.removeListener(_onSettings);
    TagOverridesStore.instance.removeListener(_onCoverEdited);
    super.dispose();
  }

  void _onSettings() => setState(() {});

  /// Se cambió una carátula en el editor de tags: si es la de esta canción,
  /// el color se vuelve a calcular ya.
  void _onCoverEdited() {
    final songId = widget.songId;
    if (songId == null || widget.artwork != null) return;
    ArtworkBytes.invalidate(songId);
    ArtworkColors.invalidate(songId);
    _source = null;
    _resolve();
  }

  Future<void> _resolve() async {
    final artwork = widget.artwork;
    final key = widget.artworkKey;
    final url = widget.artworkUrl;
    final Object? source = artwork != null && key != null
        ? 'bytes:$key'
        : widget.songId ?? (url != null ? 'url:$url' : null);
    if (source == _source) return;
    _source = source;
    Color? seed;
    if (artwork != null && key != null) {
      seed = await ArtworkColors.seedForBytes(key, artwork);
    } else if (widget.songId != null) {
      seed = await ArtworkColors.seedFor(widget.songId!);
    } else if (url != null) {
      final bytes = await ArtworkBytes.forUrl(url);
      if (bytes != null) {
        seed = await ArtworkColors.seedForBytes('url:$url', bytes);
      }
    }
    // Mientras se calcula, queda el color anterior (sin parpadeo); si la
    // canción nueva no tiene carátula, vuelve al color normal de la app.
    if (!mounted || source != _source) return;
    setState(() => _seed = seed);
  }

  @override
  Widget build(BuildContext context) {
    final seed = PlaybackSettings.instance.artworkColors ? _seed : null;
    final base = Theme.of(context);
    final theme = seed == null
        ? base
        : base.copyWith(
            colorScheme: ColorScheme.fromSeed(
                seedColor: seed, brightness: base.brightness),
          );
    return AnimatedTheme(
      data: theme,
      duration: const Duration(milliseconds: 700),
      child: Builder(builder: (context) => widget.builder(context, seed)),
    );
  }
}

/// Fondo con degradé del color de la carátula (y tema teñido).
class ArtworkGradient extends StatelessWidget {
  const ArtworkGradient({
    super.key,
    this.songId,
    this.artwork,
    this.artworkKey,
    this.artworkUrl,
    required this.child,
  });

  final int? songId;
  final Uint8List? artwork;
  final String? artworkKey;
  final String? artworkUrl;
  final Widget child;

  static const base = Color(0xFF070B14);
  static const defaultTop = Color(0xFF0E1B33);

  @override
  Widget build(BuildContext context) {
    return ArtworkTinted(
      songId: songId,
      artwork: artwork,
      artworkKey: artworkKey,
      artworkUrl: artworkUrl,
      builder: (context, seed) => AnimatedContainer(
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.3,
            colors: [
              seed == null ? defaultTop : Color.lerp(base, seed, 0.55)!,
              base,
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}

/// [ArtworkGradient] de lo que está sonando en el reproductor principal
/// ("Reproduciendo", "Letra", "A continuación").
class ArtworkBackdrop extends StatelessWidget {
  const ArtworkBackdrop(
      {super.key, required this.mediaItems, required this.child});

  final Stream<MediaItem?> mediaItems;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: mediaItems,
      builder: (context, snapshot) => ArtworkGradient(
        songId: snapshot.data?.extras?['songId'] as int?,
        artworkUrl: artworkUrlOf(snapshot.data),
        child: child,
      ),
    );
  }
}
