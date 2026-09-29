import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';

/// Pide el permiso de audio/almacenamiento (solo Android: en desktop la
/// biblioteca lee todos los discos y no hay permiso que pedir).
class RequestPermissionScreen extends StatelessWidget {
  const RequestPermissionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const AppHeaderTitle(large: true),
              const SizedBox(height: 40),
              Icon(Icons.lock, color: theme.colorScheme.onSurface, size: 80),
              const SizedBox(height: 24),
              Text('Permiso requerido', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                'Para acceder a tu música, necesitamos permiso de '
                'almacenamiento o audio.',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              FilledButton.icon(
                icon: const Icon(Icons.vpn_key),
                label: const Text('Solicitar permiso'),
                onPressed: () async {
                  final permission = AppProviders.permissionOf(context);
                  final songs = AppProviders.songOf(context);
                  await permission.checkPermission();
                  if (context.mounted && permission.granted == true) {
                    songs.loadSongs();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
