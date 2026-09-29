import 'package:flutter/foundation.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/profile.dart';
import 'package:tk_music/domain/repositories/profile_repository.dart';
import 'package:tk_music/services/active_profile.dart';

class ProfileProvider extends ChangeNotifier {
  ProfileProvider() {
    _init();
  }

  List<Profile> _profiles = [];
  Profile? _activeProfile;
  bool _loading = true;

  List<Profile> get profiles => _profiles;
  Profile? get activeProfile => _activeProfile;
  bool get loading => _loading;

  /// `true` mientras no se resolvió si hay un perfil recordado; una vez
  /// resuelto, `activeProfile == null` significa que hay que mostrar el
  /// selector de perfil.
  bool get needsProfile => !_loading && _activeProfile == null;

  Future<void> _init() async {
    final repo = sl<ProfileRepository>();
    _profiles = await repo.getProfiles();
    _activeProfile = await repo.getRememberedProfile();
    ActiveProfile.instance.set(_activeProfile?.id);
    _loading = false;
    notifyListeners();
  }

  Future<Profile> createProfile(String name) async {
    final trimmed = name.trim();
    final profile = await sl<ProfileRepository>().addProfile(trimmed);
    _profiles = [..._profiles, profile];
    notifyListeners();
    return profile;
  }

  Future<void> selectProfile(Profile profile,
      {required bool rememberMe}) async {
    final repo = sl<ProfileRepository>();
    if (rememberMe) {
      await repo.rememberProfile(profile);
    } else {
      await repo.forgetProfile();
    }
    _activeProfile = profile;
    ActiveProfile.instance.set(profile.id);
    notifyListeners();
  }

  /// Vuelve al selector de perfil sin borrar la lista de perfiles.
  Future<void> logout() async {
    await sl<ProfileRepository>().forgetProfile();
    _activeProfile = null;
    ActiveProfile.instance.set(null);
    notifyListeners();
  }
}
