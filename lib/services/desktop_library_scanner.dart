import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:tk_music/services/dj/music_files.dart';

/// La biblioteca de desktop: todas las canciones de todos los discos de la
/// PC. El primer escaneo se espera (con avance); después la lista queda
/// guardada, la app abre con ella al instante y se vuelve a revisar en
/// segundo plano una vez por sesión (o cuando se pide). Si cambió algo,
/// sube [revision] y la biblioteca se recarga.
class DesktopLibraryScanner extends ChangeNotifier {
  DesktopLibraryScanner._();
  static final instance = DesktopLibraryScanner._();

  /// Para los tests: dónde se guarda la lista y qué discos se recorren.
  @visibleForTesting
  Future<Directory> Function() storageDir = getApplicationSupportDirectory;
  @visibleForTesting
  List<String> Function() roots = listDrives;
  @visibleForTesting
  List<DriveInfo> Function() driveInfo = listDriveInfo;

  /// Discos que no se pudieron leer en la última búsqueda (lectora de DVD
  /// vacía, disco desconectado…), con el motivo. Se saltean y se sigue.
  List<(String path, String reason)> unreadable = const [];

  static const _fileName = 'library_files.json';

  List<MusicFile>? _files;
  Future<List<MusicFile>?>? _loading;
  StreamSubscription<MusicScanProgress>? _scan;
  Completer<List<MusicFile>>? _scanDone;
  bool _refreshedThisSession = false;

  /// Carpetas que el usuario sacó de la biblioteca (con todo lo de adentro).
  final Set<String> hiddenFolders = {};

  bool _isHidden(String path) {
    final lower = path.toLowerCase();
    return hiddenFolders.any((folder) {
      final f = folder.toLowerCase();
      return lower == f || lower.startsWith('$f${Platform.pathSeparator}');
    });
  }

  /// Saca [folder] (y sus subcarpetas) de la biblioteca.
  Future<void> hideFolder(String folder) async {
    if (!hiddenFolders.add(folder)) return;
    _files = [...?_files?.where((f) => !_isHidden(f.path))];
    await _saveCache();
    notifyListeners();
    revision.value++;
  }

  /// Vuelve a incluir [folder]: se buscan de nuevo sus canciones.
  Future<void> showFolder(String folder) async {
    if (!hiddenFolders.remove(folder)) return;
    await _saveCache();
    notifyListeners();
    unawaited(scan());
  }

  bool scanning = false;
  int foundSoFar = 0;
  int foldersSoFar = 0;
  String currentFolder = '';
  DateTime? lastScan;

  /// Sube cada vez que cambia el conjunto de archivos (para recargar).
  final revision = ValueNotifier<int>(0);

  /// Los archivos conocidos: lo guardado o, la primera vez, el escaneo
  /// completo. Arranca la revisión en segundo plano si todavía no se hizo.
  Future<List<MusicFile>> files() async {
    final cached = _files ?? await (_loading ??= _loadCache());
    if (cached == null) return scan();
    if (!_refreshedThisSession) {
      _refreshedThisSession = true;
      unawaited(scan());
    }
    return cached;
  }

  /// Recorre todos los discos. Si ya hay un escaneo en curso, espera ese.
  Future<List<MusicFile>> scan() {
    final running = _scanDone;
    if (running != null) return running.future;
    final done = _scanDone = Completer<List<MusicFile>>();
    _refreshedThisSession = true;
    scanning = true;
    foundSoFar = 0;
    foldersSoFar = 0;
    List<(String, String)> notReady;
    try {
      notReady = [
        for (final drive in driveInfo())
          if (!drive.readable) (drive.path, drive.problem!),
      ];
    } catch (_) {
      notReady = const [];
    }
    unreadable = notReady;
    notifyListeners();
    _scan = scanMusic(_safeRoots(),
            extensions: libraryAudioExtensions, skip: _isHidden)
        .listen((progress) async {
      foundSoFar = progress.found.length;
      foldersSoFar = progress.folders;
      currentFolder = progress.current;
      unreadable = [...notReady, ...progress.unreadable];
      if (!progress.done) {
        notifyListeners();
        return;
      }
      await _finish(progress.found);
      done.complete(progress.found);
    }, onError: (Object e) {
      scanning = false;
      _scanDone = null;
      notifyListeners();
      if (!done.isCompleted) done.complete(_files ?? const []);
    });
    return done.future;
  }

