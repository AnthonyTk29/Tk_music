import 'package:shared_preferences/shared_preferences.dart';

/// Lo que el Modo DJ recuerda entre sesiones: si el mezclador está
/// abierto, el sentido del pitch del controlador y, por cada controlador,
/// por dónde suena y si se muestra la ventana de "nuevo dispositivo".
/// Si no se puede leer o guardar, se sigue con los valores de siempre.
class DjSettingsStore {
  static const _mixerOpenKey = 'dj.mixerOpen';
  static const _invertPitchKey = 'dj.controller.invertPitch';

  static String _controllerKey(String controllerId, String what) =>
      'dj.controller.$controllerId.$what';

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(Future<void> Function(SharedPreferences prefs) f) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    try {
      await f(prefs);
    } catch (_) {}
  }

  /// null: nunca se eligió.
  Future<bool?> mixerOpen() async => (await _prefs())?.getBool(_mixerOpenKey);

  Future<void> setMixerOpen(bool open) =>
      _write((prefs) => prefs.setBool(_mixerOpenKey, open));

  Future<bool> invertPitch() async =>
      (await _prefs())?.getBool(_invertPitchKey) ?? false;

  Future<void> setInvertPitch(bool invert) =>
      _write((prefs) => prefs.setBool(_invertPitchKey, invert));

  /// Por dónde suena el controlador (nombre de `DjSpeakers`), si se eligió.
  Future<String?> controllerSpeakers(String controllerId) async =>
      (await _prefs())?.getString(_controllerKey(controllerId, 'speakers'));

  Future<void> setControllerSpeakers(String controllerId, String speakers) =>
      _write((prefs) =>
          prefs.setString(_controllerKey(controllerId, 'speakers'), speakers));

  /// "No mostrar de nuevo" en la ventana de nuevo dispositivo.
  Future<bool> controllerSilent(String controllerId) async =>
      (await _prefs())?.getBool(_controllerKey(controllerId, 'silent')) ??
      false;

  Future<void> setControllerSilent(String controllerId, bool silent) => _write(
      (prefs) => prefs.setBool(_controllerKey(controllerId, 'silent'), silent));
}
