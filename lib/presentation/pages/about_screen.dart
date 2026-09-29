import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_logo.dart';

/// Datos de la app y contacto del desarrollador.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _developerName = 'Ing. Anthony Loor';
  static const _developerEmail = 'aloor0781@gmail.com';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const AppHeaderTitle(section: 'Acerca de')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Column(
              children: [
                const AppLogo(size: 72),
                const SizedBox(height: 12),
                Text('TK Music', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  'Versión 1.0.0',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.person_outline),
            title: Text('Desarrollado por'),
            subtitle: Text(_developerName),
          ),
          ListTile(
            leading: const Icon(Icons.email_outlined),
            title: const Text('Contacto'),
            subtitle: const Text(_developerEmail),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _sendEmail(context),
          ),
        ],
      ),
    );
  }

  Future<void> _sendEmail(BuildContext context) async {
    final uri = Uri(
      scheme: 'mailto',
      path: _developerEmail,
      query: 'subject=${Uri.encodeComponent('TK Music')}',
    );
    final launched = await launchUrl(uri);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('No se pudo abrir el correo. Escribí a $_developerEmail'),
        ),
      );
    }
  }
}
