import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/services/artwork_bytes.dart';
import 'package:tk_music/services/online_catalog.dart';

/// Carátula de lo que suena, sea de la biblioteca ([SongArtwork]) o de la
/// sección Online (por URL). `null` si no hay ninguna.
class MediaArtwork extends StatelessWidget {
  const MediaArtwork({
    super.key,
    required this.item,
    this.size = 48,
    this.borderRadius = 8,
  });

  final MediaItem item;
  final double size;
  final double borderRadius;

  /// Si [item] tiene de dónde sacar carátula.
  static bool hasArtwork(MediaItem item) =>
      item.extras?['songId'] is int || artworkUrlOf(item) != null;

  @override
  Widget build(BuildContext context) {
    final songId = item.extras?['songId'] as int?;
    if (songId != null) {
      return SongArtwork(
          songId: songId, size: size, borderRadius: borderRadius);
    }
    final url = artworkUrlOf(item);
    if (url == null) return _Placeholder(size: size, radius: borderRadius);
    return UrlArtwork(url: url, size: size, borderRadius: borderRadius);
  }
}

/// Carátula por URL, guardada en el dispositivo después de la primera vez.
class UrlArtwork extends StatelessWidget {
  const UrlArtwork({
    super.key,
    required this.url,
    this.size = 48,
    this.borderRadius = 8,
  });

  final String url;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: ArtworkBytes.forUrl(url),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return _Placeholder(size: size, radius: borderRadius);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, __, ___) =>
                _Placeholder(size: size, radius: borderRadius),
          ),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.radius});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.music_note,
          size: size * 0.5, color: scheme.onSurfaceVariant),
    );
  }
}
