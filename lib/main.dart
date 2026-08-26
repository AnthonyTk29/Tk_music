import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:tk_music/pages/request_permission.dart';
import 'dart:io';
import 'package:tk_music/pages/music_player_android_screen.dart';
import 'package:audio_service/audio_service.dart';
import 'package:tk_music/services/audio_handler.dart';

late final AudioHandler audioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.tk_music.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF182848)),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF182848),
          brightness: Brightness.dark,
        ),
      ),
      home: const PermissionChecker(),
    );
  }
}

// Widget que verifica permisos y decide qué pantalla mostrar
class PermissionChecker extends StatefulWidget {
  const PermissionChecker({super.key});

  @override
  State<PermissionChecker> createState() => _PermissionCheckerState();
}

class _PermissionCheckerState extends State<PermissionChecker> {
  bool? hasPermission;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    bool granted = false;

    if (Platform.isAndroid) {
      final androidVersion = await DeviceInfoPlugin().androidInfo;
      if (androidVersion.version.sdkInt >= 33) {
        // Android 13+
        granted = await Permission.audio.request().isGranted;
        await Permission.notification.request();
      } else {
        // Android < 13
        granted = await Permission.storage.request().isGranted;
      }
    } else {
      granted = true;
    }

    if (mounted) {
      setState(() {
        hasPermission = granted;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (hasPermission == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    } else if (hasPermission == true) {
      return const MusicPlayerScreen();
    } else {
      return const RequestPermissionScreen();
    }
  }
}
