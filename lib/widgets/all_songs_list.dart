import 'package:flutter/material.dart';
import '../services/music_scanner.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../controllers/audio_controller.dart';

class AllSongsList extends StatefulWidget {
  const AllSongsList({super.key});

  @override
  State<AllSongsList> createState() => _AllSongsListState();
}

class _AllSongsListState extends State<AllSongsList> {
  final MusicScanner _scanner = MusicScanner();
  List<SongModel> _songs = [];

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  void _loadSongs() async {
    List<SongModel> songs = await _scanner.getAllMp3();
    setState(() {
      _songs = songs;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _songs.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : ListView.builder(
            itemCount: _songs.length,
            itemBuilder: (context, index) {
              final song = _songs[index];
              return ListTile(
                title: Text(song.title),
                subtitle: Text(song.artist ?? "Desconocido"),
                trailing: IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () {
                    // Cargar y reproducir la canción en background
                    AudioController.loadSong(song.data);
                    AudioController.play();
                  },
                ),
              );
            },
          );
  }
}
