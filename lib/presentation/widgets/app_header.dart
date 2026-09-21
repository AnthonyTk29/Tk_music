import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/app_logo.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';

/// Logo + nombre de la app, para usar como `title` del AppBar principal.
class AppHeaderTitle extends StatelessWidget {
  const AppHeaderTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppLogo(size: 30),
        const SizedBox(width: 10),
        RichText(
          text: TextSpan(
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
            children: [
              TextSpan(
                text: 'TK',
                style: TextStyle(color: theme.colorScheme.primary),
              ),
              const TextSpan(text: ' Music'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Avatar circular con la inicial del perfil activo. Al tocarlo abre un
/// menú chico con el nombre y la opción de cerrar sesión, para no tener que
/// mantener un ícono de logout aparte en la barra.
class ProfileAvatarButton extends StatelessWidget {
  const ProfileAvatarButton({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = AppProviders.profileOf(context).activeProfile;
    final theme = Theme.of(context);
    final initial =
        (profile?.name.isNotEmpty ?? false) ? profile!.name[0].toUpperCase() : '?';

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showMenu(context),
        child: CircleAvatar(
          radius: 16,
          backgroundColor: theme.colorScheme.primary,
          child: Text(
            initial,
            style: TextStyle(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final profile = AppProviders.profileOf(context).activeProfile;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(profile?.name ?? 'Perfil'),
              enabled: false,
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                AppProviders.profileOf(context).logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}
