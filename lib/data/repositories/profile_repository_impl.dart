import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/safe_json.dart';
import 'package:tk_music/domain/entities/profile.dart';
import 'package:tk_music/domain/repositories/profile_repository.dart';

class ProfileRepositoryImpl implements ProfileRepository {
  static const _profilesKey = 'profiles';
  static const _rememberedIdKey = 'rememberedProfileId';

  final _random = Random.secure();

  @override
  Future<List<Profile>> getProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKey);
    return readJson(
      raw,
      (decoded) => (decoded as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((json) =>
              Profile(id: json['id'] as String, name: json['name'] as String))
          .toList(),
      fallback: const [],
      context: 'ProfileRepositoryImpl.getProfiles',
    );
  }

  @override
  Future<Profile> addProfile(String name) async {
    final profiles = await getProfiles();
    final profile = Profile(id: _newId(), name: name);
    await _saveProfiles([...profiles, profile]);
    return profile;
  }

  @override
  Future<Profile?> getRememberedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_rememberedIdKey);
    if (id == null) return null;

    final profiles = await getProfiles();
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    // El perfil recordado ya no existe (se borró la lista, reinstaló, etc).
    return null;
  }

  @override
  Future<void> rememberProfile(Profile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rememberedIdKey, profile.id);
  }

  @override
  Future<void> forgetProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberedIdKey);
  }

  Future<void> _saveProfiles(List<Profile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(
      profiles.map((p) => {'id': p.id, 'name': p.name}).toList(),
    );
    await prefs.setString(_profilesKey, raw);
  }

  String _newId() =>
      List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();
}
