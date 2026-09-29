import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';

import 'app_error_code.dart';
import 'app_exception.dart';
import 'error_alert_dialog.dart';

/// Middleware central de errores: un único lugar por el que pasa cualquier
/// [AppException] que alguien tiró (o cualquier excepción cruda que se
/// haya escapado sin traducir), venga de donde venga — un `throw` puntual
/// en un servicio, o algo que nadie atrapó y llegó hasta acá por
/// FlutterError.onError/PlatformDispatcher.onError en main.dart.
///
/// Hace dos cosas siempre, sin que quien tira la excepción tenga que
/// acordarse:
///  1. La registra — consola + Crashlytics (con el mensaje TÉCNICO, nunca
///     el que ve el usuario), para poder ver patrones reales de uso en vez
///     de depender de que alguien mande una captura de pantalla.
///  2. Muestra la pantalla de alerta (ErrorAlertDialog) con el mensaje
///     para el USUARIO, con ícono/color según la severidad del código.
///
/// Usa [navigatorKey] en vez de pedir un BuildContext: así también lo
/// pueden llamar servicios/motores (PartySyncEngine, AutomixEngine, etc.)
/// que no tienen ningún widget a mano.
class ErrorReporter {
  ErrorReporter._();
  static final ErrorReporter instance = ErrorReporter._();

  final navigatorKey = GlobalKey<NavigatorState>();
  bool _dialogShowing = false;

  /// Lo prende main.dart solo si Firebase arrancó bien y la plataforma
  /// tiene Crashlytics (Android). En desktop Crashlytics no existe: sin
  /// este corte, cada error intentaba mandarse igual, ese intento fallaba
  /// de forma asíncrona, y el fallo volvía a entrar acá por la zona global
  /// — un bucle.
  bool crashlyticsEnabled = false;

  /// Punto de entrada único para un error puntual y accionable — lo
  /// registra Y le muestra la pantalla de alerta a la persona. [error]
  /// puede ser una [AppException] (caso ideal: ya tiene código + los dos
  /// mensajes) o cualquier otra cosa (se envuelve como
  /// [AppErrorCode.unknown] con un mensaje genérico, así ningún error
  /// queda sin registrar ni sin avisar solo por no haber sido traducido
  /// todavía a un código específico).
  void report(Object error, [StackTrace? stackTrace]) {
    _log(error, stackTrace);
    _presentToUser(_asException(error));
  }

  /// Igual que [report] pero sin mostrar nada — solo registra. Para
  /// operaciones en lote (p. ej. importar varios audios de WhatsApp) donde
  /// interrumpir con un diálogo por cada fallo sería peor experiencia que
  /// juntarlos y avisar una sola vez al final con el propio resumen de la
  /// pantalla que hace la operación.
  void log(Object error, [StackTrace? stackTrace]) => _log(error, stackTrace);

  AppException _asException(Object error) => error is AppException
      ? error
      : AppException(
          AppErrorCode.unknown,
          userMessage: 'Ocurrió un problema inesperado.',
          technicalMessage: error.toString(),
        );

  void _log(Object error, StackTrace? stackTrace) {
    final exception = _asException(error);
    debugPrint('${exception.code.name}: ${exception.technicalMessage}');

    if (!crashlyticsEnabled) return;
    // Un reporter de errores que a su vez puede tirar una excepción es el
    // peor tipo de falla: se atrapa tanto el fallo inmediato como el
    // asíncrono, para que nunca vuelva a entrar al manejador global.
    try {
      FirebaseCrashlytics.instance
          .recordError(exception, stackTrace,
              reason: exception.code.name, fatal: false)
          .catchError((Object e) =>
              debugPrint('No se pudo reportar a Crashlytics: $e'));
    } catch (e) {
      debugPrint('No se pudo reportar a Crashlytics: $e');
    }
  }

  void _presentToUser(AppException exception) {
    final context = navigatorKey.currentContext;
    // Puede no haber ninguna pantalla montada todavía (arrancando la app) o
    // ya estarse mostrando otra alerta — en los dos casos ya quedó
    // registrado arriba, que es lo que importa para poder diagnosticarlo
    // después aunque nadie lo haya visto en el momento.
    if (context == null || _dialogShowing) return;

    _dialogShowing = true;
    ErrorAlertDialog.show(context, exception).whenComplete(() {
      _dialogShowing = false;
    });
  }
}
