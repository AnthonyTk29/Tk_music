import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';
import 'active_profile.dart';

/// Guarda los niveles del ecualizador (ganancia por banda + si está
/// activado) para que se mantengan entre reinicios de la app — el efecto
/// nativo de Android arranca siempre "plano" en cada instancia nueva del
/// reproductor.
class EqualizerStore {
  String get _gainsKey => '${ActiveProfile.instance.key}.equalizerGains';
  String get _enabledKey => '${ActiveProfile.instance.key}.equalizerEnabled';
  String get _presetKey => '${ActiveProfile.instance.key}.equalizerPreset';

  /// Nombre del preset elegido (Normal/Pop/Rock/Clásica/Usuario), solo para
  /// saber cuál marcar seleccionado la próxima vez que se abre la
  /// pantalla — las ganancias en sí ya se guardan/restauran aparte con
  /// [getGains], sea cual sea el preset que las haya generado.
  Future<String?> getPreset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_presetKey);
  }

  Future<void> setPreset(String preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_presetKey, preset);
  }

  Future<Map<int, double>> getGains() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_gainsKey);
    return readJson(
      raw,
      (decoded) => (decoded as Map<String, dynamic>)
          .map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())),
      fallback: const {},
      context: 'EqualizerStore.getGains',
    );
  }

  Future<void> saveGain(int bandIndex, double gain) async {
    final gains = await getGains();
    gains[bandIndex] = gain;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _gainsKey,
      jsonEncode(gains.map((k, v) => MapEntry(k.toString(), v))),
    );
  }

  Future<void> clearGains() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_gainsKey);
  }

  Future<bool> getEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }
}
