import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/repositories/song_repository.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/services/whatsapp_import_service.dart';

/// Deja elegir audios recibidos por WhatsApp (notas de voz y reenviados,
/// normalmente ocultos de la biblioteca a propósito) y copiarlos a Download
/// para que pasen a estar disponibles como una canción más. No mueve ni
/// borra el original de WhatsApp.
class WhatsAppImportScreen extends StatefulWidget {
  const WhatsAppImportScreen({super.key});

  @override
  State<WhatsAppImportScreen> createState() => _WhatsAppImportScreenState();
}

class _WhatsAppImportScreenState extends State<WhatsAppImportScreen> {
  final _importer = WhatsAppImportService();
  // Reproductor propio y liviano solo para escuchar y verificar antes de
  // importar — no pasa por MyAudioHandler/notificación, es nomás una
  // vista previa dentro de esta pantalla.
  final _previewPlayer = AudioPlayer();
  final _scrollController = ScrollController();
  late Future<List<Song>> _future;
  final _selected = <int>{};
  bool _importing = false;
  int? _previewingId;

  @override
  void initState() {
    super.initState();
    _future = sl<SongRepository>().getWhatsAppAudios();
    _previewPlayer.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && mounted) {
        setState(() => _previewingId = null);
      }
    });
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _togglePreview(Song song) async {
    if (_previewingId == song.mediaStoreId) {
      await _previewPlayer.stop();
      if (mounted) setState(() => _previewingId = null);
      return;
    }
    setState(() => _previewingId = song.mediaStoreId);
    try {
      await _previewPlayer.setAudioSource(
        AudioSource.uri(Uri.file(song.filePath)),
      );
      await _previewPlayer.play();
    } catch (_) {
      if (mounted) setState(() => _previewingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importar de WhatsApp')),
      body: FutureBuilder<List<Song>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('No se pudo leer los audios: ${snapshot.error}'),
            );
          }

          final songs = snapshot.data ?? const [];
          if (songs.isEmpty) {
            return const _EmptyState();
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'Elegí qué audios recibidos por WhatsApp querés poder usar '
                  'en la app. Se copian a Download, el original no se toca.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: AlphabetIndexedList(
                  labels: songs.map((s) => s.title).toList(),
                  controller: _scrollController,
                  listPadding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                  child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    final isPreviewing = _previewingId == song.mediaStoreId;
                    return CheckboxListTile(
                      value: _selected.contains(song.mediaStoreId),
                      onChanged: _importing
                          ? null
                          : (checked) => setState(() {
                                if (checked ?? false) {
                                  _selected.add(song.mediaStoreId);
                                } else {
                                  _selected.remove(song.mediaStoreId);
                                }
                              }),
                      secondary: IconButton(
                        tooltip: isPreviewing ? 'Detener' : 'Escuchar',
                        icon: Icon(isPreviewing
                            ? Icons.stop_circle
                            : Icons.play_circle_outline),
                        onPressed: () => _togglePreview(song),
                      ),
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: song.duration != null
                          ? Text(_formatDuration(song.duration!))
                          : null,
                    );
                  },
                  ),
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: _importing ? null : _importSelected,
                  icon: _importing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_importing
                      ? 'Importando...'
                      : 'Importar (${_selected.length})'),
                ),
              ),
            ),
    );
  }

  Future<void> _importSelected() async {
    await _previewPlayer.stop();
    setState(() => _previewingId = null);

    final songs = await _future;
    final toImport =
        songs.where((s) => _selected.contains(s.mediaStoreId)).toList();

    setState(() => _importing = true);

    var ok = 0;
    var failed = 0;
    for (final song in toImport) {
      try {
        await _importer.importToDownloads(song);
        ok++;
      } catch (_) {
        failed++;
      }
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _selected.clear();
    });

    await AppProviders.songOf(context).loadSongs();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failed == 0
            ? '$ok audio(s) importado(s) a Download'
            : '$ok importado(s), $failed falló(aron)'),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'No se encontraron audios de WhatsApp para importar.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