  List<String> _safeRoots() {
    try {
      return roots();
    } catch (_) {
      return const [];
    }
  }

  void cancelScan() {
    final done = _scanDone;
    unawaited(_scan?.cancel());
    _scan = null;
    _scanDone = null;
    scanning = false;
    notifyListeners();
    if (done != null && !done.isCompleted) done.complete(_files ?? const []);
  }

  Future<void> _finish(List<MusicFile> found) async {
    final changed = !_sameFiles(_files, found);
    _files = found;
    lastScan = DateTime.now();
    scanning = false;
    _scan = null;
    _scanDone = null;
    await _saveCache();
    notifyListeners();
    if (changed) revision.value++;
  }

  /// Suma archivos nuevos (descargas, importados) sin esperar al escaneo.
  Future<void> addFiles(Iterable<String> paths) async {
    final current = [...?_files];
    final known = {for (final f in current) f.path.toLowerCase()};
    var added = false;
    for (final path in paths) {
      if (known.contains(path.toLowerCase())) continue;
      try {
        final stat = await File(path).stat();
        current.add(
            MusicFile(path: path, size: stat.size, modified: stat.modified));
        added = true;
      } on FileSystemException {
        // Ya no está.
      }
    }
    if (!added) return;
    _files = current;
    await _saveCache();
    revision.value++;
  }

  /// Quita archivos borrados (mandados a la papelera).
  Future<void> removeFiles(Iterable<String> paths) async {
    final gone = {for (final path in paths) path.toLowerCase()};
    final current = _files;
    if (current == null) return;
    final kept =
        current.where((f) => !gone.contains(f.path.toLowerCase())).toList();
    if (kept.length == current.length) return;
    _files = kept;
    await _saveCache();
    revision.value++;
  }

  static bool _sameFiles(List<MusicFile>? a, List<MusicFile> b) {
    if (a == null || a.length != b.length) return false;
    final sizes = {for (final f in a) f.path: f.size};
    return b.every((f) => sizes[f.path] == f.size);
  }

  Future<File> _cacheFile() async =>
      File('${(await storageDir()).path}${Platform.pathSeparator}$_fileName');

  Future<List<MusicFile>?> _loadCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      lastScan = DateTime.tryParse(data['scannedAt'] as String? ?? '');
      hiddenFolders
        ..clear()
        ..addAll((data['hidden'] as List? ?? const []).cast<String>());
      final list = [
        for (final item in data['files'] as List)
          MusicFile(
            path: item['p'] as String,
            size: (item['s'] as num).toInt(),
            modified:
                DateTime.fromMillisecondsSinceEpoch((item['m'] as num).toInt()),
          ),
      ];
      _files = list;
      return list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache() async {
    try {
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'scannedAt': (lastScan ?? DateTime.now()).toIso8601String(),
        'hidden': hiddenFolders.toList(),
        'files': [
          for (final f in _files ?? const <MusicFile>[])
            {'p': f.path, 's': f.size, 'm': f.modified.millisecondsSinceEpoch},
        ],
      }));
    } catch (e) {
      debugPrint('No se pudo guardar la lista de la biblioteca: $e');
    }
  }

  @visibleForTesting
  void resetForTest() {
    cancelScan();
    _files = null;
    _loading = null;
    _refreshedThisSession = false;
    lastScan = null;
    hiddenFolders.clear();
    revision.value = 0;
  }
}
