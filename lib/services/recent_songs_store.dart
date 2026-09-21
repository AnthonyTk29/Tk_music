import 'package:shared_preferences/shared_preferences.dart';

import 'active_profile.dart';

/// Guarda los ids de MediaStore de las últimas canciones reproducidas, más
/// reciente primero, separadas por perfil, para armar "Accesos directos".
class RecentSongsStore {
  static const _maxEntries = 30;

  String get _key => '${ActiveProfile.instance.key}.recentSongIds';

  Future<List<int>> getRecentIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw.map(int.parse).toList();
  }

  Future<void> recordPlayed(int songId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key) ?? const [])
        .map(int.parse)
        .toList();

    // Se saca si ya estaba, para que vuelva a quedar primero sin duplicarse.
    current.remove(songId);
    current.insert(0, songId);
    if (current.length > _maxEntries) {
      current.removeRange(_maxEntries, current.length);
    }

    await prefs.setStringList(_key, current.map((e) => e.toString()).toList());
  }
}
