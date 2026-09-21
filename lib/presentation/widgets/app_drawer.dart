import 'package:flutter/material.dart';

import 'package:tk_music/presentation/pages/about_screen.dart';
import 'package:tk_music/presentation/pages/automix_screen.dart';
import 'package:tk_music/presentation/pages/equalizer_screen.dart';
import 'package:tk_music/presentation/pages/external_storage_screen.dart';
import 'package:tk_music/presentation/pages/help_screen.dart';
import 'package:tk_music/presentation/pages/party_sync_screen.dart';
import 'package:tk_music/presentation/pages/playlists_tab.dart';
import 'package:tk_music/presentation/pages/whatsapp_import_screen.dart';
import 'package:tk_music/presentation/widgets/app_logo.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';

/// Menú lateral con las secciones que no entran cómodas en la barra
/// inferior (Playlists, fuentes de música externas). La navegación
/// principal (Principal/Buscar/Biblioteca/Favoritos) se queda abajo porque
/// son las pestañas de uso diario.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = AppProviders.profileOf(context).activeProfile;
    final theme = Theme.of(context);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  const AppLogo(size: 34),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('TK Music', style: theme.textTheme.titleMedium),
                        if (profile != null)
                          Text(
                            profile.name,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.queue_music_outlined),
              title: const Text('Playlists'),
              onTap: () => _push(context, const PlaylistsTab()),
            ),
            ListTile(
              leading: const Icon(Icons.usb),
              title: const Text('Almacenamiento externo'),
              subtitle: const Text('Música de un pendrive (USB-OTG)'),
              onTap: () => _push(context, const ExternalStorageScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('Importar de WhatsApp'),
              subtitle: const Text('Sumar audios recibidos a tu biblioteca'),
              onTap: () => _push(context, const WhatsAppImportScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('Mezclador automático'),
              subtitle: const Text('Automix con crossfade y control de volumen'),
              onTap: () => _push(context, const AutomixScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.bluetooth_audio),
              title: const Text('Sincronizar con otro teléfono'),
              subtitle: const Text('Misma canción a la vez por Bluetooth'),
              onTap: () => _push(context, const PartySyncScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.equalizer),
              title: const Text('Ecualizador'),
              subtitle: const Text('Graves, medios y agudos de lo que suena'),
              onTap: () => _push(context, const EqualizerScreen()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Guía de uso'),
              onTap: () => _push(context, const HelpScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Acerca de'),
              onTap: () => _push(context, const AboutScreen()),
            ),
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    // Playlists no trae su propio Scaffold/AppBar (vive embebida en la
    // pestaña de siempre), así que se le agrega acá al navegarla desde el
    // drawer.
    final wrapped = screen is PlaylistsTab
        ? Scaffold(
            appBar: AppBar(title: const Text('Playlists')),
            body: screen,
          )
        : screen;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => wrapped),
    );
  }
}
