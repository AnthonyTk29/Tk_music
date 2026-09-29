import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:tk_music/core/platform.dart';

/// Carpeta elegida con el selector de Android (Storage Access Framework):
/// el permiso queda persistido, así no hay que volver a pedirla cada vez
/// que se abre la app mientras el mismo pendrive siga conectado.
class PickedDirectory {
  const PickedDirectory({required this.uri, required this.name});

  final String uri;
  final String name;
}

/// Un archivo o carpeta dentro de un [PickedDirectory], tal como lo devuelve
/// Android vía DocumentsContract.
class ExternalEntry {
  const ExternalEntry({
    required this.name,
    required this.uri,
    required this.isDirectory,
    required this.size,
    this.modified = 0,
  });

  final String name;
  final String uri;
  final bool isDirectory;
  final int size;

  /// Fecha de modificación (ms desde 1970; 0 si no se sabe).
  final int modified;
}

const _audioExtensions = {
  'mp3',
  'wav',
  'm4a',
  'aac',
  'opus',
  'ogg',
  'flac',
  'wma',
  'amr',
};

bool isAudioFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _audioExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// Puente con el selector de carpetas de Android (SAF) para poder leer
/// música desde un pendrive conectado por USB-OTG: Android moderno no
/// expone una ruta de archivo directa para ese almacenamiento, hay que
/// navegarlo por URIs `content://` vía DocumentsContract.
///
/// En desktop un pendrive es una unidad más (E:\, /media/...): el "uri" es
/// directamente la ruta y se navega con el sistema de archivos.
class ExternalStorageService {
  static const _channel = MethodChannel('tk_music/external_storage');

  /// Abre el selector nativo de carpetas. Devuelve `null` si el usuario
  /// cancela.
  /// [initialPath]: carpeta del almacenamiento interno donde abrir el
  /// selector en Android (p. ej. la de WhatsApp).
  Future<PickedDirectory?> pickDirectory({String? initialPath}) async {
    if (isDesktopPlatform) {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Elegí la carpeta del pendrive',
      );
      if (path == null) return null;
      final name = p.basename(path);
      return PickedDirectory(uri: path, name: name.isEmpty ? path : name);
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
        'pickDirectory', {if (initialPath != null) 'initialPath': initialPath});
    if (result == null) return null;
    return PickedDirectory(
      uri: result['uri'] as String,
      name: result['name'] as String,
    );
  }

  Future<List<ExternalEntry>> listChildren(String uri) async {
    if (isDesktopPlatform) return _sortEntries(await _listDesktop(uri));
    final raw = await _channel.invokeListMethod<Object?>(
      'listChildren',
      {'uri': uri},
    );
    if (raw == null) return const [];

    final entries = raw.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return ExternalEntry(
        name: map['name'] as String? ?? '',
        uri: map['uri'] as String,
        isDirectory: map['isDirectory'] as bool? ?? false,
        size: (map['size'] as num?)?.toInt() ?? 0,
        modified: (map['modified'] as num?)?.toInt() ?? 0,
      );
    }).toList();
    return _sortEntries(entries);
  }

  List<ExternalEntry> _sortEntries(List<ExternalEntry> entries) {
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  Future<List<ExternalEntry>> _listDesktop(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    final entries = <ExternalEntry>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.') || name.startsWith(r'$')) continue;
        final isDirectory = entity is Directory;
        var size = 0;
        if (!isDirectory) {
          try {
            size = await (entity as File).length();
          } on FileSystemException {
            continue;
          }
        }
        entries.add(ExternalEntry(
          name: name,
          uri: entity.path,
          isDirectory: isDirectory,
          size: size,
        ));
      }
    } on FileSystemException {
      // Carpeta sin permiso de lectura o pendrive desconectado a mitad de
      // camino: se muestra lo que se llegó a leer.
    }
    return entries;
  }

  Future<void> releasePermission(String uri) async {
    // En desktop no hay permiso persistido que liberar.
    if (isDesktopPlatform) return;
    await _channel.invokeMethod('releasePermission', {'uri': uri});
  }
}
