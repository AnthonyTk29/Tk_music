import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';

import 'package:tk_music/core/platform.dart';
import 'package:tk_music/services/artwork_bytes.dart';
import 'package:tk_music/services/tag_overrides_store.dart';

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
    final placeholder = Container(
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
    );

    // Se redibuja si cambia alguna carátula desde el editor de tags.
    return ListenableBuilder(
      listenable: TagOverridesStore.instance,
      builder: (context, _) => _build(context, placeholder),
    );
  }

  Widget _build(BuildContext context, Widget placeholder) {
    final custom = TagOverridesStore.instance.coverFile(songId);
    if (custom != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.file(
          custom,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * 2).round(),
          errorBuilder: (_, __, ___) => placeholder,
        ),
      );
    }

    // En Android las carátulas salen de MediaStore vía on_audio_query, que
    // no existe en desktop: ahí se lee la carátula embebida en el archivo
    // (ArtworkBytes, cacheada en memoria).
    if (isDesktopPlatform) {
      return FutureBuilder<Uint8List?>(
        // Dos tamaños nada más, para que la misma carátula no se pida una
        // vez por cada tamaño de pantalla.
        future: ArtworkBytes.forSong(songId, size: size <= 64 ? 128 : 512),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) return placeholder;
          return ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Las carátulas embebidas o de internet pueden ser grandes: se
              // decodifican al tamaño en que se ven, no enteras.
              cacheWidth: (size * 2).round(),
            ),
          );
        },
      );
    }

    return QueryArtworkWidget(
      id: songId,
      type: ArtworkType.AUDIO,
      artworkBorder: BorderRadius.circular(borderRadius),
      artworkHeight: size,
      artworkWidth: size,
      // Sin carátula en el teléfono: la de internet (si está activado).
      nullArtworkWidget: FutureBuilder<Uint8List?>(
        future: ArtworkBytes.fromInternet(songId),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) return placeholder;
          return ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * 2).round(),
            ),
          );
        },
      ),
    );
  }
}
