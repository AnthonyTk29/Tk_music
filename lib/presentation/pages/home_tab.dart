import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/quick_access_grid.dart';

/// Pestaña "Principal": accesos directos a lo último reproducido.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: QuickAccessSection()),
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyHint(),
        ),
      ],
    );
  }
}

/// Se ve debajo de los accesos directos (o solo, si todavía no hay ninguno)
/// para que la pestaña principal no quede vacía a simple vista.
class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasShortcuts = AppProviders.songOf(context).songs.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note_rounded,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              hasShortcuts
                  ? 'Reproduce algo para verlo aquí como acceso directo'
                  : 'Todavía no hay música en tu biblioteca',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
