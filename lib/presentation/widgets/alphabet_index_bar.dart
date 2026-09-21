import 'package:flutter/material.dart';

const _letters = [
  '#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'Ñ', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

/// Franja lateral A-Z para saltar rápido en una lista larga (como en
/// Contactos): tocar o arrastrar el dedo por las letras salta a la primera
/// canción que empieza con esa letra. Se oculta sola si la lista es corta
/// (no aporta nada y solo estorba).
class AlphabetIndexBar extends StatefulWidget {
  const AlphabetIndexBar({
    super.key,
    required this.labels,
    required this.controller,
    this.itemExtent = 64,
    this.padding = EdgeInsets.zero,
    this.minItemsToShow = 15,
  });

  /// Una etiqueta (normalmente el título) por cada ítem de la lista, en el
  /// mismo orden en que aparecen — se usa su primera letra para saber a
  /// qué altura saltar.
  final List<String> labels;
  final ScrollController controller;

  /// Alto de fila usado solo como respaldo antes de que la lista termine su
  /// primer layout (todavía no hay `maxScrollExtent` real que medir). Una
  /// vez que la lista tiene clientes, el alto real de fila se recalcula a
  /// partir de las métricas de scroll — así se ajusta solo a la fuente,
  /// densidad y tamaño de texto de cada dispositivo en vez de asumir un
  /// valor fijo que se desalinea en pantallas distintas.
  final double itemExtent;

  /// El mismo padding vertical que tiene el `ListView`/`ScrollView` que
  /// envuelve, para poder calcular la altura real de cada fila a partir de
  /// `maxScrollExtent`.
  final EdgeInsets padding;
  final int minItemsToShow;

  @override
  State<AlphabetIndexBar> createState() => _AlphabetIndexBarState();
}

class _AlphabetIndexBarState extends State<AlphabetIndexBar> {
  String? _activeLetter;

  Map<String, int> _firstIndexByLetter() {
    final map = <String, int>{};
    for (var i = 0; i < widget.labels.length; i++) {
      final letter = _letterFor(widget.labels[i]);
      map.putIfAbsent(letter, () => i);
    }
    return map;
  }

  String _letterFor(String label) {
    if (label.isEmpty) return '#';
    final ch = label[0].toUpperCase();
    return RegExp(r'[A-ZÑ]').hasMatch(ch) ? ch : '#';
  }

  void _jumpTo(String letter, Map<String, int> available) {
    final index = available[letter];
    if (index == null || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final target = (widget.padding.top + index * _realItemHeight())
        .clamp(0.0, position.maxScrollExtent);
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    setState(() => _activeLetter = letter);
  }

  /// Deriva el alto real de cada fila a partir de las métricas de scroll ya
  /// calculadas por Flutter (extensión total de contenido = padding +
  /// cantidad de ítems * alto de fila), en vez de asumir un valor fijo —
  /// así funciona igual sin importar el tamaño de fuente, la densidad de
  /// pantalla o el diseño de cada fila en cualquier dispositivo.
  double _realItemHeight() {
    final itemCount = widget.labels.length;
    if (itemCount == 0 || !widget.controller.hasClients) {
      return widget.itemExtent;
    }
    final position = widget.controller.position;
    final contentExtent = position.maxScrollExtent + position.viewportDimension;
    final rowsExtent = contentExtent - widget.padding.vertical;
    if (rowsExtent <= 0) return widget.itemExtent;
    return rowsExtent / itemCount;
  }

  void _handleTouch(
      Offset localPosition, double height, Map<String, int> available) {
    final index = (localPosition.dy / height * _letters.length)
        .floor()
        .clamp(0, _letters.length - 1);
    final letter = _letters[index];
    if (available.containsKey(letter)) {
      _jumpTo(letter, available);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.labels.length < widget.minItemsToShow) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final available = _firstIndexByLetter();

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) => _handleTouch(
              details.localPosition, constraints.maxHeight, available),
          onVerticalDragEnd: (_) => setState(() => _activeLetter = null),
          onTapDown: (details) => _handleTouch(
              details.localPosition, constraints.maxHeight, available),
          onTapUp: (_) => setState(() => _activeLetter = null),
          child: Container(
            width: 18,
            color: Colors.transparent,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final letter in _letters)
                  Text(
                    letter,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: _activeLetter == letter
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: available.containsKey(letter)
                          ? (_activeLetter == letter
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant)
                          : theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.25),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Envuelve una lista con la franja [AlphabetIndexBar] pegada al borde
/// derecho, dejándole al [child] un padding a la derecha para que no quede
/// tapado. [labels] tiene que estar en el mismo orden que los ítems que
/// renderiza [child] con [controller].
class AlphabetIndexedList extends StatelessWidget {
  const AlphabetIndexedList({
    super.key,
    required this.labels,
    required this.controller,
    required this.child,
    this.itemExtent = 64,
    this.listPadding = EdgeInsets.zero,
  });

  final List<String> labels;
  final ScrollController controller;
  final Widget child;
  final double itemExtent;

  /// El padding vertical exacto del `ListView`/`ReorderableListView` que
  /// envuelve [child] — se lo pasa a [AlphabetIndexBar] para que calcule el
  /// alto real de fila y salte al lugar correcto en cualquier dispositivo.
  final EdgeInsets listPadding;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 20),
          child: child,
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: AlphabetIndexBar(
            labels: labels,
            controller: controller,
            itemExtent: itemExtent,
            padding: listPadding,
          ),
        ),
      ],
    );
  }
}
