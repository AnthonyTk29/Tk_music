import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/artwork_backdrop.dart';
import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';
import 'package:tk_music/presentation/widgets/media_artwork.dart';
import 'package:tk_music/services/automix_engine.dart';
import 'package:tk_music/services/queue_capable_handler.dart';

/// Cola de reproducción actual, reordenable con arrastrar-y-soltar. Se abre
/// desde "Reproduciendo"; si el Mezclador automático está sonando, muestra
/// esa lista (la misma que se ve en su propia pantalla) en vez de la cola
/// del reproductor normal, que mientras tanto queda vieja/sin uso.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppHeaderTitle(section: 'A continuación')),
      body: AnimatedBuilder(
        animation: AutomixEngine.instance,
        builder: (context, _) {
          if (AutomixEngine.instance.status != AutomixStatus.idle) {
            final current = AutomixEngine.instance.currentSong;
            return ArtworkGradient(
              songId: current?.mediaStoreId,
              child: _AutomixQueueList(engine: AutomixEngine.instance),
            );
          }
          return ArtworkBackdrop(
            mediaItems: sl<AudioHandler>().mediaItem,
            child: const _NormalQueueList(),
          );
        },
      ),
    );
  }
}

class _NormalQueueList extends StatefulWidget {
  const _NormalQueueList();

  @override
  State<_NormalQueueList> createState() => _NormalQueueListState();
}

class _NormalQueueListState extends State<_NormalQueueList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handler = sl<AudioHandler>();
    final queueHandler = handler as QueueCapableHandler;

    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      builder: (context, queueSnapshot) {
        final items = queueSnapshot.data ?? const [];
        if (items.isEmpty) {
          return const Center(child: Text('La cola está vacía'));
        }

        return StreamBuilder<MediaItem?>(
          stream: handler.mediaItem,
          builder: (context, currentSnapshot) {
            final currentId = currentSnapshot.data?.id;

            return AlphabetIndexedList(
              labels: items.map((i) => i.title).toList(),
              controller: _controller,
              listPadding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
              child: ReorderableListView.builder(
                scrollController: _controller,
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
                itemCount: items.length,
                onReorder: (oldIndex, newIndex) {
                  if (newIndex > oldIndex) newIndex -= 1;
                  queueHandler.moveQueueItem(oldIndex, newIndex);
                },
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isCurrent = item.id == currentId;

                  return Dismissible(
                    key: ValueKey('${item.id}_$index'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Icon(Icons.delete_outline,
                          color:
                              Theme.of(context).colorScheme.onErrorContainer),
                    ),
                    onDismissed: (_) => handler.removeQueueItemAt(index),
                    child: ListTile(
                      tileColor: isCurrent
                          ? Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                          : null,
                      leading: MediaArtwork.hasArtwork(item)
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: MediaArtwork(item: item, size: 44),
                            )
                          : const Icon(Icons.music_note),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w500,
                          color: isCurrent
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                      subtitle: Text(
                        item.artist ?? 'Desconocido',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isCurrent
                          ? Icon(Icons.graphic_eq,
                              color: Theme.of(context).colorScheme.primary)
                          : const Icon(Icons.drag_handle),
                      onTap: () async {
                        await handler.skipToQueueItem(index);
                        await handler.play();
                      },
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// Misma cola que se ve en la pantalla del Mezclador automático (canción
/// actual + "Siguen", reordenable), para no tener que salir de
/// "Reproduciendo" y volver al Automix solo para ver o reordenar la lista.
class _AutomixQueueList extends StatefulWidget {
  const _AutomixQueueList({required this.engine});

  final AutomixEngine engine;

  @override
  State<_AutomixQueueList> createState() => _AutomixQueueListState();
}

class _AutomixQueueListState extends State<_AutomixQueueList> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final current = engine.currentSong;
    final upcoming = engine.upcomingQueue;
    final theme = Theme.of(context);

    if (current == null) {
      return const Center(child: Text('La cola está vacía'));
    }

    return AlphabetIndexedList(
      labels: [current.title, ...upcoming.map((s) => s.title)],
      controller: _controller,
      listPadding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
      child: ReorderableListView.builder(
        scrollController: _controller,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 116),
        itemCount: upcoming.length + 1,
        onReorder: (oldIndex, newIndex) {
          // La posición 0 es la canción actual, no reordenable: se traduce
          // a índices de [upcoming] (que arranca en 1 acá) antes de llamar.
          if (oldIndex == 0) return;
          var from = oldIndex - 1;
          var to = newIndex - 1;
          if (to > from) to -= 1;
          engine.reorderUpcoming(from, to);
        },
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListTile(
              key: const ValueKey('automix_current'),
              tileColor: theme.colorScheme.surfaceContainerHighest,
              leading: const Icon(Icons.graphic_eq),
              title: Text(
                current.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
              subtitle: Text(
                current.artist ?? 'Desconocido',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing:
                  Icon(Icons.graphic_eq, color: theme.colorScheme.primary),
            );
          }

          final song = upcoming[index - 1];
          return ListTile(
            key: ValueKey('${song.mediaStoreId}_$index'),
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Text('$index'),
            ),
            title:
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: song.artist != null
                ? Text(song.artist!,
                    maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
            trailing: const Icon(Icons.drag_handle),
          );
        },
      ),
    );
  }
}
