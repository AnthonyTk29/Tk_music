import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/app_providers.dart';

class RequestPermissionScreen extends StatelessWidget {
  const RequestPermissionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock,
                  color: Theme.of(context).colorScheme.onSurface, size: 80),
              const SizedBox(height: 24),
              Text('Permiso requerido',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                'Para acceder a tu música, necesitamos permiso de almacenamiento o audio.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
