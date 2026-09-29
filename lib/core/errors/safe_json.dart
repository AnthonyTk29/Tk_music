import 'dart:convert';

import 'error_reporter.dart';

/// Decodifica y parsea JSON guardado en SharedPreferences de forma segura:
/// si [raw] es `null`, está corrupto, o quedó de un esquema viejo que ya no
/// calza con lo que [parse] espera, devuelve [fallback] en vez de dejar
/// pasar la excepción — favoritos, playlists y perfiles se leen en las
/// primeras pantallas que se abren, así que un dato corrupto ahí no puede
/// tirar abajo el arranque entero de la app.
///
/// Se registra igual (sin mostrarle nada a la persona: perder un dato
/// guardado corrupto no amerita interrumpirla con una alerta, y no hay
/// nada que pueda hacer al respecto) para poder ver en Crashlytics si
/// algún cambio de esquema futuro rompe datos de gente real.
T readJson<T>(
  String? raw,
  T Function(dynamic decoded) parse, {
  required T fallback,
  required String context,
}) {
  if (raw == null) return fallback;
  try {
    return parse(jsonDecode(raw));
  } catch (e, stack) {
    ErrorReporter.instance
        .log(Exception('JSON corrupto en $context: $e'), stack);
    return fallback;
  }
}
