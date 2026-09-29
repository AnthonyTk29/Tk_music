import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'package:tk_music/core/di/service_locator.dart';

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/dj/dj_controls.dart';
import 'package:tk_music/presentation/widgets/progress_task_dialog.dart';
import 'package:tk_music/services/dj/audio_quality.dart';
import 'package:tk_music/services/dj/dj_deck.dart';
import 'package:tk_music/services/dj/dj_mixer.dart';
import 'package:tk_music/services/desktop_library_scanner.dart';
import 'package:tk_music/services/dj/music_files.dart';
import 'package:tk_music/services/track_features_store.dart';

/// De dónde se muestran canciones.
enum _Source { library, allDisks, folder }

/// Una canción en la lista: de la biblioteca (con sus etiquetas) o un
/// archivo suelto de un disco.
class _Entry {
  _Entry.fromSong(Song this.song)
      : path = song.filePath,
        title = song.title,
        subtitle = song.artist,
        file = null;

  _Entry.fromFile(MusicFile this.file)
      : path = file.path,
        title = file.name,
        subtitle = file.folder,
        song = null;

  final String path;
  final String title;
  final String? subtitle;
  final Song? song;
  final MusicFile? file;

  String get format => p.extension(path).replaceFirst('.', '').toUpperCase();
  Song toSong() => song ?? file!.toSong();
}

/// Gestor de archivos del modo DJ: la biblioteca, todos los discos de la PC
/// (navegando carpeta por carpeta o buscando en todos) y solo MP3/WAV. Las
/// canciones repetidas se marcan y se agrupan: se despliegan para ver cada
/// copia, con su calidad y su volumen, cuál conviene dejar (RECOMENDADA) y
/// cuáles tienen problemas (BAJA CALIDAD, BAJO VOLUMEN, CORTADA). Cada
/// archivo se puede escuchar antes (pre-escucha) y marcar para mandarlo a
/// la Papelera de reciclaje.
///
/// Hay dos modos:
///  - **DJ** ([DjFileBrowser.new]): solo MP3/WAV, carga en los decks.
///  - **Reproductor** ([DjFileBrowser.forPlayer], pestaña Biblioteca en
///    desktop): todos los formatos, la biblioteca completa (todos los discos)
///    y reproducir en el reproductor principal.
class DjFileBrowser extends StatefulWidget {
  const DjFileBrowser({
    super.key,
    required DjMixer this.mixer,
    required this.librarySongs,
    required Future<void> Function(DjDeck deck, Song song) this.onLoad,
    required Future<void> Function(Song song) this.onLoadToFree,
    required VoidCallback this.onClose,
    this.target,
    this.onFilesDeleted,
    this.onQueue,
    @visibleForTesting this.quality,
  }) : onPlay = null;

  /// Modo reproductor: [onPlay] suena [song] con [context] como cola.
  const DjFileBrowser.forPlayer({
    super.key,
    required this.librarySongs,
    required Future<void> Function(Song song, List<Song> context) this.onPlay,
    this.onFilesDeleted,
    @visibleForTesting this.quality,
  })  : mixer = null,
        onQueue = null,
        onLoad = null,
        onLoadToFree = null,
        onClose = null,
        target = null;

  final DjMixer? mixer;
  final List<Song> librarySongs;
  final DjDeck? target;
  final Future<void> Function(DjDeck deck, Song song)? onLoad;
  final Future<void> Function(Song song)? onLoadToFree;
  final VoidCallback? onClose;
  final Future<void> Function(Song song, List<Song> context)? onPlay;

  /// Modo DJ para armar la lista del Auto DJ: cada fila tiene "+ LISTA" en
  /// vez de A/B.
  final void Function(Song song)? onQueue;

  /// Se mandaron archivos a la papelera (para actualizar la biblioteca).
  final void Function(List<String> paths)? onFilesDeleted;

  /// Para los tests: calidad, volumen y papelera sin el plugin nativo.
  final AudioQualityService? quality;

  @override
  State<DjFileBrowser> createState() => _DjFileBrowserState();
}

class _DjFileBrowserState extends State<DjFileBrowser> {
  // Lo encontrado buscando en los discos queda para la próxima vez que se
  // abra la ventana (en esta sesión), aparte para cada modo (el DJ busca
  // solo MP3/WAV).
  static final _scannedByMode = <bool, List<MusicFile>>{};
  static final _scannedLabelByMode = <bool, String>{};
  List<MusicFile>? get _scanned => _scannedByMode[_playerMode];
  set _scanned(List<MusicFile>? value) => value == null
      ? _scannedByMode.remove(_playerMode)
      : _scannedByMode[_playerMode] = value;
  String get _scannedLabel => _scannedLabelByMode[_playerMode] ?? '';
  set _scannedLabel(String value) => _scannedLabelByMode[_playerMode] = value;

  bool get _playerMode => widget.onPlay != null;
  Set<String> get _extensions =>
      _playerMode ? libraryAudioExtensions : djAudioExtensions;

  _Source _source = _Source.library;
  String? _folder;
  Future<({List<String> folders, List<MusicFile> files})>? _listing;

  final _search = TextEditingController();
  String _query = '';
  bool _mp3 = true;
  bool _wav = true;

  /// Modo reproductor: los demás formatos (M4A, FLAC, OGG…).
  bool _other = true;
  bool _onlyRepeated = false;
  final Set<String> _expanded = {};

  StreamSubscription<MusicScanProgress>? _scan;
  bool _cancel = false;
  int _scanFolders = 0;
  String _scanCurrent = '';

  /// Todos los discos; los que no se pueden leer (DVD vacío…) se muestran
  /// apagados.
  late final List<DriveInfo> _driveInfo = listDriveInfo();
  late final List<String> _drives = [
    for (final drive in _driveInfo)
      if (drive.readable) drive.path,
  ];

  /// Lo que no se pudo leer en la última búsqueda en los discos.
  List<(String, String)> _scanUnreadable = const [];
  late final _userFolders = userFolders();

  // Calidad, volumen y papelera.
  late final AudioQualityService _quality =
      widget.quality ?? AudioQualityService.instance;
  final Set<String> _selected = {};
  final Set<String> _deleted = {};
  final Set<String> _pendingInfo = {};
  Timer? _infoTimer;
  final Set<String> _measuring = {};
  final Set<String> _measured = {};
  final _stats = <String, (int, DateTime)>{};
  bool _reviewing = false;

  /// La revisión es para después marcar las copias peores.
  bool _marking = false;
  bool _reviewCancel = false;
  int _reviewDone = 0;
  int _reviewTotal = 0;
  String? _notice;
  Timer? _noticeTimer;

