import 'app_error_code.dart';

/// Excepción tipada de la app: en vez de atrapar y resolver el error ahí
/// mismo donde pasó, se arma esto con el código de qué pasó + los dos
/// mensajes (uno para mostrarle a la persona, otro para el log/Crashlytics)
/// y se deja subir sola hasta el único manejador global (ver
/// ErrorReporter + main.dart), que decide ícono/color según
/// [code].severity y la muestra en la pantalla de alerta. El código de
/// negocio ya no necesita su propio try/catch para cada cosa que puede
/// fallar — solo lo necesita el punto puntual donde se traduce una
/// excepción ajena (de un plugin, de una llamada nativa) a esto.
class AppException implements Exception {
  const AppException(
    this.code, {
    required this.userMessage,
    required this.technicalMessage,
  });

  final AppErrorCode code;

  /// Texto en español, listo para mostrar tal cual en la alerta.
  final String userMessage;

  /// Detalle técnico — va siempre al log/Crashlytics, nunca a la pantalla.
  final String technicalMessage;

  AppErrorSeverity get severity => code.severity;
  AppErrorCategory get category => code.category;

  @override
  String toString() => 'AppException(${code.name}): $technicalMessage';
}
