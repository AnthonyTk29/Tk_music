import 'package:flutter/material.dart';
import '../controllers/audio_controller.dart';

class SongLoader extends StatelessWidget {
  final String songPath;

  const SongLoader({super.key, required this.songPath});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      child: const Text("Cargar canción"),
      onPressed: () async {
        await AudioController.loadSong(songPath);
      },
    );
  }
}