  /// Lo que se está mostrando (para marcar todo y revisar las repetidas).
  List<(String, List<_Entry>)> _visibleGroups = const [];

  // Pre-escucha.
  Player? _preview;
  String? _previewPath;
  double _previewFraction = 0;
  StreamSubscription<Duration>? _previewSub;
  StreamSubscription<bool>? _previewDone;

  @override
  void dispose() {
    _cancel = true;
    _reviewCancel = true;
    _scan?.cancel();
    _search.dispose();
    _infoTimer?.cancel();
    _noticeTimer?.cancel();
    _previewSub?.cancel();
    _previewDone?.cancel();
    _preview?.dispose();
    super.dispose();
  }

  void _notify(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  // ---------------------------------------------------------------------
  // Calidad y volumen
  // ---------------------------------------------------------------------

  (int, DateTime) _statOf(String path) {
    return _stats.putIfAbsent(path, () => fileStat(path));
  }

  CopyFacts _facts(_Entry e) {
    final file = e.file;
    final (size, modified) =
        file != null ? (file.size, file.modified) : _statOf(e.path);
    return _quality.factsFor(e.path, size, modified);
  }

  /// Pide (de a tandas) la calidad de lo que se está mostrando.
  void _needInfo(String path) {
    if (_quality.cachedInfo(path) != null || !_pendingInfo.add(path)) return;
    _infoTimer ??= Timer(const Duration(milliseconds: 60), () async {
      _infoTimer = null;
      final batch = _pendingInfo.toList();
      _pendingInfo.clear();
      await _quality.loadInfo(batch);
      if (mounted) setState(() {});
    });
  }

  Future<void> _measure(String path) async {
    if (_measured.contains(path) || !_measuring.add(path)) return;
    if (mounted) setState(() {});
    await _quality.measureLoudness(path);
    _measuring.remove(path);
    _measured.add(path);
    if (mounted) setState(() {});
  }

  /// Calidad y volumen de todas las copias (al desplegar una repetida).
  Future<void> _analyze(List<_Entry> entries) async {
    await _quality.loadInfo(entries.map((e) => e.path));
    if (!mounted) return;
    setState(() {});
    for (final e in entries) {
      if (!mounted || (_reviewing && _reviewCancel)) return;
      await _measure(e.path);
    }
  }

  bool _groupAnalyzed(List<_Entry> entries) =>
      entries.every((e) => _measured.contains(e.path));

  /// Revisa todas las repetidas que se están mostrando (las que ya estaban
  /// revisadas no se vuelven a medir). Con [thenMark], al terminar marca en
  /// todas las copias peores.
  Future<void> _reviewRepeated({bool thenMark = false}) async {
    final repeated = _visibleGroups.where((g) => g.$2.length > 1).toList();
    final pending = repeated.where((g) => !_groupAnalyzed(g.$2)).toList();
    setState(() {
      _reviewing = true;
      _marking = thenMark;
      _reviewCancel = false;
      _reviewDone = repeated.length - pending.length;
      _reviewTotal = repeated.length;
    });
    // La calidad de todas de una vez (es rápido); el volumen, de a una.
    await _quality.loadInfo([
      for (final (_, entries) in pending)
        for (final e in entries) e.path,
    ]);
    for (final (_, entries) in pending) {
      if (_reviewCancel || !mounted) break;
      await _analyze(entries);
      if (!mounted) return;
      setState(() => _reviewDone++);
    }
    if (!mounted) return;
    final stopped = _reviewCancel;
    setState(() {
      _reviewing = false;
      _marking = false;
    });
    if (thenMark) {
      _selectWorseCopies(stoppedAt: stopped ? _reviewDone : null);
    } else if (!stopped) {
      _notify('Listo: en cada repetida quedó marcada la RECOMENDADA. '
          '"Marcar las copias peores" las deja listas para la papelera.');
    }
  }

  /// "Marcar las copias peores": en todas las repetidas de la lista (revisa
  /// primero las que falten).
  Future<void> _markWorseEverywhere() async {
    final missing =
        _visibleGroups.any((g) => g.$2.length > 1 && !_groupAnalyzed(g.$2));
    if (missing) {
      await _reviewRepeated(thenMark: true);
    } else {
      _selectWorseCopies();
    }
  }

  // ---------------------------------------------------------------------
  // Marcar y mandar a la papelera
  // ---------------------------------------------------------------------

  bool _inDeck(String path) =>
      widget.mixer?.decks.any((d) => d.song?.filePath == path) ?? false;

  void _setSelected(Iterable<String> paths, bool value) {
    var blocked = 0;
    setState(() {
      for (final path in paths) {
        if (value && _inDeck(path)) {
          blocked++;
          continue;
        }
        value ? _selected.add(path) : _selected.remove(path);
      }
    });
    if (blocked > 0) {
      _notify(blocked == 1
          ? 'Esa canción está cargada en un deck: no se puede marcar.'
          : '$blocked canciones están cargadas en un deck: no se marcaron.');
    }
  }

  /// En cada repetida revisada: todas las copias menos la recomendada.
  /// [stoppedAt]: se detuvo la revisión y solo hay tantas revisadas.
  void _selectWorseCopies({int? stoppedAt}) {
    final worse = <String>[];
    var groups = 0;
    for (final (_, entries) in _visibleGroups) {
      if (entries.length < 2 || !_groupAnalyzed(entries)) continue;
      groups++;
      final verdicts = judgeCopies([for (final e in entries) _facts(e)]);
      for (final e in entries) {
        if (verdicts[e.path]?.recommended == true) {
          _selected.remove(e.path);
        } else {
          worse.add(e.path);
        }
      }
    }
    _setSelected(worse, true);
    final total = _visibleGroups.where((g) => g.$2.length > 1).length;
    final where =
        groups == 1 ? '1 canción repetida' : '$groups canciones repetidas';
    final partial = stoppedAt != null && groups < total
        ? ' Se detuvo la revisión: faltan ${total - groups} repetidas.'
        : '';
    if (worse.isEmpty) {
      if (partial.isNotEmpty) _notify(partial.trim());
      return;
    }
    _notify(worse.length == 1
        ? 'Marcada 1 copia peor en $where. Revisala (podés escucharla con el '
            'botón de play) y desmarcala si la querés conservar.$partial'
        : 'Marcadas ${worse.length} copias peores en $where. Revisalas '
            '(podés escucharlas con el botón de play) y desmarcá las que '
            'quieras conservar.$partial');
  }

  Future<void> _recycleSelected() async {
    final paths = _selected.where((path) => !_inDeck(path)).toList();
    if (paths.isEmpty) return;
    final total = paths.fold<int>(0, (sum, path) => sum + _statOf(path).$1);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Mandar ${paths.length} '
            '${paths.length == 1 ? 'archivo' : 'archivos'} a la papelera?'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Se borran de la PC y van a la Papelera de reciclaje de '
                  'Windows (${formatFileSize(total)}). Si te equivocás, se '
                  'recuperan desde ahí.'),
              const SizedBox(height: 12),
              for (final path in paths.take(8))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('•  ${p.basename(path)}   —   ${p.dirname(path)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              if (paths.length > 8) Text('… y ${paths.length - 8} más'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD9443B)),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Mandar a la papelera'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_previewPath != null && paths.contains(_previewPath)) {
      await _stopPreview();
    }
    final done = await _recycleWithProgress(paths);
    if (!mounted) return;
    final freed = done.fold<int>(0, (sum, path) => sum + _statOf(path).$1);
    setState(() {
      _deleted.addAll(done);
      _selected.removeAll(done);
      _scanned?.removeWhere((f) => done.contains(f.path));
      if (_source == _Source.folder && _folder != null) {
        _listing = listFolder(_folder!, extensions: _extensions);
      }
    });
    final failed = [
      for (final path in paths)
        if (!done.contains(path)) path
    ];
    _notify(failed.isEmpty
        ? '${done.length} a la papelera · ${formatFileSize(freed)} liberados.'
        : '${done.length} a la papelera; ${failed.length} no se pudieron (en '
            'uso o sin permiso).');
    if (done.isNotEmpty) widget.onFilesDeleted?.call(done.toList());
    await _showRecycleResult(done.length, freed, failed);
  }

