import 'package:flutter/material.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:audio_service/audio_service.dart';
import 'package:tk_music/main.dart' show audioHandler;
import 'package:tk_music/services/audio_handler.dart';
import 'package:tk_music/widgets/mini_player.dart';
import 'package:tk_music/widgets/song_artwork.dart';

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final OnAudioQuery _audioQuery = OnAudioQuery();
  final _searchController = TextEditingController();
  List<SongModel> songs = [];
  String _search = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    bool permissionStatus = await _audioQuery.permissionsRequest();
    if (!permissionStatus) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final loaded = await _audioQuery.querySongs();
    if (!mounted) return;
    setState(() {
      songs = loaded;
      _loading = false;
    });

    if (loaded.isEmpty) return;

    // La cola se arma una sola vez; al tocar una canción sólo saltamos a ella.
    await (audioHandler as MyAudioHandler).setQueue(
      loaded
          .map((song) => MediaItem(
                id: song.data,
                album: song.album ?? 'Unknown',
                title: song.title,
                artist: song.artist ?? 'Unknown',
                duration: Duration(milliseconds: song.duration ?? 0),
                // La carátula se resuelve después usando este id.
                extras: {'songId': song.id},
              ))
          .toList(),
    );
  }

  Future<void> _playSong(int index) async {
    if (index < 0 || index >= songs.length) return;
    await audioHandler.skipToQueueItem(index);
    await audioHandler.play();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reproductor Android'),
        actions: [
          StreamBuilder<PlaybackState>(
            stream: audioHandler.playbackState,
            builder: (context, snapshot) {
              final shuffle = snapshot.data?.shuffleMode ==
                  AudioServiceShuffleMode.all;
              return IconButton(
                tooltip: 'Shuffle',
                onPressed: () => audioHandler.setShuffleMode(shuffle
                    ? AudioServiceShuffleMode.none
                    : AudioServiceShuffleMode.all),
                icon: Icon(Icons.shuffle,
                    color: shuffle ? Theme.of(context).colorScheme.primary : null),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Buscar canción, artista o álbum',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _search = value.trim().toLowerCase()),
            ),
          ),
          Expanded(child: _buildBody()),
          const MiniPlayer(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (songs.isEmpty) {
      return const Center(child: Text('No se encontraron canciones'));
    }

    final visibleSongs = songs.where((song) {
      if (_search.isEmpty) return true;
      final text = '${song.title} ${song.artist ?? ''} ${song.album ?? ''}'.toLowerCase();
      return text.contains(_search);
    }).toList();

    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        // Se compara por id para que la selección siga siendo correcta si la
        // canción cambia desde la notificación.
        final currentId = snapshot.data?.id;
        return ListView.builder(
          itemCount: visibleSongs.length,
          itemBuilder: (context, index) {
            final song = visibleSongs[index];
            final isCurrent = song.data == currentId;
            return ListTile(
              leading: SongArtwork(songId: song.id),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                song.artist ?? 'Desconocido',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected: isCurrent,
              trailing: isCurrent
                  ? const Icon(Icons.equalizer, color: Colors.blueAccent)
                  : null,
              onTap: () => _playSong(songs.indexOf(song)),
            );
          },
        );
      },
    );
  }
}
