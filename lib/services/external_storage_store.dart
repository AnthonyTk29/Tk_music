import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'active_profile.dart';
import 'external_storage_service.dart';

/// Carpetas de pendrive ya autorizadas por el usuario, guardadas por perfil
/// para no tener que volver a elegirlas cada vez que se abre la app
/// (el permiso SAF ya persiste solo, esto es lo que hace falta para
/// mostrarlas en la lista sin depender de recordar el URI de memoria).
class ExternalStorageStore extends ChangeNotifier {
  ExternalStorageStore._();
  static final instance = ExternalStorageStore._();

  final _service = ExternalStorageService();

  String get _key => '${ActiveProfile.instance.key}.externalRoots';

  Future<List<PickedDirectory>> getRoots() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw.map((entry) {
      final map = jsonDecode(entry) as Map<String, dynamic>;
      return PickedDirectory(
        uri: map['uri'] as String,
        name: map['name'] as String,
      );
    }).toList();
  }

  Future<PickedDirectory?> addFromPicker() async {
    final picked = await _service.pickDirectory();
    if (picked == null) return null;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? <String>[];
    if (raw.any((entry) => (jsonDecode(entry) as Map)['uri'] == picked.uri)) {
      return picked;
    }
    raw.add(jsonEncode({'uri': picked.uri, 'name': picked.name}));
    await prefs.setStringList(_key, raw);
    notifyListeners();
    return picked;
  }

  Future<void> remove(PickedDirectory dir) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? <String>[];
    raw.removeWhere((entry) => (jsonDecode(entry) as Map)['uri'] == dir.uri);
    await prefs.setStringList(_key, raw);
    await _service.releasePermission(dir.uri);
    notifyListeners();
  }
}
