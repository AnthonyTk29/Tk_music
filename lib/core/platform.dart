import 'dart:io' show Platform;

/// `true` en Windows/Linux/macOS — para las varias ramas de código que
/// necesitan un camino distinto ahí (reproductor con media_kit en vez de
/// just_audio, biblioteca por carpeta elegida en vez de MediaStore, sin
/// notificación del sistema porque audio_service no tiene esa integración
/// armada fuera de Android/iOS).
bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Análisis nativo de audio (forma de onda, espectro, volumen para el
/// Automix): MainActivity.kt en Android y Media Foundation en Windows
/// (audio_analysis_plugin.cpp). En Linux/macOS todavía no hay.
bool get hasNativeAudioAnalysis => Platform.isAndroid || Platform.isWindows;

/// Tags, carátulas y controles multimedia del sistema armados a mano para
/// desktop (desktop_media_plugin.cpp / media_controls_plugin.cpp): por
/// ahora solo Windows.
bool get hasWindowsMediaIntegration => Platform.isWindows;

bool get isAndroidPlatform => Platform.isAndroid;

/// Sincronizar por Bluetooth: el puente nativo existe en Android y Windows.
bool get supportsBluetoothSync => Platform.isAndroid || Platform.isWindows;

/// Lector de QR en vivo con la cámara (mobile_scanner). En Windows/Linux se
/// sacan fotos y se leen con [decodeQrImage].
bool get hasLiveQrScanner =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
