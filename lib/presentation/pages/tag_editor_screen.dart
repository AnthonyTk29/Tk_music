import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'package:tk_music/core/platform.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/services/artwork_bytes.dart';
import 'package:tk_music/services/artwork_colors.dart';
import 'package:tk_music/services/id3.dart';
import 'package:tk_music/services/tag_overrides_store.dart';
import 'package:tk_music/services/track_features.dart';
import 'package:tk_music/services/track_features_store.dart';

/// Editor de tags de una canción: título, artista, álbum, género y
/// carátula. Los cambios se ven en toda la app; en desktop, los MP3 además
/// se pueden guardar dentro del archivo. También muestra (y deja calcular)
/// el ritmo y la tonalidad.
class TagEditorScreen extends StatefulWidget {
  const TagEditorScreen({super.key, required this.songId});

  final int songId;

  @override
  State<TagEditorScreen> createState() => _TagEditorScreenState();
}

class _TagEditorScreenState extends State<TagEditorScreen> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _genre = TextEditingController();
  Song? _original;
  Uint8List? _newCover;
  bool _removeCover = false;
  bool _writeToFile = true;
  bool _saving = false;
  TrackFeatures? _features;
  bool _analyzing = false;

  bool get _canWriteFile =>
      isDesktopPlatform &&
      (_original?.filePath.toLowerCase().endsWith('.mp3') ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_original != null) return;
    final provider = AppProviders.songOf(context);
    final original = provider.originalOf(widget.songId);
    if (original == null) return;
    _original = original;
    final current = TagOverridesStore.instance.apply(original);
    _title.text = current.title;
    _artist.text = current.artist ?? '';
    _album.text = current.album ?? '';
    _genre.text = current.genre ?? '';
    _features = TrackFeaturesStore.instance.cached(original.filePath);
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _genre.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    // A JPEG de 600 px como máximo: liviana para guardar, para la etiqueta
    // del MP3 y para mandarla por Bluetooth en las sesiones.
    final jpeg = await Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final resized = decoded.width > 600 || decoded.height > 600
          ? img.copyResize(decoded,
              width: decoded.width >= decoded.height ? 600 : null,
              height: decoded.height > decoded.width ? 600 : null)
          : decoded;
      return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
    });
    if (!mounted) return;
    if (jpeg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo leer esa imagen')));
      return;
    }
    setState(() {
      _newCover = jpeg;
      _removeCover = false;
    });
  }

  Future<void> _analyze() async {
    final original = _original;
    if (original == null) return;
    setState(() => _analyzing = true);
    final features = await TrackFeaturesStore.instance.featuresFor(
        original.filePath,
        durationMs: original.duration?.inMilliseconds);
    if (!mounted) return;
    setState(() {
      _features = features;
      _analyzing = false;
    });
  }

  Future<void> _save() async {
    final original = _original;
    if (original == null) return;
    setState(() => _saving = true);
    final songs = AppProviders.songOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    await TagOverridesStore.instance.save(
      original,
      title: _title.text,
      artist: _artist.text,
      album: _album.text,
      genre: _genre.text,
      cover: _newCover,
      removeCover: _removeCover,
    );

    var fileNote = '';
    if (_canWriteFile && _writeToFile) {
      try {
        // Al archivo va lo que queda vigente (lo corregido o, si se vació
        // un campo, el original): nunca borra un dato del archivo.
        final effective = TagOverridesStore.instance.apply(original);
        final ok = await writeMp3Tags(
          original.filePath,
          title: effective.title,
          artist: effective.artist,
          album: effective.album,
          genre: effective.genre,
          cover: _newCover,
        );
        fileNote = ok
            ? ' y en el archivo'
            : ' (el archivo tiene un formato de etiqueta que no se puede editar)';
      } catch (e) {
        fileNote =
            ' (no se pudo escribir el archivo: ¿está sonando o es de solo lectura?)';
      }
    }

    ArtworkBytes.invalidate(original.mediaStoreId);
    ArtworkColors.invalidate(original.mediaStoreId);
    songs.refreshSong(original.mediaStoreId);
    messenger
        .showSnackBar(SnackBar(content: Text('Cambios guardados$fileNote')));
    navigator.pop();
  }

  Future<void> _reset() async {
    final original = _original;
    if (original == null) return;
    final songs = AppProviders.songOf(context);
    await TagOverridesStore.instance.reset(original.mediaStoreId);
    ArtworkBytes.invalidate(original.mediaStoreId);
    ArtworkColors.invalidate(original.mediaStoreId);
    songs.refreshSong(original.mediaStoreId);
    if (!mounted) return;
    setState(() {
      _title.text = original.title;
      _artist.text = original.artist ?? '';
      _album.text = original.album ?? '';
      _genre.text = original.genre ?? '';
      _newCover = null;
      _removeCover = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final original = _original;
    return Scaffold(
      appBar: AppBar(
        title: const AppHeaderTitle(section: 'Editar información'),
        actions: [
          if (original != null)
            TextButton(
                onPressed: _saving ? null : _reset,
                child: const Text('Restaurar original')),
        ],
      ),
      body: original == null
          ? const Center(
              child: Text('Esta canción ya no está en tu biblioteca'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Center(child: _coverPreview(original)),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _pickCover,
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('Cambiar carátula'),
                        ),
                        if (_newCover != null ||
                            (!_removeCover &&
                                TagOverridesStore.instance
                                        .coverFile(original.mediaStoreId) !=
                                    null))
                          TextButton(
                            onPressed: () => setState(() {
                              _newCover = null;
                              _removeCover = true;
                            }),
                            child: const Text('Usar la del archivo'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _field(_title, 'Título', original.title),
                    _field(_artist, 'Artista', original.artist),
                    _field(_album, 'Álbum', original.album),
                    _field(_genre, 'Género', original.genre),
                    if (_canWriteFile)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Guardar también en el archivo MP3'),
                        subtitle: const Text(
                            'Así se ve igual en otros reproductores'),
                        value: _writeToFile,
                        onChanged: (v) => setState(() => _writeToFile = v),
                      ),
                    const SizedBox(height: 8),
                    _FeaturesCard(
                      features: _features,
                      analyzing: _analyzing,
                      onAnalyze: hasNativeAudioAnalysis ? _analyze : null,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save),
                      label: const Text('Guardar'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Los cambios se ven en toda la app (biblioteca, colas, '
                      'sesiones compartidas). Si dejás un campo vacío, vuelve '
                      'al valor original del archivo.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _coverPreview(Song original) {
    const size = 160.0;
    final bytes = _newCover;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child:
            Image.memory(bytes, width: size, height: size, fit: BoxFit.cover),
      );
    }
    if (_removeCover) {
      // Vista previa de "sin carátula propia": la del archivo (o ninguna).
      return Opacity(
        opacity: 0.6,
        child: SongArtwork(
            songId: original.mediaStoreId, size: size, borderRadius: 20),
      );
    }
    return SongArtwork(
        songId: original.mediaStoreId, size: size, borderRadius: 20);
  }

  Widget _field(
      TextEditingController controller, String label, String? originalValue) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          helperText: originalValue == null || originalValue.isEmpty
              ? null
              : 'En el archivo: $originalValue',
        ),
      ),
    );
  }
}

class _FeaturesCard extends StatelessWidget {
  const _FeaturesCard(
      {required this.features,
      required this.analyzing,
      required this.onAnalyze});

  final TrackFeatures? features;
  final bool analyzing;
  final VoidCallback? onAnalyze;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = features;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.speed, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: f == null
                  ? Text('Ritmo y tonalidad sin analizar',
                      style: theme.textTheme.bodyMedium)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          f.hasTempo
                              ? '${f.bpm.toStringAsFixed(1)} BPM'
                              : 'Sin pulso claro',
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          [
                            if (f.keyName != null)
                              '${f.keyName} (${f.camelot})',
                            'energía ${(f.energy * 10).round()}/10',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
            ),
            if (analyzing)
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else if (f == null && onAnalyze != null)
              TextButton(onPressed: onAnalyze, child: const Text('Analizar')),
          ],
        ),
      ),
    );
  }
}
