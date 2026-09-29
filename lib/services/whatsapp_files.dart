import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/services/external_storage_service.dart';
import 'package:tk_music/services/whatsapp_import_service.dart';

/// Un audio dentro de la carpeta de WhatsApp habilitada.
class WaFile {
  const WaFile({
    required this.docId,
    required this.name,
    required this.parent,
    required this.uri,
    this.size = 0,
    this.modified = 0,
  });

  /// Id del documento (p. ej. "primary:Android/media/…/PTT-…opus").
  final String docId;
  final String name;

  /// docId de la carpeta donde está.
  final String parent;

  /// content:// para escucharlo o copiarlo.
  final String uri;
  final int size;

  /// ms desde 1970 (0 si no se sabe).
  final int modified;

  bool get voiceNote =>
      isWhatsAppVoiceNote(name) || parent.toLowerCase().contains('voice notes');

  /// Nombre sin extensión, legible ("Nota de voz 27-09-2026 (3)").
  String get title =>
      friendlyWhatsAppTitle(name.replaceAll(RegExp(r'\.[^.]+$'), ''));

  DateTime? get date =>
      whatsAppDate(name) ??
      (modified > 0 ? DateTime.fromMillisecondsSinceEpoch(modified) : null);
}

/// Una carpeta dentro de la carpeta de WhatsApp habilitada.
class WaFolder {
  const WaFolder({
    required this.docId,
    required this.name,
    this.parent,
    this.otherFiles = 0,
  });

  final String docId;
  final String name;

  /// docId de la carpeta de arriba (null en la raíz).
  final String? parent;

  /// Archivos que no son audio que tiene directamente (fotos, videos…).
  final int otherFiles;
}

/// Todo lo que hay en la carpeta de WhatsApp: carpetas y audios, con
/// cuentas por carpeta (incluyendo subcarpetas).
class WaTree {
  WaTree({
    required this.rootDocId,
    required List<WaFolder> folders,
    required List<WaFile> files,
  }) : files = List.unmodifiable(files) {
    for (final folder in folders) {
      _folders[folder.docId] = folder;
    }
    _folders.putIfAbsent(rootDocId,
        () => WaFolder(docId: rootDocId, name: _lastPart(rootDocId)));
    for (final folder in _folders.values) {
      if (folder.parent != null && folder.docId != rootDocId) {
        (_subfolders[folder.parent!] ??= []).add(folder);
      }
      // Los archivos que no son audio suman en su carpeta y en todas las
      // de arriba.
      if (folder.otherFiles > 0) {
        for (final id in _chain(folder.docId)) {
          _others[id] = (_others[id] ?? 0) + folder.otherFiles;
        }
      }
    }
    for (final file in this.files) {
      (_filesIn[file.parent] ??= []).add(file);
      for (final id in _chain(file.parent)) {
        _audioCount[id] = (_audioCount[id] ?? 0) + 1;
        _bytes[id] = (_bytes[id] ?? 0) + file.size;
      }
    }
    for (final list in _subfolders.values) {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    for (final list in _filesIn.values) {
      list.sort((a, b) => b.modified.compareTo(a.modified));
    }
  }

  final String rootDocId;
  final List<WaFile> files;

  final _folders = <String, WaFolder>{};
  final _subfolders = <String, List<WaFolder>>{};
  final _filesIn = <String, List<WaFile>>{};
  final _audioCount = <String, int>{};
  final _others = <String, int>{};
  final _bytes = <String, int>{};

  static String _lastPart(String docId) =>
      docId.split('/').last.split(':').last;

  /// La carpeta y todas las de arriba, hasta la raíz.
  Iterable<String> _chain(String docId) sync* {
    String? id = docId;
    final seen = <String>{};
    while (id != null && seen.add(id)) {
      yield id;
      if (id == rootDocId) return;
      id = _folders[id]?.parent;
    }
  }

  WaFolder? folder(String docId) => _folders[docId];
  WaFolder get root => _folders[rootDocId]!;

  /// Subcarpetas que tienen algún audio (en ellas o más adentro).
  List<WaFolder> subfoldersOf(String docId) => [
        for (final folder in _subfolders[docId] ?? const <WaFolder>[])
          if (audioCount(folder.docId) > 0) folder,
      ];

  List<WaFile> filesIn(String docId) => _filesIn[docId] ?? const [];

  /// Audios de la carpeta y de sus subcarpetas.
  int audioCount(String docId) => _audioCount[docId] ?? 0;

  /// Archivos que no son audio de la carpeta y sus subcarpetas: se borran
  /// también si se borra la carpeta entera.
  int otherFilesCount(String docId) => _others[docId] ?? 0;

  /// Lo que ocupan los audios de la carpeta y sus subcarpetas.
  int audioBytes(String docId) => _bytes[docId] ?? 0;

  /// Todos los audios de la carpeta y sus subcarpetas.
  List<WaFile> filesUnder(String docId) => [
        for (final file in files)
          if (isInside(file.parent, docId)) file,
      ];

  /// Si [docId] es [folderDocId] o está dentro.
  bool isInside(String docId, String folderDocId) =>
      _chain(docId).contains(folderDocId);

  /// De la raíz a la carpeta (para la ruta de arriba).
  List<WaFolder> pathTo(String docId) =>
      [for (final id in _chain(docId)) _folders[id]!].reversed.toList();
}

/// Por qué no se pudo leer o borrar algo en la carpeta de WhatsApp.
class WhatsAppFilesException implements Exception {
  const WhatsAppFilesException(this.code, this.message);
  final String code;
  final String message;

