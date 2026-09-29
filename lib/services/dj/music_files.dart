import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/entities/song_id.dart';

/// Tamaño y fecha de un archivo; (0, 2000-01-01) si no se puede leer.
(int size, DateTime modified) fileStat(String path) {
  try {
    final stat = File(path).statSync();
    return (stat.size, stat.modified);
  } catch (_) {
    return (0, DateTime(2000));
  }
}

/// Abre el Explorador de archivos con [path] seleccionado (Windows) o la
/// carpeta que lo tiene (Linux/macOS).
Future<void> showInFileManager(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      await Process.run('xdg-open', [p.dirname(path)]);
    }
  } catch (_) {}
}

/// Formatos que muestra el gestor de archivos del modo DJ.
const djAudioExtensions = {'.mp3', '.wav'};

bool isDjAudio(String path) =>
    djAudioExtensions.contains(p.extension(path).toLowerCase());

/// Un archivo de música en disco.
class MusicFile {
  const MusicFile({
    required this.path,
    required this.size,
    required this.modified,
  });

  final String path;
  final int size;
  final DateTime modified;

  String get name => p.basenameWithoutExtension(path);
  String get folder => p.dirname(path);

  /// "MP3" o "WAV".
  String get format => p.extension(path).replaceFirst('.', '').toUpperCase();

  /// Para cargarlo en un deck: el título sale del nombre del archivo (el
  /// deck lee después las etiquetas y la duración real).
  Song toSong() => Song(
        mediaStoreId: stableSongId(path),
        title: name,
        filePath: path,
      );
}

/// Una canción y sus copias: [files] tiene más de uno si está repetida
/// (mismo nombre una vez limpio, en distintas carpetas o con "(1)",
/// "copia", "from YouTube", etc.).
class MusicGroup {
  MusicGroup(this.key, this.files);

  final String key;
  final List<MusicFile> files;

  bool get repeated => files.length > 1;
  MusicFile get first => files.first;

  /// Las copias pesan exactamente lo mismo: casi seguro el mismo archivo.
  bool get identicalCopies =>
      repeated && files.every((f) => f.size == files.first.size);
}

final _brackets = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');
// "003 - ", "12. ", "007.grupo" (con el punto pegado) o "05 ".
final _leadingNumber = RegExp(r'^\s*\d{1,3}(\s*[-._)]+\s*|\s+)');
final _noise = RegExp(
  r'\b(from youtube|official video|official audio|video oficial|'
  r'audio oficial|con letra|letra|lyrics?|hq|hd|xxx+|copia|copy|'
  r'mp3|remasterizado|remastered)\b',
);

/// Clave para reconocer la misma canción aunque el archivo se llame un poco
/// distinto: sin mayúsculas ni tildes, sin el número de pista, sin lo que
/// va entre paréntesis y sin agregados típicos ("from YouTube", "(1)",
/// "copia", "xxx"…).
String duplicateKey(String fileName) {
  var s = p.basenameWithoutExtension(fileName).toLowerCase();
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final buffer = StringBuffer();
  for (final ch in s.split('')) {
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  s = buffer.toString();
  s = s.replaceAll(_brackets, ' ');
  s = s.replaceAll('_', ' ');
  s = s.replaceFirst(_leadingNumber, '');
  s = s.replaceAll(_noise, ' ');
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return s.isEmpty ? p.basename(fileName).toLowerCase() : s;
}

/// Agrupa los archivos por canción (ver [duplicateKey]), ordenados por
/// nombre. Dentro de un grupo, primero la copia más reciente.
List<MusicGroup> groupDuplicates(Iterable<MusicFile> files) {
  final groups = <String, List<MusicFile>>{};
  for (final file in files) {
    groups.putIfAbsent(duplicateKey(file.path), () => []).add(file);
  }
  final result = [
    for (final entry in groups.entries)
      MusicGroup(entry.key,
          entry.value..sort((a, b) => b.modified.compareTo(a.modified))),
  ]..sort((a, b) =>
      a.first.name.toLowerCase().compareTo(b.first.name.toLowerCase()));
  return result;
}

/// Un disco de la PC y si se puede leer. Una lectora de DVD vacía o un
/// disco desconectado aparece pero no responde ("El dispositivo no está
/// listo"): queda marcado con [problem] y se sigue con los demás.
class DriveInfo {
  const DriveInfo(this.path, {this.problem});
  final String path;
  final String? problem;
  bool get readable => problem == null;
}

/// Todos los discos de la PC (C:\, D:\…), también los que no se pueden
/// leer. En Linux/macOS, la raíz y la carpeta personal.
List<DriveInfo> listDriveInfo() {
  if (!Platform.isWindows) {
    return [
      const DriveInfo('/'),
      if (Platform.environment['HOME'] != null)
        DriveInfo(Platform.environment['HOME']!),
    ];
  }
  final drives = <DriveInfo>[];
  for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
    final path = '${String.fromCharCode(c)}:\\';
    try {
      if (Directory(path).existsSync()) drives.add(DriveInfo(path));
    } on FileSystemException catch (e) {
      drives.add(
          DriveInfo(path, problem: (e.osError?.message ?? e.message).trim()));
    } catch (e) {
      drives.add(DriveInfo(path, problem: '$e'));
    }
  }
  return drives;
}

/// Los discos que se pueden leer.
List<String> listDrives() => [
      for (final drive in listDriveInfo())
        if (drive.readable) drive.path,
    ];