  /// Manda [paths] a la papelera de a pocos, con una ventana que muestra
  /// el avance ("12 de 40 · 30 %") y el archivo que se está enviando.
  Future<Set<String>> _recycleWithProgress(List<String> paths) async {
    final progress = ValueNotifier<(int, String)>((0, ''));
    final done = <String>{};
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: ProgressTaskDialog(
          title: 'Mandando a la papelera…',
          progress: progress,
          total: paths.length,
        ),
      ),
    ));
    const batch = 3;
    for (var i = 0; i < paths.length; i += batch) {
      final chunk = paths.sublist(i, math.min(paths.length, i + batch));
      progress.value = (i, p.basename(chunk.first));
      done.addAll(await _quality.recycle(chunk));
      progress.value = (i + chunk.length, p.basename(chunk.last));
    }
    // Que se llegue a ver el 100 %.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    return done;
  }

  /// Confirmación de lo que se borró (y de lo que no se pudo).
  Future<void> _showRecycleResult(
      int done, int freed, List<String> failed) async {
    if (!mounted) return;
    final ok = failed.isEmpty;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle : Icons.warning_amber,
            color: ok ? DjColors.loop : DjColors.cue, size: 40),
        title: Text(done == 0
            ? 'No se borró nada'
            : ok
                ? 'Listo: ${done == 1 ? 'se borró 1 archivo' : 'se borraron $done archivos'}'
                : 'Se borraron $done de ${done + failed.length}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (done > 0)
                Text('${done == 1 ? 'Está' : 'Están'} en la Papelera de '
                    'reciclaje de Windows · ${formatFileSize(freed)} '
                    'liberados. Si te equivocaste, se ${done == 1 ? 'recupera' : 'recuperan'} '
                    'desde ahí (clic derecho → Restaurar).'),
              if (failed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                    '${failed.length == 1 ? 'Este no se pudo borrar' : 'Estos no se pudieron borrar'} '
                    '(lo está usando otro programa o no hay permiso):'),
                const SizedBox(height: 6),
                for (final path in failed.take(8))
                  Text('•  ${p.basename(path)}   —   ${p.dirname(path)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                if (failed.length > 8) Text('… y ${failed.length - 8} más'),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Pre-escucha
  // ---------------------------------------------------------------------

  Future<void> _togglePreview(_Entry e) async {
    if (_previewPath == e.path) {
      await _stopPreview();
      return;
    }
    final player = _preview ??= Player(
      configuration: const PlayerConfiguration(title: 'TK Music · pre-escucha'),
    );
    // Comparando copias de la misma canción, arranca en el mismo momento.
    final previous = _previewPath;
    final from =
        previous != null && duplicateKey(previous) == duplicateKey(e.path)
            ? player.state.position
            : null;
    await _previewSub?.cancel();
    await _previewDone?.cancel();
    setState(() {
      _previewPath = e.path;
      _previewFraction = 0;
    });
    unawaited(_measure(e.path));
    if (_playerMode && isAudioAvailable) {
      unawaited(sl<AudioHandler>().pause());
    }
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(
          'audio-device', widget.mixer?.outputDevice ?? 'auto');
    }
    await player.open(Media(e.path), play: false);
    var duration = player.state.duration;
    if (duration == Duration.zero) {
      duration = await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3), onTimeout: () => Duration.zero);
    }
    if (!mounted || _previewPath != e.path) return;
    final start = from ?? duration * 0.3;
    if (start > Duration.zero && start < duration) await player.seek(start);
    await player.play();
    _previewSub = player.stream.position.listen((position) {
      final total = player.state.duration.inMilliseconds;
      if (!mounted || total <= 0) return;
      setState(() =>
          _previewFraction = (position.inMilliseconds / total).clamp(0.0, 1.0));
    });
    _previewDone = player.stream.completed.listen((done) {
      if (done) unawaited(_stopPreview());
    });
  }

  Future<void> _stopPreview() async {
    await _previewSub?.cancel();
    await _previewDone?.cancel();
    _previewSub = null;
    _previewDone = null;
    await _preview?.stop();
    if (mounted) setState(() => _previewPath = null);
  }

  Future<void> _seekPreview(double fraction) async {
    final player = _preview;
    if (player == null) return;
    final total = player.state.duration;
    setState(() => _previewFraction = fraction);
    await player.seek(total * fraction);
  }

  // ---------------------------------------------------------------------

  void _openFolder(String path) {
    setState(() {
      _source = _Source.folder;
      _folder = path;
      _expanded.clear();
      _listing = listFolder(path, extensions: _extensions);
    });
  }

  void _startScan(List<String> roots, String label) {
    _scan?.cancel();
    _cancel = false;
    setState(() {
      _source = _Source.allDisks;
      _scanned = [];
      _scannedLabel = label;
      _scanFolders = 0;
      _expanded.clear();
    });
    _scan = scanMusic(roots, cancelled: () => _cancel, extensions: _extensions)
        .listen((progress) {
      if (!mounted) return;
      setState(() {
        _scanned = progress.found;
        _scanFolders = progress.folders;
        _scanCurrent = progress.current;
        _scanUnreadable = [
          for (final drive in _driveInfo)
            if (!drive.readable) (drive.path, drive.problem!),
          ...progress.unreadable,
        ];
        if (progress.done) _scan = null;
      });
    });
  }

  void _stopScan() {
    _cancel = true;
    _scan?.cancel();
    setState(() => _scan = null);
  }

  bool get _scanning => _scan != null;

  // ---------------------------------------------------------------------

  bool _passesFilters(_Entry e) {
    if (_deleted.contains(e.path)) return false;
    final ext = p.extension(e.path).toLowerCase();
    if (ext == '.mp3') {
      if (!_mp3) return false;
    } else if (ext == '.wav') {
      if (!_wav) return false;
    } else if (!_playerMode || !_other || !_extensions.contains(ext)) {
      return false;
    }
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return '${e.title} ${e.subtitle ?? ''}'.toLowerCase().contains(q) ||
        e.path.toLowerCase().contains(q);
  }

  /// Agrupa por canción (las repetidas quedan juntas).
  List<(String key, List<_Entry> entries)> _group(Iterable<_Entry> entries) {
    final groups = <String, List<_Entry>>{};
    for (final e in entries.where(_passesFilters)) {
      groups.putIfAbsent(duplicateKey(e.path), () => []).add(e);
    }
    final result = [
      for (final g in groups.entries)
        if (!_onlyRepeated || g.value.length > 1) (g.key, g.value),
    ]..sort((a, b) => a.$2.first.title
        .toLowerCase()
        .compareTo(b.$2.first.title.toLowerCase()));
    return result;
  }

  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    return DjPanel(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      accent: target == null ? null : DjColors.forDeck(target.label),
      child: Column(
        children: [
          _header(target),
          const SizedBox(height: 6),
          _toolbar(),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 210, child: _sidebar()),
                const VerticalDivider(width: 12, color: DjColors.border),
                Expanded(child: _content()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(DjDeck? target) {
    if (_playerMode) {
      return const Row(
        children: [
          Icon(Icons.folder_open, color: DjColors.muted, size: 20),
          SizedBox(width: 8),
          Text('Archivos de la PC',
              style: TextStyle(
                  color: DjColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          SizedBox(width: 10),
          Flexible(
            child: Text(
                'Todos los discos · repetidas, calidad y volumen · doble '
                'clic para reproducir',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: DjColors.muted, fontSize: 12)),
          ),
        ],
      );
    }
    return Row(
      children: [
        const Icon(Icons.folder_open, color: DjColors.muted, size: 20),
        const SizedBox(width: 8),
        Text(
          widget.onQueue != null
              ? 'Agregar a la lista del Auto DJ'
              : target == null
                  ? 'Archivos'
                  : 'Cargar en el deck ${target.label}',
          style: TextStyle(
            color:
                target == null ? DjColors.text : DjColors.forDeck(target.label),
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 10),
        const Text('Solo MP3 y WAV',
            style: TextStyle(color: DjColors.muted, fontSize: 12)),
        const Spacer(),
        if (target == null)
          Text(
              widget.onQueue != null
                  ? 'Doble clic: agregar a la lista   '
                  : 'Doble clic: al deck que no está sonando   ',
              style: const TextStyle(color: DjColors.muted, fontSize: 12)),
        IconButton(
          tooltip: 'Cerrar',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close, color: DjColors.muted),
        ),
      ],
    );
  }

  Widget _toolbar() {
    Widget chip(String label, bool value, ValueChanged<bool> onChanged,
            {Color color = DjColors.deckA}) =>
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: FilterChip(
            label: Text(label),
            selected: value,
            onSelected: onChanged,
            selectedColor: color.withValues(alpha: 0.25),
            checkmarkColor: color,
            labelStyle: TextStyle(
                color: value ? DjColors.text : DjColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700),
            side: BorderSide(color: value ? color : DjColors.border),
            backgroundColor: DjColors.panelHigh,
            visualDensity: VisualDensity.compact,
          ),
        );
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 36,
            child: TextField(
              controller: _search,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v.trim()),
              style: const TextStyle(color: DjColors.text, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Buscar canción, artista o carpeta',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                filled: true,
                fillColor: DjColors.panelHigh,
                border: OutlineInputBorder(borderSide: BorderSide.none),
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ),
        chip('MP3', _mp3, (v) => setState(() => _mp3 = v)),
        chip('WAV', _wav, (v) => setState(() => _wav = v)),
        if (_playerMode)
          chip('Otros', _other, (v) => setState(() => _other = v)),
        chip('Solo repetidas', _onlyRepeated,
            (v) => setState(() => _onlyRepeated = v),
            color: DjColors.cue),
      ],
    );
  }

  Widget _sidebar() {
    Widget title(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Text(text,
              style: const TextStyle(
                  color: DjColors.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2)),
        );
    Widget item(IconData icon, String label, bool selected, VoidCallback onTap,
            {String? trailing}) =>
        Material(
          color: selected ? DjColors.panelHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  Icon(icon,
                      size: 18,
                      color: selected ? DjColors.deckA : DjColors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: selected ? DjColors.text : DjColors.muted,
                            fontSize: 13,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500)),
                  ),
                  if (trailing != null)
                    Text(trailing,
                        style: const TextStyle(
                            color: DjColors.muted, fontSize: 11)),
                ],
              ),
            ),
          ),
        );

    final inDrive = _source == _Source.folder ? _folder : null;
    return ListView(
      children: [
        title('BIBLIOTECA'),
        item(
            Icons.library_music,
            _playerMode ? 'Todas mis canciones' : 'Biblioteca TK Music',
            _source == _Source.library, () {
          setState(() {
            _source = _Source.library;
            _expanded.clear();
          });
        }, trailing: _playerMode ? '${widget.librarySongs.length}' : null),
        // En el modo reproductor la biblioteca ya son todos los discos.
        if (!_playerMode)
          item(
            Icons.travel_explore,
            'Todas las canciones',
            _source == _Source.allDisks,
            () {
              if (_scanned == null && !_scanning) {
                _startScan(_drives, 'todos los discos');
              } else {
                setState(() => _source = _Source.allDisks);
              }
            },
            trailing: _scanned == null ? null : '${_scanned!.length}',
          ),
        title('DISCOS'),
        for (final drive in _driveInfo)
          if (drive.readable)
            item(
              Icons.storage,
              _driveLabel(drive.path),
              inDrive != null && p.rootPrefix(inDrive) == drive.path,
              () => _openFolder(drive.path),
            )
          else
            Tooltip(
              message: 'No se puede leer: ${drive.problem}. Si es una '
                  'lectora de DVD o un pendrive, fijate que tenga el disco '
                  'puesto; mientras tanto se saltea.',
              child: Opacity(
                opacity: 0.45,
                child: item(
                  Icons.block,
                  _driveLabel(drive.path),
                  false,
                  () => _notify('No se puede leer ${drive.path} '
                      '(${drive.problem}): se saltea y se sigue con los '
                      'demás discos.'),
                  trailing: 'no se lee',
                ),
              ),
            ),
        if (_userFolders.isNotEmpty) title('CARPETAS'),
        for (final (label, path) in _userFolders)
          item(Icons.folder, label, inDrive == path, () => _openFolder(path)),
        if (_playerMode &&
            DesktopLibraryScanner.instance.hiddenFolders.isNotEmpty) ...[
          title('FUERA DE LA BIBLIOTECA'),
          for (final hidden in DesktopLibraryScanner.instance.hiddenFolders)
            Tooltip(
              message: '$hidden\nTocá para volver a incluirla',
              child: item(
                Icons.visibility_off_outlined,
                p.basename(hidden),
                false,
                () => _showFolder(hidden),
                trailing: 'incluir',
              ),
            ),
        ],
      ],
    );
  }

  static String _driveLabel(String drive) =>
      drive.endsWith(':\\') ? 'Disco ${drive.substring(0, 2)}' : drive;

  Widget _content() {
    switch (_source) {
      case _Source.library:
        final list = _list(
          _group(widget.librarySongs.map(_Entry.fromSong)),
          header: _playerMode ? 'Todas mis canciones' : 'Biblioteca TK Music',
          emptyText: _playerMode
              ? 'No hay canciones con estos filtros.'
              : 'No hay MP3 ni WAV en la biblioteca con estos filtros.',
        );
        if (!_playerMode) return list;
        return Column(
          children: [
            _libraryScanStatus(),
            Expanded(child: list),
          ],
        );
      case _Source.allDisks:
        return _allDisks();
      case _Source.folder:
        return _folderView();
    }
  }

  /// Modo reproductor: cómo está la búsqueda de canciones en todos los
  /// discos (la biblioteca) y el botón para volver a buscar.
  Widget _libraryScanStatus() {
    final scanner = DesktopLibraryScanner.instance;
    return ListenableBuilder(
      listenable: scanner,
      builder: (context, _) {
        const style = TextStyle(color: DjColors.muted, fontSize: 12);
        if (scanner.scanning) {
          return Row(
            children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Buscando canciones en todos los discos… '
                  '${scanner.foundSoFar} archivos en ${scanner.foldersSoFar} '
                  'carpetas · ${scanner.currentFolder}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              TextButton(
                  onPressed: scanner.cancelScan, child: const Text('Detener')),
            ],
          );
        }
        final last = scanner.lastScan;
        final notRead = scanner.unreadable;
        final row = Row(
          children: [
            Expanded(
              child: Text(
                last == null
                    ? 'Canciones de todos los discos de la PC'
                    : 'Canciones de todos los discos · revisado '
                        '${_ago(last)}',
                style: style,
              ),
            ),
            TextButton.icon(
              onPressed: () => unawaited(scanner.scan()),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Buscar de nuevo en todos los discos'),
            ),
          ],
        );
        if (notRead.isEmpty) return row;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row,
            _unreadableNote(notRead),
          ],
        );
      },
    );
  }

  /// "No se pudo leer: E:\ (El dispositivo no está listo)" — se salteó.
  Widget _unreadableNote(List<(String, String)> notRead) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 14, color: DjColors.cue),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'No se pudo leer: '
                '${notRead.map((u) => '${u.$1} (${u.$2})').join(', ')}. '
                'Se salteó y se siguió con los demás.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: DjColors.cue, fontSize: 12),
              ),
            ),
          ],
        ),
      );

  Future<void> _hideFolder(String folder) async {
    await DesktopLibraryScanner.instance.hideFolder(folder);
    if (!mounted) return;
    setState(() {});
    _notify('"${p.basename(folder)}" ya no forma parte de la biblioteca. Se '
        'puede volver a incluir desde "Fuera de la biblioteca".');
  }

  Future<void> _showFolder(String folder) async {
    await DesktopLibraryScanner.instance.showFolder(folder);
    if (!mounted) return;
    setState(() {});
    _notify('"${p.basename(folder)}" vuelve a la biblioteca: buscando sus '
        'canciones…');
  }

  static String _ago(DateTime time) {
    final minutes = DateTime.now().difference(time).inMinutes;
    if (minutes < 1) return 'recién';
    if (minutes < 60) return 'hace $minutes min';
    final hours = minutes ~/ 60;
    if (hours < 24) return 'hace $hours h';
    return 'hace ${hours ~/ 24} días';
  }

  Widget _allDisks() {
    final found = _scanned ?? const [];
    final status = _scanning
        ? Row(
            children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Buscando en $_scannedLabel… ${found.length} canciones en '
                  '$_scanFolders carpetas · $_scanCurrent',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: DjColors.muted, fontSize: 12),
                ),
              ),
              TextButton(onPressed: _stopScan, child: const Text('Detener')),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: Text(
                  _scanned == null
                      ? ''
                      : '${found.length} canciones en $_scannedLabel',
                  style: const TextStyle(color: DjColors.muted, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: () => _startScan(_drives, 'todos los discos'),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Buscar de nuevo en todos los discos'),
              ),
            ],
          );
    return Column(
      children: [
        status,
        if (_scanUnreadable.isNotEmpty) _unreadableNote(_scanUnreadable),
        Expanded(
          child: _list(
            _group(found.map(_Entry.fromFile)),
            emptyText: _scanning
                ? 'Buscando…'
                : 'No se encontraron MP3 ni WAV con estos filtros.',
          ),
        ),
      ],
    );
  }

  Widget _folderView() {
    final folder = _folder!;
    final parts = <String>[];
    var current = folder;
    while (true) {
      parts.insert(0, current);
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    // reverse: en rutas largas se ve siempre la carpeta actual.
    final breadcrumb = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              const Icon(Icons.chevron_right, size: 16, color: DjColors.muted),
            InkWell(
              onTap: () => _openFolder(parts[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  i == 0 ? _driveLabel(parts[i]) : p.basename(parts[i]),
                  style: TextStyle(
                    color:
                        i == parts.length - 1 ? DjColors.text : DjColors.muted,
                    fontSize: 13,
                    fontWeight: i == parts.length - 1
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Subir una carpeta',
              onPressed: p.dirname(folder) == folder
                  ? null
                  : () => _openFolder(p.dirname(folder)),
              icon: const Icon(Icons.arrow_upward, size: 18),
            ),
            Expanded(child: breadcrumb),
            TextButton.icon(
              onPressed: () => _startScan([folder],
                  p.basename(folder).isEmpty ? folder : p.basename(folder)),
              icon: const Icon(Icons.manage_search, size: 16),
              label: const Text('Buscar aquí y en subcarpetas'),
            ),
            if (_playerMode && p.dirname(folder) != folder)
              IconButton(
                tooltip: 'No incluir esta carpeta en la biblioteca (por '
                    'ejemplo, sonidos de un programa o un juego)',
                onPressed: () => _hideFolder(folder),
                icon: const Icon(Icons.visibility_off_outlined, size: 18),
              ),
          ],
        ),
        Expanded(
          child: FutureBuilder(
            future: _listing,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final folders = _query.isEmpty
                  ? data.folders
                  : data.folders
                      .where((f) => p
                          .basename(f)
                          .toLowerCase()
                          .contains(_query.toLowerCase()))
                      .toList();
              return _list(
                _group(data.files.map(_Entry.fromFile)),
                folders: folders,
                emptyText: 'No hay MP3 ni WAV en esta carpeta.',
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------

  Widget _list(
    List<(String, List<_Entry>)> groups, {
    List<String> folders = const [],
    String? header,
    required String emptyText,
  }) {
    _visibleGroups = groups;
    // Lista plana: carpetas, grupos y (si están desplegados) sus copias.
    final rows = <Widget Function()>[];
    for (final folder in folders) {
      rows.add(() => _folderRow(folder));
    }
    final repeated = groups.where((g) => g.$2.length > 1).length;
    for (final (key, entries) in groups) {
      if (entries.length == 1) {
        rows.add(() => _entryRow(entries.first));
        continue;
      }
      final open = _expanded.contains(key);
      rows.add(() => _groupRow(key, entries, open));
      if (open) {
        for (final e in entries) {
          rows.add(() => _entryRow(e, twins: entries));
        }
      }
    }
    final allPaths = [
      for (final (_, entries) in groups)
        for (final e in entries)
          if (!_inDeck(e.path)) e.path,
    ];
    final selectedHere = allPaths.where(_selected.contains).length;
    const headerStyle = TextStyle(
        color: DjColors.muted,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1);
    return Column(
      children: [
        _actionsBar(repeated),
        if (_previewPath != null) _previewBar(),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Tooltip(
                  message:
                      selectedHere == allPaths.length && allPaths.isNotEmpty
                          ? 'Desmarcar todas'
                          : 'Marcar todas las que se ven',
                  child: Checkbox(
                    tristate: true,
                    visualDensity: VisualDensity.compact,
                    value: selectedHere == 0
                        ? false
                        : selectedHere == allPaths.length
                            ? true
                            : null,
                    onChanged: allPaths.isEmpty
                        ? null
                        : (_) => _setSelected(
                            allPaths, selectedHere != allPaths.length),
                  ),
                ),
              ),
              const SizedBox(width: 28),
              Expanded(
                flex: 5,
                child: Text(
                  '${header ?? 'TÍTULO'}  ·  ${groups.length} canciones'
                  '${repeated > 0 ? '  ·  $repeated repetidas' : ''}',
                  style: headerStyle,
                ),
              ),
              const Expanded(
                  flex: 4,
                  child: Text('ARTISTA / CARPETA', style: headerStyle)),
              const SizedBox(
                  width: 76, child: Text('CALIDAD', style: headerStyle)),
              const SizedBox(
                  width: 50, child: Text('VOL dB', style: headerStyle)),
              const SizedBox(width: 48, child: Text('BPM', style: headerStyle)),
              const SizedBox(
                  width: 36, child: Text('TONO', style: headerStyle)),
              const SizedBox(
                  width: 64, child: Text('TAMAÑO', style: headerStyle)),
              const SizedBox(width: 76),
            ],
          ),
        ),
        const Divider(height: 8, color: DjColors.border),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(emptyText,
                      style: const TextStyle(color: DjColors.muted)))
              : ListenableBuilder(
                  listenable: Listenable.merge([
                    if (widget.mixer != null) ...[
                      widget.mixer!.a,
                      widget.mixer!.b
                    ],
                  ]),
                  builder: (context, _) => ListView.builder(
                    itemCount: rows.length,
                    itemExtent: 36,
                    itemBuilder: (context, index) => rows[index](),
                  ),
                ),
        ),
      ],
    );
  }

  /// Revisar repetidas, marcar las peores y mandar a la papelera.
  Widget _actionsBar(int repeated) {
    final selectedSize =
        _selected.fold<int>(0, (sum, path) => sum + _statOf(path).$1);
    if (repeated == 0 && _selected.isEmpty && _notice == null) {
      return const SizedBox.shrink();
    }
    final left = <Widget>[
      if (_reviewing) ...[
        const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2)),
        Text(
            _marking
                ? 'Revisando $_reviewDone de $_reviewTotal repetidas para '
                    'marcar las copias peores…'
                : 'Revisando $_reviewDone de $_reviewTotal repetidas…',
            style: const TextStyle(color: DjColors.text, fontSize: 12)),
        TextButton(
          onPressed: () => setState(() => _reviewCancel = true),
          child: const Text('Detener'),
        ),
      ] else if (repeated > 0)
        Tooltip(
          message: 'Mide la calidad y el volumen de cada copia de las '
              'canciones repetidas y marca la RECOMENDADA',
          child: TextButton.icon(
            onPressed: _reviewRepeated,
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: Text('Revisar repetidas ($repeated)'),
          ),
        ),
      if (repeated > 0 && !_reviewing)
        Tooltip(
          message: 'En todas las canciones repetidas de la lista: revisa las '
              'que falten y marca todas las copias menos la RECOMENDADA',
          child: TextButton.icon(
            onPressed: _markWorseEverywhere,
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('Marcar las copias peores'),
          ),
        ),
    ];
    final right = <Widget>[
      if (_selected.isNotEmpty) ...[
        Text(
            '${_selected.length} '
            '${_selected.length == 1 ? 'marcada' : 'marcadas'} · '
            '${formatFileSize(selectedSize)}',
            style: const TextStyle(color: DjColors.text, fontSize: 12)),
        TextButton(
          onPressed: () => setState(_selected.clear),
          child: const Text('Desmarcar'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD9443B),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: _recycleSelected,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: Text('Mandar a la papelera (${_selected.length})'),
        ),
      ],
    ];
    Widget wrap(List<Widget> children, WrapAlignment alignment) => Wrap(
          spacing: 8,
          runSpacing: 2,
          alignment: alignment,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: DjColors.panelHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (left.isNotEmpty || right.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth > 900
                  ? Row(
                      children: [
                        Expanded(child: wrap(left, WrapAlignment.start)),
                        Flexible(child: wrap(right, WrapAlignment.end)),
                      ],
                    )
                  : wrap([...left, ...right], WrapAlignment.start),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
              child: Text(_notice!,
                  style: const TextStyle(color: DjColors.cue, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// Lo que se está pre-escuchando, con la barra para moverse.
  Widget _previewBar() {
    final path = _previewPath!;
    final mixing = widget.mixer?.decks.any((d) => d.playing) ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: DjColors.loop.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: DjColors.loop.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Parar la pre-escucha',
            visualDensity: VisualDensity.compact,
            onPressed: _stopPreview,
            icon: const Icon(Icons.stop, color: DjColors.loop),
          ),
          Flexible(
            flex: 2,
            child: Text(p.basename(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: DjColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
          Expanded(
            flex: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: _previewFraction,
                activeColor: DjColors.loop,
                onChanged: _seekPreview,
              ),
            ),
          ),
          if (mixing)
            const Tooltip(
              message: 'La pre-escucha sale por los mismos parlantes que la '
                  'mezcla',
              child: Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.warning_amber, size: 18, color: DjColors.cue),
              ),
            ),
        ],
      ),
    );
  }

  Widget _folderRow(String folder) {
    return InkWell(
      onTap: () => _openFolder(folder),
      hoverColor: DjColors.panelHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            const SizedBox(width: 28),
            const Icon(Icons.folder, size: 18, color: DjColors.cue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.basename(folder),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: DjColors.text, fontSize: 13)),
            ),
            if (_playerMode)
              IconButton(
                tooltip: 'No incluir esta carpeta en la biblioteca',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => _hideFolder(folder),
                icon: const Icon(Icons.visibility_off_outlined,
                    color: DjColors.muted),
              ),
            const Icon(Icons.chevron_right, size: 18, color: DjColors.muted),
          ],
        ),
      ),
    );
  }

  Widget _groupRow(String key, List<_Entry> entries, bool open) {
    for (final e in entries) {
      _needInfo(e.path);
    }
    final verdicts = judgeCopies([for (final e in entries) _facts(e)]);
    final best = entries.firstWhere(
        (e) => verdicts[e.path]?.recommended == true,
        orElse: () => entries.first);
    final analyzed = _groupAnalyzed(entries);
    final sameSize =
        entries.every((e) => _facts(e).size == _facts(entries.first).size);
    final selectable = [
      for (final e in entries)
        if (!_inDeck(e.path)) e.path
    ];
    final selectedCount = selectable.where(_selected.contains).length;
    final measuring = entries.any((e) => _measuring.contains(e.path));
    return InkWell(
      onTap: () {
        setState(() => open ? _expanded.remove(key) : _expanded.add(key));
        if (!open) unawaited(_analyze(entries));
      },
      hoverColor: DjColors.panelHigh,
      child: Container(
        padding: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          color: DjColors.cue.withValues(alpha: 0.06),
          border: const Border(left: BorderSide(color: DjColors.cue, width: 3)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Checkbox(
                tristate: true,
                visualDensity: VisualDensity.compact,
                value: selectedCount == 0
                    ? false
                    : selectedCount == selectable.length
                        ? true
                        : null,
                onChanged: selectable.isEmpty
                    ? null
                    : (_) => _setSelected(
                        selectable, selectedCount != selectable.length),
              ),
            ),
            SizedBox(
              width: 28,
              child: Icon(open ? Icons.expand_more : Icons.chevron_right,
                  size: 18, color: DjColors.cue),
            ),
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  Flexible(
                    flex: 3,
                    child: Text(entries.first.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: DjColors.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  _badges([
                    _badge(
                      'REPETIDA ×${entries.length}'
                      '${sameSize ? ' · IDÉNTICAS' : ''}',
                      DjColors.cue,
                      sameSize
                          ? 'Las ${entries.length} copias pesan lo mismo: son '
                              'el mismo archivo repetido'
                          : 'La misma canción está ${entries.length} veces '
                              '(tocá para ver cada copia)',
                    ),
                    if (measuring) ...[
                      const SizedBox(width: 6),
                      const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5)),
                    ] else if (analyzed) ...[
                      const SizedBox(width: 6),
                      const Tooltip(
                        message: 'Revisada: la RECOMENDADA es la que conviene '
                            'dejar',
                        child: Icon(Icons.fact_check,
                            size: 15, color: DjColors.loop),
                      ),
                    ],
                  ]),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                  entries.first.file != null
                      ? '${entries.map((e) => p.dirname(e.path)).toSet().length} carpetas'
                      : (entries.first.subtitle ?? ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: DjColors.muted, fontSize: 12)),
            ),
            SizedBox(width: 76, child: _qualityCell(_facts(best))),
            const SizedBox(width: 50),
            ..._featureCells(best.path),
            const SizedBox(width: 64),
            SizedBox(
              width: 76,
              child: Tooltip(
                message: 'Carga la copia RECOMENDADA',
                child: _loadButtons(best),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Las marcas de una fila: si no entran, se recortan (el título ya se
  /// achica con "…").
  Widget _badges(List<Widget> children) => Flexible(
        flex: 2,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );

  Widget _badge(String text, Color color, String tooltip) => Tooltip(
        message: tooltip,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.black,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900)),
        ),
      );

  Widget _qualityCell(CopyFacts facts) {
    final label = facts.qualityLabel;
    if (label == null) return const SizedBox.shrink();
    final color = facts.isWav
        ? const Color(0xFF20C6E6)
        : facts.lowQuality
            ? const Color(0xFFFF5A4E)
            : (facts.kbps ?? 0) >= 250
                ? DjColors.loop
                : DjColors.cue;
    return Text(label,
        maxLines: 1,
        style: TextStyle(
            color: color, fontSize: 11.5, fontWeight: FontWeight.w700));
  }

  Widget _entryRow(_Entry entry, {List<_Entry> twins = const []}) {
    final child = twins.isNotEmpty;
    _needInfo(entry.path);
    final inA = widget.mixer?.a.song?.filePath == entry.path;
    final inB = widget.mixer?.b.song?.filePath == entry.path;
    final color = inA
        ? DjColors.deckA
        : inB
            ? DjColors.deckB
            : DjColors.text;
    final target = widget.target;
    final facts = _facts(entry);
    final verdict = judgeCopies([
      for (final e in child ? twins : [entry]) _facts(e)
    ])[entry.path]!;
    final identical =
        child && twins.where((t) => _facts(t).size == facts.size).length > 1;
    final previewing = _previewPath == entry.path;
    final db = _quality.cachedLoudness(entry.path);
    const muted = TextStyle(color: DjColors.muted, fontSize: 12);
    final reasons = verdict.reasons.join(' · ');
    return InkWell(
      onTap:
          target == null ? null : () => widget.onLoad!(target, entry.toSong()),
      onDoubleTap: _playerMode
          ? () => _play(entry)
          : widget.onQueue != null
              ? () => _queue(entry)
              : target == null
                  ? () => widget.onLoadToFree!(entry.toSong())
                  : null,
      hoverColor: DjColors.panelHigh,
      child: Container(
        padding: const EdgeInsets.only(right: 4),
        color: previewing ? DjColors.loop.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Tooltip(
                message: inA || inB
                    ? 'Está cargada en un deck'
                    : 'Marcar para mandar a la papelera',
                child: Checkbox(
                  visualDensity: VisualDensity.compact,
                  value: _selected.contains(entry.path),
                  onChanged: inA || inB
                      ? null
                      : (v) => _setSelected([entry.path], v ?? false),
                ),
              ),
            ),
            SizedBox(
              width: 28,
              child: IconButton(
                tooltip: previewing ? 'Parar' : 'Escuchar (pre-escucha)',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                iconSize: 20,
                onPressed: () => _togglePreview(entry),
                icon: Icon(
                    previewing ? Icons.stop_circle : Icons.play_circle_outline,
                    color: previewing ? DjColors.loop : DjColors.muted),
              ),
            ),
            if (child)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.subdirectory_arrow_right,
                    size: 16, color: DjColors.cue),
              ),
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  Flexible(
                    flex: 3,
                    child: Text(
                      child ? p.basename(entry.path) : entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _badges([
                    if (verdict.recommended)
                      _badge('RECOMENDADA', DjColors.loop,
                          'La que conviene dejar: $reasons'),
                    if (verdict.lowQuality)
                      _badge('BAJA CALIDAD', const Color(0xFFFF5A4E), reasons),
                    if (verdict.lowVolume)
                      _badge('BAJO VOLUMEN', DjColors.cue, reasons),
                    if (verdict.cut)
                      _badge('CORTADA', const Color(0xFFFF8A3D), reasons),
                    if (verdict.fakeFormat != null)
                      _badge('FORMATO FALSO', const Color(0xFFB45CFF), reasons),
                  ]),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Tooltip(
                message: entry.path,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    child ? p.dirname(entry.path) : (entry.subtitle ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
              ),
            ),
            SizedBox(width: 76, child: _qualityCell(facts)),
            SizedBox(
              width: 50,
              child: _measuring.contains(entry.path)
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5)),
                    )
                  : Text(
                      db == null
                          ? ''
                          : db.toStringAsFixed(1).replaceAll('.', ','),
                      style: verdict.lowVolume
                          ? muted.copyWith(color: DjColors.cue)
                          : muted),
            ),
            ..._featureCells(entry.path),
            SizedBox(
              width: 64,
              child: Text(
                facts.size == 0 ? '' : formatFileSize(facts.size),
                style: identical ? muted.copyWith(color: DjColors.cue) : muted,
              ),
            ),
            SizedBox(width: 76, child: _loadButtons(entry)),
          ],
        ),
      ),
    );
  }

  List<Widget> _featureCells(String path) {
    final f = TrackFeaturesStore.instance.cached(path);
    const muted = TextStyle(color: DjColors.muted, fontSize: 12);
    return [
      SizedBox(
          width: 48,
          child: Text(f?.hasTempo == true ? f!.bpm.toStringAsFixed(1) : '',
              style: muted)),
      SizedBox(
          width: 36,
          child: Text(f?.camelot ?? '',
              style: muted.copyWith(color: const Color(0xFFB45CFF)))),
    ];
  }

  /// Modo reproductor: suena [entry] con lo que se ve como cola (de cada
  /// repetida, la copia recomendada; o la copia que se eligió).
  Future<void> _play(_Entry entry) async {
    final queue = <Song>[];
    var index = 0;
    for (final (_, entries) in _visibleGroups) {
      final chosen = entries.contains(entry)
          ? entry
          : entries.length == 1
              ? entries.first
              : entries.firstWhere(
                  (e) =>
                      judgeCopies([for (final c in entries) _facts(c)])[e.path]
                          ?.recommended ==
                      true,
                  orElse: () => entries.first);
      if (identical(chosen, entry)) index = queue.length;
      queue.add(chosen.toSong());
    }
    if (queue.isEmpty) queue.add(entry.toSong());
    await widget.onPlay!(queue[index], queue);
  }

  void _queue(_Entry entry) {
    widget.onQueue!(entry.toSong());
    _notify('Agregada a la lista: ${entry.title}');
  }

  Widget _loadButtons(_Entry entry) {
    if (widget.onQueue != null) {
      return SizedBox(
        height: 24,
        child: DjPad(
          label: '+ LISTA',
          color: DjColors.cue,
          dense: true,
          tooltip: 'Agregar al final de la lista del Auto DJ',
          onTap: () => _queue(entry),
        ),
      );
    }
    if (_playerMode) {
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          height: 26,
          width: 64,
          child: DjPad(
            label: 'PLAY',
            icon: Icons.play_arrow,
            color: DjColors.loop,
            dense: true,
            tooltip: 'Reproducir (con lo que se ve como cola)',
            onTap: () => _play(entry),
          ),
        ),
      );
    }
    final mixer = widget.mixer!;
    final target = widget.target;
    if (target != null) {
      return SizedBox(
        height: 24,
        child: DjPad(
          label: 'CARGAR',
          color: DjColors.forDeck(target.label),
          dense: true,
          tooltip: 'Cargar en el deck ${target.label}',
          onTap: () => widget.onLoad!(target, entry.toSong()),
        ),
      );
    }
    final inA = mixer.a.song?.filePath == entry.path;
    final inB = mixer.b.song?.filePath == entry.path;
    return Row(
      children: [
        for (final (deck, active) in [
          (mixer.a, inA),
          (mixer.b, inB),
        ]) ...[
          if (deck.label == 'B') const SizedBox(width: 4),
          Expanded(
            child: SizedBox(
              height: 22,
              child: DjPad(
                label: deck.label,
                color: DjColors.forDeck(deck.label),
                dense: true,
                active: active,
                tooltip: 'Cargar en el deck ${deck.label}',
                onTap: () => widget.onLoad!(deck, entry.toSong()),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
