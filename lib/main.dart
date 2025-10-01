import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tk_music/pages/RequestPermission.dart';
import 'controllers/audio_controller.dart';
import 'widgets/player_controls.dart';
import 'widgets/all_songs_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AudioController.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Widget? _startPage;

  @override
  void initState() {
    super.initState();
    _determineStartPage();
  }

  Future<void> _determineStartPage() async {
    if (Platform.isAndroid) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      final wasAsked = prefs.getBool('wasPermissionAsked') ?? false;

      final statusAudio = await Permission.audio.status;
      final statusStorage = await Permission.storage.status;

      final granted = statusAudio.isGranted || statusStorage.isGranted;

      if (granted) {
        setState(() {
          _startPage =
              const MusicScreen(); // Pantalla principal con lista y controles
        });
      } else {
        setState(() {
          _startPage = const RequestPermissionScreen();
        });
      }
    } else {
      // Para iOS u otras plataformas mostramos la lista directamente
      setState(() {
        _startPage = const MusicScreen();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _startPage ??
          const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
    );
  }
}

// Pantalla principal con lista de canciones y controles
class MusicScreen extends StatelessWidget {
  const MusicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Music Player Background")),
      body: const Column(
        children: [
          Expanded(child: AllSongsList()),
          PlayerControls(),
        ],
      ),
    );
  }
}