bool _exists(String path) {
  try {
    return Directory(path).existsSync();
  } catch (_) {
    return false;
  }
}

/// Carpetas del usuario que conviene tener a mano.
List<(String label, String path)> userFolders() {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null) return const [];
  return [
    for (final (label, name) in const [
      ('Música', 'Music'),
      ('Escritorio', 'Desktop'),
      ('Descargas', 'Downloads'),
    ])
      if (_exists(p.join(home, name))) (label, p.join(home, name)),
  ];
}

/// Carpetas del sistema y de programas: no tienen música del usuario,
/// varias no se pueden ni leer (la Papelera, "System Volume Information")
/// y recorrerlas hacía eterno el escaneo si se elegía un disco entero.
const skippedSystemFolders = {
  'windows',
  'program files',
  'program files (x86)',
  'programdata',
  'appdata',
  'system volume information',
  'recovery',
  'perflogs',
  'msocache',
  'node_modules',
  // Juegos y tiendas de apps: miles de efectos de sonido, no canciones.
  'windowsapps',
  'xboxgames',
  'steamapps',
  'steamlibrary',
  'epic games',
  'riot games',
  'origin games',
  'ea games',
  'gog games',
  'ubisoft game launcher',
};

bool _skipFolder(String name) =>
    name.startsWith('.') ||
    name.startsWith(r'$') ||
    skippedSystemFolders.contains(name.toLowerCase());

/// Formatos de audio que reproduce la app (la biblioteca de desktop); el
/// Modo DJ usa solo [djAudioExtensions].
const libraryAudioExtensions = {
  '.mp3',
  '.m4a',
  '.aac',
  '.wav',
  '.flac',
  '.ogg',
  '.opus',
  '.wma',
};

/// Contenido de una carpeta: subcarpetas (sin las del sistema) y los
/// archivos de [extensions] (MP3/WAV por defecto) que tiene. Una carpeta sin
/// permiso devuelve vacío.
Future<({List<String> folders, List<MusicFile> files})> listFolder(String path,
    {Set<String> extensions = djAudioExtensions}) async {
  final folders = <String>[];
  final files = <MusicFile>[];
  try {
    await for (final entity in Directory(path).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        if (!_skipFolder(name)) folders.add(entity.path);
      } else if (entity is File &&
          extensions.contains(p.extension(name).toLowerCase())) {
        try {
          final stat = await entity.stat();
          files.add(MusicFile(
              path: entity.path, size: stat.size, modified: stat.modified));
        } on FileSystemException {
          // Bloqueado o borrado mientras se leía.
        }
      }
    }
  } on FileSystemException {
    // Sin permiso de lectura.
  }
  folders.sort((a, b) =>
      p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
  files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return (folders: folders, files: files);
}

/// Avance de [scanMusic].
class MusicScanProgress {
  const MusicScanProgress(this.found, this.folders, this.current, this.done,
      {this.unreadable = const []});
  final List<MusicFile> found;
  final int folders;
  final String current;
  final bool done;

  /// Discos o carpetas de arranque que no se pudieron leer (con el motivo):
  /// se saltearon y se siguió con el resto.
  final List<(String path, String reason)> unreadable;
}

/// Busca todos los MP3/WAV debajo de [roots] (discos enteros incluidos),
/// salteando carpetas del sistema y las que no se pueden leer. Avisa cada
/// poco con lo encontrado hasta el momento; se corta si [cancelled]
/// devuelve true.
Stream<MusicScanProgress> scanMusic(
  List<String> roots, {
  bool Function()? cancelled,
  Set<String> extensions = djAudioExtensions,
  bool Function(String folder)? skip,
}) async* {
  final found = <MusicFile>[];
  final pending = [...roots.reversed];
  final rootSet = roots.toSet();
  final unreadable = <(String, String)>[];
  var folders = 0;
  var lastReport = DateTime.now();
  while (pending.isNotEmpty) {
    if (cancelled?.call() ?? false) break;
    final dir = pending.removeLast();
    folders++;
    try {
      await for (final entity in Directory(dir).list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (!_skipFolder(name) && !(skip?.call(entity.path) ?? false)) {
            pending.add(entity.path);
          }
        } else if (entity is File &&
            extensions.contains(p.extension(name).toLowerCase())) {
          try {
            final stat = await entity.stat();
            found.add(MusicFile(
                path: entity.path, size: stat.size, modified: stat.modified));
          } catch (_) {
            // Bloqueado o borrado mientras se leía.
          }
        }
      }
    } catch (e) {
      // Sin permiso de lectura, o un disco que no responde (DVD vacío,
      // pendrive sacado): se anota y se sigue con los demás.
      if (rootSet.contains(dir)) {
        unreadable.add((
          dir,
          e is FileSystemException
              ? (e.osError?.message ?? e.message).trim()
              : '$e',
        ));
      }
    }
    final now = DateTime.now();
    if (now.difference(lastReport).inMilliseconds > 250) {
      lastReport = now;
      yield MusicScanProgress(List.of(found), folders, dir, false,
          unreadable: List.of(unreadable));
    }
  }
  yield MusicScanProgress(List.of(found), folders, '', true,
      unreadable: List.of(unreadable));
}

/// "3,4 MB"
String formatFileSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
  return '${(bytes / 1024).round()} KB';
}
