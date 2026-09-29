import 'package:flutter/material.dart';

import 'package:tk_music/presentation/navigation/breadcrumbs.dart';
import 'package:tk_music/presentation/widgets/app_logo.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';

/// Logo + nombre de la app, para usar como `title` de los AppBar de todas
/// las pantallas. Con [section], el nombre de la pantalla va debajo en
/// chico ("Letra", "Ajustes"…). [large] es para pantallas sin barra
/// (elegir perfil, primer uso).
///
/// Si la pantalla se abrió encima de otras, en vez del nombre solo se ven
/// las migas de pan ("Inicio › Biblioteca › Artistas › Bad Bunny"): cada
/// una se toca para volver a esa pantalla.
class AppHeaderTitle extends StatelessWidget {
  const AppHeaderTitle({
    super.key,
    this.section,
    this.large = false,
    this.crumb,
    this.parents = const [],
  });

  final String? section;
  final bool large;

  /// Cómo se llama esta pantalla en las migas de las que se abran encima
  /// (por defecto, [section]).
  final String? crumb;

  /// Migas intermedias que no son pantallas propias (p. ej. "Biblioteca" y
  /// "Artistas" antes de un artista): tocarlas vuelve a la pantalla de
  /// atrás, que es donde están.
  final List<String> parents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = ModalRoute.of(context);
    final label = crumb ?? section;
    if (route != null && label != null && !large) {
      breadcrumbs.setLabel(route, label);
    }
    final brand = RichText(
      maxLines: 1,
      text: TextSpan(
        style: (large
                ? theme.textTheme.headlineMedium
                : section == null
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.titleMedium)
            ?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
          height: 1.15,
          color: theme.colorScheme.onSurface,
        ),
        children: [
          TextSpan(
            text: 'TK',
            style: TextStyle(color: theme.colorScheme.primary),
          ),
          const TextSpan(text: ' Music'),
        ],
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppLogo(size: large ? 52 : (section == null ? 30 : 28)),
        SizedBox(width: large ? 14 : 10),
        Flexible(
          child: section == null
              ? brand
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    brand,
                    ListenableBuilder(
                      listenable: breadcrumbs,
                      builder: (context, _) => _sectionOrTrail(context, route),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _sectionOrTrail(BuildContext context, ModalRoute<dynamic>? route) {
    final theme = Theme.of(context);
    final below = route == null
        ? const <(String, Route<dynamic>)>[]
        : breadcrumbs.trailBelow(route);
    if (below.isEmpty) {
      return Text(
        section!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.2,
        ),
      );
    }
    final navigator = Navigator.of(context);
    void backTo(Route<dynamic> target) =>
        navigator.popUntil((r) => r == target);
    final previous = below.last.$2;
    return BreadcrumbTrail(
      items: [
        for (final (label, target) in below) (label, () => backTo(target)),
        for (final parent in parents) (parent, () => backTo(previous)),
        (section!, null),
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
    final initial = (profile?.name.isNotEmpty ?? false)
        ? profile!.name[0].toUpperCase()
        : '?';

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
