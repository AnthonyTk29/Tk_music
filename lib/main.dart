import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/core/theme/app_theme.dart';
import 'package:tk_music/services/audio_handler.dart';
import 'package:tk_music/presentation/providers/permission_provider.dart';
import 'package:tk_music/presentation/providers/song_provider.dart';
import 'package:tk_music/presentation/pages/music_player_screen.dart';
import 'package:tk_music/presentation/pages/request_permission_screen.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AudioHandler? audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.tk_music.channel.audio',
        androidNotificationChannelName: 'Audio playback',
        androidNotificationOngoing: true,
      ),
    ).timeout(const Duration(seconds: 10));
  } catch (e) {
    debugPrint('AudioService init failed: $e');
  }

  initServiceLocator(audioHandler);

  final permissionProvider = PermissionProvider();
  final songProvider = SongProvider();

  runApp(MyApp(
    permissionProvider: permissionProvider,
    songProvider: songProvider,
  ));
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.permissionProvider,
    required this.songProvider,
  });

  final PermissionProvider permissionProvider;
  final SongProvider songProvider;

  @override
  Widget build(BuildContext context) {
    return AppProviders(
      permissionProvider: permissionProvider,
      songProvider: songProvider,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
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

  @override
  void initState() {
    super.initState();
    _check();
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
              FilledButton(
                onPressed: () => setState(() { _error = null; _check(); }),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
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
