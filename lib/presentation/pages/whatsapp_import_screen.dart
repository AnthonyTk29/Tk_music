import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/core/errors/error_reporter.dart';
import 'package:tk_music/domain/entities/song_id.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/repositories/song_repository.dart';
import 'package:tk_music/presentation/navigation/breadcrumbs.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/progress_task_dialog.dart';
import 'package:tk_music/services/basic_player.dart';
import 'package:tk_music/services/dj/music_files.dart' show formatFileSize;
import 'package:tk_music/services/whatsapp_files.dart';
import 'package:tk_music/services/whatsapp_import_service.dart';

/// Un audio de WhatsApp en la lista: de la carpeta habilitada (se puede
/// navegar y borrar) o solo de la biblioteca del sistema (reenviados,
/// cuando todavía no se habilitó la carpeta).
class _WaAudio {
  _WaAudio({
    required this.key,
    required this.song,
    required this.voiceNote,
    this.date,
    this.size,
    this.file,
    this.folderName,
  });

  /// docId (carpeta habilitada) o ruta (biblioteca del sistema).
  final String key;
  final Song song;
  final bool voiceNote;
  final DateTime? date;
  final int? size;

  /// null: no está en la carpeta habilitada, no se puede borrar desde acá.
  final WaFile? file;
  final String? folderName;

  bool get deletable => file != null;
}

class _Data {
  _Data(this.tree, this.audios, {this.treeError})
      : byDocId = {
          for (final a in audios)
            if (a.file != null) a.file!.docId: a,
        };

  final WaTree? tree;
  final List<_WaAudio> audios;
  final Map<String, _WaAudio> byDocId;
  final String? treeError;
}

enum _View { folders, all }

enum _Filter { all, voice, audio }

/// Gestor de los audios de WhatsApp (Android): navegar por las carpetas de
/// WhatsApp o ver todos los audios juntos, buscar, escuchar, pasarlos a la
/// biblioteca (se copian a Música/TK Music/Audios de WhatsApp) y borrarlos,
/// de a uno, todos o carpetas enteras. Borrar y pasar muestran una ventana
/// de avance y un resumen de lo que se hizo y lo que no.
///
/// Para navegar, ver las notas de voz y borrar hace falta habilitar una vez
/// la carpeta de WhatsApp (selector de Android, que se abre directo ahí):
/// WhatsApp guarda las notas de voz donde el sistema no las indexa. Sin
/// eso, se ven solo los audios reenviados y solo se pueden pasar.
class WhatsAppImportScreen extends StatefulWidget {
  const WhatsAppImportScreen({
    super.key,
    @visibleForTesting this.files,
    @visibleForTesting this.loadForwarded,
    @visibleForTesting this.importAudio,
  });

  final WhatsAppFiles? files;
  final Future<List<Song>> Function()? loadForwarded;
  final Future<void> Function(Song song)? importAudio;

  @override
  State<WhatsAppImportScreen> createState() => _WhatsAppImportScreenState();
}

class _WhatsAppImportScreenState extends State<WhatsAppImportScreen> {
  /// Carpeta de WhatsApp habilitada (se llamaba así cuando era solo para
  /// las notas de voz; se mantiene para no pedirla de nuevo).
  final _prefs = WhatsAppLibraryPrefs();

  late final WhatsAppFiles _files = widget.files ?? WhatsAppFiles();
  final _search = TextEditingController();

  // Reproductor propio y liviano para escuchar; se crea recién al usarlo.
  BasicPlayer? _previewPlayer;
  StreamSubscription<void>? _previewDone;
  String? _previewingKey;

  late Future<_Data> _future;
  String? _rootUri;
  Set<String> _imported = {};

  _View? _viewChoice;
  _Filter _filter = _Filter.all;
  String? _folderDocId;

  final _selectedAudios = <String>{};
  final _selectedFolders = <String>{};

  @override
  void initState() {
    super.initState();
    _future = _load();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _previewDone?.cancel();
    _previewPlayer?.dispose();
    _search.dispose();
    super.dispose();
  }

  // ---- Datos ----

