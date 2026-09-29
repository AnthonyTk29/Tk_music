import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ajustes de reproducción de la app (pantalla "Ajustes"). Globales del
/// dispositivo, no por perfil: son preferencias de cómo suena el equipo.
class PlaybackSettings extends ChangeNotifier {
  PlaybackSettings._();
  static final instance = PlaybackSettings._();

  static const _prefix = 'settings.';

  /// Emparejar el volumen entre canciones (todas suenan parecido de
  /// fuerte), en el reproductor normal.
  bool normalizeVolume = true;

  /// Segundos de cruce entre canciones en el reproductor normal (0 = sin
  /// crossfade, reproducción continua sin cortes).
  int crossfadeSeconds = 0;

  /// Cruzar sobre el pulso: arrancar el cruce en un golpe de la canción que
  /// termina y ajustar apenas la velocidad de la que entra para que los
  /// tempos coincidan (usa el análisis de BPM).
  bool beatMatching = true;

  /// Buscar letras sincronizadas en internet (LRCLIB) cuando la canción no
  /// trae una propia.
  bool onlineLyrics = true;

  /// Buscar carátulas en internet (iTunes) para las canciones que no traen
  /// imagen en el archivo.
  bool onlineArtwork = true;

  /// Teñir "Reproduciendo" con el color de la carátula.
  bool artworkColors = true;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    normalizeVolume =
        prefs.getBool('${_prefix}normalizeVolume') ?? normalizeVolume;
    crossfadeSeconds =
        prefs.getInt('${_prefix}crossfadeSeconds') ?? crossfadeSeconds;
    beatMatching = prefs.getBool('${_prefix}beatMatching') ?? beatMatching;
    onlineLyrics = prefs.getBool('${_prefix}onlineLyrics') ?? onlineLyrics;
    onlineArtwork = prefs.getBool('${_prefix}onlineArtwork') ?? onlineArtwork;
    artworkColors = prefs.getBool('${_prefix}artworkColors') ?? artworkColors;
    notifyListeners();
  }

  Future<void> setNormalizeVolume(bool value) =>
      _setBool('normalizeVolume', value, () => normalizeVolume = value);
  Future<void> setBeatMatching(bool value) =>
      _setBool('beatMatching', value, () => beatMatching = value);
  Future<void> setOnlineLyrics(bool value) =>
      _setBool('onlineLyrics', value, () => onlineLyrics = value);
  Future<void> setOnlineArtwork(bool value) =>
      _setBool('onlineArtwork', value, () => onlineArtwork = value);
  Future<void> setArtworkColors(bool value) =>
      _setBool('artworkColors', value, () => artworkColors = value);

  Future<void> setCrossfadeSeconds(int value) async {
    crossfadeSeconds = value.clamp(0, 12);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}crossfadeSeconds', crossfadeSeconds);
  }

  Future<void> _setBool(String key, bool value, VoidCallback apply) async {
    apply();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefix$key', value);
  }
}
