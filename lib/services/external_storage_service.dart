import 'package:flutter/services.dart';

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
  });

  final String name;
  final String uri;
  final bool isDirectory;
  final int size;
}

const _audioExtensions = {
  'mp3', 'wav', 'm4a', 'aac', 'opus', 'ogg', 'flac', 'wma',
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
class ExternalStorageService {
  static const _channel = MethodChannel('tk_music/external_storage');

  /// Abre el selector nativo de carpetas. Devuelve `null` si el usuario
  /// cancela.
  Future<PickedDirectory?> pickDirectory() async {
    final result =
        await _channel.invokeMapMethod<String, dynamic>('pickDirectory');
    if (result == null) return null;
    return PickedDirectory(
      uri: result['uri'] as String,
      name: result['name'] as String,
    );
  }

  Future<List<ExternalEntry>> listChildren(String uri) async {
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
      );
    }).toList();

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  Future<void> releasePermission(String uri) {
    return _channel.invokeMethod('releasePermission', {'uri': uri});
  }
}