  Future<_Data> _load() async {
    try {
      _rootUri = await _prefs.rootUri();
      _imported = await _prefs.imported();
    } catch (_) {}

    var forwarded = const <Song>[];
    try {
      forwarded = await (widget.loadForwarded ??
          () => sl<SongRepository>().getWhatsAppAudios())();
    } catch (_) {}

    WaTree? tree;
    String? treeError;
    final root = _rootUri;
    if (root != null) {
      try {
        tree = await _files.listTree(root);
      } on WhatsAppFilesException catch (e) {
        // Permiso perdido (WhatsApp reinstalado, carpeta movida): se vuelve
        // a pedir con el botón.
        treeError = e.noPermission
            ? 'Se perdió el permiso de la carpeta de WhatsApp: volvé a '
                'habilitarla.'
            : 'No se pudo leer la carpeta de WhatsApp (${e.message}).';
      } catch (e) {
        treeError = 'No se pudo leer la carpeta de WhatsApp ($e).';
      }
    }

    final byName = {
      for (final song in forwarded)
        song.filePath.split(RegExp(r'[/\\]')).last.toLowerCase(): song,
    };
    final audios = <_WaAudio>[];
    if (tree != null) {
      for (final file in tree.files) {
        final known = byName.remove(file.name.toLowerCase());
        audios.add(_WaAudio(
          key: file.docId,
          song: Song(
            mediaStoreId: stableSongId(file.uri),
            title: file.title,
            filePath: file.uri,
            duration: known?.duration,
          ),
          voiceNote: file.voiceNote,
          date: file.date,
          size: file.size,
          file: file,
          folderName: _folderLabel(tree.folder(file.parent)?.name ?? ''),
        ));
      }
    }
    for (final song in byName.values) {
      audios.add(_WaAudio(
        key: song.filePath,
        song: song.copyWith(title: friendlyWhatsAppTitle(song.title)),
        voiceNote: isWhatsAppVoiceNote(song.filePath),
        date: whatsAppDate(song.filePath) ?? song.dateAdded,
      ));
    }
    // Los más recientes primero.
    audios.sort((a, b) =>
        (b.date ?? DateTime(2000)).compareTo(a.date ?? DateTime(2000)));

    // Si la carpeta en la que se estaba ya no existe (se borró), a la raíz.
    if (tree == null ||
        (_folderDocId != null && tree.folder(_folderDocId!) == null)) {
      _folderDocId = null;
    }
    return _Data(tree, audios, treeError: treeError);
  }

  void _reload() {
    setState(() => _future = _load());
  }

  Future<void> _saveImported() => _prefs.setImported(_imported);

  /// Abre el selector de Android directo en la carpeta de WhatsApp.
  Future<void> _enableFolder() async {
    final picked = await _files.pickWhatsAppFolder();
    if (picked == null || !mounted) return;
    await _prefs.setRootUri(picked);
    _selectedAudios.clear();
    _selectedFolders.clear();
    _folderDocId = null;
    _viewChoice = null;
    _reload();
  }

  // ---- Escuchar ----

  Future<void> _togglePreview(_WaAudio audio) async {
    if (_previewingKey == audio.key) {
      await _stopPreview();
      return;
    }
    setState(() => _previewingKey = audio.key);
    try {
      final player = _previewPlayer ??= BasicPlayer();
      _previewDone ??= player.completed.listen((_) {
        if (mounted) setState(() => _previewingKey = null);
      });
      await player.setSource(audio.song.filePath);
      await player.play();
    } catch (_) {
      if (mounted) setState(() => _previewingKey = null);
      _notify('No se pudo reproducir "${audio.song.title}".');
    }
  }

