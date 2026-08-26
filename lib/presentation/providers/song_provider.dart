import 'package:flutter/foundation.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/usecases/get_songs.dart';

class SongProvider extends ChangeNotifier {
  SongProvider() {
    loadSongs();
  }

  List<Song> _songs = [];
  bool _loading = true;
  String _search = '';

  List<Song> get songs => _songs;
  bool get loading => _loading;
  String get search => _search;

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
    notifyListeners();

    final (songs, failure) = await sl<GetSongs>()();
    _songs = songs ?? [];
    _loading = false;
    notifyListeners();
  }
}
