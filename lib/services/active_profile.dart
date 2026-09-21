/// Perfil activo en memoria, para que los servicios (favoritos, recientes,
/// playlists, última posición) puedan separar sus datos por perfil sin
/// depender de un BuildContext o del árbol de providers.
///
/// [ProfileProvider] lo mantiene al día en cada login/logout; los `*Store`
/// arman sus claves de SharedPreferences con [key] como prefijo.
class ActiveProfile {
  ActiveProfile._();
  static final instance = ActiveProfile._();

  String? _profileId;

  void set(String? profileId) => _profileId = profileId;

  /// Prefijo para claves de SharedPreferences. `'guest'` si por algún motivo
  /// se llama antes de que haya un perfil activo, para no perder datos en
  /// una clave sin prefijo compartida por error entre perfiles.
  String get key => _profileId ?? 'guest';
}
