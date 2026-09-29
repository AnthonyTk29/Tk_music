import 'package:flutter/material.dart';

/// Para pantallas armadas como una columna que ocupa todo el alto (con
/// `Spacer`s para centrar y repartir): si entra, se ve igual que siempre; si
/// la ventana es más baja que el contenido (desktop con la ventana chica,
/// teléfonos chicos o apaisados), se desplaza en vez de desbordar.
class ScrollableFill extends StatelessWidget {
  const ScrollableFill({super.key, required this.child});

  /// Normalmente una `Column` con `Spacer`s.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(child: child),
        ),
      ),
    );
  }
}
