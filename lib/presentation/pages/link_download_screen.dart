import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tk_music/core/platform.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/utils/playback_actions.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/services/mp3_link_downloader.dart';

/// Pegar un enlace a un archivo MP3 y sumarlo a la biblioteca, con el
/// avance de la descarga. Solo MP3 (ver [Mp3LinkDownloader]).
class LinkDownloadScreen extends StatefulWidget {
  const LinkDownloadScreen({super.key});

  @override
  State<LinkDownloadScreen> createState() => _LinkDownloadScreenState();
}

class _Saved {
  const _Saved(this.name, this.path);
  final String name;
  final String path;
}

class _LinkDownloadScreenState extends State<LinkDownloadScreen> {
  final _link = TextEditingController();
  Mp3LinkDownloader? _downloader;
  bool _saving = false;
  int _received = 0;
  int? _total;
  String? _error;
  final List<_Saved> _saved = [];

  bool get _busy => _downloader != null || _saving;

  @override
  void dispose() {
    _downloader?.cancel();
    _link.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      setState(() {
        _link.text = text;
        _error = null;
      });
    }
  }

  Future<void> _download() async {
    final link = _link.text.trim();
    if (link.isEmpty || _busy) return;
    FocusScope.of(context).unfocus();
    final songs = AppProviders.songOf(context);
    final downloader = Mp3LinkDownloader();
    setState(() {
      _downloader = downloader;
      _received = 0;
      _total = null;
      _error = null;
    });
    try {
      final mp3 =
          await downloader.download(link, onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _received = received;
          _total = total;
        });
      });
      if (!mounted) {
        await mp3.file.delete().catchError((_) => mp3.file);
        return;
      }
      setState(() {
        _downloader = null;
        _saving = true;
      });
      final path = await downloader.saveToLibrary(mp3);
      await songs.loadSongs();
      if (!mounted) return;
      final name = mp3.fileName.replaceAll(RegExp(r'\.mp3$'), '');
      setState(() {
        _saved.insert(0, _Saved(name, path));
        _link.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$name" ya está en tu biblioteca')),
      );
      // Android puede tardar un momento en indexar el archivo nuevo.
      if (_songAt(path) == null) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) songs.loadSongs();
        });
      }
    } on Mp3LinkException catch (e) {
      if (mounted && !downloader.cancelled) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() {
          _downloader = null;
          _saving = false;
        });
      }
    }
  }

  Song? _songAt(String path) {
    final songs = AppProviders.songOf(context).songs;
    final wanted = path.toLowerCase();
    for (final song in songs) {
      if (song.filePath.toLowerCase() == wanted) return song;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _total == null ? null : _received / _total!;
    return Scaffold(
      appBar: AppBar(
          title: const AppHeaderTitle(section: 'Descargar MP3 desde enlace')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text(
                'Pegá el enlace de un archivo MP3 (de una página, tu servidor, '
                'Google Drive o Dropbox compartidos) y se suma a tu '
                'biblioteca. Solo se aceptan archivos MP3; los enlaces de '
                'YouTube, Spotify y otras páginas para escuchar en línea no se pueden '
                'descargar.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _link,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _download(),
                onChanged: (_) => setState(() => _error = null),
                decoration: InputDecoration(
                  labelText: 'Enlace del MP3',
                  hintText: 'https://…/cancion.mp3',
                  prefixIcon: const Icon(Icons.link),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Pegar',
                    icon: const Icon(Icons.content_paste),
                    onPressed: _busy ? null : _paste,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_busy) ...[
                LinearProgressIndicator(value: _saving ? null : progress),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _saving
                            ? 'Guardando en la biblioteca…'
                            : progress != null
                                ? '${(progress * 100).floor()} % · '
                                    '${_mb(_received)} de ${_mb(_total!)}'
                                : 'Descargando… ${_mb(_received)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (!_saving)
                      TextButton.icon(
                        onPressed: () => _downloader?.cancel(),
                        icon: const Icon(Icons.close),
                        label: const Text('Cancelar'),
                      ),
                  ],
                ),
              ] else
                FilledButton.icon(
                  onPressed: _link.text.trim().isEmpty ? null : _download,
                  icon: const Icon(Icons.download),
                  label: const Text('Descargar MP3'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            color: theme.colorScheme.onErrorContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                                color: theme.colorScheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_saved.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Descargadas', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  isDesktopPlatform
                      ? 'Quedan en la carpeta "Descargas" dentro de tu carpeta '
                          'de música.'
                      : 'Quedan en Música/TK Music del teléfono.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                for (final saved in _saved)
                  Builder(builder: (context) {
                    final song = _songAt(saved.path);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.check_circle_outline),
                      title: Text(saved.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: song == null
                          ? const Text('Aparece en la biblioteca en unos '
                              'segundos')
                          : null,
                      trailing: song == null
                          ? null
                          : IconButton(
                              tooltip: 'Reproducir',
                              icon: const Icon(Icons.play_arrow),
                              onPressed: () => playFromLibrary(
                                  AppProviders.songOf(context), song),
                            ),
                    );
                  }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
