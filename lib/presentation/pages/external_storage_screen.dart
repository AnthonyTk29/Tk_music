import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/utils/playback_actions.dart';
import 'package:tk_music/services/external_storage_service.dart';
import 'package:tk_music/services/external_storage_store.dart';

/// Lista de carpetas de pendrive ya conectadas, con la opción de agregar
/// una nueva (SAF) o desconectar una existente. Es una fuente separada de
/// la biblioteca del teléfono: no toca favoritos ni playlists.
class ExternalStorageScreen extends StatelessWidget {
  const ExternalStorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Almacenamiento externo')),
      body: AnimatedBuilder(
        animation: ExternalStorageStore.instance,
        builder: (context, _) {
          return FutureBuilder<List<PickedDirectory>>(
            future: ExternalStorageStore.instance.getRoots(),
            builder: (context, snapshot) {
              final roots = snapshot.data ?? const [];
              return ListView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                children: [
                  if (roots.isEmpty) const _EmptyState(),
                  for (final root in roots)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.usb),
                      ),
                      title: Text(root.name),
                      trailing: IconButton(
                        tooltip: 'Desconectar',
                        icon: const Icon(Icons.close),
                        onPressed: () => _confirmRemove(context, root),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ExternalFolderScreen(
                            uri: root.uri,
                            title: root.name,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: FilledButton.icon(
                      onPressed: () => _addRoot(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Conectar pendrive'),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // Sin try/catch acá: si falla, ExternalStorageStore.addFromPicker() ya
  // tira una AppException con el mensaje correcto — sube sola hasta la
  // alerta global en vez de que esta pantalla arme la suya con el texto
  // crudo de la excepción.
  Future<void> _addRoot(BuildContext context) async {
    final picked = await ExternalStorageStore.instance.addFromPicker();
    if (picked == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${picked.name}" conectado')),
    );
  }

  Future<void> _confirmRemove(
      BuildContext context, PickedDirectory root) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Desconectar almacenamiento'),
        content: Text('Se va a quitar el acceso a "${root.name}". '
            'Podés volver a conectarlo cuando quieras.'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            icon: const Icon(Icons.close),
            label: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Desconectar'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ExternalStorageStore.instance.remove(root);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
      child: Column(
        children: [
          Icon(Icons.usb_off, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'Todavía no conectaste ningún pendrive. Tocá "Conectar pendrive" '
            'y elegí la carpeta que querés usar.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Navegador de una carpeta del pendrive: subcarpetas primero, después los
/// archivos de audio. Tocar una canción arma la cola con todos los audios
/// visibles en esta misma carpeta (no navega recursivo a subcarpetas).
class ExternalFolderScreen extends StatefulWidget {
  const ExternalFolderScreen({super.key, required this.uri, required this.title});

  final String uri;
  final String title;

  @override
  State<ExternalFolderScreen> createState() => _ExternalFolderScreenState();
}

class _ExternalFolderScreenState extends State<ExternalFolderScreen> {
  final _service = ExternalStorageService();
  late Future<List<ExternalEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.listChildren(widget.uri);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<List<ExternalEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No se pudo leer esta carpeta: ${snapshot.error}'),
              ),
            );
          }

          final entries = snapshot.data ?? const [];
          final folders = entries.where((e) => e.isDirectory).toList();
          final audioFiles = entries
              .where((e) => !e.isDirectory && isAudioFileName(e.name))
              .toList();

          if (folders.isEmpty && audioFiles.isEmpty) {
            return const Center(child: Text('Carpeta vacía'));
          }

          if (!isAudioAvailable) {
            return _buildList(context, folders, audioFiles, null);
          }
          return StreamBuilder<MediaItem?>(
            stream: sl<AudioHandler>().mediaItem,
            builder: (context, mediaSnapshot) => _buildList(
                context, folders, audioFiles, mediaSnapshot.data?.id),
          );
        },
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    List<ExternalEntry> folders,
    List<ExternalEntry> audioFiles,
    String? currentId,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      children: [
        for (final folder in folders)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ExternalFolderScreen(
                  uri: folder.uri,
                  title: folder.name,
                ),
              ),
            ),
          ),
        for (var i = 0; i < audioFiles.length; i++)
          Builder(builder: (context) {
            final entry = audioFiles[i];
            final isCurrent = entry.uri == currentId;
            final theme = Theme.of(context);
            return ListTile(
              leading: Icon(
                Icons.music_note,
                color: isCurrent ? theme.colorScheme.primary : null,
              ),
              title: Text(
                entry.name,
                style: isCurrent
                    ? TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600)
                    : null,
              ),
              trailing: isCurrent ? const Icon(Icons.equalizer) : null,
              tileColor: isCurrent
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : null,
              onTap: isAudioAvailable
                  ? () => playFromExternalFolder(audioFiles, i)
                  : null,
            );
          }),
      ],
    );
  }
}
