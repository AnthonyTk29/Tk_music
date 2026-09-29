import 'dart:async';

import 'package:flutter/material.dart';

/// Sigue las pantallas abiertas en el navegador principal para armar las
/// migas de pan ("Biblioteca › Artistas › Bad Bunny") en el encabezado de
/// cada pantalla. Cada pantalla pone su propio nombre con
/// [BreadcrumbObserver.setLabel] (lo hace `AppHeaderTitle`).
class BreadcrumbObserver extends NavigatorObserver with ChangeNotifier {
  final _routes = <Route<dynamic>>[];
  final _labels = Expando<String>('breadcrumb');

  /// Pantallas abiertas, de la de abajo (inicio) a la de arriba.
  List<Route<dynamic>> get routes => List.unmodifiable(_routes);

  String? labelOf(Route<dynamic> route) => _labels[route];

  void setLabel(Route<dynamic> route, String label) {
    _labels[route] = label;
  }

  /// Las migas hasta [route] (sin incluirla): las pantallas de abajo que
  /// tienen nombre. Vacío si [route] no es una pantalla de este navegador.
  List<(String label, Route<dynamic> route)> trailBelow(Route<dynamic> route) {
    final index = _routes.indexOf(route);
    if (index <= 0) return const [];
    return [
      for (final below in _routes.take(index))
        if (_labels[below] case final label?) (label, below),
    ];
  }

  // Solo pantallas: diálogos, menús y hojas de abajo no son migas.
  bool _tracks(Route<dynamic>? route) => route is PageRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_tracks(route)) return;
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_routes.remove(route)) _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_routes.remove(route)) _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (_tracks(newRoute)) {
        _routes[index] = newRoute!;
      } else {
        _routes.removeAt(index);
      }
    } else if (_tracks(newRoute)) {
      _routes.add(newRoute!);
    }
    _changed();
  }

  // El navegador avisa en medio de la construcción de la primera pantalla:
  // se avisa a los que escuchan después, no ahí mismo.
  void _changed() => scheduleMicrotask(notifyListeners);
}

/// El del navegador principal de la app.
final breadcrumbs = BreadcrumbObserver();

/// La fila de migas: las anteriores se tocan para volver ahí; la última
/// (la pantalla actual) queda resaltada. Si no entra, se desliza y se ve
/// siempre el final.
class BreadcrumbTrail extends StatelessWidget {
  const BreadcrumbTrail({
    super.key,
    required this.items,
    this.fontSize = 12,
  });

  /// (nombre, qué hacer al tocarla). La primera lleva el ícono de inicio.
  final List<(String label, VoidCallback? onTap)> items;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            Icon(Icons.chevron_right, size: fontSize + 4, color: muted),
          _Crumb(
            label: items[i].$1,
            onTap: i == items.length - 1 ? null : items[i].$2,
            first: i == 0,
            current: i == items.length - 1,
            fontSize: fontSize,
          ),
        ],
      ],
    );
    // reverse: si no entra, se ve siempre el final (la pantalla actual);
    // si entra, queda pegada a la izquierda.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
          ),
          child: Align(alignment: Alignment.centerLeft, child: row),
        ),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.label,
    required this.onTap,
    required this.first,
    required this.current,
    required this.fontSize,
  });

  final String label;
  final VoidCallback? onTap;
  final bool first;
  final bool current;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = current
        ? theme.colorScheme.onSurface
        : onTap == null
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.primary;
    final text = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (first) ...[
          Icon(Icons.home_outlined, size: fontSize + 2, color: color),
          const SizedBox(width: 3),
        ],
        Text(
          label,
          maxLines: 1,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: fontSize,
            height: 1.2,
            color: color,
            fontWeight: current ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: text,
      );
    }
    return Tooltip(
      message: 'Volver a $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: text,
        ),
      ),
    );
  }
}
