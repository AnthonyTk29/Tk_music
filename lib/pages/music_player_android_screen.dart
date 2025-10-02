import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:on_audio_query/on_audio_query.dart';

class MusicPlayerAndroidScreen extends StatefulWidget {
  const MusicPlayerAndroidScreen({super.key});

  @override
  State<MusicPlayerAndroidScreen> createState() =>
      _MusicPlayerAndroidScreenState();
}

class _MusicPlayerAndroidScreenState extends State<MusicPlayerAndroidScreen> {
  final AudioPlayer _player = AudioPlayer();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  List<SongModel> songs = [];
  int currentIndex = 0;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSongs();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(
      const InitializationSettings(android: androidSettings),
    );
  }

  Future<void> _loadSongs() async {
    // Pedir permiso explícito antes de consultar
    bool permissionStatus = await _audioQuery.permissionsRequest();
    if (!permissionStatus) return;

    songs = await _audioQuery.querySongs();
    if (songs.isNotEmpty) {
      _playSong(0);
    }
    setState(() {});
  }

  Future<void> _playSong(int index) async {
    if (index < 0 || index >= songs.length) return;
    currentIndex = index;

    final path = songs[index].data;
    final file = File(path);
    if (!await file.exists()) return;

    await _player.setFilePath(path);
    await _player.play();

    // Actualizar notificación con la canción seleccionada
    await _notifications.show(
      0,
      'Reproduciendo',
      songs[index].title,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'music_channel',
          'Música de Fondo',
          'Reproducción en segundo plano',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );

    // Escuchar cuando termina la canción para pasar a la siguiente automáticamente
    _playerStateSubscription?.cancel();
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        int nextIndex = (currentIndex + 1) % songs.length;
        _playSong(nextIndex);
      }
    });

    setState(() {}); // Actualiza la UI para marcar la canción seleccionada
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reproductor Android')),
      body: songs.isEmpty
          ? const Center(child: Text('No se encontraron canciones'))
          : ListView.builder(
              itemCount: songs.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(songs[index].title),
                  subtitle: Text(songs[index].artist ?? ''),
                  selected: index == currentIndex,
                  onTap: () => _playSong(index), // 🔹 Cambiar canción al tocar
                  trailing: index == currentIndex
                      ? const Icon(Icons.equalizer, color: Colors.blueAccent)
                      : null,
                );
              },
            ),
    );
  }
}