  Future<void> _stopPreview() async {
    try {
      await _previewPlayer?.stop();
    } catch (_) {}
    if (mounted) setState(() => _previewingKey = null);
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- Qué se ve ----

  _View _viewOf(_Data data) =>
      data.tree == null ? _View.all : (_viewChoice ?? _View.folders);

  String get _query => _search.text.trim().toLowerCase();

  bool _matches(_WaAudio audio) {
    final q = _query;
    if (q.isEmpty) return true;
    return audio.song.title.toLowerCase().contains(q) ||
        (audio.file?.name.toLowerCase().contains(q) ?? false) ||
        (audio.folderName?.toLowerCase().contains(q) ?? false);
  }

  bool _passesFilter(_WaAudio audio) => switch (_filter) {
        _Filter.all => true,
        _Filter.voice => audio.voiceNote,
        _Filter.audio => !audio.voiceNote,
      };

  (List<WaFolder>, List<_WaAudio>) _visible(_Data data) {
    final tree = data.tree;
    if (_viewOf(data) == _View.folders && tree != null) {
      final current = _folderDocId ?? tree.rootDocId;
      if (_query.isEmpty) {
        return (
          tree.subfoldersOf(current),
          [
            for (final file in tree.filesIn(current))
              if (data.byDocId[file.docId] case final audio?) audio,
          ],
        );
      }
      // Buscando: los audios de esta carpeta y de todas las de adentro.
      return (
        [
          for (final folder in tree.subfoldersOf(current))
            if (_folderLabel(folder.name).toLowerCase().contains(_query))
              folder,
        ],
        [
          for (final file in tree.filesUnder(current))
            if (data.byDocId[file.docId] case final audio?)
              if (_matches(audio)) audio,
        ],
      );
    }
    return (
      const [],
      [
        for (final audio in data.audios)
          if (_passesFilter(audio) && _matches(audio)) audio,
      ],
    );
  }

  /// Los audios marcados, contando los de las carpetas marcadas.
  List<_WaAudio> _selectedAudioList(_Data data) {
    final keys = <String>{..._selectedAudios};
    final tree = data.tree;
    if (tree != null) {
      for (final folder in _selectedFolders) {
        keys.addAll(tree.filesUnder(folder).map((f) => f.docId));
      }
    }
    return [
      for (final audio in data.audios)
        if (keys.contains(audio.key)) audio,
    ];
  }

  void _clearSelection() => setState(() {
        _selectedAudios.clear();
        _selectedFolders.clear();
      });

  // ---- Pantalla ----

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Data>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final loading = snapshot.connectionState != ConnectionState.done;
        final view = data == null ? _View.all : _viewOf(data);
        final inSubfolder = !loading &&
            data?.tree != null &&
            view == _View.folders &&
            _folderDocId != null &&
            _folderDocId != data!.tree!.rootDocId;
        final (folders, audios) = data == null || loading
            ? (const <WaFolder>[], const <_WaAudio>[])
            : _visible(data);
        final allMarked = (folders.isNotEmpty || audios.isNotEmpty) &&
            folders.every((f) => _selectedFolders.contains(f.docId)) &&
            audios.every((a) => _selectedAudios.contains(a.key));
        final anySelected =
            _selectedAudios.isNotEmpty || _selectedFolders.isNotEmpty;

        return PopScope(
          canPop: !inSubfolder,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || !inSubfolder) return;
            setState(
                () => _folderDocId = data.tree!.folder(_folderDocId!)?.parent);
          },
          child: Scaffold(
            appBar: AppBar(
              title: const AppHeaderTitle(section: 'Audios de WhatsApp'),
              actions: [
                if (folders.isNotEmpty || audios.isNotEmpty)
                  IconButton(
                    tooltip: allMarked ? 'Desmarcar todos' : 'Marcar todos',
                    icon: Icon(allMarked ? Icons.deselect : Icons.select_all),
                    onPressed: () => setState(() {
                      if (allMarked) {
                        _selectedFolders.removeAll(folders.map((f) => f.docId));
                        _selectedAudios.removeAll(audios.map((a) => a.key));
                      } else {
                        _selectedFolders.addAll(folders.map((f) => f.docId));
                        _selectedAudios.addAll(audios.map((a) => a.key));
                      }
                    }),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Más opciones',
                  onSelected: (value) {
                    if (value == 'reload') _reload();
                    if (value == 'folder') _enableFolder();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'reload',
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('Actualizar'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'folder',
                      child: ListTile(
                        leading: const Icon(Icons.folder_open),
                        title: Text(_rootUri == null
                            ? 'Habilitar carpeta de WhatsApp'
                            : 'Cambiar carpeta de WhatsApp'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            body: loading
                ? const _Loading()
                : snapshot.hasError || data == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                              'No se pudieron leer los audios: ${snapshot.error}',
                              textAlign: TextAlign.center),
                        ),
                      )
                    : _body(data, view, folders, audios),
            bottomNavigationBar:
                anySelected && data != null ? _actionsBar(data) : null,
          ),
        );
      },
    );
  }

