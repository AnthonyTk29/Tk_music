import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/core/errors/app_error_code.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/core/errors/error_reporter.dart';
import 'package:tk_music/core/theme/app_theme.dart';
import 'package:tk_music/services/audio_handler.dart';
import 'package:tk_music/presentation/providers/permission_provider.dart';
import 'package:tk_music/presentation/providers/profile_provider.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';
import 'package:tk_music/presentation/pages/music_player_screen.dart';
import 'package:tk_music/presentation/pages/profile_picker_screen.dart';
import 'package:tk_music/presentation/pages/request_permission_screen.dart';
import 'package:tk_music/presentation/pages/splash_screen.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/services/waveform_loader.dart';

void main() {
  // Todo el arranque corre adentro de esta zona para que runZonedGuarded
  // pueda ver hasta los errores async que se escapan de la zona de errores
  // propia de Flutter (los que atrapa FlutterError.onError no alcanzan acá).
  // Firebase se inicializa antes que cualquier otra cosa (incluido
  // AudioService.init, que ya una vez colgó toda la apertura de la app en
  // Android 14) para que Crashlytics ya esté activo si algo falla ahí.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    try {
      await Firebase.initializeApp();
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    } catch (e) {
      debugPrint('Firebase init failed: $e');
    }

    await _runMain();
  }, (error, stack) {
    // Última red: cualquier excepción que nadie haya traducido a
    // AppException (o que directamente nadie atrapó) cae acá. El reporter
    // la envuelve como AppErrorCode.unknown, la registra y muestra la
    // alerta si hay una pantalla montada — nunca queda invisible.
    ErrorReporter.instance.report(error, stack);
  });
}

Future<void> _runMain() async {
  AudioHandler? audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.tkmusic.app.channel.audio',
        androidNotificationChannelName: 'Audio playback',
        androidNotificationOngoing: true,
      ),
    ).timeout(const Duration(seconds: 10));
  } catch (e, stack) {
    ErrorReporter.instance.report(
      AppException(
        AppErrorCode.playbackInitFailed,
        userMessage:
            'No se pudo iniciar el reproductor. Podés seguir usando la app, '
            'pero la reproducción no va a funcionar hasta reabrirla.',
        technicalMessage: 'AudioService.init: $e',
      ),
      stack,
    );
  }

  initServiceLocator(audioHandler);
  // Arranca una sola vez acá, no desde ninguna pantalla: así la forma de
  // onda de lo que esté sonando sigue analizándose siempre, sin importar
  // qué pantalla esté abierta ni si la app pasa a segundo plano.
  if (audioHandler != null) {
    WaveformLoader.instance.start(audioHandler);
  }

  final permissionProvider = PermissionProvider();
  final songProvider = SongProvider();
  final profileProvider = ProfileProvider();

  runApp(MyApp(
    permissionProvider: permissionProvider,
    songProvider: songProvider,
    profileProvider: profileProvider,
  ));
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.permissionProvider,
    required this.songProvider,
    required this.profileProvider,
  });

  final PermissionProvider permissionProvider;
  final SongProvider songProvider;
  final ProfileProvider profileProvider;

  @override
  Widget build(BuildContext context) {
    return AppProviders(
      permissionProvider: permissionProvider,
      songProvider: songProvider,
      profileProvider: profileProvider,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: ErrorReporter.instance.navigatorKey,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: const _AppShell(),
      ),
    );
  }
}

class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  String? _error;
  bool _checked = false;
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    // Tiempo fijo para que el logo se alcance a ver; la inicialización real
    // (permisos, perfil, biblioteca) ya corre en paralelo desde main().
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _splashDone = true);
    });
  }

  // dependOnInheritedWidgetOfExactType (usado dentro de AppProviders.permissionOf)
  // no puede llamarse desde initState: el widget aún no terminó de montarse y el
  // framework lo rechaza en tiempo de ejecución. didChangeDependencies es el punto
  // correcto; se guarda con _checked para que sólo corra una vez.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_checked) {
      _checked = true;
      _check();
    }
  }

  Future<void> _check() async {
    try {
      final permission = AppProviders.permissionOf(context);
      await permission.checkPermission();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_splashDone) {
      return const SplashScreen();
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text('Error al inicializar', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => setState(() { _error = null; _check(); }),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    final profile = AppProviders.profileOf(context);
    if (profile.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (profile.needsProfile) {
      return const ProfilePickerScreen();
    }

    final granted = AppProviders.permissionOf(context).granted;

    if (granted == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return granted
        ? const MusicPlayerScreen()
        : const RequestPermissionScreen();
  }
}
