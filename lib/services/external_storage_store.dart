import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/app_error_code.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/core/errors/safe_json.dart';

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
    // Cada carpeta es su propio JSON suelto en la lista — una entrada
    // corrupta se descarta sola en vez de tirar abajo la lista entera.
    return raw
        .map((entry) => readJson(
              entry,
              (decoded) => PickedDirectory(
                uri: (decoded as Map<String, dynamic>)['uri'] as String,
                name: decoded['name'] as String,
              ),
              fallback: null,
              context: 'ExternalStorageStore.getRoots',
            ))
        .whereType<PickedDirectory>()
        .toList();
  }

  Future<PickedDirectory?> addFromPicker() async {
    final PickedDirectory? picked;
    try {
      picked = await _service.pickDirectory();
    } on PlatformException catch (e) {
      throw AppException(
        e.code == 'BUSY' ? AppErrorCode.storageBusy : AppErrorCode.storagePickFailed,
        userMessage: e.code == 'BUSY'
            ? 'Ya hay una selección de carpeta en curso.'
            : 'No se pudo conectar esa carpeta.',
        technicalMessage: 'pickDirectory(${e.code}): ${e.message}',
      );
    }
    if (picked == null) return null;
    final directory = picked;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? <String>[];
    if (raw.any((entry) => _uriOf(entry) == directory.uri)) {
      return directory;
    }
    raw.add(jsonEncode({'uri': directory.uri, 'name': directory.name}));
    await prefs.setStringList(_key, raw);
    notifyListeners();
    return directory;
  }

  Future<void> remove(PickedDirectory dir) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? <String>[];
    raw.removeWhere((entry) => _uriOf(entry) == dir.uri);
    await prefs.setStringList(_key, raw);
    await _service.releasePermission(dir.uri);
    notifyListeners();
  }

  String? _uriOf(String entry) => readJson(
        entry,
        (decoded) => (decoded as Map<String, dynamic>)['uri'] as String?,
        fallback: null,
        context: 'ExternalStorageStore._uriOf',
      );
}
