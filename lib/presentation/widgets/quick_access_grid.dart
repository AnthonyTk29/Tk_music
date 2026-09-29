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
const _spacing = 8.0;

/// Tamaño máximo de cada acceso: en pantallas anchas (desktop, tablets)
/// entran más columnas en vez de agrandar las carátulas.
const _maxTileSize = 180.0;

/// Columnas y filas por página según el ancho: 3×3 en un teléfono; en
/// pantallas anchas, las columnas que entren con carátulas de hasta
/// [_maxTileSize] y 2 filas.
({int columns, int rows}) quickAccessLayout(double width) {
  final columns =
      math.max(3, ((width + _spacing) / (_maxTileSize + _spacing)).ceil());
  return (columns: columns, rows: columns > 3 ? 2 : 3);
}

/// Cuadrícula de "Accesos directos": las últimas canciones reproducidas,
/// para volver a ponerlas con un solo toque (al estilo YouTube Music).
/// Se pagina (de a 9 en un teléfono, ver [quickAccessLayout]) cuando hay
/// más; se oculta sola si todavía no se reprodujo nada en este dispositivo.
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

  int _pageCount(int perPage) => (widget.songs.length / perPage).ceil();

  /// Filas que ocupa una página concreta (en un teléfono: 1 si tiene hasta
  /// 3 accesos, 2 hasta 6, 3 con 7 a 9). Así la sección crece de a poco en
  /// vez de reservar siempre el alto máximo.
  int _rowsForPage(int page, int columns, int maxRows) {
    final perPage = columns * maxRows;
    final start = page * perPage;
    final count = math.min(perPage, widget.songs.length - start);
    return (count / columns).ceil().clamp(1, maxRows);
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
    // (Se revisa con el mínimo de accesos por página, el de un teléfono.)
    if (_page >= _pageCount(9)) {
      _page = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _buildForWidth(context, constraints.maxWidth),
      ),
    );
  }

  Widget _buildForWidth(BuildContext context, double width) {
    final theme = Theme.of(context);
    final layout = quickAccessLayout(width);
    final columns = layout.columns;
    final perPage = columns * layout.rows;
    final pageCount = _pageCount(perPage);
    final currentPage = _page.clamp(0, pageCount - 1);
    final rows = _rowsForPage(currentPage, columns, layout.rows);
    final tileSize = (width - _spacing * (columns - 1)) / columns;
    final gridHeight = rows * tileSize + (rows - 1) * _spacing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Accesos directos', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          height: gridHeight,
          child: PageView.builder(
            controller: _controller,
            itemCount: pageCount,
            onPageChanged: (page) => setState(() => _page = page),
            itemBuilder: (context, pageIndex) {
              final start = pageIndex * perPage;
              final end = math.min(start + perPage, widget.songs.length);
              final pageSongs = widget.songs.sublist(start, end);

              return GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: _spacing,
                  crossAxisSpacing: _spacing,
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
