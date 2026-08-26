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

  final audioHandler = await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.tk_music.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    ),
  );

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

class _AppShell extends StatelessWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context) {
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