  /// Sin permiso de escritura: la carpeta se habilitó solo para leer.
  bool get noWrite => code == 'NO_WRITE';

  /// Se perdió el permiso de la carpeta (WhatsApp reinstalado, carpeta
  /// movida): hay que volver a habilitarla.
  bool get noPermission => code == 'NO_PERMISSION';

  @override
  String toString() => message;
}

/// Lee y borra dentro de la carpeta de WhatsApp habilitada (Android, SAF).
class WhatsAppFiles {
  static const _channel = MethodChannel('tk_music/external_storage');

  Future<WaTree> listTree(String treeUri) async {
    final Map<String, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>(
          'listAudioTree', {'uri': treeUri, 'maxDepth': 6});
    } on PlatformException catch (e) {
      throw WhatsAppFilesException(e.code, e.message ?? e.code);
    }
    if (raw == null) {
      throw const WhatsAppFilesException('LIST_FAILED', 'Sin datos');
    }
    return treeFromMap(raw);
  }

  /// Abre el selector de Android directo en la carpeta de WhatsApp (según
  /// la versión de Android está en un lugar u otro). Devuelve la carpeta
  /// elegida o null si se canceló.
  Future<String?> pickWhatsAppFolder({ExternalStorageService? storage}) async {
    var sdk = 30;
    try {
      if (Platform.isAndroid) {
        sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      }
    } catch (_) {}
    final initial = sdk >= 30
        ? 'Android/media/com.whatsapp/WhatsApp/Media'
        : 'WhatsApp/Media';
    final picked = await (storage ?? ExternalStorageService())
        .pickDirectory(initialPath: initial);
    return picked?.uri;
  }

  static WaTree treeFromMap(Map<String, Object?> raw) {
    Map<String, Object?> asMap(Object? item) =>
        Map<String, Object?>.from(item as Map);
    return WaTree(
      rootDocId: raw['rootDocId'] as String,
      folders: [
        for (final item in (raw['folders'] as List? ?? const []))
          () {
            final map = asMap(item);
            return WaFolder(
              docId: map['docId'] as String,
              name: map['name'] as String? ?? '',
              parent: map['parent'] as String?,
              otherFiles: (map['otherFiles'] as num?)?.toInt() ?? 0,
            );
          }(),
      ],
      files: [
        for (final item in (raw['files'] as List? ?? const []))
          () {
            final map = asMap(item);
            return WaFile(
              docId: map['docId'] as String,
              name: map['name'] as String? ?? '',
              parent: map['parent'] as String,
              uri: map['uri'] as String,
              size: (map['size'] as num?)?.toInt() ?? 0,
              modified: (map['modified'] as num?)?.toInt() ?? 0,
            );
          }(),
      ],
    );
  }

  /// Borra un archivo o una carpeta entera. Es definitivo.
  Future<void> delete(String treeUri, String docId) async {
    try {
      await _channel
          .invokeMethod('deleteDocument', {'treeUri': treeUri, 'docId': docId});
    } on PlatformException catch (e) {
      throw WhatsAppFilesException(
        e.code,
        e.code == 'NO_WRITE'
            ? 'Sin permiso para borrar en esa carpeta'
            : (e.message ?? 'No se pudo borrar'),
      );
    }
  }
}

/// Lo que el gestor de audios de WhatsApp recuerda: la carpeta habilitada
/// y qué audios ya se pasaron a la biblioteca.
class WhatsAppLibraryPrefs {
  /// Se llamaba así cuando la carpeta era solo para las notas de voz; se
  /// mantiene para no volver a pedirla.
  static const _rootUriKey = 'whatsapp.voiceNotesUri';
  static const _importedKey = 'whatsapp.imported';

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<String?> rootUri() async => (await _prefs())?.getString(_rootUriKey);

  Future<void> setRootUri(String uri) async {
    try {
      await (await _prefs())?.setString(_rootUriKey, uri);
    } catch (_) {}
  }

  Future<Set<String>> imported() async =>
      ((await _prefs())?.getStringList(_importedKey) ?? const []).toSet();

  Future<void> setImported(Set<String> keys) async {
    try {
      await (await _prefs())?.setStringList(_importedKey, keys.toList());
    } catch (_) {}
  }
}
