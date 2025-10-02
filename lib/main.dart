import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tk_music/pages/RequestPermission.dart';
import 'package:tk_music/pages/music_player_android_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  Future<bool> _hasPermission() async {
    if (Platform.isAndroid) {
      final audio = await Permission.audio.status;
      final storage = await Permission.storage.status;
      return audio.isGranted || storage.isGranted;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FutureBuilder<bool>(
        future: _hasPermission(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }

          if (snapshot.data == true) {
            // Si ya tiene permisos, navegar directo a reproductor
            return const MusicPlayerAndroidScreen();
          } else {
            // Si no, mostrar pantalla de permisos
            return const RequestPermissionScreen();
          }
        },
      ),
    );
  }
}