  Widget _body(
      _Data data, _View view, List<WaFolder> folders, List<_WaAudio> audios) {
    final theme = Theme.of(context);
    final tree = data.tree;
    return Column(
      children: [
        if (tree == null)
          _EnableFolderCard(error: data.treeError, onEnable: _enableFolder),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<_View>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _View.folders,
                      icon: Icon(Icons.folder_outlined),
                      label: Text('Carpetas'),
                    ),
                    ButtonSegment(
                      value: _View.all,
                      icon: Icon(Icons.library_music_outlined),
                      label: Text('Todos los audios'),
                    ),
                  ],
                  selected: {view},
                  onSelectionChanged: (value) {
                    if (value.first == _View.folders && tree == null) {
                      _notify('Para ver las carpetas, habilitá la carpeta de '
                          'WhatsApp.');
                      return;
                    }
                    setState(() => _viewChoice = value.first);
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: view == _View.folders
                  ? 'Buscar en esta carpeta'
                  : 'Buscar en todos los audios',
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Borrar búsqueda',
                      icon: const Icon(Icons.close),
                      onPressed: _search.clear,
                    ),
            ),
          ),
        ),
        if (view == _View.folders && tree != null)
          _Breadcrumb(
            path: tree.pathTo(_folderDocId ?? tree.rootDocId),
            label: _folderLabel,
            onOpen: (docId) => setState(() => _folderDocId = docId),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  for (final (filter, label) in [
                    (_Filter.all, 'Todos (${data.audios.length})'),
                    (
                      _Filter.voice,
                      'Notas de voz '
                          '(${data.audios.where((a) => a.voiceNote).length})'
                    ),
                    (
                      _Filter.audio,
                      'Audios '
                          '(${data.audios.where((a) => !a.voiceNote).length})'
                    ),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
                ],
              ),
            ),
          ),
        Expanded(
          child: folders.isEmpty && audios.isEmpty
              ? _EmptyState(
                  message: _query.isNotEmpty
                      ? 'Nada coincide con "${_search.text.trim()}".'
                      : view == _View.folders
                          ? 'Esta carpeta no tiene audios.'
                          : 'No se encontraron audios de WhatsApp.',
                )
              : Scrollbar(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
                    children: [
                      for (final folder in folders) _folderTile(tree!, folder),
                      for (final audio in audios)
                        _audioTile(audio,
                            showFolder: view == _View.all || _query.isNotEmpty),
                      if (audios.isNotEmpty || folders.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            [
                              if (folders.isNotEmpty)
                                _plural(folders.length, 'carpeta', 'carpetas'),
                              if (audios.isNotEmpty)
                                _plural(audios.length, 'audio', 'audios'),
                            ].join(' · '),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _folderTile(WaTree tree, WaFolder folder) {
    final count = tree.audioCount(folder.docId);
    return ListTile(
      leading: const Icon(Icons.folder, color: Colors.amber, size: 32),
      title: Text(_folderLabel(folder.name),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${_plural(count, 'audio', 'audios')} · '
          '${formatFileSize(tree.audioBytes(folder.docId))}'),
      trailing: Checkbox(
        value: _selectedFolders.contains(folder.docId),
        onChanged: (checked) => setState(() {
          if (checked ?? false) {
            _selectedFolders.add(folder.docId);
          } else {
            _selectedFolders.remove(folder.docId);
          }
        }),
      ),
      onTap: () => setState(() {
        _folderDocId = folder.docId;
        _search.clear();
      }),
    );
  }

  Widget _audioTile(_WaAudio audio, {required bool showFolder}) {
    final isPreviewing = _previewingKey == audio.key;
    final inLibrary = _imported.contains(audio.key);
    final details = [
      audio.voiceNote ? 'Nota de voz' : 'Audio',
      if (audio.song.duration != null) _formatDuration(audio.song.duration!),
      if (audio.song.duration == null && (audio.size ?? 0) > 0)
        formatFileSize(audio.size!),
      if (audio.date != null) _formatDate(audio.date!),
      if (showFolder && audio.folderName != null) audio.folderName!,
    ].join(' · ');
    return CheckboxListTile(
      value: _selectedAudios.contains(audio.key),
      onChanged: (checked) => setState(() {
        if (checked ?? false) {
          _selectedAudios.add(audio.key);
        } else {
          _selectedAudios.remove(audio.key);
        }
      }),
      secondary: IconButton(
        tooltip: isPreviewing ? 'Detener' : 'Escuchar',
        icon:
            Icon(isPreviewing ? Icons.stop_circle : Icons.play_circle_outline),
        onPressed: () => _togglePreview(audio),
      ),
      title:
          Text(audio.song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(audio.voiceNote ? Icons.mic_none : Icons.music_note,
                  size: 14),
              const SizedBox(width: 4),
              Flexible(child: Text(details, overflow: TextOverflow.ellipsis)),
            ],
          ),
          if (inLibrary)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 14, color: Colors.green),
                  SizedBox(width: 4),
                  Text('En biblioteca',
                      style: TextStyle(color: Colors.green, fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionsBar(_Data data) {
    final audios = _selectedAudioList(data);
    final parts = [
      if (_selectedFolders.isNotEmpty)
        _plural(_selectedFolders.length, 'carpeta', 'carpetas'),
      _plural(audios.length, 'audio', 'audios'),
    ];
    return SafeArea(
      child: Material(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Marcados: ${parts.join(' · ')}',
                        overflow: TextOverflow.ellipsis),
                  ),
                  TextButton(
                    onPressed: _clearSelection,
                    child: const Text('Desmarcar'),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                      onPressed: () => _deleteSelected(data),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Eliminar'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          audios.isEmpty ? null : () => _importSelected(data),
                      icon: const Icon(Icons.library_add),
                      label: const Text('A biblioteca'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Pasar a la biblioteca ----

  Future<void> _importSelected(_Data data) async {
    var toImport = _selectedAudioList(data);
    if (toImport.isEmpty) return;
    final already = toImport.where((a) => _imported.contains(a.key)).length;
    if (already > 0) {
      final fresh = toImport.length - already;
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.library_music, size: 36),
          title: const Text('Algunos ya están en tu biblioteca'),
          content: Text(
              '${_plural(already, 'audio ya se pasó', 'audios ya se pasaron')} '
              'antes. Si los pasás otra vez vas a tener copias repetidas.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('all'),
              child: const Text('Pasar todos'),
            ),
            if (fresh > 0)
              FilledButton(
                onPressed: () => Navigator.of(context).pop('new'),
                child: Text('Solo los nuevos ($fresh)'),
              ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'new') {
        toImport = toImport.where((a) => !_imported.contains(a.key)).toList();
      }
    }
    await _stopPreview();
    if (!mounted) return;

    final importer =
        widget.importAudio ?? WhatsAppImportService().importToLibrary;
    final results = await runWithProgressDialog<_WaAudio>(
      context,
      title: 'Pasando a la biblioteca…',
      icon: Icons.library_add,
      items: toImport,
      labelOf: (audio) => audio.song.title,
      step: (audio) => importer(audio.song),
    );
    final ok = [
      for (final (audio, error) in results)
        if (error == null) audio,
    ];
    final failures = <String>[];
    for (final (audio, error) in results) {
      if (error == null) continue;
      failures.add(error is AppException
          ? error.userMessage
          : '${audio.song.title} — $error');
      ErrorReporter.instance.log(error, StackTrace.current);
    }
    _imported.addAll(ok.map((a) => a.key));
    await _saveImported();
    if (!mounted) return;
    setState(() {
      _selectedAudios.removeAll(ok.map((a) => a.key));
      if (failures.isEmpty) _selectedFolders.clear();
    });
    try {
      await AppProviders.songOf(context).loadSongs();
    } catch (_) {}
    if (!mounted) return;

    await _showResult(
      ok: failures.isEmpty,
      title: failures.isEmpty
          ? 'Listo: ${_plural(ok.length, 'audio pasó', 'audios pasaron')} '
              'a tu biblioteca'
          : 'Pasaron ${ok.length} de ${results.length}',
      lines: [
        if (ok.isNotEmpty)
          'Están en ${WhatsAppImportService.destinationLabel} y ya aparecen '
              'en tu biblioteca. Acá quedan marcados "En biblioteca".',
      ],
      failuresTitle: 'No se pudieron pasar:',
      failures: failures,
    );
  }

  // ---- Eliminar ----

  Future<void> _deleteSelected(_Data data) async {
    final tree = data.tree;
    final root = _rootUri;
    // Las carpetas marcadas (sin las que ya están dentro de otra marcada).
    final folders = tree == null
        ? const <WaFolder>[]
        : [
            for (final id in _selectedFolders)
              if (!_selectedFolders
                  .any((other) => other != id && tree.isInside(id, other)))
                if (tree.folder(id) case final folder?) folder,
          ];
    final marked = [
      for (final audio in data.audios)
        if (_selectedAudios.contains(audio.key)) audio,
    ];
    final files = [
      for (final audio in marked)
        if (audio.deletable &&
            !folders.any((f) => tree!.isInside(audio.file!.parent, f.docId)))
          audio,
    ];
    final notDeletable = marked.where((a) => !a.deletable).length;
    if (tree == null || root == null || (folders.isEmpty && files.isEmpty)) {
      await _showResult(
        ok: false,
        title: 'No se pueden borrar desde acá',
        lines: const [
          'Para borrar audios de WhatsApp, habilitá la carpeta de WhatsApp '
              '(menú de arriba → Habilitar carpeta de WhatsApp).',
        ],
      );
      return;
    }

    final audiosInFolders =
        folders.fold<int>(0, (sum, f) => sum + tree.audioCount(f.docId));
    final others =
        folders.fold<int>(0, (sum, f) => sum + tree.otherFilesCount(f.docId));
    final bytes =
        folders.fold<int>(0, (sum, f) => sum + tree.audioBytes(f.docId)) +
            files.fold<int>(0, (sum, a) => sum + (a.size ?? 0));
    final names = [
      for (final f in folders) '📁 ${_folderLabel(f.name)}',
      for (final a in files) a.song.title,
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon:
            const Icon(Icons.delete_forever, color: Colors.redAccent, size: 40),
        title: const Text('¿Eliminar definitivamente?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (folders.isNotEmpty)
                Text(
                    '•  ${_plural(folders.length, 'carpeta entera', 'carpetas enteras')}, con '
                    '${_plural(audiosInFolders, 'audio', 'audios')}'),
              if (files.isNotEmpty)
                Text('•  ${_plural(files.length, 'audio', 'audios')}'
                    '${folders.isEmpty ? '' : ' sueltos'}'),
              Text('•  Se liberan ${formatFileSize(bytes)}'),
              const SizedBox(height: 8),
              for (final name in names.take(5))
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              if (names.length > 5)
                Text('… y ${names.length - 5} más',
                    style: Theme.of(context).textTheme.bodySmall),
              if (others > 0) ...[
                const SizedBox(height: 10),
                _Warning(
                    'Ojo: ${folders.length == 1 ? 'esa carpeta' : 'esas carpetas'} '
                    'también ${others == 1 ? 'tiene 1 archivo' : 'tienen $others archivos'} '
                    'que no son audio (fotos, videos, documentos) y se '
                    'borran también.'),
              ],
              if (notDeletable > 0) ...[
                const SizedBox(height: 10),
                Text(
                    '${_plural(notDeletable, 'audio marcado no está', 'audios marcados no están')} en la carpeta '
                    'habilitada: no se tocan.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 10),
              const Text(
                'Se borran de WhatsApp y del teléfono. No hay papelera: no '
                'se pueden recuperar.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _stopPreview();
    if (!mounted) return;

    final targets = <(String docId, String label, bool isFolder)>[
      for (final f in folders) (f.docId, _folderLabel(f.name), true),
      for (final a in files) (a.file!.docId, a.song.title, false),
    ];
    final results = await runWithProgressDialog<(String, String, bool)>(
      context,
      title: 'Eliminando…',
      icon: Icons.delete_outline,
      items: targets,
      labelOf: (t) => t.$2,
      step: (t) => _files.delete(root, t.$1),
    );
    final deleted = [
      for (final (target, error) in results)
        if (error == null) target,
    ];
    final failures = [
      for (final (target, error) in results)
        if (error != null) '${target.$2} — $error',
    ];
    final noWrite = results.any((r) =>
        r.$2 is WhatsAppFilesException &&
        (r.$2 as WhatsAppFilesException).noWrite);
    final freed = [
      for (final t in deleted)
        t.$3 ? tree.audioBytes(t.$1) : (data.byDocId[t.$1]?.size ?? 0),
    ].fold<int>(0, (a, b) => a + b);
    if (!mounted) return;
    setState(() {
      for (final t in deleted) {
        _selectedFolders.remove(t.$1);
        _selectedAudios.remove(t.$1);
        if (t.$3) {
          _selectedAudios.removeAll(tree.filesUnder(t.$1).map((f) => f.docId));
          _selectedFolders.removeWhere((id) => tree.isInside(id, t.$1));
        }
      }
      _future = _load();
    });

    await _showResult(
      ok: failures.isEmpty,
      title: failures.isEmpty
          ? (deleted.length == 1
              ? 'Listo: se eliminó 1 elemento'
              : 'Listo: se eliminaron ${deleted.length} elementos')
          : 'Se eliminaron ${deleted.length} de ${results.length}',
      lines: [
        if (deleted.isNotEmpty) 'Se liberaron ${formatFileSize(freed)}.',
        if (noWrite)
          'Android no dio permiso para borrar en esa carpeta. Tocá el menú '
              'de arriba → "Cambiar carpeta de WhatsApp" y volvé a elegirla: '
              'así da permiso para borrar.',
      ],
      failuresTitle: 'No se pudieron eliminar:',
      failures: failures,
    );
  }

  Future<void> _showResult({
    required bool ok,
    required String title,
    List<String> lines = const [],
    String failuresTitle = '',
    List<String> failures = const [],
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle : Icons.warning_amber,
            color: ok ? Colors.green : Colors.amber, size: 40),
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(line),
                ),
              if (failures.isNotEmpty) ...[
                Text(failuresTitle),
                const SizedBox(height: 4),
                for (final failure in failures.take(6))
                  Text('•  $failure', style: const TextStyle(fontSize: 13)),
                if (failures.length > 6) Text('… y ${failures.length - 6} más'),
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

  // ---- Formato ----

  static String _plural(int n, String one, String many) =>
      n == 1 ? '1 $one' : '$n $many';

  /// WhatsApp guarda las notas de voz en una carpeta por semana ("202439"):
  /// se muestra "Semana 39 de 2024".
  static String _folderLabel(String name) {
    final week = RegExp(r'^(\d{4})(\d{2})$').firstMatch(name);
    if (week == null) return name;
    return 'Semana ${int.parse(week.group(2)!)} de ${week.group(1)}';
  }

  static String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}

/// Ruta de carpetas arriba de la lista: se toca una para volver ahí.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.path,
    required this.label,
    required this.onOpen,
  });

  final List<WaFolder> path;
  final String Function(String name) label;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    // La raíz se muestra como "WhatsApp" (la carpeta real se llama Media).
    String nameAt(int i) => i == 0 ? 'WhatsApp' : label(path[i].name);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Subir una carpeta',
            icon: const Icon(Icons.arrow_upward),
            onPressed: path.length < 2
                ? null
                : () => onOpen(path[path.length - 2].docId),
          ),
          Expanded(
            child: BreadcrumbTrail(
              fontSize: 13,
              items: [
                for (var i = 0; i < path.length; i++)
                  (nameAt(i), () => onOpen(path[i].docId)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sin la carpeta de WhatsApp habilitada solo se ven los audios reenviados:
/// ni carpetas, ni notas de voz, ni borrar.
class _EnableFolderCard extends StatelessWidget {
  const _EnableFolderCard({required this.onEnable, this.error});

  final VoidCallback onEnable;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_special_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Habilitá la carpeta de WhatsApp',
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (error != null) ...[
              Text(error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
              const SizedBox(height: 4),
            ],
            Text(
              'Para entrar por las carpetas, ver las notas de voz y poder '
              'borrar: tocá el botón, se abre la carpeta de WhatsApp; ahí '
              'tocá "Usar esta carpeta" y "Permitir". Se hace una sola vez.',
              style: theme.textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onEnable,
                icon: const Icon(Icons.folder_open),
                label: const Text('Habilitar carpeta'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber, color: Colors.amber, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Buscando audios de WhatsApp…'),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
