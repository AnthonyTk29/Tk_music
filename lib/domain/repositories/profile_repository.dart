import '../entities/profile.dart';

abstract class ProfileRepository {
  Future<List<Profile>> getProfiles();
  Future<Profile> addProfile(String name);

  /// El perfil recordado de una sesión anterior, o `null` si no hay ninguno
  /// (nunca se marcó "recordarme", o el usuario cerró sesión).
  Future<Profile?> getRememberedProfile();

  Future<void> rememberProfile(Profile profile);
  Future<void> forgetProfile();
}
