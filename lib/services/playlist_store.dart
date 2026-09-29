import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';
import 'package:tk_music/domain/entities/playlist.dart';
import 'active_profile.dart';

/// Playlists del perfil activo. Singleton (como FavoritesStore) para que
/// cualquier pantalla que cree/edite una playlist se refleje al instante en
/// las demás sin tener que recargar manualmente.
class PlaylistStore extends ChangeNotifier {
  PlaylistStore._();
  static final instance = PlaylistStore._();

  final _random = Random.secure();
  String get _key => '${ActiveProfile.instance.key}.playlists';

  Future<List<Playlist>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return readJson(
      raw,
      (decoded) =>
          (decoded as List<dynamic>).cast<Map<String, dynamic>>().map((json) {
        return Playlist(
          id: json['id'] as String,
          name: json['name'] as String,
          songIds: (json['songIds'] as List<dynamic>).cast<int>(),
        );
      }).toList(),
      fallback: const [],
      context: 'PlaylistStore.getAll',
    );
  }

  Future<Playlist> create(String name) async {
    final playlists = await getAll();
    final playlist =
        Playlist(id: _newId(), name: name.trim(), songIds: const []);
    await _save([...playlists, playlist]);
    return playlist;
  }

  Future<void> rename(String id, String name) async {
    final playlists = await getAll();
    await _save(playlists
        .map((p) => p.id == id ? p.copyWith(name: name.trim()) : p)
        .toList());
  }

  Future<void> delete(String id) async {
    final playlists = await getAll();
    await _save(playlists.where((p) => p.id != id).toList());
  }

  Future<void> addSong(String playlistId, int songId) async {
    final playlists = await getAll();
    await _save(playlists.map((p) {
      if (p.id != playlistId || p.songIds.contains(songId)) return p;
      return p.copyWith(songIds: [...p.songIds, songId]);
    }).toList());
  }

  Future<void> removeSong(String playlistId, int songId) async {
    final playlists = await getAll();
    await _save(playlists.map((p) {
      if (p.id != playlistId) return p;
      return p.copyWith(
          songIds: p.songIds.where((id) => id != songId).toList());
    }).toList());
  }

  Future<void> reorder(String playlistId, int oldIndex, int newIndex) async {
    final playlists = await getAll();
    await _save(playlists.map((p) {
      if (p.id != playlistId) return p;
      final ids = List<int>.from(p.songIds);
      final moved = ids.removeAt(oldIndex);
      ids.insert(newIndex, moved);
      return p.copyWith(songIds: ids);
    }).toList());
  }

  Future<void> _save(List<Playlist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(playlists
        .map((p) => {'id': p.id, 'name': p.name, 'songIds': p.songIds})
        .toList());
    await prefs.setString(_key, raw);
    notifyListeners();
  }

  String _newId() =>
      List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();
}
