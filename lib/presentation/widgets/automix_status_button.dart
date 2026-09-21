import 'package:flutter/material.dart';

import 'package:tk_music/presentation/pages/automix_screen.dart';
import 'package:tk_music/services/automix_engine.dart';

/// Botón flotante con una "A" que aparece en las pantallas principales
/// mientras el Mezclador automático sigue sonando de fondo (podés haber
/// salido de su pantalla, sigue mezclando solo). Parpadea para que se note
/// que está en modo automático; tocarlo vuelve a esa pantalla.
class AutomixStatusButton extends StatefulWidget {
  const AutomixStatusButton({super.key});

  @override
  State<AutomixStatusButton> createState() => _AutomixStatusButtonState();
}

class _AutomixStatusButtonState extends State<AutomixStatusButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AutomixEngine.instance,
      builder: (context, _) {
        if (AutomixEngine.instance.status == AutomixStatus.idle) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);

        return FadeTransition(
          opacity: Tween(begin: 0.45, end: 1.0).animate(_controller),
          child: Material(
            color: theme.colorScheme.primary,
            shape: const CircleBorder(),
            elevation: 6,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AutomixScreen()),
              ),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Text(
                    'A',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
