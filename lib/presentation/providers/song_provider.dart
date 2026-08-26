import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/core/errors/failures.dart';
import 'package:tk_music/data/models/song_mapper.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/usecases/get_songs.dart';
import 'package:tk_music/services/audio_handler.dart';

class SongProvider extends ChangeNotifier {
  SongProvider() {
    loadSongs();
  }

  List<Song> _songs = [];
  bool _loading = true;
  String _search = '';
  Failure? _failure;

  List<Song> get songs => _songs;
  bool get loading => _loading;
  String get search => _search;
  Failure? get failure => _failure;

  List<Song> get visibleSongs {
    if (_search.isEmpty) return _songs;
    final q = _search.toLowerCase();
    return _songs.where((s) {
      final text = '${s.title} ${s.artist ?? ''} ${s.album ?? ''}'.toLowerCase();
      return text.contains(q);
    }).toList();
  }

  void updateSearch(String value) {
    _search = value.trim();
    notifyListeners();
  }

  Future<void> loadSongs() async {
    _loading = true;
    _failure = null;
    notifyListeners();

    final (songs, failure) = await sl<GetSongs>()();
    _songs = songs ?? [];
    _failure = failure;
    _loading = false;
    notifyListeners();

    if (_songs.isNotEmpty && isAudioAvailable) {
      final items = _songs.map(SongMapper.toMediaItem).toList();
      await (sl<AudioHandler>() as MyAudioHandler).setQueue(items);
    }
  }
}
