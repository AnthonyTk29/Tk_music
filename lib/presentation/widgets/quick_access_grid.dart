import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/utils/playback_actions.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/services/recent_songs_store.dart';

const _maxTotalShortcuts = 24;
const _itemsPerPage = 9;
const _crossAxisCount = 3;

/// Cuadrícula de "Accesos directos": las últimas canciones reproducidas,
/// para volver a ponerlas con un solo toque (al estilo YouTube Music).
/// Se pagina de a 9 (3x3) cuando hay más; se oculta sola si todavía no se
/// reprodujo nada en este dispositivo.
class QuickAccessSection extends StatelessWidget {
  const QuickAccessSection({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isAudioAvailable) return const SizedBox.shrink();

    final songProvider = AppProviders.songOf(context);

    // Se reconsulta cada vez que cambia la canción actual, así los accesos
    // directos se mantienen al día sin necesitar un provider aparte.
    return StreamBuilder<MediaItem?>(
      stream: sl<AudioHandler>().mediaItem,
      builder: (context, _) {
        return FutureBuilder<List<int>>(
          future: RecentSongsStore().getRecentIds(),
          builder: (context, snapshot) {
            final ids = snapshot.data;
            if (ids == null || ids.isEmpty) return const SizedBox.shrink();

            final byId = {
              for (final s in songProvider.songs) s.mediaStoreId: s,
            };
            final recent = ids
                .map((id) => byId[id])
                .whereType<Song>()
                .take(_maxTotalShortcuts)
                .toList();
            if (recent.isEmpty) return const SizedBox.shrink();

            return _QuickAccessGrid(songs: recent);
          },
        );
      },
    );
  }
}

class _QuickAccessGrid extends StatefulWidget {
  const _QuickAccessGrid({required this.songs});

  final List<Song> songs;

  @override
  State<_QuickAccessGrid> createState() => _QuickAccessGridState();
}

class _QuickAccessGridState extends State<_QuickAccessGrid> {
  final _controller = PageController();
  int _page = 0;

  int get _pageCount => (widget.songs.length / _itemsPerPage).ceil();

  /// Filas que ocupa una página concreta: 1 si tiene hasta 3 accesos, 2 hasta
  /// 6, 3 con 7 a 9. Así la sección crece de a poco en vez de reservar
  /// siempre el alto máximo.
  int _rowsForPage(int page) {
    final start = page * _itemsPerPage;
    final count = math.min(_itemsPerPage, widget.songs.length - start);
    return (count / _crossAxisCount).ceil().clamp(1, 3);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QuickAccessGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si la lista se achica (p. ej. se depuró el historial) y la página
    // actual ya no existe, se vuelve a la primera para no quedar en blanco.
    if (_page >= _pageCount) {
      _page = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pageCount = _pageCount;
    final currentPage = _page.clamp(0, pageCount - 1);
    final rows = _rowsForPage(currentPage);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Accesos directos', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final tileSize =
                  (constraints.maxWidth - spacing * (_crossAxisCount - 1)) /
                      _crossAxisCount;
              final gridHeight = rows * tileSize + (rows - 1) * spacing;

              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                height: gridHeight,
                child: PageView.builder(
                  controller: _controller,
                  itemCount: pageCount,
                  onPageChanged: (page) => setState(() => _page = page),
                  itemBuilder: (context, pageIndex) {
                    final start = pageIndex * _itemsPerPage;
                    final end = math.min(
                        start + _itemsPerPage, widget.songs.length);
                    final pageSongs = widget.songs.sublist(start, end);

                    return GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _crossAxisCount,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        childAspectRatio: 1,
                      ),
                      itemCount: pageSongs.length,
                      itemBuilder: (context, index) => _ShortcutTile(
                        song: pageSongs[index],
                        size: tileSize,
                      ),
                    );
                  },
                ),
              );
            },
          ),
          if (pageCount > 1) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(pageCount, (i) {
                final active = i == currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({required this.song, required this.size});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => playFromLibrary(AppProviders.songOf(context), song),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              SongArtwork(
                songId: song.mediaStoreId,
                size: size,
                borderRadius: 0,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.75),
                    ],
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Text(
                  song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
