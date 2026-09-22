import 'package:flutter/material.dart';

import 'app_error_code.dart';
import 'app_exception.dart';

/// La pantalla de alerta que le muestra el error a la persona — un diálogo
/// modal, no un SnackBar de paso, porque un error merece que alguien lo
/// vea y lo cierre a propósito. El color/ícono salen de
/// [AppException.severity]: advertencia (algo no funcionó pero la app
/// sigue andando bien) vs error (lo que estaba haciendo se interrumpió).
class ErrorAlertDialog extends StatelessWidget {
  const ErrorAlertDialog({super.key, required this.exception});

  final AppException exception;

  static Future<void> show(BuildContext context, AppException exception) {
    return showDialog<void>(
      context: context,
      builder: (_) => ErrorAlertDialog(exception: exception),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWarning = exception.severity == AppErrorSeverity.warning;
    final accent = isWarning ? const Color(0xFFE0972A) : const Color(0xFFE0453A);

    return AlertDialog(
      icon: Icon(
        isWarning ? Icons.warning_amber_rounded : Icons.error_outline,
        color: accent,
        size: 36,
      ),
      title: Text(
        isWarning ? 'Advertencia' : 'Error',
        textAlign: TextAlign.center,
        style: TextStyle(color: accent, fontWeight: FontWeight.w700),
      ),
      content: Text(exception.userMessage, textAlign: TextAlign.center),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Entendido'),
        ),
      ],
    );
  }
}
