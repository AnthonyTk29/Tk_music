/// Qué tan grave es el problema — determina el ícono/color del diálogo de
/// alerta y si vale la pena mandarlo a Crashlytics como algo más que un
/// aviso menor.
enum AppErrorSeverity { warning, error }

/// De qué parte de la app viene el problema — agrupa los reportes en
/// Crashlytics y define el ícono del diálogo.
enum AppErrorCategory {
  permission,
  bluetooth,
  network,
  playback,
  storage,
  analysis,
  persistence,
  library,
  unknown,
}

/// Un código por cada situación de error que la app puede reconocer.
/// [category] y [severity] van pegados al código a propósito: quien tira la
/// excepción solo elige QUÉ pasó (el código), no CÓMO se ve la alerta — así
/// se evita que la misma clase de error termine con colores distintos según
/// quién la haya lanzado.
enum AppErrorCode {
  // ---- Bluetooth ----
  btNoPermission(AppErrorCategory.bluetooth, AppErrorSeverity.warning),
  btNoAdapter(AppErrorCategory.bluetooth, AppErrorSeverity.error),
  btNotConnected(AppErrorCategory.bluetooth, AppErrorSeverity.warning),
  btConnectFailed(AppErrorCategory.bluetooth, AppErrorSeverity.error),
  btHostFailed(AppErrorCategory.bluetooth, AppErrorSeverity.error),
  btSendFailed(AppErrorCategory.bluetooth, AppErrorSeverity.warning),
  btCapacityUnavailable(AppErrorCategory.bluetooth, AppErrorSeverity.warning),

  // ---- Wi-Fi (misma sesión de sincronizar, por la red) ----
  wifiHostFailed(AppErrorCategory.network, AppErrorSeverity.error),
  wifiConnectFailed(AppErrorCategory.network, AppErrorSeverity.error),

  // ---- Almacenamiento / SAF / WhatsApp ----
  storageSourceNotFound(AppErrorCategory.storage, AppErrorSeverity.error),
  storageImportFailed(AppErrorCategory.storage, AppErrorSeverity.error),
  storagePickFailed(AppErrorCategory.storage, AppErrorSeverity.warning),
  storageBusy(AppErrorCategory.storage, AppErrorSeverity.warning),
  storagePermissionDenied(
      AppErrorCategory.permission, AppErrorSeverity.warning),

  // ---- Análisis nativo (onda / espectro / loudness) ----
  analysisFailed(AppErrorCategory.analysis, AppErrorSeverity.warning),
  spectrumUnavailable(AppErrorCategory.analysis, AppErrorSeverity.warning),

  // ---- Reproducción ----
  playbackInitFailed(AppErrorCategory.playback, AppErrorSeverity.error),
  playbackLoadFailed(AppErrorCategory.playback, AppErrorSeverity.warning),
  equalizerUnavailable(AppErrorCategory.playback, AppErrorSeverity.warning),

  // ---- Persistencia (SharedPreferences: favoritos, playlists, perfiles) ----
  persistenceSaveFailed(AppErrorCategory.persistence, AppErrorSeverity.warning),

  // ---- Biblioteca / permisos de medios ----
  libraryLoadFailed(AppErrorCategory.library, AppErrorSeverity.error),
  libraryPermissionDenied(
      AppErrorCategory.permission, AppErrorSeverity.warning),

  // ---- Genérico: cualquier excepción no traducida a propósito cae acá,
  // nunca se pierde un error por no tener código específico todavía. ----
  unknown(AppErrorCategory.unknown, AppErrorSeverity.error);

  const AppErrorCode(this.category, this.severity);

  final AppErrorCategory category;
  final AppErrorSeverity severity;
}
