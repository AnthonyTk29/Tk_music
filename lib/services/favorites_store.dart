import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'active_profile.dart';

/// Ids de MediaStore de las canciones marcadas como "me gusta", separadas
/// por perfil. Es un singleton (no un objeto por instancia) para que el
/// toggle desde la notificación y la pantalla de Favoritos dentro de la app
/// se mantengan sincronizados: ambos escuchan al mismo [ChangeNotifier].
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();
  static final instance = FavoritesStore._();

  String get _key => '${ActiveProfile.instance.key}.likedSongIds';

  Future<Set<int>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw.map(int.parse).toSet();
  }

  Future<bool> isLiked(int songId) async => (await getAll()).contains(songId);

  /// Alterna el estado y devuelve si quedó marcada como "me gusta".
  Future<bool> toggle(int songId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    final liked = !current.contains(songId);
    if (liked) {
      current.add(songId);
    } else {
      current.remove(songId);
    }
    await prefs.setStringList(_key, current.map((e) => e.toString()).toList());
    notifyListeners();
    return liked;
  }
}
